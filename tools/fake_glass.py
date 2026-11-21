#!/usr/bin/env python3
"""fake_glass.py: pretends to be Glass running StellrGlass (the TCP client).

Standard library only, Python 3.9+. Implements PROTOCOL.md v2, pairing included.

    python3 tools/fake_glass.py 172.20.10.1                  # iPhone on Personal Hotspot
    python3 tools/fake_glass.py 192.168.1.20 --port 9191
    python3 tools/fake_glass.py 172.20.10.1 --upload IMG.jpg --frame shot.jpg

What it does:
  * Dials <iphone-ip>:<port> (5 s connect timeout) and reconnects with backoff:
    2 s doubling to a 30 s cap (reset after a welcome); 5 s fixed after 'rejected'.
  * Sends hello {device:"glass-explorer", version:2, model:"Glass 1", firmware:"XE24",
    app_version:"2.0-fake", token?}. The token comes from ./fake_glass_token.txt
    (--token-file), or --token, or none with --no-token. When welcome carries
    pair_token, the token file is replaced and it prints
    "Paired with <phone_name>, code <pair_code>".
  * Prints every frame ("<-" received, "->" sent). Acks each card with 'shown' as soon
    as it arrives. Real Glass differs: it acks 'shown' only when the card is actually on
    screen (once per card; nothing while the display is off, and only the displayed one
    of a burst), and acks 'dismissed' (notification cards: 'tapped', then 'dismissed')
    when the card is tapped. So a missing ack with real Glass is not a regression.
  * Sends status after welcome, every 60 s and on request_status. Answers ping with pong.
    Answers wifi_add with the wifi_result real Glass would send, using its checks: no
    ssid -> "missing ssid"; WPA without a password -> "a WPA network needs a password";
    a WPA password not 8-63 characters (64 hex digits is fine) -> "a WPA password must
    be 8 to 63 characters"; WEP without a key -> "a WEP network needs a key"; else ok.
    (Real Glass can still fail when saving: Wi-Fi off, addNetwork refused.)
    Heartbeat: ping after 15 s of silence, disconnect after 30 s.
  * --upload FILE (repeatable): after sync {enabled:true}, uploads each file as
    file_begin {id:"<name>:<size>", name, size, mime, taken:<mtime ms>}, file_chunk
    frames of at most 256 KiB, file_end; then waits up to 60 s for file_ack and prints
    the result. A file acked ok:true is not sent again in this run; a failed one is
    retried next session.
  * --frame JPG: while screencast is on, sends that JPEG as 'frame' {w, h} at the
    requested fps (--frame-size, default 640x360).

Exit codes: 0 success (or Ctrl-C); 1 an --exit-after-* goal wasn't met (upload failed,
no file_ack, --duration ran out, or --once couldn't connect / lost the link before
welcome); 2 bad arguments; 3 rejected by the phone (with --once, or when --duration ran
out after the last attempt was rejected).
"""

import argparse
import hashlib
import mimetypes
import os
import re
import socket
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gbproto  # noqa: E402
from gbproto import ProtocolError  # noqa: E402

MIME = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
        ".mp4": "video/mp4", ".3gp": "video/3gpp"}

_print_lock = threading.Lock()


def log(msg):
    with _print_lock:
        sys.stdout.write("%s %s\n" % (time.strftime("%H:%M:%S"), msg))
        sys.stdout.flush()


def mime_for(path):
    ext = os.path.splitext(path)[1].lower()
    return MIME.get(ext) or mimetypes.guess_type(path)[0] or "application/octet-stream"


def _json_text(value):
    """Glass's Json.text: a string, or a number written as text; otherwise None."""
    if isinstance(value, str):
        return value
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if value == value and abs(value) < 1e15 and value == int(value):
            return str(int(value))
        return repr(value)
    return None


def _jlen(s):
    """Length in UTF-16 code units, as Kotlin's String.length counts."""
    return len(s.encode("utf-16-le", "surrogatepass")) // 2


