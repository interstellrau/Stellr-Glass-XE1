#!/usr/bin/env python3
"""fake_phone.py: pretends to be the GlassBridge iPhone app (the TCP server).

Standard library only, Python 3.9+. Implements PROTOCOL.md v2, pairing (section 6)
included. Point Glass at it with config.json (no Bonjour here):

    python3 tools/fake_phone.py                 # listen on 9090, interactive console
    python3 tools/fake_phone.py --port 9191
    python3 tools/glass_adb.py config <this-mac-ip> 9090
    python3 tools/fake_phone.py --selftest --port 9191   # for the Kotlin LiveLinkTest

Behaviour (normal mode):
  * One Glass at a time. A new connection replaces the current session only once its
    hello is accepted. At most one connection waits for acceptance (a newer one
    replaces an older waiting one). No acceptable hello within 10 s: closed.
  * Pairing (PROTOCOL.md section 6): one paired token, kept in memory only. The
    pairing window opens for 120 s at start (nothing is paired yet) and on 'pair'.
    hello.token == paired token -> accept (welcome without pair fields).
    Else, window open -> pair: new 32-hex token + 4-digit code, window closes,
    welcome carries pair_token and pair_code. Else -> rejected (bad_token if the hello
    carried a token and a token is stored, otherwise pairing_required), then close.
    Before acceptance only hello and ping are handled (ping -> pong); payloads are
    still consumed. --no-auth accepts every hello.
  * After accepting: welcome, sync (on by default, like the iPhone app), screencast
    if on, queued cards (kept 10 minutes while no Glass is connected), then the
    current nav card (not announced).
  * Heartbeat: ping after 15 s of silence, drop at 30 s. ping is always answered.
  * Uploads follow the iPhone's MediaReceiver rules: a chunk whose offset isn't the
    number of bytes received so far fails the transfer ("chunks out of order"); at
    file_end the byte count must equal size ("size mismatch"); a re-upload of an id
    already saved is accepted, discarded and acked ok:true. Files land in
    ./received/<name>. Every file_ack also carries "sha256" (hex SHA-256 of the bytes
    received in that transfer) and "received" (their count); unknown fields are
    allowed by the protocol.
  * Screencast frames are saved to ./received/frames/frame-NNNNNN.jpg (the newest
    --keep-frames are kept) and ./received/frames/latest.jpg. Open
    ./received/frames/view.html in a browser for a live view.
  * Every frame sent or received is printed ("->" sent, "<-" received).

Console commands:
    card <title> | <text>        info card (queued if no Glass is connected)
    notify <app> | <text>        notification card (chime + wake)
    dismiss [<id>]               dismiss a card (default: the last one sent)
    speak <text>                 text-to-speech on Glass
    nav <maneuver> <metres> <instruction...>   nav card (maneuver: depart straight
                                 left right slight_left slight_right sharp_left
                                 sharp_right uturn arrive)
    navend                       remove the nav card
    loc <lat> <lon> [acc_m]      phone GPS fix
    sync on|off                  photo sync (sent now if connected, and on connect)
    cast on|off [fps]            screencast, fps 1-5 (default 2)
    status                       print link/pairing state; send request_status
    wifi <ssid> [<password>] [WPA|WEP|OPEN]   wifi_add (quote names with spaces)
    ping                         send ping
    pair                         open the pairing window for 120 s
    forget                       delete the paired token (and drop the current Glass)
    name <phone name>            phone_name sent in welcome
    raw <json>                   send any JSON object as a frame (no payload)
    help                         this list
    quit                         exit

--selftest (non-interactive; never reads stdin; serves connections one after another
until killed). The pairing window is permanently open, so a hello without the current
token is paired (welcome has pair_token + pair_code) and a hello with the current token
is accepted (welcome without them). Uploads are hashed but not written to disk unless
--received-dir is given. The script, from the client's point of view:

  1. C->S hello {device, version:2, model, firmware, app_version, token?}
  2. S->C welcome {server:"fake_phone", version:2, phone_name:"fake_phone",
                   pair_token?:<32 lowercase hex>, pair_code?:<4 digits>}
     S->C sync {enabled:true}
     S->C screencast {on:true, fps:2}
     S->C ping                      (the client must answer pong)
  Then, in any order the client likes (each reply is sent after the trigger is read):
  3. C->S pong            -> S->C card {id:"st-pong", title:"Selftest", text:"pong received"}
  4. C->S ping            -> S->C pong, then card {id:"st-ping", title:"Selftest",
                                                   text:"ping answered"}
  5. C->S status {battery:B, ...}
                          -> S->C card {id:"st-card", title:"Selftest",
                                        text:"status battery=B", battery:B}
  6. C->S ack {id:"st-card", event:E}
                          -> S->C card {id:"st-ack", title:"Selftest",
                                        text:"ack st-card E", ack_id:"st-card", event:E}
     (acks of any other id are only logged)
  7. C->S file_begin {id, name, size, mime, taken}, file_chunk {id, offset, bytes}+payload
     ..., file_end {id}
                          -> S->C file_ack {id, ok:true, sha256:<hex>, received:N}
                             or file_ack {id, ok:false, error:"chunks out of order" |
                                          "size mismatch" | "unknown transfer", sha256, received}
  8. C->S frame {w:W, h:H, bytes:N}+payload
                          -> S->C card {id:"st-frame", title:"Selftest",
                                        text:"frame WxH N bytes", w:W, h:H, size:N,
                                        sha256:<hex>, jpeg:<payload starts FF D8 FF>}
  All cards also carry source:"fake_phone", style:"info", time:<epoch ms> (above 2^31:
  read it as a long).
  Notes for a client test: match reply cards by id, because heartbeat replies (st-ping,
  st-pong) can arrive between them; the server never sends 'rejected' in this mode;
  uploads needn't wait for sync; a re-upload of the same id (for example the test run
  again against a long-running server) is acked ok:true with the same sha256; a newly
  accepted connection closes the previous one; a connection with no hello for 10 s is
  closed. The normal heartbeat still runs (server ping after 15 s of silence, drop at
  30 s; --ping-after / --dead-after change it).
  On stdout: "SELFTEST ready port=N" once listening, then one "SELFTEST ..." line per step.
"""

