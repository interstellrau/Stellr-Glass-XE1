#!/usr/bin/env python3
"""test_e2e.py: automated checks for the Python tools (no hardware needed).

Standard library only, Python 3.9+. Exits non-zero if anything fails.

    python3 tools/test_e2e.py                  # everything (about a minute)
    python3 tools/test_e2e.py -k Pairing       # only tests whose name contains "Pairing"
    python3 tools/test_e2e.py -v               # one line per test

What it covers:
  GbprotoTests       framing: every frame of a tricky stream round-trips with reads split at
                     every size (1 byte up) and at every split point; CRLF; blank lines;
                     payloads with newlines/JSON; line and payload limits (exact limit ok,
                     one over rejected); bad lines; "bytes" variants; FrameWriter atomicity
                     under 4 threads; FrameStream over a socket.
  StreamToolTests    make_test_stream.py write/verify/reencode, and verify catching changed
                     text, payload bytes, numbers, bool-vs-number, a missing frame, garbage.
  SessionTests       fake_glass.py against fake_phone.py: pairing, status, an upload of
                     700,000 random bytes arriving byte-identical in received/, a duplicate
                     re-upload acked ok and discarded, cards + acks, notify, dismiss, speak, nav,
                     navend, loc, wifi, status/request_status, ping, cast on/off with frames
                     saved byte-identical, sync off/on, name, queued cards; MediaReceiver
                     errors ("chunks out of order", "size mismatch", "unknown transfer").
  PairingTests       PROTOCOL.md section 6: pair inside the window and save the token; reconnect
                     with it; rejected pairing_required / bad_token; unauthenticated and silent
                     connections don't disturb the accepted session; hello timeout; a newer
                     waiting connection replaces an older one; replacement only on acceptance;
                     ping answered before hello; payloads consumed before acceptance; forget;
                     pair again.
  SelftestTests      fake_phone.py --selftest driven by a client that follows the documented
                     script exactly (what the Kotlin LiveLinkTest relies on).
  HeartbeatTests     phone pings after silence and drops at the dead time; fake_glass pings,
                     drops, reconnects 2 s after a session, 5 s after 'rejected', and backs off
                     2, 4, 8 s when the phone is unreachable.
  GlassAdbTests      glass_adb.py against a stub adb: config read-modify-write, config-clear,
                     invert-swipe, wifi.json, install advice, screen, status.
  HelpTests          every script's --help.
"""

import base64
import hashlib
import json
import os
import random
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)
import gbproto  # noqa: E402
import make_test_stream  # noqa: E402
from gbproto import Frame, FrameReader, ProtocolError, encode  # noqa: E402

PY = sys.executable
FAKE_PHONE = os.path.join(TOOLS, "fake_phone.py")
FAKE_GLASS = os.path.join(TOOLS, "fake_glass.py")
STREAM_TOOL = os.path.join(TOOLS, "make_test_stream.py")
GLASS_ADB = os.path.join(TOOLS, "glass_adb.py")
HEX32 = re.compile(r"^[0-9a-f]{32}$")
CHILD_ENV = dict(os.environ, PYTHONIOENCODING="utf-8", PYTHONUNBUFFERED="1")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def det_bytes(n, seed):
    return make_test_stream._det_bytes(n, seed)


def parse_all(data, sizes=None):
    """Parse data fed in pieces of the given sizes (cycled); returns frames."""
    reader = FrameReader()
    frames = []
    if sizes is None:
        frames.extend(reader.feed(data))
    else:
        i = 0
        k = 0
        while i < len(data):
            n = sizes[k % len(sizes)]
            frames.extend(reader.feed(data[i:i + n]))
            i += n
            k += 1
    assert reader.buffered == 0, "%d bytes left over" % reader.buffered
    return frames


class Proc(object):
    """A tool run as a subprocess, with its output collected line by line."""

    def __init__(self, args, cwd, name):
        self.name = name
        self.p = subprocess.Popen([PY, "-u"] + args, cwd=cwd, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=CHILD_ENV)
        self.lines = []
        self.done = False
        self.cond = threading.Condition()
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        for raw in self.p.stdout:
            with self.cond:
                self.lines.append(raw.decode("utf-8", "replace").rstrip("\r\n"))
                self.cond.notify_all()
        with self.cond:
            self.done = True
            self.cond.notify_all()

    def mark(self):
        with self.cond:
            return len(self.lines)

    def wait_for(self, pattern, timeout=10.0, since=0):
        rx = re.compile(pattern)
        deadline = time.monotonic() + timeout
        with self.cond:
            while True:
                for i in range(since, len(self.lines)):
                    m = rx.search(self.lines[i])
                    if m:
                        return m
                remaining = deadline - time.monotonic()
                if remaining <= 0 or self.done:
                    raise AssertionError("%s: no line matching %r within %gs. Last lines:\n%s" % (
                        self.name, pattern, timeout, "\n".join(self.lines[-25:])))
                self.cond.wait(remaining)

    def has(self, pattern, since=0):
        rx = re.compile(pattern)
        with self.cond:
            return any(rx.search(l) for l in self.lines[since:])

    def send(self, line):
        self.p.stdin.write((line + "\n").encode("utf-8"))
        self.p.stdin.flush()

    def text(self):
        with self.cond:
            return "\n".join(self.lines)

    def wait(self, timeout=10.0):
        return self.p.wait(timeout)

    def stop(self):
        if self.p.poll() is None:
            self.p.terminate()
            try:
                self.p.wait(5)
            except subprocess.TimeoutExpired:
                self.p.kill()
                self.p.wait(5)
        for f in (self.p.stdin, self.p.stdout):
            try:
                f.close()
            except OSError:
                pass


def start_phone(cwd, *extra):
    port = free_port()
    phone = Proc([FAKE_PHONE, "--port", str(port)] + list(extra), cwd, "fake_phone")
    phone.wait_for(r"Listening on .*:%d" % port, timeout=10)
    return phone, port


def run_glass(cwd, port, *extra, **kw):
    p = subprocess.run([PY, "-u", FAKE_GLASS, "127.0.0.1", "--port", str(port)] + list(extra),
                       cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=CHILD_ENV,
                       timeout=kw.get("timeout", 30))
    return p.returncode, p.stdout.decode("utf-8", "replace")


