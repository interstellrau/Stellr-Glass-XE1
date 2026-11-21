#!/usr/bin/env python3
"""make_test_stream.py: a tricky StellrGlass XE1 frame stream for cross-language checks.

Standard library only, Python 3.9+. tools/swift-check/run.sh uses it like this:

    python3 tools/make_test_stream.py write  stream.bin expected.json
    <Swift parses stream.bin, re-encodes every frame with its own encoder> > swift.bin
    python3 tools/make_test_stream.py verify swift.bin expected.json     # exit 0 = match

Commands:
  write <stream.bin> <expected.json>
      Writes the stream and the frames a correct parser must decode from it. Before
      writing, it checks that tools/gbproto.py decodes the stream to exactly those frames
      with reads of every size in "read_sizes". Exit 0, or 1 if that self-check fails.
  verify <encoded.bin> <expected.json>
      Parses <encoded.bin> (any valid encoding: key order, whitespace, escapes, CRLF and
      number formatting may differ) and checks it holds exactly the expected frames, in
      order: same count; per frame the same "type"; the same set of keys apart from
      "bytes"; equal values (strings exact, booleans exact and never equal to numbers,
      numbers by value so 3 == 3.0, floats within 1e-9 relative); and identical payload
      bytes (no payload, None, and an empty payload are equivalent). The "bytes" field
      itself isn't compared, because the framing already proves the payload length.
      The original stream.bin verifies too. Prints "OK: N frames match" and exits 0, or
      prints each mismatch (up to 20) and exits 1. Exit 2 for unreadable input.
  reencode <in.bin> <out.bin>
      Re-encodes a stream with gbproto (compact JSON, LF endings). For testing verify.

expected.json:
  {
    "format": "glassbridge-test-stream", "version": 1,
    "stream_bytes": <int>, "stream_sha256": "<hex>", "frame_count": <int>,
    "read_sizes": [1, 2, 3, ...],             # read sizes worth testing a parser with
    "frames": [
      {"index": 0, "note": "<what this frame tests>",
       "obj": {...},                           # the JSON object exactly as decoded,
                                               # including "bytes" when present
       "payload_b64": "<base64>" | null,       # null = no payload
       "payload_len": <int>,                   # 0 when there is no payload
       "payload_sha256": "<hex>" | null},
      ...
    ]
  }

What the stream exercises: blank lines (LF and CRLF, also at the very start and right
after a payload), CRLF line endings including a CRLF header followed by a payload,
payloads that contain newlines, CRLF and complete JSON frames, payloads that start with
"\\n" or end with "\\r", a payload of exactly 256 KiB (262,144 bytes), "bytes":0 versus
no "bytes" (both mean no payload), "bytes" as the first key, raw UTF-8 (accents, CJK,
emoji outside the BMP), \\u escapes including a surrogate pair and \\u2028/\\u2029,
escaped quotes, backslashes, tabs and "\\/", whitespace inside the JSON, an exponent
(1.5e2) and integral floats (3.0), epoch-ms integers above 2^32, a "pair_code" string with
leading zeros, an unknown type with a payload, unknown fields, a 50,000 character text
field, and every message type in PROTOCOL.md section 5.
"""

import argparse
import base64
import hashlib
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gbproto  # noqa: E402

READ_SIZES = [1, 2, 3, 5, 7, 13, 64, 255, 1000, 4096, 65535, 65536, 65537, 262144, 1048576]


def _det_bytes(n, seed):
    """Deterministic pseudo-random bytes (SHA-256 in counter mode)."""
    out = bytearray()
    counter = 0
    while len(out) < n:
        out += hashlib.sha256(("%s:%d" % (seed, counter)).encode("ascii")).digest()
        counter += 1
    return bytes(out[:n])