import argparse
import hashlib
import hmac
import json
import os
import secrets
import shlex
import signal
import socket
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gbproto  # noqa: E402
from gbproto import ProtocolError  # noqa: E402

MANEUVERS = ("depart", "straight", "left", "right", "slight_left", "slight_right",
             "sharp_left", "sharp_right", "uturn", "arrive")
QUEUE_TTL_S = 600
MAX_SAVED_IDS = 5000

VIEW_HTML = """<!doctype html>
<html><head><meta charset="utf-8"><title>Glass screencast</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body { margin: 0; background: #111; color: #9e9e9e; font: 14px sans-serif; }
  img { display: block; width: 100%; max-width: 1280px; margin: 0 auto; background: #000; }
  p { text-align: center; }
</style></head>
<body>
<img id="shot" src="latest.jpg" alt="latest Glass frame">
<p id="info">Reloads latest.jpg twice a second. Written by tools/fake_phone.py.</p>
<script>
  // Plain JavaScript: reload the newest frame twice a second.
  var img = document.getElementById("shot");
  setInterval(function () { img.src = "latest.jpg?t=" + Date.now(); }, 500);
</script>
</body></html>
"""

_print_lock = threading.Lock()


def log(msg):
    with _print_lock:
        sys.stdout.write("%s %s\n" % (time.strftime("%H:%M:%S"), msg))
        sys.stdout.flush()


def _num(value, default=None):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return default
    return value


def _safe_name(name):
    name = str(name or "").replace("\\", "/").split("/")[-1].strip()
    name = name.lstrip(".")
    name = "".join(ch for ch in name if ch >= " " and ch not in ':*?"<>|')
    return name[:200] or "upload.bin"


def _unique_path(directory, name):
    path = os.path.join(directory, name)
    if not os.path.exists(path):
        return path
    stem, ext = os.path.splitext(name)
    n = 1
    while True:
        path = os.path.join(directory, "%s-%d%s" % (stem, n, ext))
        if not os.path.exists(path):
            return path
        n += 1


class Transfer(object):
    def __init__(self, session, tid, name, size):
        self.session = session
        self.id = tid
        self.name = name
        self.size = size
        self.received = 0
        self.sha = hashlib.sha256()
        self.error = None
        self.duplicate = False
        self.fh = None
        self.tmp_path = None