def _is_hex(s):
    return all(c in "0123456789abcdefABCDEF" for c in s)


def wifi_result(obj):
    """The wifi_result real Glass sends for this wifi_add, short of the Android save step.

    Mirrors glass core/WifiNetwork.kt (from, normalizeSecurity, problem) and
    BridgeService.onWifiAdd. Glass can still fail later on the device itself (Wi-Fi off and
    couldn't be turned on, addNetwork refused), which this can't predict.
    """
    ssid = _json_text(obj.get("ssid"))
    reply = {"type": "wifi_result", "ssid": ssid or ""}
    if not ssid:
        reply.update(ok=False, error="missing ssid")
        return reply
    password = _json_text(obj.get("password")) or None
    raw = obj.get("security")
    s = raw.strip().upper() if isinstance(raw, str) else None
    if s == "WEP":
        security = "WEP"
    elif s in ("OPEN", "NONE", "NOPASS", ""):
        security = "OPEN"
    elif s is not None and (s.startswith("WPA") or s == "PSK"):
        security = "WPA"
    else:  # none, or something unknown
        security = "WPA" if password else "OPEN"
    error = None
    if security == "WPA":
        if not password:
            error = "a WPA network needs a password"
        elif _jlen(password) == 64 and _is_hex(password):
            error = None
        elif _jlen(password) < 8 or _jlen(password) > 63:
            error = "a WPA password must be 8 to 63 characters"
    elif security == "WEP" and not password:
        error = "a WEP network needs a key"
    reply["ok"] = error is None
    if error is not None:
        reply["error"] = error
    return reply