class Client(object):
    """A raw protocol client built on gbproto, for precise tests."""

    def __init__(self, port, timeout=5.0):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        self.stream = gbproto.FrameStream(self.sock)
        self.writer = gbproto.FrameWriter(self.sock)
        self.log = []

    def send(self, obj, payload=None):
        self.writer.send(obj, payload)

    def next_frame(self, timeout=5.0, skip_pings=True):
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError("no frame within %gs (got so far: %s)" % (
                    timeout, [f.type for f in self.log[-10:]]))
            self.sock.settimeout(remaining)
            try:
                frame = self.stream.read()
            except socket.timeout:
                continue
            if frame is None:
                raise AssertionError("connection closed while waiting for a frame (got: %s)"
                                     % [f.type for f in self.log[-10:]])
            self.log.append(frame)
            if skip_pings and frame.type == "ping":
                self.send({"type": "pong"})
                continue
            return frame

    def expect(self, ftype, timeout=5.0, skip_pings=True):
        frame = self.next_frame(timeout, skip_pings)
        if frame.type != ftype:
            raise AssertionError("expected %s, got %s" % (ftype, gbproto.describe(frame.obj)))
        return frame

    def expect_closed(self, timeout=5.0):
        """Wait for EOF/reset, ignoring frames. Returns seconds waited."""
        start = time.monotonic()
        deadline = start + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError("connection still open after %gs" % timeout)
            self.sock.settimeout(remaining)
            try:
                frame = self.stream.read()
            except socket.timeout:
                continue
            except (ConnectionResetError, OSError):
                return time.monotonic() - start
            if frame is None:
                return time.monotonic() - start
            self.log.append(frame)

    def alive(self, timeout=3.0):
        """True if a ping is answered with pong."""
        try:
            self.send({"type": "ping"})
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                f = self.next_frame(deadline - time.monotonic())
                if f.type == "pong":
                    return True
        except (AssertionError, OSError):
            return False
        return False

    def hello(self, token=None):
        h = {"type": "hello", "device": "glass-explorer", "version": 2, "model": "Test",
             "firmware": "XE24", "app_version": "test"}
        if token is not None:
            h["token"] = token
        self.send(h)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def small_tricky_stream():
    """A ~1.5 KB stream with every framing feature, plus its expected frames."""
    parts = []
    expected = []

    def add(obj, payload=None, eol=b"\n", blank=b""):
        parts.append(blank)
        if payload is not None:
            obj = dict(obj, bytes=len(payload))
        parts.append(json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + eol)
        if payload is not None:
            parts.append(payload)
        expected.append(Frame(obj, payload))

    add({"type": "hello", "device": "glass-explorer", "version": 2}, blank=b"\r\n")
    add({"type": "card", "id": "c1", "title": "Café \U0001F680", "text": "a\nb \"q\" \\"}, eol=b"\r\n")
    add({"type": "file_chunk", "id": "f:9", "offset": 0},
        b'{"type":"ping"}\n\r\n\n{"x":1}\r', eol=b"\r\n")
    add({"type": "file_chunk", "id": "f:9", "offset": 5, "bytes": 0})
    add({"type": "ping"}, blank=b"\n\n\r\n")
    add({"type": "x_unknown", "z": [1, {"a": None}]}, b"\n\n\n")
    add({"type": "frame", "w": 640, "h": 360}, bytes(range(256)) * 2, blank=b"\n")
    add({"type": "nav", "distance_m": 12.5, "step": 1, "time": 1793491200123}, eol=b"\r\n")
    add({"type": "pong"}, b"\r")
    add({"type": "end"}, eol=b"\r\n")
    return b"".join(parts), expected


# =====================================================================================
class GbprotoTests(unittest.TestCase):

    def assertFrames(self, got, expected):
        self.assertEqual(len(got), len(expected))
        for g, e in zip(got, expected):
            self.assertEqual(g.obj, e.obj)
            self.assertEqual(g.payload, e.payload)

    def test_every_read_size_and_split_point(self):
        data, expected = small_tricky_stream()
        self.assertGreater(len(data), 1000)
        for size in range(1, len(data) + 1):
            self.assertFrames(parse_all(data, [size]), expected)
        for cut in range(len(data) + 1):
            reader = FrameReader()
            got = reader.feed(data[:cut]) + reader.feed(data[cut:])
            self.assertFrames(got, expected)
            self.assertEqual(reader.buffered, 0)

    def test_big_stream_odd_splits(self):
        data, frames = make_test_stream.build()
        expected = [Frame(o, p) for (o, p, _n) in frames]
        rng = random.Random(7)
        plans = [[1], [2], [3], [7], [4096], [65536], [gbproto.CHUNK], [10 ** 7],
                 [rng.randint(1, 70000) for _ in range(50)],
                 [rng.randint(1, 9) for _ in range(50)]]
        for plan in plans:
            self.assertFrames(parse_all(data, plan), expected)

    def test_encode_round_trip(self):
        frames = [
            Frame({"type": "hello", "device": "glass-explorer", "version": 2, "token": "ab" * 16}, None),
            Frame({"type": "card", "id": "c", "title": "東京", "text": "line1\nline2\r\n"}, None),
            Frame({"type": "file_chunk", "id": "a:3", "offset": 0, "bytes": 3}, b"\n\r\n"),
            Frame({"type": "frame", "w": 1, "h": 1, "bytes": gbproto.CHUNK}, det_bytes(gbproto.CHUNK, "x")),
            Frame({"type": "x", "bytes": 0}, None),
        ]
        data = b""
        for f in frames:
            obj = {k: v for k, v in f.obj.items() if k != "bytes"} if f.payload is not None else f.obj
            data += encode(obj, f.payload)
        self.assertFrames(parse_all(data, [1]), frames)
        self.assertFrames(parse_all(data), frames)
        self.assertTrue(encode({"type": "ping"}).startswith(b'{"type":"ping"}'))
        self.assertEqual(encode({"id": 1, "type": "t"}), b'{"type":"t","id":1}\n')  # type first

    def test_crlf_and_blank_lines(self):
        data = b'\r\n\n{"type":"a"}\r\n\r\n\r\n{"type":"b","bytes":4}\r\n\r\n\r\n{"type":"c"}\n'
        got = parse_all(data, [1])
        self.assertEqual([f.type for f in got], ["a", "b", "c"])
        self.assertEqual(got[1].payload, b"\r\n\r\n")   # the payload keeps its CRLFs
        got = parse_all(b'{"type":"a"}\r\r\n')       # one \r stripped; the other is JSON whitespace
        self.assertEqual(got[0].type, "a")

    def test_line_limit(self):
        def line_of(n):
            pad = n - len(b'{"type":"x","p":""}')
            return b'{"type":"x","p":"' + b"a" * pad + b'"}'
        exact = line_of(gbproto.MAX_LINE)
        self.assertEqual(len(exact), gbproto.MAX_LINE)
        self.assertEqual(len(parse_all(exact + b"\n")), 1)
        self.assertEqual(len(parse_all(exact + b"\r\n", [1000])), 1)
        with self.assertRaises(ProtocolError):
            parse_all(line_of(gbproto.MAX_LINE + 1) + b"\n")
        reader = FrameReader()                        # no newline: rejected while still reading
        with self.assertRaises(ProtocolError):
            reader.feed(b"{" + b" " * (gbproto.MAX_LINE + 5))
        with self.assertRaises(ProtocolError):        # and the reader stays dead
            reader.feed(b'{"type":"ping"}\n')
        reader = FrameReader()
        with self.assertRaises(ProtocolError):
            for i in range(0, gbproto.MAX_LINE + 10, 997):
                reader.feed(b"a" * 997)

    def test_payload_limit(self):
        ok = b'{"type":"f","bytes":%d}\n' % gbproto.MAX_PAYLOAD + b"z" * gbproto.MAX_PAYLOAD
        got = parse_all(ok, [300000])
        self.assertEqual(len(got[0].payload), gbproto.MAX_PAYLOAD)
        with self.assertRaises(ProtocolError):       # rejected at the header, before any payload
            FrameReader().feed(b'{"type":"f","bytes":%d}\n' % (gbproto.MAX_PAYLOAD + 1))

    def test_bad_lines(self):
        bad = [b"[1,2]", b'"text"', b"5", b"null", b"true", b'{"id":"no type"}', b'{"type":5}',
               b'{"type":null}', b"{not json}", b'{"type":"a"', b'\xff\xfe{"type":"a"}',
               b'{"type":"a","v":NaN}', b"[" * 5000 + b"]" * 5000, b"   "]
        for line in bad:
            with self.assertRaises(ProtocolError, msg=repr(line[:40])):
                parse_all(line + b"\n")

    def test_frames_before_an_error_are_kept(self):
        reader = FrameReader()
        with self.assertRaises(ProtocolError) as cm:
            reader.feed(b'{"type":"a"}\n{"type":"b","bytes":2}\nxy[1]\n')
        self.assertEqual([f.type for f in cm.exception.frames], ["a", "b"])
        a, b = socket.socketpair()
        a.sendall(b'{"type":"ok"}\n{"type":"bad","bytes":-5}\n')
        stream = gbproto.FrameStream(b)
        self.assertEqual(stream.read().type, "ok")
        with self.assertRaises(ProtocolError):
            stream.read()
        a.close()
        b.close()

    def test_bytes_field_variants(self):
        for field in [b"", b',"bytes":0', b',"bytes":"5"', b',"bytes":true', b',"bytes":2.5',
                      b',"bytes":null', b',"bytes":[5]']:
            data = b'{"type":"a"' + field + b'}\n{"type":"b"}\n'
            got = parse_all(data)
            self.assertEqual([f.type for f in got], ["a", "b"], field)
            self.assertIsNone(got[0].payload)
        for field in [b',"bytes":-1', b',"bytes":-0.5']:
            with self.assertRaises(ProtocolError):
                parse_all(b'{"type":"a"' + field + b'}\n')

    def test_encode_checks(self):
        with self.assertRaises(ProtocolError):
            encode({"type": "f"}, b"x" * (gbproto.MAX_PAYLOAD + 1))
        with self.assertRaises(ProtocolError):
            encode({"type": "c", "text": "y" * gbproto.MAX_LINE})
        with self.assertRaises(ValueError):
            encode({"type": "f", "bytes": 3})
        with self.assertRaises(ValueError):
            encode({"no": "type"})
        with self.assertRaises(ValueError):
            encode(["type"])
        self.assertEqual(encode({"type": "f"}, b""), b'{"type":"f","bytes":0}\n')

    def test_writer_is_atomic_across_threads(self):
        a, b = socket.socketpair()
        writer = gbproto.FrameWriter(a)
        per_thread = 25

        def spam(tid):
            for seq in range(per_thread):
                payload = det_bytes(50000 + tid * 1000 + seq, "t%d-%d" % (tid, seq))
                writer.send({"type": "file_chunk", "t": tid, "seq": seq,
                             "sha": hashlib.sha256(payload).hexdigest()}, payload)

        threads = [threading.Thread(target=spam, args=(t,)) for t in range(4)]
        got = []

        def read():
            for fr in gbproto.FrameStream(b):
                got.append(fr)
                if len(got) == 4 * per_thread:
                    return

        reader = threading.Thread(target=read)
        reader.start()
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        reader.join(30)
        a.close()
        b.close()
        self.assertEqual(len(got), 4 * per_thread)
        for fr in got:
            self.assertEqual(hashlib.sha256(fr.payload).hexdigest(), fr.obj["sha"])
        for tid in range(4):
            self.assertEqual([f.obj["seq"] for f in got if f.obj["t"] == tid], list(range(per_thread)))

    def test_frame_stream_over_socket(self):
        a, b = socket.socketpair()
        data, expected = small_tricky_stream()

        def trickle():
            for i in range(0, len(data), 7):
                a.sendall(data[i:i + 7])
            a.shutdown(socket.SHUT_WR)

        threading.Thread(target=trickle).start()
        got = list(gbproto.read_frames(b))
        a.close()
        b.close()
        self.assertFrames(got, expected)