class MediaReceiver(object):
    """Reassembles uploads with the iPhone MediaReceiver's rules."""

    def __init__(self, out_dir):
        self.out_dir = out_dir        # None: hash only, write nothing
        self.saved = []               # ids in save order (bounded)
        self.saved_set = set()
        self.t = None
        self._n = 0
        self._lock = threading.RLock()   # reader thread vs abort() from a closing thread
        if out_dir and os.path.isdir(out_dir):
            for entry in sorted(os.listdir(out_dir)):
                path = os.path.join(out_dir, entry)
                if os.path.isfile(path) and not entry.startswith("."):
                    self._remember("%s:%d" % (entry, os.path.getsize(path)))

    def _remember(self, tid):
        if tid in self.saved_set:
            return
        self.saved.append(tid)
        self.saved_set.add(tid)
        while len(self.saved) > MAX_SAVED_IDS:
            self.saved_set.discard(self.saved.pop(0))

    def _discard_partial(self, t):
        if t.fh is not None:
            try:
                t.fh.close()
            except OSError:
                pass
            t.fh = None
        if t.tmp_path and os.path.exists(t.tmp_path):
            try:
                os.remove(t.tmp_path)
            except OSError:
                pass
        t.tmp_path = None

    def abort(self, session=None, why="link dropped"):
        with self._lock:
            self._abort(session, why)

    def begin(self, session, obj):
        with self._lock:
            self._begin(session, obj)

    def chunk(self, session, obj, payload):
        with self._lock:
            self._chunk(session, obj, payload)

    def end(self, session, obj):
        """Returns the file_ack dict to send."""
        with self._lock:
            return self._end(session, obj)

    def _abort(self, session=None, why="link dropped"):
        t = self.t
        if t is None or (session is not None and t.session is not session):
            return
        self._discard_partial(t)
        self.t = None
        log("Upload %s abandoned (%s); partial data deleted" % (t.id, why))

    def _begin(self, session, obj):
        if self.t is not None:
            self._abort(why="a new file_begin arrived")
        tid = obj.get("id")
        size = _num(obj.get("size"))
        name = obj.get("name")
        t = Transfer(session, tid if isinstance(tid, str) else str(tid),
                     name if isinstance(name, str) else "", int(size) if size is not None else -1)
        self.t = t
        if not isinstance(tid, str) or size is None or size < 0:
            t.error = "bad file_begin"
            return
        if not t.name:
            t.name = tid.rsplit(":", 1)[0]
        if tid in self.saved_set:
            t.duplicate = True
            log("Upload %s: already saved; will accept and discard" % tid)
            return
        if self.out_dir:
            os.makedirs(self.out_dir, exist_ok=True)
            self._n += 1
            t.tmp_path = os.path.join(self.out_dir, ".partial-%d-%d" % (os.getpid(), self._n))
            t.fh = open(t.tmp_path, "wb")
        log("Upload %s started: %s, %d bytes, %s" % (tid, t.name, t.size, obj.get("mime")))

    def _chunk(self, session, obj, payload):
        t = self.t
        if t is None or t.id != obj.get("id"):
            log("file_chunk for unknown transfer %r ignored" % obj.get("id"))
            return
        if t.error:
            return
        data = payload or b""
        offset = _num(obj.get("offset"))
        if offset is None or offset != t.received:
            t.error = "chunks out of order"
            log("Upload %s: chunk offset %r but %d bytes received: chunks out of order"
                % (t.id, obj.get("offset"), t.received))
            self._discard_partial(t)
            return
        t.sha.update(data)
        t.received += len(data)
        if t.fh is not None:
            t.fh.write(data)

    def _end(self, session, obj):
        t = self.t
        tid = obj.get("id")
        if t is None or t.id != tid:
            return {"type": "file_ack", "id": tid, "ok": False, "error": "unknown transfer",
                    "sha256": hashlib.sha256(b"").hexdigest(), "received": 0}
        self.t = None
        ack = {"type": "file_ack", "id": t.id}
        error = t.error
        if error is None and t.received != t.size:
            error = "size mismatch"
        if error is not None:
            self._discard_partial(t)
            ack.update(ok=False, error=error)
            log("Upload %s FAILED: %s" % (t.id, error))
        elif t.duplicate:
            ack["ok"] = True
            log("Upload %s: duplicate of a saved file, discarded, acked ok" % t.id)
        else:
            ack["ok"] = True
            if t.fh is not None:
                t.fh.close()
                t.fh = None
                final = _unique_path(self.out_dir, _safe_name(t.name))
                os.replace(t.tmp_path, final)
                t.tmp_path = None
                log("Upload %s saved to %s (%d bytes)" % (t.id, final, t.received))
            else:
                log("Upload %s complete (%d bytes, not written to disk)" % (t.id, t.received))
            self._remember(t.id)
        ack["sha256"] = t.sha.hexdigest()
        ack["received"] = t.received
        return ack


class FrameSaver(object):
    def __init__(self, frames_dir, keep):
        self.dir = frames_dir   # None: don't save
        self.keep = keep
        self.n = 0
        self.saved = []

    def save(self, payload):
        self.n += 1
        if not self.dir:
            return None
        os.makedirs(self.dir, exist_ok=True)
        view = os.path.join(self.dir, "view.html")
        if not os.path.exists(view):
            with open(view, "w") as f:
                f.write(VIEW_HTML)
        path = os.path.join(self.dir, "frame-%06d.jpg" % self.n)
        with open(path, "wb") as f:
            f.write(payload)
        tmp = os.path.join(self.dir, ".latest.tmp")
        with open(tmp, "wb") as f:
            f.write(payload)
        os.replace(tmp, os.path.join(self.dir, "latest.jpg"))
        self.saved.append(path)
        while self.keep and len(self.saved) > self.keep:
            old = self.saved.pop(0)
            try:
                os.remove(old)
            except OSError:
                pass
        return path