def _dump(obj):
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def build():
    """Returns (stream_bytes, frames) where frames is a list of (obj, payload, note)."""
    parts = []
    frames = []

    def add(obj, payload=None, note="", raw=None, eol=b"\n", blank_before=()):
        """raw: hand-written header line (bytes, no EOL). obj: what it must decode to."""
        for b in blank_before:
            parts.append(b)
        if payload is not None and raw is None:
            obj = dict(obj)
            obj["bytes"] = len(payload)
        line = raw if raw is not None else _dump(obj)
        parts.append(line + eol)
        if payload is not None:
            parts.append(payload)
        frames.append((obj, payload, note))

    big_time = 1793491200123

    add({"type": "hello", "device": "glass-explorer", "version": 2, "model": "Glass 1",
         "firmware": "XE24", "app_version": "2.0", "token": "0123456789abcdef0123456789abcdef"},
        note="hello; the stream starts with a blank line", blank_before=(b"\n",))
    add({"type": "welcome", "server": "GlassBridge iOS", "version": 2,
         "phone_name": "Alexander’s iPhone", "pair_token": "fedcba9876543210fedcba9876543210",
         "pair_code": "0042"},
        note="welcome with pair fields, CRLF; pair_code keeps its leading zeros", eol=b"\r\n")
    add({"type": "status", "battery": 87, "charging": False, "storage_free_mb": 9216,
         "storage_total_mb": 12288, "wifi_ssid": "My iPhone", "wifi_rssi": -52,
         "mock_location": True, "screen_on": True, "uptime_s": 3600},
        note="status written with spaces and tabs inside the JSON, after LF and CRLF blank lines",
        raw=b'{ "type" : "status" ,\t"battery" : 87, "charging" : false, "storage_free_mb": 9216, '
            b'"storage_total_mb": 12288, "wifi_ssid": "My iPhone", "wifi_rssi": -52, '
            b'"mock_location": true, "screen_on": true, "uptime_s": 3600 }',
        blank_before=(b"\n", b"\r\n"))
    add({"type": "card", "id": "c-1a2b3c4d", "title": "Café ☕",
         "text": "Grüße aus Adelaide — 東京 \U0001F680\nSecond line \"quoted\" "
                 "back\\slash\ttab /slash",
         "source": "Messages", "time": big_time, "style": "notification", "chime": True,
         "wake": True, "ttl_s": 30},
        note="card with raw UTF-8 (accents, CJK, emoji outside the BMP), escaped newline, quotes, "
             "backslash, tab; epoch ms above 2^32")
    add({"type": "card", "id": "c-esc", "title": "é\U0001F680",
         "text": "   line/sep"},
        note="card written with \\u escapes, a surrogate pair, U+2028/U+2029 and \\/; CRLF",
        raw=b'{"type":"card","id":"c-esc","title":"\\u00e9\\ud83d\\ude80",'
            b'"text":"\\u2028\\u2029 line\\/sep"}',
        eol=b"\r\n")
    add({"type": "ping"}, note="ping")
    add({"type": "pong"}, note="pong, CRLF", eol=b"\r\n")
    add({"type": "file_begin", "id": "IMG_0001.jpg:300000", "name": "IMG_0001.jpg", "size": 300000,
         "mime": "image/jpeg", "taken": 1793491200000}, note="file_begin")
    tricky = (b'{"type":"card","id":"inner","title":"not a frame","text":"x"}\n'
              b'\r\n\n{"type":"ping"}\r\n' + bytes(range(256)) + b"\r")
    add({"type": "file_chunk", "id": "IMG_0001.jpg:300000", "offset": 0}, tricky,
        note="file_chunk, CRLF header, payload holding JSON frames, CRLF, blank lines, every "
             "byte value, and ending in \\r", eol=b"\r\n")
    starts_nl = b"\n\n\r\npayload starts with newlines\n"
    add({"type": "file_chunk", "id": "IMG_0001.jpg:300000", "offset": len(tricky)}, starts_nl,
        note="payload starting with \\n\\n\\r\\n")
    chunk = _det_bytes(gbproto.CHUNK, "glassbridge-chunk")
    add({"type": "file_chunk", "id": "IMG_0001.jpg:300000",
         "offset": len(tricky) + len(starts_nl)}, chunk,
        note="payload of exactly 262,144 bytes (CHUNK), pseudo-random, contains many \\n",
        blank_before=())
    add({"type": "file_end", "id": "IMG_0001.jpg:300000"},
        note="file_end straight after a payload, preceded by a CRLF blank line",
        blank_before=(b"\r\n",))
    add({"type": "file_chunk", "id": "empty.jpg:0", "offset": 0, "bytes": 0},
        note='"bytes":0 means no payload')
    add({"type": "file_chunk", "id": "k.jpg:3", "offset": 0, "bytes": 3}, b"abc",
        note='"bytes" as the first key', raw=b'{"bytes":3,"type":"file_chunk","id":"k.jpg:3","offset":0}')
    add({"type": "file_ack", "id": "IMG_0001.jpg:300000", "ok": False, "error": "size mismatch"},
        note="file_ack with error")
    add({"type": "file_ack", "id": "k.jpg:3", "ok": True}, note="file_ack ok")
    add({"type": "ack", "id": "c-1a2b3c4d", "event": "shown"}, note="ack")
    add({"type": "dismiss", "id": "c-1a2b3c4d"}, note="dismiss")
    add({"type": "speak", "text": "In 100 metres, turn left. ¡Hola!"}, note="speak")
    add({"type": "nav", "instruction": "Turn left onto King William St", "maneuver": "left",
         "distance_m": 123.5, "street": "King William St", "step": 2, "steps_total": 7,
         "eta_min": 4, "remaining_m": 1234.25, "destination": "Rundle Mall", "arrived": False,
         "announce": True}, note="nav with fractional distances")
    add({"type": "nav", "instruction": "Continue", "maneuver": "straight", "distance_m": 150.0,
         "step": 3, "steps_total": 7, "eta_min": 3.0},
        note="nav with an exponent (1.5e2) and an integral float (3.0)",
        raw=b'{"type":"nav","instruction":"Continue","maneuver":"straight","distance_m":1.5e2,'
            b'"step":3,"steps_total":7,"eta_min":3.0}')
    add({"type": "nav_end"}, note="nav_end")
    add({"type": "location", "lat": -34.928499, "lon": 138.600746, "acc_m": 4.5, "alt_m": 48.25,
         "speed_mps": 1.25, "bearing": 270.5, "time": 1793491200999},
        note="location with negative and fractional numbers")
    add({"type": "request_status"}, note="request_status")
    add({"type": "sync", "enabled": True}, note="sync")
    add({"type": "screencast", "on": True, "fps": 2}, note="screencast")
    jpeg = b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\r\n\n" + \
        _det_bytes(1500, "frame") + b"\xff\xd9"
    add({"type": "frame", "w": 640, "h": 360}, jpeg, note="frame with a JPEG-like payload")
    add({"type": "x_future_thing", "x_note": "an unknown type: skip it but consume its payload"},
        b'\n{"a"}\n', note="unknown type with a 7-byte payload that looks like JSON lines",
        blank_before=())
    add({"type": "card", "id": "c-extra", "title": "Extra", "text": "Unknown fields are ignored",
         "x_extra": "kept by a re-encoder", "x_num": 7},
        note="card with unknown fields, right after a payload with a blank line between",
        blank_before=(b"\n",))
    add({"type": "wifi_add", "ssid": "Café; \"Net\", :1\\", "password": "p@ss;word,:\"\\",
         "security": "WPA"}, note="wifi_add with characters a WIFI: QR code must escape")
    add({"type": "wifi_result", "ssid": "Café; \"Net\", :1\\", "ok": False,
         "error": "network not found"}, note="wifi_result")
    add({"type": "rejected", "reason": "bad_token", "message": "Pair on your iPhone"},
        note="rejected")
    add({"type": "card", "id": "c-long", "title": "Long", "text": "x" * 50000 + "end"},
        note="a 50,000+ character line (under the 64 KiB limit)")
    add({"type": "ping"}, note="last frame, CRLF, nothing after it", eol=b"\r\n")
    return b"".join(parts), frames