# =====================================================================================
class StreamToolTests(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="gbtest-stream-")
        self.stream = os.path.join(self.dir, "stream.bin")
        self.expected = os.path.join(self.dir, "expected.json")
        rc, out = self.tool("write", self.stream, self.expected)
        self.assertEqual(rc, 0, out)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def tool(self, *args):
        p = subprocess.run([PY, STREAM_TOOL] + list(args), stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, env=CHILD_ENV, timeout=60)
        return p.returncode, p.stdout.decode("utf-8", "replace")

    def frames(self):
        with open(self.stream, "rb") as f:
            return parse_all(f.read())

    def write_variant(self, frames, name):
        path = os.path.join(self.dir, name)
        with open(path, "wb") as f:
            for fr in frames:
                obj = {k: v for k, v in fr.obj.items() if k != "bytes"}
                f.write(encode(obj, fr.payload))
        return path

    def test_expected_file_format(self):
        with open(self.expected) as f:
            doc = json.load(f)
        self.assertEqual(doc["format"], "glassbridge-test-stream")
        self.assertEqual(doc["frame_count"], len(doc["frames"]))
        with open(self.stream, "rb") as f:
            data = f.read()
        self.assertEqual(doc["stream_sha256"], hashlib.sha256(data).hexdigest())
        lens = [fr["payload_len"] for fr in doc["frames"]]
        self.assertIn(gbproto.CHUNK, lens)
        self.assertIn(b"\r\n", data)
        self.assertIn(b"\n\n", data)
        types = {fr["obj"]["type"] for fr in doc["frames"]}
        for t in ["hello", "welcome", "rejected", "ping", "pong", "status", "request_status", "card",
                  "dismiss", "speak", "ack", "nav", "nav_end", "location", "sync", "file_begin",
                  "file_chunk", "file_end", "file_ack", "screencast", "frame", "wifi_add",
                  "wifi_result"]:
            self.assertIn(t, types)
        for fr in doc["frames"]:
            if fr["payload_b64"] is not None:
                self.assertEqual(len(base64.b64decode(fr["payload_b64"])), fr["payload_len"])

    def test_verify_accepts_original_and_reencoded(self):
        rc, out = self.tool("verify", self.stream, self.expected)
        self.assertEqual(rc, 0, out)
        self.assertIn("OK: ", out)
        re_path = os.path.join(self.dir, "re.bin")
        rc, out = self.tool("reencode", self.stream, re_path)
        self.assertEqual(rc, 0, out)
        rc, out = self.tool("verify", re_path, self.expected)
        self.assertEqual(rc, 0, out)
        # Another encoder's style: escaped non-ASCII, spaces, CRLF, integers written as floats.
        path = os.path.join(self.dir, "styled.bin")
        with open(path, "wb") as f:
            for fr in self.frames():
                obj = {k: (float(v) if isinstance(v, int) and not isinstance(v, bool) and k != "bytes"
                           else v) for k, v in fr.obj.items()}
                if fr.payload is not None:
                    obj["bytes"] = len(fr.payload)
                else:
                    obj.pop("bytes", None)
                f.write(json.dumps(obj, ensure_ascii=True).replace("/", "\\/").encode("ascii") + b"\r\n")
                if fr.payload:
                    f.write(fr.payload)
        rc, out = self.tool("verify", path, self.expected)
        self.assertEqual(rc, 0, out)

    def test_verify_catches_mismatches(self):
        def variant(mutate, name):
            frames = [Frame(dict(f.obj), f.payload) for f in self.frames()]
            mutate(frames)
            return self.write_variant(frames, name)

        def change_text(frames):
            frames[3].obj["text"] += "!"

        def flip_payload(frames):
            i = next(i for i, f in enumerate(frames) if f.payload and len(f.payload) == gbproto.CHUNK)
            p = bytearray(frames[i].payload)
            p[100000] ^= 1
            frames[i] = Frame(frames[i].obj, bytes(p))

        def change_number(frames):
            frames[2].obj["battery"] = 88

        def bool_to_number(frames):
            frames[2].obj["charging"] = 0

        def change_float(frames):
            loc = next(f for f in frames if f.type == "location")
            loc.obj["lat"] += 0.0001

        def int_to_string(frames):
            frames[2].obj["battery"] = "87"

        def drop_last(frames):
            frames.pop()

        def drop_field(frames):
            del frames[1].obj["pair_code"]

        def extra_field(frames):
            frames[0].obj["surprise"] = 1

        for mutate in (change_text, flip_payload, change_number, bool_to_number, change_float,
                       int_to_string, drop_last, drop_field, extra_field):
            path = variant(mutate, mutate.__name__ + ".bin")
            rc, out = self.tool("verify", path, self.expected)
            self.assertEqual(rc, 1, "%s should fail:\n%s" % (mutate.__name__, out))
            self.assertIn("FAIL", out)
        garbage = os.path.join(self.dir, "garbage.bin")
        with open(garbage, "wb") as f:
            f.write(b"not a frame stream\n")
        rc, out = self.tool("verify", garbage, self.expected)
        self.assertEqual(rc, 1, out)