class Session(object):
    def __init__(self, server, sock, addr, number):
        self.server = server
        self.sock = sock
        self.addr = "%s:%s" % (addr[0], addr[1])
        self.n = number
        self.writer = gbproto.FrameWriter(sock)
        self.accepted = False
        self.closed = False
        self.rejecting_until = None
        self.connected_at = time.monotonic()
        self.last_rx = self.connected_at
        self.ping_outstanding = False
        self.device = None
        self._close_lock = threading.Lock()

    def label(self):
        return "#%d %s" % (self.n, self.addr)

    def send(self, obj, payload=None):
        if self.closed:
            return False
        log("-> [%d] %s" % (self.n, gbproto.describe(obj, payload)))
        try:
            self.writer.send(obj, payload)
            return True
        except (OSError, ValueError, ProtocolError) as e:
            self.close("send failed: %s" % e)
            return False

    def close(self, reason):
        with self._close_lock:
            if self.closed:
                return
            self.closed = True
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass
        self.server.session_closed(self, reason)

    def reject(self, reason, message):
        self.send({"type": "rejected", "reason": reason, "message": message})
        try:
            self.sock.shutdown(socket.SHUT_WR)  # FIN after the rejected frame
        except OSError:
            pass
        self.rejecting_until = time.monotonic() + 2.0

    def run(self):
        stream = gbproto.FrameStream(self.sock)
        reason = "connection closed by Glass"
        try:
            while True:
                frame = stream.read()
                if frame is None:
                    break
                self.last_rx = time.monotonic()
                self.ping_outstanding = False
                if self.rejecting_until is not None:
                    continue
                self.server.handle_frame(self, frame)
        except ProtocolError as e:
            reason = "protocol error: %s" % e
        except OSError as e:
            if not self.closed:
                reason = "socket error: %s" % e
        except Exception as e:  # keep the server alive whatever happens
            reason = "internal error: %r" % (e,)
        self.close(reason)


