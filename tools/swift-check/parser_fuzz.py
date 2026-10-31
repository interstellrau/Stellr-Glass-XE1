#!/usr/bin/env python3
"""parser_fuzz.py: differential test of the Swift header parser against tools/gbproto.py.

Standard library only, Python 3.9+. Used by tools/swift-check/run.sh (part 1):

    python3 tools/swift-check/parser_fuzz.py write corpus.json [--count N] [--seed S]
    gbcheck fuzz corpus.json results.json
    python3 tools/swift-check/parser_fuzz.py compare corpus.json results.json

`write` generates header lines (no line ending): valid frames in many JSON spellings
(escapes, raw UTF-8, whitespace, exponents, nesting, "bytes" variants), the same lines
with random byte mutations, and a few hand-written edge cases. For each line it records
whether gbproto.parse_line accepts it, and if so the decoded object and payload length.

`gbcheck fuzz` runs FrameParser.parseHeader on every line and writes its verdicts, with
the re-encoded header for accepted lines.

`compare` checks that both implementations accept and reject exactly the same lines and
decode accepted lines to equal values (make_test_stream.values_equal rules: strings exact,
booleans never equal numbers, numbers by value). Exit 0 on a match, 1 otherwise, 2 for
unreadable input.
"""

import argparse
import base64
import json
import os
import random
import sys

TOOLS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, TOOLS)
import gbproto  # noqa: E402
from make_test_stream import values_equal  # noqa: E402

TYPES = ["card", "nav", "status", "hello", "file_chunk", "ping", "x_new", "ack", "location"]
KEYS = ["id", "title", "text", "bytes", "n", "ok", "lat", "list", "obj", "x_extra", "time", "pair_code"]
CHARS = (["a", "Z", "0", " ", "\t", "\n", "\r", "\"", "\\", "/", "\u00e9", "\u6771", "\u2028",
          "\U0001F680", "\u0000", "\u001f", "\u007f", "\ufeff", "\ud83d"])


def rand_string(rng):
    n = rng.randint(0, 12)
    out = []
    for _ in range(n):
        if rng.random() < 0.6:
            out.append(chr(rng.randint(0x20, 0x7E)))
        else:
            out.append(rng.choice(CHARS))
    return "".join(out)


def rand_number(rng):
    r = rng.random()
    if r < 0.3:
        return rng.randint(-1000, 100000)
    if r < 0.45:
        return rng.choice([0, -0, 2 ** 31, 2 ** 53 + 1, 2 ** 63 - 1, -(2 ** 63), 1793491200123])
    if r < 0.8:
        return rng.uniform(-1e6, 1e6)
    return rng.choice([0.0, -0.0, 1.5e-7, 3.0, 1e21, 123.456, 5e-324, 1.7976931348623157e308])


def rand_value(rng, depth=0):
    r = rng.random()
    if depth > 3:
        r = r * 0.6
    if r < 0.25:
        return rand_string(rng)
    if r < 0.45:
        return rand_number(rng)
    if r < 0.52:
        return rng.choice([True, False])
    if r < 0.56:
        return None
    if r < 0.8:
        return [rand_value(rng, depth + 1) for _ in range(rng.randint(0, 4))]
    return {rand_string(rng): rand_value(rng, depth + 1) for _ in range(rng.randint(0, 4))}


def rand_bytes_field(rng):
    return rng.choice([0, 0, 1, 5, -1, -1.5, 2.5, 3.0, "5", True, None, [3], 1048577, 1048576])


def rand_object(rng):
    obj = {"type": rng.choice(TYPES)}
    for _ in range(rng.randint(0, 6)):
        key = rng.choice(KEYS) if rng.random() < 0.7 else rand_string(rng)
        obj[key] = rand_bytes_field(rng) if key == "bytes" else rand_value(rng)
    if rng.random() < 0.1:
        obj["type"] = rng.choice([5, None, True, ["card"], ""])
    if rng.random() < 0.05:
        del obj["type"]
    return obj