# =====================================================================================
class ToolTestCase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="gbtest-")
        self.procs = []
        self.clients = []

    def tearDown(self):
        for c in self.clients:
            c.close()
        for p in self.procs:
            p.stop()
        shutil.rmtree(self.dir, ignore_errors=True)

    def phone(self, *extra):
        phone, port = start_phone(self.dir, *extra)
        self.procs.append(phone)
        return phone, port

    def client(self, port):
        c = Client(port)
        self.clients.append(c)
        return c

    def glass_proc(self, port, *extra):
        p = Proc([FAKE_GLASS, "127.0.0.1", "--port", str(port)] + list(extra), self.dir, "fake_glass")
        self.procs.append(p)
        return p


class SessionTests(ToolTestCase):

    def test_full_session(self):
        upload = os.path.join(self.dir, "IMG_TEST.jpg")
        data = os.urandom(700000)
        with open(upload, "wb") as f:
            f.write(data)
        shot = os.path.join(self.dir, "shot.jpg")
        shot_bytes = b"\xff\xd8\xff\xe0" + os.urandom(3000) + b"\xff\xd9"
        with open(shot, "wb") as f:
            f.write(shot_bytes)
        phone, port = self.phone()
        phone.send("card Early | queued before Glass connects")
        phone.wait_for(r"card c-[0-9a-f]{8} queued")
        glass = self.glass_proc(port, "--upload", upload, "--frame", shot, "--duration", "60")

        code = glass.wait_for(r"Paired with fake_phone, code (\d{4})").group(1)
        phone.wait_for(r"PAIRED new Glass .*code %s\." % code)
        glass.wait_for(r"Token saved to .*fake_glass_token\.txt")
        with open(os.path.join(self.dir, "fake_glass_token.txt")) as f:
            self.assertRegex(f.read().strip(), HEX32)
        glass.wait_for(r"CARD \[c-[0-9a-f]{8}\] Early \| queued before Glass connects")
        phone.wait_for(r"STATUS battery 87%")

        # Upload: 700,000 bytes in 3 chunks, byte-identical in received/.
        glass.wait_for(r"Upload IMG_TEST\.jpg:700000: ok sha256 matches", timeout=20)
        phone.wait_for(r"Upload IMG_TEST\.jpg:700000 saved to")
        self.assertEqual(phone.text().count('"type":"file_chunk"'), 3)
        with open(os.path.join(self.dir, "received", "IMG_TEST.jpg"), "rb") as f:
            self.assertEqual(f.read(), data)

        m = phone.mark()
        g = glass.mark()
        phone.send("card Hello | World — café")
        cid = glass.wait_for(r"CARD \[(c-[0-9a-f]{8})\] Hello \| World — café \(info\)", since=g).group(1)
        phone.wait_for(r"ACK %s shown" % cid, since=m)
        phone.send("notify Messages | Dinner at 7?")
        nid = glass.wait_for(r"CARD \[(c-[0-9a-f]{8})\] Messages \| Dinner at 7\? \(notification\)", since=g).group(1)
        phone.wait_for(r"ACK %s shown" % nid, since=m)
        phone.wait_for(r'"style":"notification","chime":true,"wake":true', since=m)
        phone.send("dismiss %s" % cid)
        glass.wait_for(r"DISMISS %s" % cid, since=g)
        phone.send("speak Turn left in 100 metres")
        glass.wait_for(r"SPEAK Turn left in 100 metres", since=g)
        phone.send("nav left 120 Turn left onto King William St")
        glass.wait_for(r"NAV step 1/5 left 120 m: Turn left onto King William St \(announce\)", since=g)
        phone.send("nav left 40 Turn left onto King William St")
        glass.wait_for(r"NAV step 1/5 left 40 m: Turn left onto King William St$", since=g)
        phone.send("nav arrive 0 You have arrived")
        glass.wait_for(r"NAV step 2/5 arrive 0 m: You have arrived \(announce\)", since=g)
        phone.send("navend")
        glass.wait_for(r"NAV ended", since=g)
        phone.send("loc -34.9285 138.6007")
        glass.wait_for(r"LOCATION -34\.9285, 138\.6007", since=g)
        phone.send('wifi "Home Net" secret123')
        glass.wait_for(r"WIFI_ADD Home Net \(WPA\)", since=g)
        phone.wait_for(r"WIFI Home Net: ok", since=m)
        m = phone.mark()
        phone.send("status")
        phone.wait_for(r"Link: Glass #\d+ .* connected", since=m)
        phone.wait_for(r"Pairing: paired \(code %s\), window closed" % code, since=m)
        glass.wait_for(r'<- \{"type":"request_status"\}', since=g)
        phone.wait_for(r'<- \[\d+\] \{"type":"status"', since=m)
        m = phone.mark()
        phone.send("ping")
        phone.wait_for(r'<- \[\d+\] \{"type":"pong"\}', since=m)

        # Screencast: frames saved byte-identical, and they stop after cast off.
        phone.send("cast on 5")
        glass.wait_for(r"SCREENCAST on at 5 fps", since=g)
        phone.wait_for(r"Frame 1 saved to .*frame-000001\.jpg", timeout=10)
        frame_line = '{"type":"frame","w":640,"h":360,"bytes":%d}' % len(shot_bytes)
        deadline = time.monotonic() + 10
        while phone.text().count(frame_line) < 3:
            self.assertLess(time.monotonic(), deadline, "fewer than 3 frames arrived")
            time.sleep(0.1)
        saved = os.listdir(os.path.join(self.dir, "received", "frames"))
        for name in ("frame-000001.jpg", "frame-000002.jpg", "latest.jpg", "view.html"):
            self.assertIn(name, saved)
        with open(os.path.join(self.dir, "received", "frames", "latest.jpg"), "rb") as f:
            self.assertEqual(f.read(), shot_bytes)
        self.assertTrue(os.path.exists(os.path.join(self.dir, "received", "frames", "view.html")))
        phone.send("cast off")
        glass.wait_for(r"SCREENCAST off", since=g)
        time.sleep(0.6)
        m = phone.mark()
        time.sleep(1.0)
        self.assertFalse(phone.has(r'"type":"frame"', since=m), "frames still arriving after cast off")

        phone.send("sync off")
        glass.wait_for(r"SYNC disabled", since=g)
        phone.send("sync on")
        glass.wait_for(r"SYNC enabled", since=g + 1)
        phone.send("raw {\"type\":\"x_future\",\"note\":\"unknown types are ignored\"}")
        glass.wait_for(r"Ignored unknown type 'x_future'", since=g)
        phone.send("name Alexander's iPhone")
        phone.wait_for(r"Phone name is now")
        phone.send("quit")
        self.assertEqual(phone.wait(10), 0)
        glass.wait_for(r"Disconnected", since=g)
        glass.stop()

    def test_duplicate_reupload_is_acked_and_discarded(self):
        upload = os.path.join(self.dir, "VID_0001.mp4")
        data = os.urandom(300000)
        with open(upload, "wb") as f:
            f.write(data)
        phone, port = self.phone("--no-auth")
        for attempt in range(2):
            rc, out = run_glass(self.dir, port, "--upload", upload, "--exit-after-upload", "--no-token")
            self.assertEqual(rc, 0, out)
            self.assertIn("Upload VID_0001.mp4:300000: ok", out)
            self.assertIn('"mime":"video/mp4"', out)
        phone.wait_for(r"duplicate of a saved file, discarded, acked ok")
        files = sorted(os.listdir(os.path.join(self.dir, "received")))
        self.assertEqual(files, ["VID_0001.mp4"])
        # The id is remembered across restarts too (files already in received/).
        phone.stop()
        phone2, port2 = self.phone("--no-auth")
        rc, out = run_glass(self.dir, port2, "--upload", upload, "--exit-after-upload", "--no-token")
        self.assertEqual(rc, 0, out)
        phone2.wait_for(r"duplicate of a saved file")
        self.assertEqual(sorted(os.listdir(os.path.join(self.dir, "received"))), ["VID_0001.mp4"])

    def test_media_receiver_errors(self):
        phone, port = self.phone("--no-auth")
        c = self.client(port)
        c.hello()
        c.expect("welcome")
        c.expect("sync")
        c.send({"type": "file_begin", "id": "a.jpg:10", "name": "a.jpg", "size": 10, "mime": "image/jpeg",
                "taken": 1})
        c.send({"type": "file_chunk", "id": "a.jpg:10", "offset": 0}, b"12345")
        c.send({"type": "file_chunk", "id": "a.jpg:10", "offset": 7}, b"67890")
        c.send({"type": "file_end", "id": "a.jpg:10"})
        ack = c.expect("file_ack")
        self.assertEqual((ack.get("ok"), ack.get("error")), (False, "chunks out of order"))
        c.send({"type": "file_begin", "id": "b.jpg:10", "name": "b.jpg", "size": 10, "mime": "image/jpeg",
                "taken": 1})
        c.send({"type": "file_chunk", "id": "b.jpg:10", "offset": 0}, b"12345")
        c.send({"type": "file_end", "id": "b.jpg:10"})
        ack = c.expect("file_ack")
        self.assertEqual((ack.get("ok"), ack.get("error")), (False, "size mismatch"))
        c.send({"type": "file_end", "id": "nothing:1"})
        ack = c.expect("file_ack")
        self.assertEqual((ack.get("ok"), ack.get("error")), (False, "unknown transfer"))
        payload = b"\n" * 3 + b'{"type":"ping"}\n' + b"x" * 11
        c.send({"type": "file_begin", "id": "c.jpg:%d" % len(payload), "name": "../c.jpg",
                "size": len(payload), "mime": "image/jpeg", "taken": 1})
        c.send({"type": "file_chunk", "id": "c.jpg:%d" % len(payload), "offset": 0}, payload)
        c.send({"type": "file_end", "id": "c.jpg:%d" % len(payload)})
        ack = c.expect("file_ack")
        self.assertTrue(ack.get("ok"))
        self.assertEqual(ack.get("sha256"), hashlib.sha256(payload).hexdigest())
        self.assertEqual(ack.get("received"), len(payload))
        with open(os.path.join(self.dir, "received", "c.jpg"), "rb") as f:
            self.assertEqual(f.read(), payload)
        self.assertEqual(sorted(os.listdir(os.path.join(self.dir, "received"))), ["c.jpg"])
        # An abandoned partial upload is deleted when the link drops.
        c.send({"type": "file_begin", "id": "d.jpg:100", "name": "d.jpg", "size": 100, "mime": "image/jpeg",
                "taken": 1})
        c.send({"type": "file_chunk", "id": "d.jpg:100", "offset": 0}, b"x" * 50)
        self.assertTrue(c.alive())
        c.close()
        phone.wait_for(r"Upload d\.jpg:100 abandoned")
        self.assertEqual(sorted(os.listdir(os.path.join(self.dir, "received"))), ["c.jpg"])


