#!/usr/bin/env python3
"""GlassBridge wire protocol v2: reference framing in Python (PROTOCOL.md section 3).

Standard library only, Python 3.9+. Shared by fake_phone.py, fake_glass.py,
make_test_stream.py and test_e2e.py.

Import it:

    import gbproto
    data = gbproto.encode({"type": "card", "id": "c1", "title": "Hi", "text": "Hello"})
    reader = gbproto.FrameReader()
    for frame in reader.feed(data):          # feed() takes any split, even 1 byte
        print(frame.type, frame.obj, frame.payload)

    writer = gbproto.FrameWriter(sock)       # thread-safe, header+payload atomic
    writer.send({"type": "file_chunk", "id": "a.jpg:5", "offset": 0}, b"ABCDE")

    stream = gbproto.FrameStream(sock)       # blocking reads from a socket
    frame = stream.read()                    # Frame, or None at EOF

Or run it to dump a stream file:

    python3 tools/gbproto.py decode stream.bin [--hex]

Rules implemented (PROTOCOL.md section 3):
  * each frame is one JSON object line ending in \\n; one trailing \\r is stripped;
    blank lines (empty after stripping \\r) are skipped;
  * an integer "bytes": N > 0 means exactly N raw payload bytes follow the \\n.
    "bytes" absent, 0, or not an integer (string, bool, fraction) means no payload;
    a negative number is a protocol error;
  * limits: a line is at most MAX_LINE (65,536) bytes, not counting the \\n or one
    trailing \\r; a payload is at most MAX_PAYLOAD (1,048,576) bytes. Exceeding either
    raises ProtocolError (the caller drops the connection);
  * a line that is not UTF-8 JSON, not an object, or has no string "type" raises
    ProtocolError;
  * payloads are always consumed, whatever the type.

A decoded frame is Frame(obj, payload): obj is the dict exactly as received (including
"bytes" when present) and payload is bytes, or None when the frame carries no payload.
"""

import argparse
import base64
import collections
import json
import sys
import threading
import time

CHUNK = 256 * 1024          # 262,144: keep file chunks at or below this
MAX_LINE = 65536            # bytes in one JSON line, excluding "\n" (and one "\r")
MAX_PAYLOAD = 1048576       # bytes in one payload
PROTOCOL_VERSION = 2
DEFAULT_PORT = 9090


class ProtocolError(Exception):
    """The peer broke the framing rules. Drop the connection.

    When raised by FrameReader.feed(), .frames holds the frames completed in that same
    feed() call before the error (handle them, then drop the connection).
    """

    frames = ()


class Frame(collections.namedtuple("Frame", "obj payload")):
    """One decoded frame: obj (dict) and payload (bytes, or None if there is none)."""

    __slots__ = ()

    @property
    def type(self):
        return self.obj.get("type")

    def get(self, key, default=None):
        return self.obj.get(key, default)


def now_ms():
    """Current wall-clock time in epoch milliseconds (an int)."""
    return int(time.time() * 1000)


def _reject_constant(name):
    raise ValueError("JSON constant %s is not allowed" % name)


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def payload_length(obj):
    """How many payload bytes follow a header object (0 = no payload).

    Raises ProtocolError for a negative "bytes". Does not apply the size limit.
    """
    n = obj.get("bytes")
    if not _is_number(n):
        return 0
    if n < 0:
        raise ProtocolError("negative bytes: %r" % (n,))
    if not _is_int(n):
        return 0  # a fraction is "not an integer": no payload
    return n