# ----- comparison ---------------------------------------------------------------

def _is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def values_equal(a, b):
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    if _is_num(a) and _is_num(b):
        if isinstance(a, int) and isinstance(b, int):
            return a == b
        return math.isclose(float(a), float(b), rel_tol=1e-9, abs_tol=1e-12)
    if isinstance(a, dict) and isinstance(b, dict):
        return set(a) == set(b) and all(values_equal(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(values_equal(x, y) for x, y in zip(a, b))
    return type(a) is type(b) and a == b


def _short(v, limit=80):
    text = json.dumps(v, ensure_ascii=True)
    return text if len(text) <= limit else text[:limit] + "...(%d chars)" % len(text)


def compare(expected, got_frames, strict_bytes=False, max_errors=20):
    """expected: list of {"obj", "payload"(bytes|None)}; got_frames: list of gbproto.Frame.
    Returns a list of mismatch descriptions (empty = match)."""
    errors = []
    if len(got_frames) != len(expected):
        errors.append("frame count: expected %d, got %d" % (len(expected), len(got_frames)))
    for i, (exp, got) in enumerate(zip(expected, got_frames)):
        if len(errors) >= max_errors:
            break
        eobj, gobj = exp["obj"], got.obj
        where = "frame %d (%s)" % (i, eobj.get("type"))
        if gobj.get("type") != eobj.get("type"):
            errors.append("%s: type expected %r, got %r" % (where, eobj.get("type"), gobj.get("type")))
            continue
        ekeys = set(eobj) - (set() if strict_bytes else {"bytes"})
        gkeys = set(gobj) - (set() if strict_bytes else {"bytes"})
        for k in sorted(ekeys - gkeys):
            errors.append("%s: field %r missing" % (where, k))
        for k in sorted(gkeys - ekeys):
            errors.append("%s: unexpected field %r = %s" % (where, k, _short(gobj[k])))
        for k in sorted(ekeys & gkeys):
            if not values_equal(eobj[k], gobj[k]):
                errors.append("%s: field %r expected %s, got %s"
                              % (where, k, _short(eobj[k]), _short(gobj[k])))
        ep = exp["payload"] or b""
        gp = got.payload or b""
        if strict_bytes and (exp["payload"] is None) != (got.payload is None):
            errors.append("%s: payload presence differs" % where)
        if ep != gp:
            first = next((j for j in range(min(len(ep), len(gp))) if ep[j] != gp[j]),
                         min(len(ep), len(gp)))
            errors.append("%s: payload differs (expected %d bytes, got %d; first difference at "
                          "byte %d)" % (where, len(ep), len(gp), first))
    return errors[:max_errors]


def parse_stream(data, read_size=None):
    reader = gbproto.FrameReader()
    frames = []
    if read_size is None:
        frames.extend(reader.feed(data))
    else:
        for i in range(0, len(data), read_size):
            frames.extend(reader.feed(data[i:i + read_size]))
    if reader.buffered:
        raise gbproto.ProtocolError("%d trailing bytes don't form a complete frame" % reader.buffered)
    return frames


def load_expected(path):
    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f)
    if doc.get("format") != "glassbridge-test-stream":
        raise ValueError("%s is not a glassbridge-test-stream file" % path)
    out = []
    for fr in doc["frames"]:
        p = fr.get("payload_b64")
        out.append({"obj": fr["obj"], "payload": base64.b64decode(p) if p is not None else None})
    return doc, out


# ----- commands -----------------------------------------------------------------

def cmd_write(stream_path, expected_path):
    data, frames = build()
    expected = [{"obj": o, "payload": p} for (o, p, _n) in frames]
    for size in [None] + READ_SIZES:
        errors = compare(expected, parse_stream(data, size), strict_bytes=True)
        if errors:
            print("FAIL: gbproto disagrees with the generator (read size %s):" % size)
            for e in errors:
                print("  " + e)
            return 1
    doc = {
        "format": "glassbridge-test-stream",
        "version": 1,
        "stream_bytes": len(data),
        "stream_sha256": hashlib.sha256(data).hexdigest(),
        "frame_count": len(frames),
        "read_sizes": READ_SIZES,
        "frames": [{
            "index": i,
            "note": note,
            "obj": obj,
            "payload_b64": base64.b64encode(p).decode("ascii") if p is not None else None,
            "payload_len": len(p) if p is not None else 0,
            "payload_sha256": hashlib.sha256(p).hexdigest() if p is not None else None,
        } for i, (obj, p, note) in enumerate(frames)],
    }
    with open(stream_path, "wb") as f:
        f.write(data)
    with open(expected_path, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=True, indent=1)
        f.write("\n")
    print("Wrote %s (%d bytes, %d frames) and %s" % (stream_path, len(data), len(frames), expected_path))
    return 0


def cmd_verify(encoded_path, expected_path):
    try:
        _doc, expected = load_expected(expected_path)
        with open(encoded_path, "rb") as f:
            data = f.read()
    except (OSError, ValueError, KeyError) as e:
        print("ERROR: %s" % e)
        return 2
    try:
        got = parse_stream(data)
    except gbproto.ProtocolError as e:
        print("FAIL: %s is not a valid frame stream: %s" % (encoded_path, e))
        return 1
    errors = compare(expected, got)
    if errors:
        print("FAIL: %s does not match %s:" % (encoded_path, expected_path))
        for e in errors:
            print("  " + e)
        return 1
    print("OK: %d frames match (%s, %d bytes)" % (len(got), encoded_path, len(data)))
    return 0


def cmd_reencode(in_path, out_path):
    with open(in_path, "rb") as f:
        frames = parse_stream(f.read())
    with open(out_path, "wb") as f:
        for fr in frames:
            obj = {k: v for k, v in fr.obj.items() if k != "bytes"}
            f.write(gbproto.encode(obj, fr.payload))
    print("Re-encoded %d frames to %s" % (len(frames), out_path))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Write a tricky StellrGlass XE1 frame stream with its expected frames, or verify a "
                    "stream another implementation re-encoded.",
        epilog="Exit codes: 0 ok, 1 mismatch / invalid stream, 2 unreadable input.")
    sub = parser.add_subparsers(dest="cmd")
    w = sub.add_parser("write", help="write <stream.bin> and <expected.json>")
    w.add_argument("stream")
    w.add_argument("expected")
    v = sub.add_parser("verify", help="check <encoded.bin> against <expected.json>")
    v.add_argument("encoded")
    v.add_argument("expected")
    r = sub.add_parser("reencode", help="re-encode a stream with gbproto (for testing verify)")
    r.add_argument("input")
    r.add_argument("output")
    args = parser.parse_args(argv)
    try:
        sys.stdout.reconfigure(errors="replace")
    except (AttributeError, ValueError):
        pass
    if args.cmd == "write":
        return cmd_write(args.stream, args.expected)
    if args.cmd == "verify":
        return cmd_verify(args.encoded, args.expected)
    if args.cmd == "reencode":
        return cmd_reencode(args.input, args.output)
    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