# =====================================================================================
class PairingTests(ToolTestCase):

    def test_pairing_flow(self):
        phone, port = self.phone("--hello-timeout", "2")
        token_file = os.path.join(self.dir, "fake_glass_token.txt")

        # 1. First connection inside the start-up window: paired, token saved, codes match.
        rc, out = run_glass(self.dir, port, "--exit-after-welcome")
        self.assertEqual(rc, 0, out)
        code = re.search(r"Paired with fake_phone, code (\d{4})", out).group(1)
        phone.wait_for(r"PAIRED new Glass .*code %s\." % code)
        with open(token_file) as f:
            token = f.read().strip()
        self.assertRegex(token, HEX32)
        self.assertIn('"pair_token":"%s"' % token, out)

        # 2. Reconnect with the saved token: accepted, no pair fields, token unchanged.
        rc, out = run_glass(self.dir, port, "--exit-after-welcome")
        self.assertEqual(rc, 0, out)
        self.assertNotIn("Paired with", out)
        self.assertNotIn("pair_token", out)
        self.assertIn('"token":"%s"' % token, out)
        self.assertIn("accepted with saved token", out)
        with open(token_file) as f:
            self.assertEqual(f.read().strip(), token)

        # 3. Hold an accepted session A.
        a = self.client(port)
        a.hello(token)
        w = a.expect("welcome")
        self.assertNotIn("pair_token", w.obj)
        self.assertNotIn("pair_code", w.obj)
        a.expect("sync")

        # 4. No token (window closed): rejected pairing_required, closed; A unaffected.
        b = self.client(port)
        b.hello()
        r = b.expect("rejected")
        self.assertEqual(r.get("reason"), "pairing_required")
        b.expect_closed(5)
        self.assertTrue(a.alive())

        # 5. Wrong token: rejected bad_token; A unaffected.
        c = self.client(port)
        c.hello("0" * 32)
        r = c.expect("rejected")
        self.assertEqual(r.get("reason"), "bad_token")
        c.expect_closed(5)
        self.assertTrue(a.alive())

        # 6. A silent connection is closed by the hello timeout (2 s here, 10 s by default).
        d = self.client(port)
        waited = d.expect_closed(8)
        self.assertGreater(waited, 1.5)
        self.assertLess(waited, 5.0)
        self.assertFalse(d.log, "the phone sent something before acceptance")
        self.assertTrue(a.alive())

        # 7. Ping is answered before hello; other frames are ignored and their payloads consumed.
        g = self.client(port)
        g.send({"type": "ping"})
        self.assertEqual(g.next_frame(skip_pings=False).type, "pong")
        g.send({"type": "card", "id": "x", "title": "t", "text": "ignored before acceptance"})
        g.send({"type": "file_chunk", "id": "z", "offset": 0},
               b'\n{"type":"hello","device":"glass-explorer","version":2}\n')
        g.hello(token)
        w = g.expect("welcome")         # if the payload had been parsed, this would be 'rejected'
        self.assertNotIn("pair_token", w.obj)
        g.expect("sync")
        a.expect_closed(5)              # accepted G replaced A

        # 8. Waiting connections: a newer one replaces an older one; neither disturbs G until
        #    it is accepted.
        e = self.client(port)
        time.sleep(0.3)
        f = self.client(port)
        self.assertLess(e.expect_closed(3), 1.5)
        self.assertTrue(g.alive())
        f.hello(token)
        f.expect("welcome")
        f.expect("sync")
        g.expect_closed(5)
        self.assertTrue(f.alive())

        # 9. forget: token deleted, current session dropped, window stays closed.
        m = phone.mark()
        phone.send("forget")
        phone.wait_for(r"Forgot the paired Glass", since=m)
        f.expect_closed(5)
        rc, out = run_glass(self.dir, port, "--once")
        self.assertEqual(rc, 3, out)
        self.assertIn("Rejected: pairing_required", out)

        # 10. pair: window open again; the old token is replaced by a new one.
        phone.send("pair")
        phone.wait_for(r"Pairing window open for 120 s", since=m)
        rc, out = run_glass(self.dir, port, "--exit-after-welcome")
        self.assertEqual(rc, 0, out)
        code2 = re.search(r"Paired with fake_phone, code (\d{4})", out).group(1)
        phone.wait_for(r"PAIRED new Glass .*code %s\." % code2, since=m)
        with open(token_file) as f2:
            token2 = f2.read().strip()
        self.assertRegex(token2, HEX32)
        self.assertNotEqual(token2, token)

        # 11. With the window closed again: wrong token -> bad_token, no token -> pairing_required.
        other = os.path.join(self.dir, "other_token.txt")
        rc, out = run_glass(self.dir, port, "--once", "--token", "f" * 32, "--token-file", other)
        self.assertEqual(rc, 3, out)
        self.assertIn("Rejected: bad_token", out)
        self.assertFalse(os.path.exists(other))
        rc, out = run_glass(self.dir, port, "--once", "--no-token")
        self.assertEqual(rc, 3, out)
        self.assertIn("Rejected: pairing_required", out)
        rc, out = run_glass(self.dir, port, "--exit-after-welcome")
        self.assertEqual(rc, 0, out)
        self.assertIn("accepted with saved token", out)

    def test_window_expires_and_no_auth(self):
        phone, port = self.phone("--pair-window", "1")
        phone.wait_for(r"Pairing window closed", timeout=5)
        rc, out = run_glass(self.dir, port, "--once", "--no-token")
        self.assertEqual(rc, 3, out)
        self.assertIn("pairing_required", out)
        phone2, port2 = self.phone("--no-auth")
        rc, out = run_glass(self.dir, port2, "--exit-after-welcome", "--token", "a" * 32)
        self.assertEqual(rc, 0, out)
        self.assertNotIn("pair_token", out)