def spell(obj, rng):
    """One of many valid JSON spellings of obj (bytes, no newline)."""
    style = rng.random()
    if style < 0.3:
        text = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    elif style < 0.55:
        text = json.dumps(obj, ensure_ascii=True)
    elif style < 0.75:
        text = json.dumps(obj, ensure_ascii=False, separators=(" , ", " : "))
        text = "\t " + text + " \r"
    else:
        text = json.dumps(obj, ensure_ascii=rng.random() < 0.5, separators=(",", ":"))
        text = text.replace("/", "\\/") if rng.random() < 0.5 else text
    if rng.random() < 0.1:
        text = text.replace("e+", "E+").replace("e-", "E-")
    return text.encode("utf-8", errors="surrogatepass")


def mutate(line, rng):
    b = bytearray(line)
    for _ in range(rng.randint(1, 3)):
        op = rng.random()
        pos = rng.randint(0, max(0, len(b) - 1)) if b else 0
        if op < 0.35 and b:
            b[pos] = rng.randint(0, 255)
        elif op < 0.6:
            b.insert(pos, rng.choice(b'{}[]",:\\ \tetfn0123456789-+.eE\xc0\xed\xf5\x80\xff\r'))
        elif op < 0.85 and b:
            del b[pos]
        else:
            b += bytes([rng.randint(0, 255)])
    return bytes(b).replace(b"\n", b" ")


EDGE_CASES = [
    b'{"type":"x"}', b' {"type":"x"} ', b'{"type":"x",}', b'{"type":"x"}}', b'{"type":"x"} x',
    b'{"type":"x","n":NaN}', b'{"type":"x","n":Infinity}', b'{"type":"x","n":-Infinity}',
    b'{"type":"x","n":01}', b'{"type":"x","n":1.}', b'{"type":"x","n":.5}', b'{"type":"x","n":-}',
    b'{"type":"x","n":1e}', b'{"type":"x","n":1E+2}', b'{"type":"x","n":-0}', b'{"type":"x","n":0e0}',
    b'{"type":"x","s":"\\ud800"}', b'{"type":"x","s":"\\udc00x"}', b'{"type":"x","s":"\\ud83d\\ude80"}',
    b'{"type":"x","s":"\\u00"}', b'{"type":"x","s":"\\x41"}', b'{"type":"x","s":"a\tb"}',
    b'{"type":"x","s":"\\u0000"}', b'{"type":"\xc0\xaf"}', b'{"type":"\xed\xa0\x80"}',
    b'{"type":"\xf4\x90\x80\x80"}', b'{"type":"\xf0\x9f\x9a\x80"}', b'\xef\xbb\xbf{"type":"x"}',
    b'{"type":"x","a":1,"a":2}', b'{"type":"x","bytes":-0}', b'{"type":"x","bytes":-0.0}',
    b'{"type":"x","bytes":1e1}', b'{"type":"x","bytes":"5"}', b'{"type":"x","bytes":true}',
    b'{"type":"x","bytes":-1}', b'{"type":"x","bytes":1048577}', b'{"type":"x","bytes":1048576}',
    b'[]', b'"type"', b'null', b'{}', b'{"type":null}', b'{"type":1}', b"{'type':'x'}",
    b'{"type":"x"\r}', b'{"type"\t:\t"x"}', b'{"type":"x","t":tru}', b'{"type":"x","t":nul}',
    b'{"type":"x","deep":' + b"[" * 150 + b"]" * 150 + b"}",
    b'{"type":"x","n":123456789012345678}', b'{"type":"x","n":-9223372036854775808}',
]