class PhoneServer(object):
    def __init__(self, port=gbproto.DEFAULT_PORT, host="0.0.0.0", auth=True, selftest=False,
                 phone_name="fake_phone", received_dir="received", keep_frames=200,
                 ping_after=15.0, dead_after=30.0, hello_timeout=10.0, pair_window=120.0,
                 quiet_frames=False):
        self.port = port
        self.host = host
        self.auth = auth
        self.selftest = selftest
        self.phone_name = phone_name
        self.ping_after = ping_after
        self.dead_after = dead_after
        self.hello_timeout = hello_timeout
        self.pair_window = pair_window
        self.quiet_frames = quiet_frames
        self.lock = threading.RLock()
        self.sessions = []
        self.current = None
        self.waiting = None
        self.token = None
        self.pair_code = None
        self.window_deadline = None
        self._window_was_open = False
        self.sync_enabled = True
        self.cast_on = bool(selftest)
        self.cast_fps = 2
        self.queue = []          # [(expires_monotonic, card)]
        self.nav = None
        self.nav_step = 0
        self.last_card_id = None
        self.last_status = None
        self.media = MediaReceiver(received_dir)
        frames_dir = os.path.join(received_dir, "frames") if received_dir else None
        self.frames = FrameSaver(frames_dir, keep_frames)
        self.listener = None
        self._count = 0
        self._stop = threading.Event()

    # ----- lifecycle -------------------------------------------------------

    def start(self):
        self.listener = socket.create_server((self.host, self.port), backlog=8)
        self.port = self.listener.getsockname()[1]
        if self.auth and not self.selftest and self.token is None:
            self.open_window(announce=False)
        threading.Thread(target=self._accept_loop, name="accept", daemon=True).start()
        threading.Thread(target=self._watchdog, name="watchdog", daemon=True).start()

    def stop(self):
        self._stop.set()
        try:
            self.listener.close()
        except OSError:
            pass
        with self.lock:
            sessions = list(self.sessions)
        for s in sessions:
            s.close("fake_phone shutting down")

    def _accept_loop(self):
        while not self._stop.is_set():
            try:
                sock, addr = self.listener.accept()
            except OSError:
                if self._stop.is_set():
                    return
                time.sleep(0.2)
                continue
            try:
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            except OSError:
                pass
            with self.lock:
                self._count += 1
                session = Session(self, sock, addr, self._count)
                self.sessions.append(session)
                old_wait = self.waiting
                self.waiting = session
            log("Connection %s opened (waiting for hello)" % session.label())
            if old_wait is not None:
                old_wait.close("replaced by a newer connection waiting for acceptance")
            threading.Thread(target=session.run, name="session-%d" % session.n, daemon=True).start()

    def session_closed(self, session, reason):
        was_current = False
        with self.lock:
            if session in self.sessions:
                self.sessions.remove(session)
            if self.waiting is session:
                self.waiting = None
            if self.current is session:
                self.current = None
                was_current = True
        self.media.abort(session)
        if was_current:
            log("Glass disconnected %s: %s" % (session.label(), reason))
            if self.selftest:
                log("SELFTEST session %d closed: %s" % (session.n, reason))
        else:
            log("Connection %s closed: %s" % (session.label(), reason))

    def _watchdog(self):
        while not self._stop.is_set():
            time.sleep(0.2)
            now = time.monotonic()
            with self.lock:
                sessions = list(self.sessions)
                window_open = self.window_open()
                if self._window_was_open and not window_open and not self.selftest:
                    log("Pairing window closed")
                self._window_was_open = window_open
                self.queue = [(exp, c) for (exp, c) in self.queue if exp > now]
            for s in sessions:
                if s.closed:
                    continue
                if s.rejecting_until is not None:
                    if now >= s.rejecting_until:
                        s.close("rejected")
                    continue
                if not s.accepted and now - s.connected_at >= self.hello_timeout:
                    s.close("no acceptable hello within %g s" % self.hello_timeout)
                    continue
                silence = now - s.last_rx
                if silence >= self.dead_after:
                    s.close("nothing received for %g s" % self.dead_after)
                elif s.accepted and silence >= self.ping_after and not s.ping_outstanding:
                    # Before acceptance the phone sends nothing but pong/welcome/rejected.
                    s.ping_outstanding = True
                    s.send({"type": "ping"})

    # ----- pairing ---------------------------------------------------------

    def window_open(self):
        if self.selftest:
            return True
        return self.window_deadline is not None and time.monotonic() < self.window_deadline

    def open_window(self, announce=True):
        with self.lock:
            self.window_deadline = time.monotonic() + self.pair_window
            self._window_was_open = True
        log("Pairing window open for %d s: start (or restart) GlassBridge on Glass to pair"
            % self.pair_window)

    def forget(self):
        with self.lock:
            had = self.token is not None
            self.token = None
            self.pair_code = None
            current = self.current
        log("Forgot the paired Glass" if had else "No Glass was paired")
        if current is not None:
            current.close("forgotten (Forget Glass)")

    def _decide(self, hello):
        tok = hello.get("token")
        has_tok = isinstance(tok, str) and tok != ""
        if not self.auth:
            return "accept", None
        if self.token is not None and has_tok and hmac.compare_digest(
                tok.encode("utf-8"), self.token.encode("utf-8")):
            return "accept", None
        if self.window_open():
            return "pair", None
        if has_tok and self.token is not None:
            return "reject", "bad_token"
        return "reject", "pairing_required"

    # ----- frames ----------------------------------------------------------

    def handle_frame(self, s, frame):
        obj, payload = frame.obj, frame.payload
        t = frame.type
        if t == "frame" and self.quiet_frames:
            pass
        else:
            log("<- [%d] %s" % (s.n, gbproto.describe(obj, payload)))
        if t == "ping":
            s.send({"type": "pong"})
            if self.selftest and s.accepted:
                self._st_card(s, "st-ping", "ping answered")
                log("SELFTEST ping answered with pong")
            return
        if not s.accepted:
            if t == "hello":
                self._on_hello(s, obj)
            else:
                log("Ignored %r from %s: hello not accepted yet" % (t, s.label()))
            return
        if s is not self.current:
            return
        if t == "hello":
            log("Ignored a second hello on an accepted session")
        elif t == "pong":
            if self.selftest:
                log("SELFTEST pong received")
                self._st_card(s, "st-pong", "pong received")
        elif t == "status":
            self.last_status = obj
            log("STATUS battery %s%%%s, storage %s/%s MB free, wifi %s (%s dBm), mock_location %s, "
                "screen_on %s, uptime %s s" % (
                    obj.get("battery"), " charging" if obj.get("charging") else "",
                    obj.get("storage_free_mb"), obj.get("storage_total_mb"), obj.get("wifi_ssid"),
                    obj.get("wifi_rssi"), obj.get("mock_location"), obj.get("screen_on"),
                    obj.get("uptime_s")))
            if self.selftest:
                b = obj.get("battery")
                log("SELFTEST status received battery=%s" % (b,))
                self._st_card(s, "st-card", "status battery=%s" % (b,), battery=b)
        elif t == "ack":
            log("ACK %s %s" % (obj.get("id"), obj.get("event")))
            if self.selftest and obj.get("id") == "st-card":
                ev = obj.get("event")
                log("SELFTEST ack st-card %s" % (ev,))
                self._st_card(s, "st-ack", "ack st-card %s" % (ev,), ack_id="st-card", event=ev)
        elif t == "file_begin":
            self.media.begin(s, obj)
        elif t == "file_chunk":
            self.media.chunk(s, obj, payload)
        elif t == "file_end":
            ack = self.media.end(s, obj)
            s.send(ack)
            if self.selftest:
                log("SELFTEST upload %s ok=%s received=%d sha256=%s%s" % (
                    ack.get("id"), ack.get("ok"), ack.get("received", 0), ack.get("sha256"),
                    "" if ack.get("ok") else " error=%s" % ack.get("error")))
        elif t == "frame":
            data = payload or b""
            path = self.frames.save(data)
            if self.quiet_frames:
                if self.frames.n % 10 == 1:
                    log("<- frames: %d received so far (latest %sx%s, %d bytes)" % (
                        self.frames.n, obj.get("w"), obj.get("h"), len(data)))
            elif path and (self.frames.n == 1 or self.frames.n % 50 == 0):
                log("Frame %d saved to %s (and latest.jpg)" % (self.frames.n, path))
            if path and self.frames.n == 1:
                log("Live view: open %s in a browser" % os.path.abspath(
                    os.path.join(self.frames.dir, "view.html")))
            if self.selftest:
                w, h = obj.get("w"), obj.get("h")
                digest = hashlib.sha256(data).hexdigest()
                log("SELFTEST frame %sx%s %d bytes sha256=%s" % (w, h, len(data), digest))
                self._st_card(s, "st-frame", "frame %sx%s %d bytes" % (w, h, len(data)),
                              w=w, h=h, size=len(data), sha256=digest,
                              jpeg=data[:3] == b"\xff\xd8\xff")
        elif t == "wifi_result":
            log("WIFI %s: %s%s" % (obj.get("ssid"), "ok" if obj.get("ok") else "FAILED",
                                   "" if obj.get("ok") else " (%s)" % obj.get("error")))
        else:
            log("Ignored unknown type %r" % (t,))

    def _st_card(self, s, cid, text, **extra):
        card = {"type": "card", "id": cid, "title": "Selftest", "text": text,
                "source": "fake_phone", "style": "info", "time": gbproto.now_ms()}
        card.update(extra)
        s.send(card)

    def _on_hello(self, s, obj):
        s.device = {k: obj.get(k) for k in ("device", "version", "model", "firmware", "app_version")}
        old = None
        with self.lock:
            if s.closed:
                return
            decision, reason = self._decide(obj)
            if decision == "reject":
                if self.waiting is s:
                    self.waiting = None
                if reason == "bad_token":
                    msg = "This Glass isn't paired with this phone. Type 'pair' in fake_phone, then retry."
                else:
                    msg = "Pairing required. Type 'pair' in fake_phone's console."
                log("REJECTED %s: %s%s" % (s.label(), reason, "" if self.selftest else
                                            " (type 'pair' to let this Glass pair)"))
                if self.selftest:
                    log("SELFTEST rejected %s" % reason)
                s.reject(reason, msg)
                return
            welcome = {"type": "welcome", "server": "fake_phone", "version": gbproto.PROTOCOL_VERSION,
                       "phone_name": self.phone_name}
            if decision == "pair":
                self.token = secrets.token_hex(16)
                self.pair_code = "%04d" % secrets.randbelow(10000)
                if not self.selftest:
                    self.window_deadline = None
                welcome["pair_token"] = self.token
                welcome["pair_code"] = self.pair_code
            old = self.current
            if self.waiting is s:
                self.waiting = None
            s.accepted = True
            self.current = s
            if decision == "pair":
                log("PAIRED new Glass %s: code %s. Check that Glass shows the same code."
                    % (s.label(), self.pair_code))
            else:
                log("Glass accepted %s (%s)" % (s.label(),
                                                "token ok" if self.auth else "--no-auth"))
            log("Device: model %s, firmware %s, app %s" % (
                obj.get("model"), obj.get("firmware"), obj.get("app_version")))
            if self.selftest:
                log("SELFTEST hello accepted (%s)" % (
                    "paired, code %s" % self.pair_code if decision == "pair" else "token ok"))
            s.send(welcome)
            s.send({"type": "sync", "enabled": self.sync_enabled})
            if self.cast_on:
                s.send({"type": "screencast", "on": True, "fps": self.cast_fps})
            now = time.monotonic()
            queued = [c for (exp, c) in self.queue if exp > now]
            self.queue = []
            for card in queued:
                s.send(card)
            if self.nav is not None:
                nav = dict(self.nav)
                nav["announce"] = False
                s.send(nav)
            if self.selftest:
                s.send({"type": "ping"})
                log("SELFTEST welcome, sync, screencast and ping sent")
        if old is not None and old is not s:
            old.close("replaced by a newly accepted Glass")

    # ----- console actions -------------------------------------------------

    def send_to_glass(self, obj, payload=None, quiet_if_absent=False):
        with self.lock:
            s = self.current
            if s is None:
                if not quiet_if_absent:
                    log("No Glass connected; %s not sent" % obj.get("type"))
                return False
            return s.send(obj, payload)

    def send_card(self, card):
        self.last_card_id = card["id"]
        with self.lock:
            if self.current is None:
                self.queue.append((time.monotonic() + QUEUE_TTL_S, card))
                log("No Glass connected; card %s queued for 10 minutes" % card["id"])
                return
            self.current.send(card)

    def status_text(self):
        with self.lock:
            lines = []
            s = self.current
            if s is None:
                lines.append("Link: no Glass connected")
            else:
                lines.append("Link: Glass %s connected for %d s" % (
                    s.label(), time.monotonic() - s.connected_at))
                if s.device:
                    lines.append("Device: %s" % json.dumps(s.device))
            if self.waiting is not None:
                lines.append("Waiting connection: %s" % self.waiting.label())
            if not self.auth:
                lines.append("Pairing: off (--no-auth)")
            else:
                paired = "paired (code %s)" % self.pair_code if self.token else "not paired"
                if self.selftest:
                    win = "window always open (--selftest)"
                elif self.window_open():
                    win = "window open, %d s left" % (self.window_deadline - time.monotonic())
                else:
                    win = "window closed"
                lines.append("Pairing: %s, %s" % (paired, win))
            lines.append("Phone name: %s" % self.phone_name)
            lines.append("Sync: %s, screencast: %s%s, queued cards: %d, nav: %s" % (
                "on" if self.sync_enabled else "off", "on" if self.cast_on else "off",
                " @%d fps" % self.cast_fps if self.cast_on else "", len(self.queue),
                "active" if self.nav else "none"))
            if self.last_status:
                lines.append("Last status: %s" % gbproto.describe(self.last_status))
            return "\n".join(lines)