# =====================================================================================
class SelftestTests(ToolTestCase):
    """Drives fake_phone --selftest exactly as its docstring documents."""

    def test_selftest_script(self):
        port = free_port()
        phone = Proc([FAKE_PHONE, "--selftest", "--port", str(port)], self.dir, "fake_phone --selftest")
        self.procs.append(phone)
        phone.wait_for(r"SELFTEST ready port=%d" % port)

        # Session 1: no token -> paired.
        c = self.client(port)
        c.hello()
        w = c.expect("welcome")
        self.assertEqual(w.get("server"), "fake_phone")
        self.assertEqual(w.get("version"), 2)
        self.assertEqual(w.get("phone_name"), "fake_phone")
        token = w.get("pair_token")
        self.assertRegex(token, HEX32)
        self.assertRegex(w.get("pair_code"), r"^\d{4}$")
        self.assertEqual(c.expect("sync").get("enabled"), True)
        sc = c.expect("screencast")
        self.assertEqual((sc.get("on"), sc.get("fps")), (True, 2))
        self.assertEqual(c.next_frame(skip_pings=False).type, "ping")
        c.send({"type": "pong"})
        card = c.expect("card")
        self.assertEqual((card.get("id"), card.get("title"), card.get("text")),
                         ("st-pong", "Selftest", "pong received"))

        c.send({"type": "status", "battery": 77, "charging": False, "storage_free_mb": 1,
                "storage_total_mb": 2, "mock_location": False, "screen_on": True, "uptime_s": 5})
        card = c.expect("card")
        self.assertEqual((card.get("id"), card.get("text"), card.get("battery")),
                         ("st-card", "status battery=77", 77))
        self.assertEqual(card.get("source"), "fake_phone")
        c.send({"type": "ack", "id": "st-card", "event": "shown"})
        card = c.expect("card")
        self.assertEqual((card.get("id"), card.get("text"), card.get("ack_id"), card.get("event")),
                         ("st-ack", "ack st-card shown", "st-card", "shown"))

        data = det_bytes(600 * 1024, "selftest-upload")
        fid = "IMG_SELFTEST.jpg:%d" % len(data)
        c.send({"type": "file_begin", "id": fid, "name": "IMG_SELFTEST.jpg", "size": len(data),
                "mime": "image/jpeg", "taken": gbproto.now_ms()})
        for off in range(0, len(data), gbproto.CHUNK):
            c.send({"type": "file_chunk", "id": fid, "offset": off}, data[off:off + gbproto.CHUNK])
        c.send({"type": "file_end", "id": fid})
        ack = c.expect("file_ack", timeout=10)
        self.assertEqual(ack.get("id"), fid)
        self.assertIs(ack.get("ok"), True)
        self.assertEqual(ack.get("sha256"), hashlib.sha256(data).hexdigest())
        self.assertEqual(ack.get("received"), len(data))

        jpeg = b"\xff\xd8\xff\xe0" + det_bytes(25000, "jpeg") + b"\xff\xd9"
        c.send({"type": "frame", "w": 640, "h": 360}, jpeg)
        card = c.expect("card")
        self.assertEqual(card.get("id"), "st-frame")
        self.assertEqual(card.get("text"), "frame 640x360 %d bytes" % len(jpeg))
        self.assertEqual((card.get("w"), card.get("h"), card.get("size")), (640, 360, len(jpeg)))
        self.assertEqual(card.get("sha256"), hashlib.sha256(jpeg).hexdigest())
        self.assertIs(card.get("jpeg"), True)

        c.send({"type": "ping"})
        self.assertEqual(c.next_frame(skip_pings=False).type, "pong")
        card = c.expect("card")
        self.assertEqual((card.get("id"), card.get("text")), ("st-ping", "ping answered"))

        c.send({"type": "file_begin", "id": "bad:4", "name": "bad", "size": 4, "mime": "image/jpeg",
                "taken": 1})
        c.send({"type": "file_chunk", "id": "bad:4", "offset": 2}, b"ab")
        c.send({"type": "file_end", "id": "bad:4"})
        ack = c.expect("file_ack")
        self.assertEqual((ack.get("ok"), ack.get("error")), (False, "chunks out of order"))
        c.send({"type": "ack", "id": "st-pong", "event": "shown"})  # only logged
        self.assertTrue(c.alive())

        # Session 2 (new connection) with the token: accepted without pair fields; it replaces
        # session 1. Re-uploading the same file is still ok with the same sha256.
        c2 = self.client(port)
        c2.hello(token)
        w = c2.expect("welcome")
        self.assertNotIn("pair_token", w.obj)
        self.assertNotIn("pair_code", w.obj)
        c2.expect("sync")
        c2.expect("screencast")
        self.assertEqual(c2.next_frame(skip_pings=False).type, "ping")
        c.expect_closed(5)
        c2.send({"type": "file_begin", "id": fid, "name": "IMG_SELFTEST.jpg", "size": len(data),
                 "mime": "image/jpeg", "taken": 1})
        for off in range(0, len(data), gbproto.CHUNK):
            c2.send({"type": "file_chunk", "id": fid, "offset": off}, data[off:off + gbproto.CHUNK])
        c2.send({"type": "file_end", "id": fid})
        ack = c2.expect("file_ack", timeout=10)
        self.assertIs(ack.get("ok"), True)
        self.assertEqual(ack.get("sha256"), hashlib.sha256(data).hexdigest())
        c2.close()

        # Session 3: a wrong token is paired too (the window is always open in selftest mode).
        c3 = self.client(port)
        c3.hello("1" * 32)
        w = c3.expect("welcome")
        self.assertRegex(w.get("pair_token"), HEX32)
        self.assertNotEqual(w.get("pair_token"), token)
        c3.close()

        for step in ("SELFTEST hello accepted (paired, code", "SELFTEST welcome, sync, screencast and ping sent",
                     "SELFTEST pong received", "SELFTEST status received battery=77",
                     "SELFTEST ack st-card shown", "SELFTEST upload %s ok=True" % fid,
                     "SELFTEST frame 640x360", "SELFTEST ping answered", "SELFTEST hello accepted (token ok)"):
            phone.wait_for(re.escape(step))
        self.assertFalse(os.path.exists(os.path.join(self.dir, "received")),
                         "selftest wrote files without --received-dir")


