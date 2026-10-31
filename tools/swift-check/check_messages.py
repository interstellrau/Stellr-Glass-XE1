#!/usr/bin/env python3
"""check_messages.py: validate the Swift Msg builders' output with the Python reference.

Standard library only, Python 3.9+. Used by tools/swift-check/run.sh (part 2):

    gbcheck emit builders.bin
    python3 tools/swift-check/check_messages.py builders.bin

builders.bin holds one frame per iPhone -> Glass builder, in the fixed order written by
gbcheck's runEmit (StreamChecks.swift). Each frame is decoded with tools/gbproto.py (an
implementation independent of the Swift parser) and checked against PROTOCOL.md
section 5: required and optional fields, JSON types (integers are ints, never bools or
fractions; booleans are true/false; enums hold known values), section 6 pair fields, and
"type" as the first key of every header line.

Exit 0 when every frame passes, 1 on any mismatch, 2 for unreadable input.
"""

import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gbproto  # noqa: E402

INT = "int"
NUM = "number"
STR = "str"
BOOL = "bool"

MANEUVERS = {"depart", "straight", "left", "right", "slight_left", "slight_right",
             "sharp_left", "sharp_right", "uturn", "arrive"}

# type -> (required {field: kind}, optional {field: kind}) from PROTOCOL.md section 5.
SCHEMA = {
    "welcome": ({"server": STR, "version": INT, "phone_name": STR},
                {"pair_token": STR, "pair_code": STR}),
    "rejected": ({"reason": STR}, {"message": STR}),
    "card": ({"id": STR, "title": STR, "text": STR},
             {"source": STR, "time": INT, "style": STR, "chime": BOOL, "wake": BOOL, "ttl_s": INT}),
    "dismiss": ({"id": STR}, {}),
    "speak": ({"text": STR}, {}),
    "nav": ({"instruction": STR, "maneuver": STR, "distance_m": NUM, "step": INT, "steps_total": INT},
            {"street": STR, "eta_min": INT, "remaining_m": NUM, "destination": STR,
             "arrived": BOOL, "announce": BOOL}),
    "nav_end": ({}, {}),
    "location": ({"lat": NUM, "lon": NUM, "acc_m": NUM, "time": INT},
                 {"alt_m": NUM, "speed_mps": NUM, "bearing": NUM}),
    "sync": ({"enabled": BOOL}, {}),
    "request_status": ({}, {}),
    "file_ack": ({"id": STR, "ok": BOOL}, {"error": STR, "sha256": STR, "received": INT}),
    "screencast": ({"on": BOOL}, {"fps": INT}),
    "wifi_add": ({"ssid": STR, "security": STR}, {"password": STR}),
    "ping": ({}, {}),
    "pong": ({}, {}),
}

EXPECTED_ORDER = ["welcome", "welcome", "rejected", "rejected", "card", "card", "dismiss", "speak",
                  "nav", "nav_end", "location", "sync", "request_status", "file_ack", "file_ack",
                  "screencast", "wifi_add", "wifi_add", "ping", "pong"]


def kind_ok(value, kind):
    if kind == INT:
        return isinstance(value, int) and not isinstance(value, bool)
    if kind == NUM:
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if kind == STR:
        return isinstance(value, str)
    if kind == BOOL:
        return isinstance(value, bool)
    return False