class FakeGlass(object):
    def __init__(self, args):
        self.args = args
        self.host = args.host
        self.port = args.port
        self.start_time = time.monotonic()
        self.stop_event = threading.Event()
        self.exit_code = None
        self.state_lock = threading.Lock()
        # token
        self.token = None
        if args.no_token:
            self.token = None
        elif args.token:
            self.token = args.token
        elif os.path.exists(args.token_file):
            with open(args.token_file) as f:
                self.token = f.read().strip() or None
        # media
        self.pending = list(args.upload or [])
        self.retry_next = []
        self.upload_results = []          # (id, ok, error)
        self.frame_data = None
        if args.frame:
            with open(args.frame, "rb") as f:
                self.frame_data = f.read()
        self.frame_w, self.frame_h = args.frame_size
        self.frames_sent = 0
        # per connection
        self.gen = 0
        self.sock = None
        self.writer = None
        self.connected = False
        self.welcomed = False
        self.rejected = None
        self.last_rx = 0.0
        self.ping_outstanding = False
        self.sync_enabled = False
        self.cast_on = False
        self.cast_fps = 2
        self.uploading = False
        self.ack_waiters = {}
        self.last_result = None
        self._welcomed_ever = False
        self._frame_gen = None
        self._ack_note_done = False

    # ----- plumbing ----------------------------------------------------------

    def send(self, obj, payload=None, gen=None):
        with self.state_lock:
            if not self.connected or (gen is not None and gen != self.gen):
                return False
            writer = self.writer
        if obj.get("type") == "frame":
            if not self.args.quiet_frames:
                log("-> frame %sx%s (%d bytes)" % (obj.get("w"), obj.get("h"), len(payload or b"")))
        else:
            log("-> %s" % gbproto.describe(obj, payload))
        try:
            writer.send(obj, payload)
            return True
        except (OSError, ValueError, ProtocolError) as e:
            log("Send failed: %s" % e)
            self.drop_link()
            return False

    def drop_link(self):
        sock = self.sock
        if sock is not None:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def finish(self, code):
        if self.exit_code is None:
            self.exit_code = code
        self.stop_event.set()
        self.drop_link()

    def status(self):
        a = self.args
        return {"type": "status", "battery": a.battery, "charging": False,
                "storage_free_mb": 9216, "storage_total_mb": 12288,
                "wifi_ssid": "FakeHotspot", "wifi_rssi": -52, "mock_location": True,
                "screen_on": True, "uptime_s": int(time.monotonic() - self.start_time)}

    def save_token(self, token):
        self.token = token
        if self.args.no_token:
            return
        path = self.args.token_file
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            f.write(token + "\n")
        os.replace(tmp, path)
        log("Token saved to %s" % os.path.abspath(path))

    # ----- main loop -----------------------------------------------------------

    def run(self):
        a = self.args
        if a.duration:
            t = threading.Timer(a.duration, self._duration_up)
            t.daemon = True
            t.start()
        delay = 2.0
        try:
            while not self.stop_event.is_set():
                result = self.session()
                self.last_result = result
                if self.stop_event.is_set():
                    break
                if a.once:
                    if result == "rejected":
                        self.finish(3)
                    elif result == "welcomed" and not (a.exit_after_upload and self.pending):
                        self.finish(0)
                    else:
                        self.finish(1)
                    break
                if result == "rejected":
                    wait = 5.0
                    delay = 2.0
                elif result == "welcomed":
                    delay = 2.0
                    wait = delay
                    delay = min(delay * 2, 30.0)
                else:
                    wait = delay
                    delay = min(delay * 2, 30.0)
                log("Reconnecting in %g s" % wait)
                self.stop_event.wait(wait)
        except KeyboardInterrupt:
            self.finish(0)
        return self.exit_code if self.exit_code is not None else 0

    def _duration_up(self):
        a = self.args
        code = 0
        if (a.exit_after_welcome and not self.welcomed_ever()) or (
                a.exit_after_upload and (self.pending or self.retry_next or self.uploading)):
            code = 3 if self.last_result == "rejected" or self.rejected else 1
        log("--duration %g s elapsed; exiting with %d" % (a.duration, code))
        self.finish(code)

    def welcomed_ever(self):
        return self._welcomed_ever

    def session(self):
        log("Connecting to %s:%d ..." % (self.host, self.port))
        try:
            sock = socket.create_connection((self.host, self.port), timeout=5)
        except OSError as e:
            log("Connect failed: %s" % e)
            return "failed"
        sock.settimeout(None)
        try:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        except OSError:
            pass
        with self.state_lock:
            self.gen += 1
            gen = self.gen
            self.sock = sock
            self.writer = gbproto.FrameWriter(sock)
            self.connected = True
            self.welcomed = False
            self.rejected = None
            self.last_rx = time.monotonic()
            self.ping_outstanding = False
            self.sync_enabled = False
            self.cast_on = False
        log("Connected to %s:%d" % (self.host, self.port))
        if self.stop_event.is_set():
            self.drop_link()
        hello = {"type": "hello", "device": "glass-explorer", "version": gbproto.PROTOCOL_VERSION,
                 "model": "Glass 1", "firmware": "XE24", "app_version": "2.0-fake"}
        if self.token and not self.args.no_token:
            hello["token"] = self.token
        self.send(hello, gen=gen)
        threading.Thread(target=self._watchdog, args=(gen,), daemon=True).start()
        reason = "closed by the phone"
        try:
            stream = gbproto.FrameStream(sock)
            while True:
                frame = stream.read()
                if frame is None:
                    break
                self.last_rx = time.monotonic()
                self.ping_outstanding = False
                self.dispatch(frame, gen)
        except ProtocolError as e:
            reason = "protocol error: %s" % e
        except OSError as e:
            reason = "socket error: %s" % e
        with self.state_lock:
            self.connected = False
            self.sock = None
            waiters = list(self.ack_waiters.values())
            self.ack_waiters = {}
        for w in waiters:
            w[0].set()  # result stays None: link dropped
        try:
            sock.close()
        except OSError:
            pass
        if not self.stop_event.is_set():
            log("Disconnected: %s" % reason)
        if self.rejected:
            return "rejected"
        return "welcomed" if self.welcomed else "failed"

    def _watchdog(self, gen):
        a = self.args
        while not self.stop_event.is_set():
            time.sleep(0.2)
            with self.state_lock:
                if gen != self.gen or not self.connected:
                    return
            silence = time.monotonic() - self.last_rx
            if silence >= a.dead_after:
                log("Nothing received for %g s; dropping the link" % a.dead_after)
                self.drop_link()
                return
            if silence >= a.ping_after and not self.ping_outstanding:
                self.ping_outstanding = True
                self.send({"type": "ping"}, gen=gen)

    def _status_loop(self, gen):
        while not self.stop_event.wait(self.args.status_every):
            if not self.send(self.status(), gen=gen):
                return

    # ----- frames from the phone ---------------------------------------------

    def dispatch(self, frame, gen):
        obj, payload = frame.obj, frame.payload
        t = frame.type
        log("<- %s" % gbproto.describe(obj, payload))
        if t == "ping":
            self.send({"type": "pong"}, gen=gen)
        elif t == "pong":
            pass
        elif t == "welcome":
            self.welcomed = True
            self._welcomed_ever = True
            name = obj.get("phone_name")
            if obj.get("pair_token"):
                self.save_token(str(obj.get("pair_token")))  # saved before the line below
                log("Paired with %s, code %s" % (name, obj.get("pair_code")))
            else:
                log("Welcome from %s (server %s, version %s): accepted%s" % (
                    name, obj.get("server"), obj.get("version"),
                    "" if not self.token else (" with --token" if self.args.token else " with saved token")))
            self.send(self.status(), gen=gen)
            threading.Thread(target=self._status_loop, args=(gen,), daemon=True).start()
            if self.args.exit_after_welcome:
                log("--exit-after-welcome: done")
                self.finish(0)
        elif t == "rejected":
            self.rejected = obj.get("reason")
            log("Rejected: %s (%s)" % (obj.get("reason"), obj.get("message", "")))
        elif t == "card":
            log("CARD [%s] %s | %s%s" % (obj.get("id"), obj.get("title"), obj.get("text"),
                                         " (%s)" % obj.get("style") if obj.get("style") else ""))
            if not self._ack_note_done:
                self._ack_note_done = True
                log("Note: fake_glass acks every card 'shown' as it arrives. Real Glass acks "
                    "'shown' only when the card is on screen (none while the display is off), "
                    "and 'dismissed' (notifications: 'tapped' then 'dismissed') on a tap.")
            self.send({"type": "ack", "id": obj.get("id"), "event": "shown"}, gen=gen)
        elif t == "dismiss":
            log("DISMISS %s" % obj.get("id"))
        elif t == "speak":
            log("SPEAK %s" % obj.get("text"))
        elif t == "nav":
            log("NAV step %s/%s %s %s m: %s%s" % (
                obj.get("step"), obj.get("steps_total"), obj.get("maneuver"), obj.get("distance_m"),
                obj.get("instruction"), " (announce)" if obj.get("announce") else ""))
        elif t == "nav_end":
            log("NAV ended")
        elif t == "location":
            log("LOCATION %s, %s (+-%s m)" % (obj.get("lat"), obj.get("lon"), obj.get("acc_m")))
        elif t == "request_status":
            self.send(self.status(), gen=gen)
        elif t == "sync":
            self.sync_enabled = bool(obj.get("enabled"))
            log("SYNC %s" % ("enabled" if self.sync_enabled else "disabled"))
            self._maybe_upload(gen)
        elif t == "screencast":
            self.cast_on = bool(obj.get("on"))
            fps = obj.get("fps", 2)
            if isinstance(fps, bool) or not isinstance(fps, (int, float)):
                fps = 2
            self.cast_fps = max(1, min(5, int(fps)))
            log("SCREENCAST %s%s" % ("on" if self.cast_on else "off",
                                     " at %d fps" % self.cast_fps if self.cast_on else ""))
            if self.cast_on:
                if self.frame_data is None:
                    log("(no --frame given, so no frames will be sent)")
                else:
                    threading.Thread(target=self._frame_loop, args=(gen,), daemon=True).start()
        elif t == "wifi_add":
            log("WIFI_ADD %s (%s)" % (obj.get("ssid"), obj.get("security")))
            self.send(wifi_result(obj), gen=gen)
        elif t == "file_ack":
            with self.state_lock:
                w = self.ack_waiters.get(obj.get("id"))
            if w is None:
                log("file_ack for %r that isn't being uploaded" % obj.get("id"))
            else:
                w[1] = obj
                w[0].set()
        else:
            log("Ignored unknown type %r" % (t,))

    # ----- screencast ----------------------------------------------------------

    def _frame_loop(self, gen):
        with self.state_lock:
            if self._frame_gen == gen:
                return  # a frame loop already runs for this connection
            self._frame_gen = gen
        try:
            while not self.stop_event.is_set() and self.cast_on:
                if not self.send({"type": "frame", "w": self.frame_w, "h": self.frame_h},
                                 self.frame_data, gen=gen):
                    return
                self.frames_sent += 1
                self.stop_event.wait(1.0 / self.cast_fps)
        finally:
            with self.state_lock:
                if self._frame_gen == gen:
                    self._frame_gen = None

    # ----- uploads -------------------------------------------------------------

    def _maybe_upload(self, gen):
        with self.state_lock:
            if self.uploading or not self.sync_enabled or not (self.pending or self.retry_next):
                return
            self.pending.extend(self.retry_next)
            self.retry_next = []
            self.uploading = True
        threading.Thread(target=self._upload_loop, args=(gen,), daemon=True).start()

    def _upload_loop(self, gen):
        try:
            while self.pending and self.sync_enabled and not self.stop_event.is_set():
                path = self.pending[0]
                result = self._upload_one(path, gen)
                if result is None:
                    return  # link dropped; the file stays pending for the next session
                self.pending.pop(0)
                ok, fid, error = result
                self.upload_results.append((fid, ok, error))
                if not ok:
                    self.retry_next.append(path)
        finally:
            with self.state_lock:
                self.uploading = False
        if self.args.exit_after_upload and not self.pending:
            ok = all(r[1] for r in self.upload_results) and not self.retry_next
            log("--exit-after-upload: %s" % ("all uploads ok" if ok else "an upload failed"))
            self.finish(0 if ok else 1)

    def _upload_one(self, path, gen):
        """Returns (ok, id, error), or None if the link dropped."""
        name = os.path.basename(path)
        try:
            size = os.path.getsize(path)
            taken = int(os.path.getmtime(path) * 1000)
        except OSError as e:
            log("Upload %s: %s" % (path, e))
            return False, name, str(e)
        fid = "%s:%d" % (name, size)
        waiter = [threading.Event(), None]
        with self.state_lock:
            self.ack_waiters[fid] = waiter
        sha = hashlib.sha256()
        log("Upload %s: starting (%d bytes)" % (fid, size))
        if not self.send({"type": "file_begin", "id": fid, "name": name, "size": size,
                          "mime": mime_for(path), "taken": taken}, gen=gen):
            return None
        offset = 0
        with open(path, "rb") as f:
            while True:
                data = f.read(gbproto.CHUNK)
                if not data:
                    break
                if not self.send({"type": "file_chunk", "id": fid, "offset": offset}, data, gen=gen):
                    return None
                sha.update(data)
                offset += len(data)
        if offset != size or os.path.getsize(path) != size:
            log("Upload %s: the file changed during the upload" % fid)
        if not self.send({"type": "file_end", "id": fid}, gen=gen):
            return None
        if not waiter[0].wait(self.args.ack_timeout):
            with self.state_lock:
                self.ack_waiters.pop(fid, None)
            log("Upload %s: no file_ack within %g s" % (fid, self.args.ack_timeout))
            return False, fid, "no file_ack"
        with self.state_lock:
            self.ack_waiters.pop(fid, None)
        ack = waiter[1]
        if ack is None:
            return None
        if ack.get("ok") is True:
            extra = ""
            if ack.get("sha256"):
                extra = " sha256 %s" % ("matches" if ack.get("sha256") == sha.hexdigest()
                                        else "MISMATCH (%s)" % ack.get("sha256"))
            log("Upload %s: ok%s" % (fid, extra))
            return True, fid, None
        log("Upload %s: FAILED (%s)" % (fid, ack.get("error")))
        return False, fid, ack.get("error")