# =====================================================================================
class HeartbeatTests(ToolTestCase):

    def test_phone_pings_then_drops(self):
        phone, port = self.phone("--no-auth", "--ping-after", "1", "--dead-after", "2.5")
        c = self.client(port)
        c.hello()
        c.expect("welcome")
        c.expect("sync")
        t0 = time.monotonic()
        f = c.next_frame(timeout=4, skip_pings=False)     # don't answer
        self.assertEqual(f.type, "ping")
        self.assertGreater(time.monotonic() - t0, 0.7)
        c.expect_closed(4)
        self.assertGreater(time.monotonic() - t0, 2.2)
        phone.wait_for(r"nothing received for 2\.5 s")

    def test_glass_heartbeat_and_backoff(self):
        srv = socket.create_server(("127.0.0.1", 0))
        srv.settimeout(12)
        port = srv.getsockname()[1]
        glass = self.glass_proc(port, "--ping-after", "1", "--dead-after", "2.5", "--duration", "25",
                                "--token-file", os.path.join(self.dir, "t.txt"))
        try:
            # 1st connection: rejected -> next attempt 5 s later.
            s1, _ = srv.accept()
            st1 = gbproto.FrameStream(s1)
            s1.settimeout(5)
            self.assertEqual(st1.read().type, "hello")
            s1.sendall(encode({"type": "rejected", "reason": "pairing_required"}))
            s1.shutdown(socket.SHUT_WR)
            t1 = time.monotonic()
            s2, _ = srv.accept()
            t2 = time.monotonic()
            s1.close()
            self.assertGreater(t2 - t1, 4.3)
            self.assertLess(t2 - t1, 7.0)
            glass.wait_for(r"Rejected: pairing_required")
            glass.wait_for(r"Reconnecting in 5 s")
            # 2nd: welcome (paired), then silence -> Glass pings, then drops at 2.5 s.
            st2 = gbproto.FrameStream(s2)
            s2.settimeout(5)
            self.assertEqual(st2.read().type, "hello")
            s2.sendall(encode({"type": "welcome", "server": "test", "version": 2, "phone_name": "Raw",
                               "pair_token": "c" * 32, "pair_code": "0007"}))
            glass.wait_for(r"Paired with Raw, code 0007")
            last_tx = time.monotonic()
            types = []
            while True:
                try:
                    fr = st2.read()
                except (socket.timeout, OSError):
                    break
                if fr is None:
                    break
                types.append(fr.type)
                if fr.type == "ping":
                    self.assertGreater(time.monotonic() - last_tx, 0.7)
            t3 = time.monotonic()
            self.assertIn("status", types)
            self.assertIn("ping", types)
            self.assertGreater(t3 - last_tx, 2.0)
            self.assertLess(t3 - last_tx, 4.5)
            with open(os.path.join(self.dir, "t.txt")) as f:
                self.assertEqual(f.read().strip(), "c" * 32)
            # 3rd: 2 s after a session that had been welcomed; sends the saved token.
            s3, _ = srv.accept()
            t4 = time.monotonic()
            s2.close()
            self.assertGreater(t4 - t3, 1.5)
            self.assertLess(t4 - t3, 4.0)
            s3.settimeout(5)
            hello = gbproto.FrameStream(s3).read()
            self.assertEqual(hello.get("token"), "c" * 32)
            s3.close()
        finally:
            srv.close()

    def test_glass_backoff_doubles_when_unreachable(self):
        port = free_port()   # nothing listens here
        rc, out = run_glass(self.dir, port, "--duration", "6.6")
        self.assertEqual(rc, 0, out)
        waits = re.findall(r"Reconnecting in (\d+) s", out)
        self.assertEqual(waits[:3], ["2", "4", "8"], out)


# =====================================================================================
STUB_ADB = r'''#!/usr/bin/env python3
import json, os, re, shutil, sys
root = os.environ["STUB_ADB_ROOT"]
args = sys.argv[1:]
with open(os.environ["STUB_ADB_LOG"], "a") as f:
    f.write(json.dumps(args) + "\n")
if args[:1] == ["-s"]:
    args = args[2:]
def dev(p):
    return os.path.join(root, p.lstrip("/"))
cmd = args[0]
if cmd == "devices":
    print("List of devices attached\nSTUB123 device product:glass_1 model:Glass_1")
elif cmd == "install":
    if os.environ.get("STUB_INSTALL_FAIL"):
        print("Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures do not match]")
        sys.exit(1)
    print("Success")
elif cmd == "uninstall":
    print("Success")
elif cmd == "push":
    os.makedirs(os.path.dirname(dev(args[2])), exist_ok=True)
    shutil.copyfile(args[1], dev(args[2]))
    print("1 file pushed")
elif cmd == "pull":
    if not os.path.exists(dev(args[1])):
        print("adb: error: remote object '%s' does not exist" % args[1])
        sys.exit(1)
    shutil.copyfile(dev(args[1]), args[2])
elif cmd == "logcat":
    print("logcat " + " ".join(args[1:]))
elif cmd == "shell":
    c = args[1]
    m = re.match(r"mkdir -p (\S+)", c)
    if m:
        os.makedirs(dev(m.group(1)), exist_ok=True)
        print("GB_DIR_OK")
    elif c.startswith("rm -f "):
        p = dev(c[6:])
        if os.path.exists(p):
            os.remove(p)
    elif c.startswith("cat "):
        p = dev(c[4:])
        if os.path.exists(p):
            print(open(p).read())
        else:
            print("%s: No such file or directory" % c[4:])
    elif c.startswith("screencap -p "):
        p = dev(c[13:])
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "wb").write(b"\x89PNG\r\n\x1a\nstub")
    elif c == "settings put secure mock_location 1":
        open(dev("mock"), "w").write("1")
    elif c == "settings get secure mock_location":
        print(open(dev("mock")).read() if os.path.exists(dev("mock")) else "0")
    elif c.startswith("am startservice"):
        print("Starting service: Intent { cmp=au.interstellr.glassbridge/.BridgeService }")
    elif c.startswith("am start"):
        print("Starting: Intent { cmp=au.interstellr.glassbridge/.MainActivity }")
    elif c == "dumpsys battery":
        print("Current Battery Service state:\n  AC powered: false\n  USB powered: true\n  level: 64\n  scale: 100")
    elif c.startswith("dumpsys activity services"):
        print("ACTIVITY MANAGER SERVICES\n  * ServiceRecord{41 u0 au.interstellr.glassbridge/.BridgeService}")
    elif c.startswith("dumpsys package"):
        print("Packages:\n  Package [au.interstellr.glassbridge]\n    versionCode=2 targetSdk=19\n    versionName=2.0")
    elif c == "dumpsys wifi":
        print("mWifiInfo SSID: My iPhone, BSSID: 00:11, RSSI: -50")
    else:
        print("stub: unhandled shell command: " + c)
'''