def check_frame(i, obj, errors):
    t = obj.get("type")
    where = "frame %d (%s)" % (i, t)
    if t not in SCHEMA:
        errors.append("%s: unexpected type" % where)
        return
    required, optional = SCHEMA[t]
    for field, kind in required.items():
        if field not in obj:
            errors.append("%s: required field %r missing" % (where, field))
        elif not kind_ok(obj[field], kind):
            errors.append("%s: field %r should be %s, got %r" % (where, field, kind, obj[field]))
    for field, kind in optional.items():
        if field in obj and not kind_ok(obj[field], kind):
            errors.append("%s: field %r should be %s, got %r" % (where, field, kind, obj[field]))
    extra = set(obj) - set(required) - set(optional) - {"type"}
    if extra:
        errors.append("%s: fields not in PROTOCOL.md: %s" % (where, sorted(extra)))
    if t == "welcome":
        if obj.get("version") != 2:
            errors.append("%s: version must be 2" % where)
        if ("pair_token" in obj) != ("pair_code" in obj):
            errors.append("%s: pair_token and pair_code must come together" % where)
        if "pair_token" in obj and not re.fullmatch(r"[0-9a-f]{32}", str(obj["pair_token"])):
            errors.append("%s: pair_token must be 32 lowercase hex" % where)
        if "pair_code" in obj and not re.fullmatch(r"[0-9]{4}", str(obj["pair_code"])):
            errors.append("%s: pair_code must be 4 digits" % where)
    if t == "rejected" and obj.get("reason") not in ("pairing_required", "bad_token"):
        errors.append("%s: unknown reason %r" % (where, obj.get("reason")))
    if t == "card" and "style" in obj and obj["style"] not in ("info", "notification"):
        errors.append("%s: unknown style %r" % (where, obj["style"]))
    if t == "card" and "time" in obj and obj["time"] < 2 ** 31:
        errors.append("%s: time should be epoch ms" % where)
    if t == "nav":
        if obj.get("maneuver") not in MANEUVERS:
            errors.append("%s: unknown maneuver %r" % (where, obj.get("maneuver")))
        if not (1 <= obj.get("step", 0) <= obj.get("steps_total", 0)):
            errors.append("%s: step must be 1..steps_total" % where)
        if obj.get("distance_m", -1) < 0:
            errors.append("%s: distance_m must be >= 0" % where)
    if t == "screencast" and "fps" in obj and not (1 <= obj["fps"] <= 5):
        errors.append("%s: fps must be 1-5" % where)
    if t == "wifi_add":
        if obj.get("security") not in ("WPA", "WEP", "OPEN"):
            errors.append("%s: unknown security %r" % (where, obj.get("security")))
        if obj.get("security") == "OPEN" and "password" in obj:
            errors.append("%s: open network must not carry a password" % where)


def main(argv):
    if len(argv) != 2:
        print("usage: check_messages.py <builders.bin>")
        return 2
    try:
        with open(argv[1], "rb") as f:
            data = f.read()
    except OSError as e:
        print("ERROR: %s" % e)
        return 2
    errors = []
    # "type" must be the first key of every header line (like gbproto.encode_line).
    for n, line in enumerate(data.split(b"\n")):
        if line and not line.startswith(b'{"type":'):
            errors.append("line %d does not start with {\"type\": %r" % (n, line[:40]))
    reader = gbproto.FrameReader()
    try:
        frames = reader.feed(data)
    except gbproto.ProtocolError as e:
        print("FAIL: gbproto can't decode the Swift builder output: %s" % e)
        return 1
    if reader.buffered:
        errors.append("%d trailing bytes" % reader.buffered)
    types = [fr.type for fr in frames]
    if types != EXPECTED_ORDER:
        errors.append("frame types %s, expected %s" % (types, EXPECTED_ORDER))
    for i, fr in enumerate(frames):
        check_frame(i, fr.obj, errors)
        if fr.payload:
            errors.append("frame %d (%s): unexpected payload" % (i, fr.type))
    if len(frames) >= 4:
        if "pair_token" in frames[0].obj:
            errors.append("frame 0: a plain welcome must not carry pair fields")
        if "pair_token" not in frames[1].obj:
            errors.append("frame 1: the paired welcome must carry pair_token and pair_code")
        if frames[2].obj.get("reason") != "pairing_required" or frames[3].obj.get("reason") != "bad_token":
            errors.append("frames 2-3: rejected reasons should be pairing_required, bad_token")
    if len(frames) > 8 and frames[8].obj.get("maneuver") != "depart":
        errors.append("frame 8: the first nav card should be the depart step")
    if errors:
        print("FAIL: Swift builder output doesn't match PROTOCOL.md:")
        for e in errors[:30]:
            print("  " + e)
        return 1
    print("OK: %d Swift builder frames decode with gbproto and match PROTOCOL.md section 5 (%s)"
          % (len(frames), ", ".join(sorted(set(types)))))
    sample = frames[1].obj if len(frames) > 1 else {}
    print("   e.g. %s" % json.dumps(sample, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
