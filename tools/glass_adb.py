#!/usr/bin/env python3
"""glass_adb.py: adb helpers for testing GlassBridge on Glass (macOS or Linux).

Standard library only, Python 3.9+. Needs adb on PATH (macOS:
`brew install --cask android-platform-tools`), or pass --adb /path/to/adb, or set ADB.

    python3 tools/glass_adb.py install                 # dist/GlassBridge-debug.apk, adb install -r
    python3 tools/glass_adb.py mock                    # allow mock locations (once per Glass)
    python3 tools/glass_adb.py config 192.168.1.20     # dial this host (port 9090) instead of discovery
    python3 tools/glass_adb.py start                   # start BridgeService (re-reads wifi.json)
    python3 tools/glass_adb.py launch                  # open the card screen
    python3 tools/glass_adb.py screen --watch 2        # screenshots into ./screens/ every 2 s
    python3 tools/glass_adb.py logs                    # GlassBridge + GlassBridgeInput logcat
    python3 tools/glass_adb.py status                  # battery, service, config.json, mock setting
    python3 tools/glass_adb.py setup 192.168.1.20      # install + mock + config + start + launch

Subcommands:
  devices                       adb devices -l
  install [apk]                 adb install -r (default dist/GlassBridge-debug.apk). On
                                INSTALL_FAILED_UPDATE_INCOMPATIBLE it prints the uninstall advice.
  uninstall                     adb uninstall au.interstellr.glassbridge (deletes app data,
                                including the pairing token)
  mock                          adb shell settings put secure mock_location 1, then reads it back
  start                         adb shell am startservice -n au.interstellr.glassbridge/.BridgeService
  launch                        adb shell am start -n au.interstellr.glassbridge/.MainActivity
  config <host> [port]          set "host" (and "port", default 9090) in config.json
  config-clear                  remove "host" and "port" from config.json (other keys stay; the
                                file is deleted if nothing is left)
  config-show                   print config.json
  invert-swipe on|off           set "invert_swipe" in config.json
  wifi <ssid> <password> [WPA|WEP|OPEN]
                                push wifi.json (Glass reads and deletes it), then startservice so
                                the running service re-reads it. Use "" as the password for OPEN.
  screen [--watch S] [--open]   adb shell screencap -p /sdcard/gb_screen.png, adb pull to
                                ./screens/<timestamp>.png and ./screens/latest.png
  logs [--clear] [--all] [--dump]
                                adb logcat -v time -s GlassBridge GlassBridgeInput (plus crashes:
                                AndroidRuntime:E, System.err:W)
  status                        app version, BridgeService running?, mock_location, battery,
                                Wi-Fi, config.json
  setup [host] [port]           install, mock, config (if host given), start, launch

config.json is read-modify-written (adb pull, change, adb push), so keys this tool doesn't
know about are kept. The files dir is created first if it doesn't exist:
/sdcard/Android/data/au.interstellr.glassbridge/files/
"""

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

PKG = "au.interstellr.glassbridge"
FILES_DIR = "/sdcard/Android/data/%s/files" % PKG
REMOTE_CONFIG = FILES_DIR + "/config.json"
REMOTE_WIFI = FILES_DIR + "/wifi.json"
REMOTE_SCREEN = "/sdcard/gb_screen.png"
SERVICE = PKG + "/.BridgeService"
ACTIVITY = PKG + "/.MainActivity"
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_APK = os.path.join(REPO, "dist", "GlassBridge-debug.apk")
LOG_FILTER = ["GlassBridge:V", "GlassBridgeInput:V", "AndroidRuntime:E", "System.err:W"]


class Fail(Exception):
    pass


class Adb(object):
    def __init__(self, adb_path=None, serial=None):
        path = adb_path or os.environ.get("ADB") or shutil.which("adb")
        if not path:
            raise Fail("adb not found. Install Android platform-tools "
                       "(macOS: brew install --cask android-platform-tools) or pass --adb PATH.")
        self.path = path
        self.serial = serial

    def argv(self, *args):
        cmd = [self.path]
        if self.serial:
            cmd += ["-s", self.serial]
        return cmd + list(args)

    def run(self, *args, **kw):
        """Run adb with captured output. Returns (returncode, combined output text)."""
        try:
            p = subprocess.run(self.argv(*args), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               timeout=kw.get("timeout", 120))
        except subprocess.TimeoutExpired:
            raise Fail("adb %s timed out. Is Glass connected (adb devices)?" % " ".join(args))
        except OSError as e:
            raise Fail("can't run adb (%s): %s" % (self.path, e))
        return p.returncode, p.stdout.decode("utf-8", "replace")

    def shell(self, command, **kw):
        # Old adbd (KitKat) doesn't pass the remote exit status back, so callers check output.
        return self.run("shell", command, **kw)

    def call(self, *args):
        """Run adb attached to this terminal (for logcat). Returns the exit code."""
        try:
            return subprocess.call(self.argv(*args))
        except KeyboardInterrupt:
            return 0