def _card_id():
    return "c-" + secrets.token_hex(4)


def _split_pipe(rest, default_title):
    if "|" in rest:
        a, b = rest.split("|", 1)
        return a.strip(), b.strip()
    return default_title, rest.strip()


def run_command(server, line):
    """Run one console line. Returns False when the console should quit."""
    line = line.strip()
    if not line or line.startswith("#"):
        return True
    cmd, _, rest = line.partition(" ")
    cmd = cmd.lower()
    rest = rest.strip()
    try:
        if cmd in ("quit", "exit", "q"):
            return False
        elif cmd in ("help", "?"):
            with _print_lock:
                print(__doc__.split("Console commands:")[1].split("--selftest")[0].rstrip())
        elif cmd == "card":
            title, text = _split_pipe(rest, "fake_phone")
            server.send_card({"type": "card", "id": _card_id(), "title": title, "text": text,
                              "source": "fake_phone", "time": gbproto.now_ms(), "style": "info"})
        elif cmd == "notify":
            app, text = _split_pipe(rest, "Notification")
            server.send_card({"type": "card", "id": _card_id(), "title": app, "text": text,
                              "source": app, "time": gbproto.now_ms(), "style": "notification",
                              "chime": True, "wake": True})
        elif cmd == "dismiss":
            cid = rest or server.last_card_id
            if not cid:
                log("usage: dismiss <id>")
            else:
                server.send_to_glass({"type": "dismiss", "id": cid})
        elif cmd == "speak":
            if not rest:
                log("usage: speak <text>")
            else:
                server.send_to_glass({"type": "speak", "text": rest})
        elif cmd == "nav":
            parts = rest.split(None, 2)
            if len(parts) < 2:
                log("usage: nav <maneuver> <metres> <instruction...>")
                return True
            maneuver = parts[0].lower()
            metres = float(parts[1])
            if metres == int(metres):
                metres = int(metres)
            instruction = parts[2] if len(parts) > 2 else maneuver.replace("_", " ").capitalize()
            if maneuver not in MANEUVERS:
                log("note: %r is not a known maneuver; Glass should show it as straight" % maneuver)
            with server.lock:
                prev = server.nav
                if prev is None:
                    server.nav_step = 1
                elif prev.get("instruction") != instruction or prev.get("maneuver") != maneuver:
                    server.nav_step += 1
                step = server.nav_step
                changed = prev is None or step != prev.get("step")
                nav = {"type": "nav", "instruction": instruction, "maneuver": maneuver,
                       "distance_m": metres, "step": step, "steps_total": max(5, step),
                       "eta_min": max(1, int(round(metres / 80.0))), "remaining_m": metres,
                       "destination": "Fake destination", "arrived": maneuver == "arrive",
                       "announce": changed}
                server.nav = nav
            if not server.send_to_glass(nav, quiet_if_absent=True):
                log("No Glass connected; nav card kept and sent (not announced) on connect")
        elif cmd == "navend":
            with server.lock:
                server.nav = None
                server.nav_step = 0
            server.send_to_glass({"type": "nav_end"})
        elif cmd == "loc":
            parts = rest.split()
            if len(parts) < 2:
                log("usage: loc <lat> <lon> [acc_m]")
                return True
            fix = {"type": "location", "lat": float(parts[0]), "lon": float(parts[1]),
                   "acc_m": float(parts[2]) if len(parts) > 2 else 5.0, "time": gbproto.now_ms()}
            server.send_to_glass(fix)
        elif cmd == "sync":
            if rest not in ("on", "off"):
                log("usage: sync on|off")
                return True
            server.sync_enabled = rest == "on"
            if not server.send_to_glass({"type": "sync", "enabled": server.sync_enabled},
                                        quiet_if_absent=True):
                log("Sync %s (sent when Glass connects)" % rest)
        elif cmd == "cast":
            parts = rest.split()
            if not parts or parts[0] not in ("on", "off"):
                log("usage: cast on|off [fps]")
                return True
            server.cast_on = parts[0] == "on"
            if len(parts) > 1:
                server.cast_fps = max(1, min(5, int(parts[1])))
            msg = {"type": "screencast", "on": server.cast_on}
            if server.cast_on:
                msg["fps"] = server.cast_fps
            if not server.send_to_glass(msg, quiet_if_absent=True):
                log("Screencast %s (sent when Glass connects)" % parts[0])
        elif cmd == "status":
            for text in server.status_text().split("\n"):
                log(text)
            server.send_to_glass({"type": "request_status"}, quiet_if_absent=True)
        elif cmd == "wifi":
            parts = shlex.split(rest)
            if not parts:
                log("usage: wifi <ssid> [<password>] [WPA|WEP|OPEN]")
                return True
            ssid = parts[0]
            password = parts[1] if len(parts) > 1 else ""
            security = parts[2].upper() if len(parts) > 2 else ("WPA" if password else "OPEN")
            msg = {"type": "wifi_add", "ssid": ssid, "security": security}
            if password and security != "OPEN":
                msg["password"] = password
            server.send_to_glass(msg)
        elif cmd == "ping":
            server.send_to_glass({"type": "ping"})
        elif cmd == "pair":
            if not server.auth:
                log("Pairing is off (--no-auth)")
            else:
                server.open_window()
        elif cmd == "forget":
            server.forget()
        elif cmd == "name":
            if not rest:
                log("usage: name <phone name>")
            else:
                server.phone_name = rest
                log("Phone name is now %r (sent in the next welcome)" % rest)
        elif cmd == "raw":
            obj = json.loads(rest)
            if not isinstance(obj, dict) or not isinstance(obj.get("type"), str):
                log("raw needs a JSON object with a string \"type\"")
            else:
                gbproto.encode(obj)  # raises ValueError/ProtocolError before anything is sent
                server.send_to_glass(obj)
        else:
            log("Unknown command %r. Type 'help'." % cmd)
    except (ValueError, KeyError, ProtocolError) as e:
        log("Error: %s" % e)
    except Exception as e:  # never let a typo kill the console
        log("Error: %r" % (e,))
    return True