def parse_line(line, max_payload=MAX_PAYLOAD):
    """Parse one header line (bytes, without its line ending).

    Returns (obj, payload_length). Raises ProtocolError.
    """
    try:
        text = line.decode("utf-8")
    except UnicodeDecodeError:
        raise ProtocolError("line is not valid UTF-8")
    try:
        obj = json.loads(text, parse_constant=_reject_constant)
    except RecursionError:
        raise ProtocolError("line is nested too deeply")
    except ValueError as e:
        raise ProtocolError("line is not valid JSON: %s" % e)
    if not isinstance(obj, dict):
        raise ProtocolError("line is not a JSON object")
    if not isinstance(obj.get("type"), str):
        raise ProtocolError("frame has no string 'type'")
    n = payload_length(obj)
    if n > max_payload:
        raise ProtocolError("payload of %d bytes exceeds the %d byte limit" % (n, max_payload))
    return obj, n


def encode_line(obj):
    """JSON for one header line (bytes, no newline). 'type' is written first."""
    if not isinstance(obj, dict) or not isinstance(obj.get("type"), str):
        raise ValueError("a frame must be a dict with a string 'type'")
    ordered = {"type": obj["type"]}
    for key, value in obj.items():
        if key != "type":
            ordered[key] = value
    try:
        text = json.dumps(ordered, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
        return text.encode("utf-8")
    except UnicodeEncodeError as e:
        raise ValueError("frame text is not encodable as UTF-8: %s" % e)


def encode(obj, payload=None, check=True):
    """Encode one frame to bytes: JSON line + "\\n" + payload.

    With a payload (bytes-like, may be empty), "bytes" is set to its length.
    Without one, a positive integer "bytes" in obj is refused (it would desync the
    stream). With check=True (default) the line and payload limits are enforced
    (raises ProtocolError); check=False is only for building bad streams in tests.
    """
    if payload is not None:
        payload = bytes(payload)
        obj = dict(obj)
        obj["bytes"] = len(payload)
    elif isinstance(obj, dict) and payload_length(obj) > 0:
        raise ValueError("obj has 'bytes' but no payload was given")
    line = encode_line(obj)
    if check:
        if len(line) > MAX_LINE:
            raise ProtocolError("line of %d bytes exceeds the %d byte limit" % (len(line), MAX_LINE))
        if payload is not None and len(payload) > MAX_PAYLOAD:
            raise ProtocolError("payload of %d bytes exceeds the %d byte limit"
                                % (len(payload), MAX_PAYLOAD))
    if payload:
        return line + b"\n" + payload
    return line + b"\n"


class FrameReader(object):
    """Incremental parser. feed(bytes) returns the list of Frames completed so far.

    Handles any split (reads as small as one byte). After a ProtocolError the reader
    is dead: every later feed() raises the same error.
    """

    def __init__(self, max_line=MAX_LINE, max_payload=MAX_PAYLOAD):
        self.max_line = max_line
        self.max_payload = max_payload
        self._buf = bytearray()
        self._scan = 0        # index in _buf up to which there is no "\n"
        self._header = None   # obj waiting for its payload
        self._need = 0        # payload bytes still expected for _header
        self.error = None

    @property
    def buffered(self):
        """Bytes received but not yet returned as a frame (0 = clean frame boundary)."""
        return len(self._buf)

    def feed(self, data):
        if self.error is not None:
            raise self.error
        frames = []
        try:
            self._feed(data, frames)
        except ProtocolError as e:
            e.frames = tuple(frames)
            self.error = e
            raise
        return frames

    def _feed(self, data, frames):
        buf = self._buf
        buf += data
        pos = 0
        while True:
            if self._header is not None:
                if len(buf) - pos < self._need:
                    break
                payload = bytes(buf[pos:pos + self._need])
                pos += self._need
                frames.append(Frame(self._header, payload))
                self._header = None
                self._need = 0
                continue
            nl = buf.find(b"\n", max(self._scan, pos))
            if nl < 0:
                self._scan = len(buf)
                if len(buf) - pos > self.max_line + 1:  # +1 leaves room for a "\r"
                    raise ProtocolError("line exceeds the %d byte limit" % self.max_line)
                break
            line = bytes(buf[pos:nl])
            pos = nl + 1
            if line.endswith(b"\r"):
                line = line[:-1]
            if len(line) > self.max_line:
                raise ProtocolError("line of %d bytes exceeds the %d byte limit"
                                    % (len(line), self.max_line))
            if not line:
                continue  # blank line
            obj, need = parse_line(line, self.max_payload)
            if need > 0:
                self._header = obj
                self._need = need
            else:
                frames.append(Frame(obj, None))
        if pos:
            del buf[:pos]
            self._scan = max(0, self._scan - pos)


class FrameWriter(object):
    """Thread-safe writer: each frame (header + payload) goes out in one locked write.

    target is a socket (uses sendall) or a binary file-like object (write + flush).
    send() returns the encoded bytes. Socket errors propagate (OSError).
    """

    def __init__(self, target):
        self._lock = threading.Lock()
        self.target = target
        if hasattr(target, "sendall"):
            self._write = target.sendall
        else:
            def _write(data):
                target.write(data)
                if hasattr(target, "flush"):
                    target.flush()
            self._write = _write

    def send(self, obj, payload=None):
        data = encode(obj, payload)
        with self._lock:
            self._write(data)
        return data


class FrameStream(object):
    """Blocking frame reader over a socket: read() returns a Frame, or None at EOF.

    Socket timeouts (socket.timeout) and ProtocolError propagate to the caller.
    """

    def __init__(self, sock, reader=None, bufsize=65536):
        self.sock = sock
        self.reader = reader or FrameReader()
        self.bufsize = bufsize
        self._pending = collections.deque()
        self._error = None
        self.eof = False

    def read(self):
        """Next Frame, or None at EOF. Frames that arrived before a protocol error are
        returned first; the ProtocolError is raised after them."""
        while not self._pending:
            if self._error is not None:
                raise self._error
            if self.eof:
                return None
            data = self.sock.recv(self.bufsize)
            if not data:
                self.eof = True
                return None
            try:
                self._pending.extend(self.reader.feed(data))
            except ProtocolError as e:
                self._pending.extend(e.frames)
                self._error = e
        return self._pending.popleft()

    def __iter__(self):
        while True:
            frame = self.read()
            if frame is None:
                return
            yield frame


def read_frames(sock):
    """Generator of Frames read from a socket until EOF."""
    return iter(FrameStream(sock))


def describe(obj, payload=None, limit=400):
    """Short one-line text for logging a frame."""
    try:
        text = encode_line(obj).decode("utf-8")
    except ValueError:
        text = repr(obj)
    if len(text) > limit:
        text = text[:limit] + "...(%d chars)" % len(text)
    if payload is not None:
        text += " +%d bytes" % len(payload)
    return text


def _main(argv=None):
    parser = argparse.ArgumentParser(
        description="GlassBridge v2 framing reference. Imported by the other tools; "
                    "run directly to dump the frames in a stream file.",
        epilog="Example: python3 tools/gbproto.py decode stream.bin")
    sub = parser.add_subparsers(dest="cmd")
    dec = sub.add_parser("decode", help="print every frame in a stream file")
    dec.add_argument("file")
    dec.add_argument("--hex", action="store_true", help="print payloads as hex (default: base64 prefix)")
    args = parser.parse_args(argv)
    if args.cmd != "decode":
        parser.print_help()
        return 0
    with open(args.file, "rb") as f:
        data = f.read()
    reader = FrameReader()
    try:
        frames = reader.feed(data)
    except ProtocolError as e:
        print("protocol error: %s" % e)
        return 1
    for i, fr in enumerate(frames):
        line = "%3d %s" % (i, describe(fr.obj, fr.payload))
        if fr.payload:
            shown = fr.payload[:32]
            line += "  " + (shown.hex() if args.hex else base64.b64encode(shown).decode("ascii"))
            if len(fr.payload) > 32:
                line += "..."
        print(line)
    if reader.buffered:
        print("warning: %d trailing bytes do not form a complete frame" % reader.buffered)
    print("%d frames" % len(frames))
    return 0


if __name__ == "__main__":
    sys.exit(_main())