def say(text):
    sys.stdout.write(text.rstrip("\n") + "\n")
    sys.stdout.flush()


def ensure_files_dir(adb):
    cmd = ("mkdir -p {d} 2>/dev/null || (mkdir /sdcard/Android; mkdir /sdcard/Android/data; "
           "mkdir /sdcard/Android/data/{p}; mkdir {d}) 2>/dev/null; "
           "[ -d {d} ] && echo GB_DIR_OK").format(d=FILES_DIR, p=PKG)
    _rc, out = adb.shell(cmd)
    if "GB_DIR_OK" not in out:
        raise Fail("couldn't create %s on Glass:\n%s" % (FILES_DIR, out.strip()))


def read_config(adb):
    ensure_files_dir(adb)
    with tempfile.TemporaryDirectory() as d:
        local = os.path.join(d, "config.json")
        rc, _out = adb.run("pull", REMOTE_CONFIG, local)
        if rc != 0 or not os.path.exists(local):
            return {}
        with open(local, "r", encoding="utf-8") as f:
            text = f.read()
    if not text.strip():
        return {}
    try:
        cfg = json.loads(text)
    except ValueError as e:
        raise Fail("config.json on Glass isn't valid JSON (%s):\n%s\nFix it, or delete it with: "
                   "adb shell rm %s" % (e, text, REMOTE_CONFIG))
    if not isinstance(cfg, dict):
        raise Fail("config.json on Glass isn't a JSON object:\n%s" % text)
    return cfg


def write_config(adb, cfg):
    if not cfg:
        adb.shell("rm -f %s" % REMOTE_CONFIG)
        say("config.json removed (no keys left). Glass discovers the iPhone on its own.")
        return
    with tempfile.TemporaryDirectory() as d:
        local = os.path.join(d, "config.json")
        with open(local, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2)
            f.write("\n")
        rc, out = adb.run("push", local, REMOTE_CONFIG)
        if rc != 0:
            raise Fail("adb push failed:\n%s" % out.strip())
    say("config.json on Glass is now:\n%s" % json.dumps(cfg, indent=2))
    say("Glass reads it on its next reconnect; the input keys when the card screen opens.")


def cmd_devices(adb, args):
    _rc, out = adb.run("devices", "-l")
    say(out)
    return 0


def cmd_install(adb, args):
    apk = args.apk or DEFAULT_APK
    if not os.path.isfile(apk):
        raise Fail("APK not found: %s (build it with: cd glass && ./gradlew assembleDebug)" % apk)
    say("Installing %s ..." % apk)
    rc, out = adb.run("install", "-r", apk, timeout=300)
    say(out)
    if "INSTALL_FAILED_UPDATE_INCOMPATIBLE" in out:
        say("The installed GlassBridge was signed with a different key. Remove it first "
            "(this deletes its data, including the pairing token):\n"
            "    adb uninstall %s\nthen run install again." % PKG)
        return 1
    if rc != 0 or "Success" not in out:
        say("Install failed.")
        return 1
    say("Installed. Next: python3 tools/glass_adb.py mock, then start.")
    return 0


def cmd_uninstall(adb, args):
    rc, out = adb.run("uninstall", PKG)
    say(out)
    return 0 if rc == 0 and "Success" in out else 1


def cmd_mock(adb, args):
    adb.shell("settings put secure mock_location 1")
    _rc, out = adb.shell("settings get secure mock_location")
    value = out.strip()
    say("mock_location = %s" % value)
    if value != "1":
        say("Mock locations didn't turn on. Is debug mode on (Settings > Device info > Turn on debug)?")
        return 1
    say("Restart the service so it picks this up: python3 tools/glass_adb.py start")
    return 0


def cmd_start(adb, args):
    _rc, out = adb.shell("am startservice -n %s" % SERVICE)
    say(out)
    if "Error" in out or "not found" in out.lower():
        return 1
    return 0