def _local_ips():
    ips = []
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(("10.255.255.255", 1))  # no packet is sent
        ips.append(probe.getsockname()[0])
        probe.close()
    except OSError:
        pass
    return ips


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Pretend to be the GlassBridge iPhone app (TCP server, PROTOCOL.md v2).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Console commands: card, notify, dismiss, speak, nav, navend, loc, sync, cast, "
               "status, wifi, ping, pair, forget, name, raw, help, quit.\n"
               "See the docstring at the top of this file for details and the --selftest script.")
    parser.add_argument("--port", type=int, default=gbproto.DEFAULT_PORT, help="TCP port (default 9090)")
    parser.add_argument("--host", default="0.0.0.0", help="address to bind (default 0.0.0.0)")
    parser.add_argument("--selftest", action="store_true",
                        help="non-interactive scripted mode for the Kotlin LiveLinkTest")
    parser.add_argument("--no-auth", action="store_true", help="disable pairing: accept every hello")
    parser.add_argument("--name", default="fake_phone", help="phone_name sent in welcome")
    parser.add_argument("--received-dir", default=None,
                        help="where uploads and frames go (default ./received; "
                             "with --selftest nothing is written unless this is given)")
    parser.add_argument("--keep-frames", type=int, default=200,
                        help="numbered screencast frames to keep (0 = all; default 200)")
    parser.add_argument("--quiet-frames", action="store_true",
                        help="don't print every screencast frame (one line per 10)")
    parser.add_argument("--ping-after", type=float, default=15.0, metavar="S",
                        help="testing: send ping after S s of silence (default 15)")
    parser.add_argument("--dead-after", type=float, default=30.0, metavar="S",
                        help="testing: drop the link after S s of silence (default 30)")
    parser.add_argument("--hello-timeout", type=float, default=10.0, metavar="S",
                        help="testing: close a connection with no accepted hello after S s (default 10)")
    parser.add_argument("--pair-window", type=float, default=120.0, metavar="S",
                        help="testing: pairing window length in s (default 120)")
    args = parser.parse_args(argv)

    try:
        sys.stdout.reconfigure(errors="replace", line_buffering=True)
    except (AttributeError, ValueError):
        pass

    received = args.received_dir
    if received is None and not args.selftest:
        received = "received"
    server = PhoneServer(port=args.port, host=args.host, auth=not args.no_auth,
                         selftest=args.selftest, phone_name=args.name, received_dir=received,
                         keep_frames=args.keep_frames, ping_after=args.ping_after,
                         dead_after=args.dead_after, hello_timeout=args.hello_timeout,
                         pair_window=args.pair_window, quiet_frames=args.quiet_frames)
    try:
        server.start()
    except OSError as e:
        log("Can't listen on %s:%d: %s" % (args.host, args.port, e))
        return 1

    def _term(signum, frame):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, _term)

    log("Listening on %s:%d (protocol v2, phone_name %r, pairing %s)" % (
        args.host, server.port, server.phone_name,
        "off" if args.no_auth else ("always open" if args.selftest else "on")))
    try:
        if args.selftest:
            log("SELFTEST ready port=%d" % server.port)
            while True:
                time.sleep(1)
        for ip in _local_ips():
            log("This machine: %s. On Glass: python3 tools/glass_adb.py config %s %d"
                % (ip, ip, server.port))
        if received:
            log("Uploads go to %s/, screencast frames to %s/frames/ (open view.html there)"
                % (os.path.abspath(received), os.path.abspath(received)))
        log("Type 'help' for commands.")
        interactive = sys.stdin.isatty()
        while True:
            try:
                line = input("gb> " if interactive else "")
            except EOFError:
                log("stdin closed; still serving. Ctrl-C to stop.")
                while True:
                    time.sleep(1)
            if not run_command(server, line):
                break
    except KeyboardInterrupt:
        pass
    finally:
        server.stop()
        log("fake_phone stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