class GlassAdbTests(ToolTestCase):

    def setUp(self):
        ToolTestCase.setUp(self)
        self.root = os.path.join(self.dir, "device")
        os.makedirs(self.root)
        self.log = os.path.join(self.dir, "adb.log")
        self.stub = os.path.join(self.dir, "adb")
        with open(self.stub, "w") as f:
            f.write(STUB_ADB)
        os.chmod(self.stub, os.stat(self.stub).st_mode | stat.S_IEXEC)
        self.cfg = os.path.join(self.root, "sdcard/Android/data/au.interstellr.glassbridge/files/config.json")

    def adb(self, *args, **env):
        e = dict(CHILD_ENV, STUB_ADB_ROOT=self.root, STUB_ADB_LOG=self.log)
        e.update(env)
        p = subprocess.run([PY, GLASS_ADB, "--adb", self.stub] + list(args), cwd=self.dir,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=e, timeout=60)
        return p.returncode, p.stdout.decode("utf-8", "replace")

    def config(self):
        with open(self.cfg) as f:
            return json.load(f)

    def calls(self):
        with open(self.log) as f:
            return [json.loads(l) for l in f]

    def test_config_read_modify_write(self):
        rc, out = self.adb("config", "192.168.1.20")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.config(), {"host": "192.168.1.20", "port": 9090})
        rc, out = self.adb("invert-swipe", "on")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.config(), {"host": "192.168.1.20", "port": 9090, "invert_swipe": True})
        with open(self.cfg, "w") as f:
            json.dump({"host": "1.2.3.4", "port": 1, "invert_swipe": True, "future_key": [1]}, f)
        rc, out = self.adb("config", "10.0.0.5", "9191")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.config(), {"host": "10.0.0.5", "port": 9191, "invert_swipe": True,
                                         "future_key": [1]})
        rc, out = self.adb("config-clear")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.config(), {"invert_swipe": True, "future_key": [1]})
        rc, out = self.adb("invert-swipe", "off")
        self.assertEqual(self.config()["invert_swipe"], False)
        with open(self.cfg, "w") as f:
            json.dump({"host": "1.2.3.4"}, f)
        rc, out = self.adb("config-clear")
        self.assertEqual(rc, 0, out)
        self.assertFalse(os.path.exists(self.cfg))
        with open(self.cfg, "w") as f:
            f.write("{broken")
        rc, out = self.adb("config", "1.1.1.1")
        self.assertEqual(rc, 1, out)
        self.assertIn("isn't valid JSON", out)
        self.assertTrue(any(c[:2] == ["shell", "mkdir -p /sdcard/Android/data/au.interstellr.glassbridge/files"]
                            or (c[0] == "shell" and c[1].startswith("mkdir -p")) for c in self.calls()))

    def test_wifi_install_screen_status(self):
        rc, out = self.adb("wifi", "My iPhone", "pa ss;word")
        self.assertEqual(rc, 0, out)
        wifi = os.path.join(self.root, "sdcard/Android/data/au.interstellr.glassbridge/files/wifi.json")
        with open(wifi) as f:
            self.assertEqual(json.load(f), [{"ssid": "My iPhone", "security": "WPA", "password": "pa ss;word"}])
        self.assertIn(["shell", "am startservice -n au.interstellr.glassbridge/.BridgeService"], self.calls())
        rc, out = self.adb("wifi", "Cafe", "", "open")
        self.assertEqual(rc, 0, out)
        with open(wifi) as f:
            self.assertEqual(json.load(f), [{"ssid": "Cafe", "security": "OPEN"}])

        apk = os.path.join(self.dir, "x.apk")
        with open(apk, "wb") as f:
            f.write(b"PK")
        rc, out = self.adb("install", apk)
        self.assertEqual(rc, 0, out)
        self.assertIn(["install", "-r", apk], self.calls())
        rc, out = self.adb("install", apk, STUB_INSTALL_FAIL="1")
        self.assertEqual(rc, 1, out)
        self.assertIn("adb uninstall au.interstellr.glassbridge", out)
        rc, out = self.adb("install", os.path.join(self.dir, "missing.apk"))
        self.assertEqual(rc, 1, out)

        rc, out = self.adb("screen")
        self.assertEqual(rc, 0, out)
        shots = os.listdir(os.path.join(self.dir, "screens"))
        self.assertIn("latest.png", shots)
        self.assertEqual(len(shots), 2)
        self.assertIn(["shell", "screencap -p /sdcard/gb_screen.png"], self.calls())

        rc, out = self.adb("mock")
        self.assertEqual(rc, 0, out)
        self.assertIn("mock_location = 1", out)
        rc, out = self.adb("config", "172.20.10.1")
        rc, out = self.adb("status")
        self.assertEqual(rc, 0, out)
        for text in ("version 2.0", "BridgeService: running", "mock_location: 1", "level: 64",
                     "My iPhone", '"host": "172.20.10.1"'):
            self.assertIn(text, out)
        rc, out = self.adb("logs", "--dump")
        self.assertEqual(rc, 0, out)
        self.assertIn(["logcat", "-v", "time", "-d", "-s", "GlassBridge:V", "GlassBridgeInput:V",
                       "AndroidRuntime:E", "System.err:W"], self.calls())
        rc, out = self.adb("start")
        self.assertEqual(rc, 0, out)
        rc, out = self.adb("launch")
        self.assertEqual(rc, 0, out)
        self.assertIn(["shell", "am start -n au.interstellr.glassbridge/.MainActivity"], self.calls())


class HelpTests(unittest.TestCase):
    def test_help(self):
        for script in ("gbproto.py", "fake_phone.py", "fake_glass.py", "make_test_stream.py",
                       "glass_adb.py", "test_e2e.py"):
            p = subprocess.run([PY, os.path.join(TOOLS, script), "--help"], stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, env=CHILD_ENV, timeout=30)
            self.assertEqual(p.returncode, 0, script + "\n" + p.stdout.decode())
            self.assertIn(b"usage", p.stdout.lower(), script)


def main():
    if "--help" in sys.argv or "-h" in sys.argv:
        print("usage: test_e2e.py [-v] [-k PATTERN] [unittest options]\n")
        print(__doc__)
        return 0
    start = time.monotonic()
    prog = unittest.main(module=__name__, exit=False, argv=[sys.argv[0]] + sys.argv[1:])
    result = prog.result
    total = result.testsRun
    bad = len(result.failures) + len(result.errors)
    print("\nSUMMARY: %d tests, %d passed, %d failed, %d errors, %d skipped in %.1f s"
          % (total, total - bad - len(result.skipped), len(result.failures), len(result.errors),
             len(result.skipped), time.monotonic() - start))
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