def cmd_launch(adb, args):
    _rc, out = adb.shell("am start -n %s" % ACTIVITY)
    say(out)
    return 1 if "Error" in out else 0


def cmd_config(adb, args):
    cfg = read_config(adb)
    cfg["host"] = args.host
    cfg["port"] = args.port
    write_config(adb, cfg)
    return 0


def cmd_config_clear(adb, args):
    cfg = read_config(adb)
    cfg.pop("host", None)
    cfg.pop("port", None)
    write_config(adb, cfg)
    return 0


def cmd_config_show(adb, args):
    cfg = read_config(adb)
    say(json.dumps(cfg, indent=2) if cfg else "(no config.json)")
    return 0


def cmd_invert_swipe(adb, args):
    cfg = read_config(adb)
    cfg["invert_swipe"] = args.state == "on"
    write_config(adb, cfg)
    return 0


def cmd_wifi(adb, args):
    security = args.security.upper()
    entry = {"ssid": args.ssid, "security": security}
    if security != "OPEN":
        if not args.password:
            raise Fail("a password is needed for %s (use OPEN for an open network)" % security)
        entry["password"] = args.password
    ensure_files_dir(adb)
    d = tempfile.mkdtemp()
    local = os.path.join(d, "wifi.json")
    try:
        with open(local, "w", encoding="utf-8") as f:
            json.dump([entry], f)
        rc, out = adb.run("push", local, REMOTE_WIFI)
    finally:
        shutil.rmtree(d, ignore_errors=True)  # don't leave the password on this machine
    if rc != 0:
        raise Fail("adb push failed:\n%s" % out.strip())
    say("Pushed wifi.json for %r (%s). Starting the service so it reads (and deletes) it ..."
        % (args.ssid, security))
    return cmd_start(adb, args)