def _frame_size(text):
    m = re.match(r"^(\d+)[xX](\d+)$", text)
    if not m:
        raise argparse.ArgumentTypeError("expected WxH, for example 640x360")
    return int(m.group(1)), int(m.group(2))


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Pretend to be Glass running StellrGlass (TCP client, PROTOCOL.md v2).",
        epilog="Exit codes: 0 ok, 1 goal not met, 2 bad arguments, 3 rejected. "
               "See the docstring at the top of this file for details.")
    parser.add_argument("host", help="iPhone (or fake_phone) address, e.g. 172.20.10.1")
    parser.add_argument("--port", type=int, default=gbproto.DEFAULT_PORT, help="TCP port (default 9090)")
    parser.add_argument("--upload", action="append", metavar="FILE",
                        help="upload FILE after sync {enabled:true} (repeatable)")
    parser.add_argument("--frame", metavar="JPG", help="JPEG to send as 'frame' while screencast is on")
    parser.add_argument("--frame-size", type=_frame_size, default=(640, 360), metavar="WxH",
                        help="w/h sent with each frame (default 640x360)")
    tok = parser.add_mutually_exclusive_group()
    tok.add_argument("--token", help="send this pairing token (a new pair_token still gets saved)")
    tok.add_argument("--no-token", action="store_true", help="never send or save a token")
    parser.add_argument("--token-file", default="fake_glass_token.txt",
                        help="where the pairing token is kept (default ./fake_glass_token.txt)")
    parser.add_argument("--once", action="store_true",
                        help="one connection attempt, no reconnect; exit 0 welcomed, 3 rejected, 1 otherwise")
    parser.add_argument("--duration", type=float, metavar="S", help="exit after S seconds")
    parser.add_argument("--exit-after-welcome", action="store_true", help="exit 0 once welcome arrives")
    parser.add_argument("--exit-after-upload", action="store_true",
                        help="exit once every --upload file got its file_ack (0 all ok, 1 otherwise)")
    parser.add_argument("--quiet-frames", action="store_true", help="don't print each frame sent")
    parser.add_argument("--battery", type=int, default=87, help="battery %% in status (default 87)")
    parser.add_argument("--status-every", type=float, default=60.0, metavar="S",
                        help="status period in s (default 60)")
    parser.add_argument("--ack-timeout", type=float, default=60.0, metavar="S",
                        help="wait this long for file_ack (default 60)")
    parser.add_argument("--ping-after", type=float, default=15.0, metavar="S",
                        help="testing: ping after S s of silence (default 15)")
    parser.add_argument("--dead-after", type=float, default=30.0, metavar="S",
                        help="testing: drop the link after S s of silence (default 30)")
    args = parser.parse_args(argv)

    try:
        sys.stdout.reconfigure(errors="replace", line_buffering=True)
    except (AttributeError, ValueError):
        pass

    for path in (args.upload or []):
        if not os.path.isfile(path):
            parser.error("--upload: no such file: %s" % path)
    if args.frame:
        if not os.path.isfile(args.frame):
            parser.error("--frame: no such file: %s" % args.frame)
        if os.path.getsize(args.frame) > gbproto.MAX_PAYLOAD:
            parser.error("--frame: larger than the 1 MiB payload limit")
    if args.exit_after_upload and not args.upload:
        parser.error("--exit-after-upload needs --upload")

    glass = FakeGlass(args)
    log("fake_glass: token %s" % ("none" if not glass.token or args.no_token else
                                  "%s...%s" % (glass.token[:4], glass.token[-4:])))
    try:
        return glass.run()
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