def cmd_write(path, count, seed):
    rng = random.Random(seed)
    lines = list(EDGE_CASES)
    while len(lines) < count:
        line = spell(rand_object(rng), rng)
        if rng.random() < 0.45:
            line = mutate(line, rng)
        if len(line) <= 4096:
            lines.append(line)
    cases = []
    accepted = 0
    for i, line in enumerate(lines):
        entry = {"i": i, "line_b64": base64.b64encode(line).decode("ascii")}
        try:
            obj, n = gbproto.parse_line(line)
            # Values Swift can't round-trip through JSON text (inf from 1e400) are not
            # generated; keep the case but skip value comparison if one appears.
            entry["ok"] = True
            entry["payload_len"] = n
            try:
                entry["obj"] = json.loads(json.dumps(obj, allow_nan=False))
            except ValueError:
                entry["obj"] = None
            accepted += 1
        except gbproto.ProtocolError as e:
            entry["ok"] = False
            entry["why"] = str(e)[:80]
        cases.append(entry)
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"format": "glassbridge-parser-fuzz", "seed": seed, "cases": cases}, f,
                  ensure_ascii=True)
    print("Wrote %d header lines (%d accepted, %d rejected by gbproto) to %s"
          % (len(cases), accepted, len(cases) - accepted, path))
    return 0


def normalize(value):
    """Swift strings can't hold lone UTF-16 surrogates (Python's json.loads keeps a lone
    \\ud800 escape as-is); the Swift parser turns each into U+FFFD. Do the same here."""
    if isinstance(value, str):
        return "".join("\ufffd" if 0xD800 <= ord(ch) <= 0xDFFF else ch for ch in value)
    if isinstance(value, list):
        return [normalize(v) for v in value]
    if isinstance(value, dict):
        return {normalize(k): normalize(v) for k, v in value.items()}
    return value


def cmd_compare(corpus_path, results_path):
    try:
        with open(corpus_path, "r", encoding="utf-8") as f:
            corpus = json.load(f)
        with open(results_path, "r", encoding="utf-8") as f:
            results = json.load(f)
    except (OSError, ValueError) as e:
        print("ERROR: %s" % e)
        return 2
    by_index = {r["i"]: r for r in results.get("results", [])}
    errors = []
    compared = 0
    for case in corpus["cases"]:
        i = case["i"]
        line = base64.b64decode(case["line_b64"])
        got = by_index.get(i)
        shown = line[:70]
        if got is None:
            errors.append("case %d: no Swift result" % i)
            continue
        if got["ok"] != case["ok"]:
            errors.append("case %d: Python %s, Swift %s: %r (Python: %s; Swift: %s)" % (
                i, "accepts" if case["ok"] else "rejects", "accepts" if got["ok"] else "rejects",
                shown, case.get("why", "ok"), got.get("why", "ok")))
            continue
        if not case["ok"]:
            continue
        if got.get("payload_len") != case["payload_len"]:
            errors.append("case %d: payload length Python %r, Swift %r: %r"
                          % (i, case["payload_len"], got.get("payload_len"), shown))
        if case.get("obj") is None or got.get("obj") is None:
            continue
        if not values_equal(normalize(case["obj"]), got["obj"]):
            errors.append("case %d: values differ: %r\n    Python %s\n    Swift  %s" % (
                i, shown, json.dumps(case["obj"], ensure_ascii=True)[:200],
                json.dumps(got["obj"], ensure_ascii=True)[:200]))
            continue
        compared += 1
    if errors:
        print("FAIL: Swift and Python disagree on %d of %d header lines:" % (len(errors), len(corpus["cases"])))
        for e in errors[:20]:
            print("  " + e)
        return 1
    rejected = sum(1 for c in corpus["cases"] if not c["ok"])
    print("OK: Swift and Python agree on all %d header lines (%d accepted with equal values, %d rejected)"
          % (len(corpus["cases"]), compared, rejected))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="Differential fuzz of the Swift header parser.")
    sub = parser.add_subparsers(dest="cmd")
    w = sub.add_parser("write")
    w.add_argument("corpus")
    w.add_argument("--count", type=int, default=4000)
    w.add_argument("--seed", type=int, default=20261101)
    cmp_ = sub.add_parser("compare")
    cmp_.add_argument("corpus")
    cmp_.add_argument("results")
    args = parser.parse_args(argv)
    if args.cmd == "write":
        return cmd_write(args.corpus, args.count, args.seed)
    if args.cmd == "compare":
        return cmd_compare(args.corpus, args.results)
    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