def capture_screen(adb, out_dir):
    _rc, out = adb.shell("screencap -p %s" % REMOTE_SCREEN)
    if out.strip():
        say(out.strip())
    os.makedirs(out_dir, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    path = os.path.join(out_dir, "%s.png" % stamp)
    n = 1
    while os.path.exists(path):
        path = os.path.join(out_dir, "%s-%d.png" % (stamp, n))
        n += 1
    rc, out = adb.run("pull", REMOTE_SCREEN, path)
    if rc != 0 or not os.path.exists(path):
        raise Fail("screenshot pull failed:\n%s" % out.strip())
    shutil.copyfile(path, os.path.join(out_dir, "latest.png"))
    return path


def cmd_screen(adb, args):
    out_dir = args.out
    first = True
    try:
        while True:
            path = capture_screen(adb, out_dir)
            say("Saved %s (and %s)" % (path, os.path.join(out_dir, "latest.png")))
            if first and args.open and shutil.which("open"):
                subprocess.call(["open", path])
            first = False
            if not args.watch:
                return 0
            time.sleep(args.watch)
    except KeyboardInterrupt:
        return 0


def cmd_logs(adb, args):
    if args.clear:
        adb.run("logcat", "-c")
    argv = ["logcat", "-v", "time"]
    if args.dump:
        argv.append("-d")
    if not args.all:
        argv += ["-s"] + LOG_FILTER
    say("adb %s   (Ctrl-C to stop)" % " ".join(argv))
    return adb.call(*argv)


def cmd_status(adb, args):
    _rc, out = adb.shell("dumpsys package %s" % PKG)
    m = re.search(r"versionName=(\S+)", out)
    code = re.search(r"versionCode=(\d+)", out)
    if m:
        say("GlassBridge: installed, version %s%s" % (m.group(1), " (code %s)" % code.group(1) if code else ""))
    else:
        say("GlassBridge: not installed")
    _rc, out = adb.shell("dumpsys activity services %s" % PKG)
    say("BridgeService: %s" % ("running" if "BridgeService" in out else "not running"))
    _rc, out = adb.shell("settings get secure mock_location")
    say("mock_location: %s%s" % (out.strip(), "" if out.strip() == "1" else
                                 "  (run: python3 tools/glass_adb.py mock)"))
    _rc, out = adb.shell("dumpsys battery")
    keep = ("AC powered", "USB powered", "status", "level", "scale", "temperature", "voltage")
    say("Battery:")
    for line in out.splitlines():
        if line.strip().split(":")[0] in keep:
            say("  " + line.strip())
    _rc, out = adb.shell("dumpsys wifi")
    wifi = [l.strip() for l in out.splitlines() if "mWifiInfo" in l or l.strip().startswith("SSID:")]
    say("Wi-Fi: %s" % (wifi[0] if wifi else "(unknown)"))
    _rc, out = adb.shell("cat %s" % REMOTE_CONFIG)
    text = out.strip()
    if not text or "No such file" in text or "does not exist" in text:
        say("config.json: (none: Glass discovers the iPhone)")
    else:
        say("config.json: %s" % text)
    return 0


def cmd_setup(adb, args):
    steps = [("install", lambda: cmd_install(adb, args)), ("mock", lambda: cmd_mock(adb, args))]
    if args.host:
        steps.append(("config", lambda: cmd_config(adb, args)))
    steps += [("start", lambda: cmd_start(adb, args)), ("launch", lambda: cmd_launch(adb, args))]
    for name, fn in steps:
        say("== %s" % name)
        rc = fn()
        if rc != 0:
            say("Stopped: %s failed." % name)
            return rc
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="adb helpers for GlassBridge on Glass (package %s)." % PKG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Files dir on Glass: %s/\nSee the docstring at the top of this file for more." % FILES_DIR)
    parser.add_argument("--adb", help="path to adb (default: $ADB, then adb on PATH)")
    parser.add_argument("-s", "--serial", help="device serial, when more than one is connected")
    sub = parser.add_subparsers(dest="cmd", metavar="command")

    sub.add_parser("devices", help="adb devices -l")
    p = sub.add_parser("install", help="adb install -r the debug APK")
    p.add_argument("apk", nargs="?", help="APK (default dist/GlassBridge-debug.apk)")
    sub.add_parser("uninstall", help="adb uninstall GlassBridge (deletes its data)")
    sub.add_parser("mock", help="allow mock locations (settings put secure mock_location 1)")
    sub.add_parser("start", help="start BridgeService (re-reads wifi.json)")
    sub.add_parser("launch", help="open MainActivity")
    p = sub.add_parser("config", help="set host/port in config.json")
    p.add_argument("host")
    p.add_argument("port", nargs="?", type=int, default=9090)
    sub.add_parser("config-clear", help="remove host/port from config.json")
    sub.add_parser("config-show", help="print config.json")
    p = sub.add_parser("invert-swipe", help="set invert_swipe in config.json")
    p.add_argument("state", choices=["on", "off"])
    p = sub.add_parser("wifi", help="push wifi.json and restart the service")
    p.add_argument("ssid")
    p.add_argument("password")
    p.add_argument("security", nargs="?", default="WPA", type=str.upper, choices=["WPA", "WEP", "OPEN"])
    p = sub.add_parser("screen", help="screenshot into ./screens/")
    p.add_argument("--watch", type=float, metavar="SECONDS", help="repeat every SECONDS until Ctrl-C")
    p.add_argument("--open", action="store_true", help="open the first screenshot (macOS 'open')")
    p.add_argument("--out", default="screens", help="output folder (default ./screens)")
    p = sub.add_parser("logs", help="logcat for GlassBridge and GlassBridgeInput")
    p.add_argument("--clear", action="store_true", help="clear the log first")
    p.add_argument("--all", action="store_true", help="every tag, not just GlassBridge's")
    p.add_argument("--dump", action="store_true", help="print the current log and exit")
    sub.add_parser("status", help="app, service, mock_location, battery, Wi-Fi, config.json")
    p = sub.add_parser("setup", help="install + mock + config + start + launch")
    p.add_argument("host", nargs="?")
    p.add_argument("port", nargs="?", type=int, default=9090)
    p.add_argument("--apk", help="APK (default dist/GlassBridge-debug.apk)")

    args = parser.parse_args(argv)
    if not args.cmd:
        parser.print_help()
        return 2
    handlers = {
        "devices": cmd_devices, "install": cmd_install, "uninstall": cmd_uninstall,
        "mock": cmd_mock, "start": cmd_start, "launch": cmd_launch, "config": cmd_config,
        "config-clear": cmd_config_clear, "config-show": cmd_config_show,
        "invert-swipe": cmd_invert_swipe, "wifi": cmd_wifi, "screen": cmd_screen,
        "logs": cmd_logs, "status": cmd_status, "setup": cmd_setup,
    }
    try:
        adb = Adb(args.adb, args.serial)
        return handlers[args.cmd](adb, args)
    except Fail as e:
        say("error: %s" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
