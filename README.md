# GlassBridge

GlassBridge brings Google Glass Explorer Edition back to life on its final firmware, XE24,
with an iPhone in place of Google's dead MyGlass servers. The iPhone app is the server; the
Glass app dials it over Wi-Fi (usually the iPhone's Personal Hotspot) and keeps one TCP link
open for everything.

| Feature | How |
|---|---|
| Cards and notifications | Cards from the iPhone app, and a Shortcuts "Send to Glass" action for iMessage and email automations |
| Directions | Apple Maps routing on the iPhone; turn cards with arrows and spoken turns on Glass |
| Phone GPS on Glass | iPhone location injected as Android's mock GPS (one adb command to enable) |
| Photo and video backup | New Glass shots upload to the iPhone and land in Photos |
| Screencast | Live view of the GlassBridge screen on the iPhone |
| Wi-Fi setup | A `WIFI:` QR code, a push to a linked Glass, or `wifi.json` over adb |
| Device info and Find my Glass | Battery, storage, Wi-Fi and firmware; last-connected time and place |
| Pairing | A one-time pairing code so only your Glass can connect |

Calls work without any of this: pair Glass as a Bluetooth headset in iPhone Settings.

## Status

Built in October 2026; nothing has run on real Glass or a real iPhone yet, and the iPhone app
outside `Core/` hasn't been compiled by Xcode. `TESTING.md` is the hardware runbook, and
`CLAUDE.md` keeps the list of what has and hasn't been verified.

## Layout

| Path | Contents |
|---|---|
| `PROTOCOL.md` | Wire protocol v2: JSON Lines over TCP 9090, raw binary payloads, pairing. The contract between the apps. |
| `glass/` | Glass app: plain Android for API 19 (KitKat), Kotlin, no dependencies |
| `ios/` | iPhone app: SwiftUI for iOS 17+, XcodeGen project |
| `tools/` | Python stand-ins for each side, protocol reference, cross-language checks, adb helper |
| `dist/GlassBridge-debug.apk` | Prebuilt Glass APK |
| `TESTING.md` | Hardware test runbook |
| `CLAUDE.md` | Project rules, owner decisions, verification ledger |

## Glass app

Install the prebuilt APK on a Glass with debug mode on (Settings › Device info › Turn on debug):

```
python3 tools/glass_adb.py install      # adb install -r dist/GlassBridge-debug.apk
python3 tools/glass_adb.py mock         # adb shell settings put secure mock_location 1
python3 tools/glass_adb.py launch       # open the card screen (starts the service)
```

`python3 tools/glass_adb.py --help` lists the rest: `config` (point Glass at a laptop),
`wifi` (push a network), `screen` (screenshot), `logs`, `status`, `invert-swipe`.

To build it yourself you need JDK 17 or later and the Android SDK (platform 35, build-tools
35.0.0); Android Studio provides both. Put `sdk.dir=…` in `glass/local.properties` or set
`ANDROID_HOME`, then:

```
cd glass && ./gradlew assembleDebug     # app/build/outputs/apk/debug/app-debug.apk
```

Debug builds are signed with the committed `glass/debug.keystore`, so APKs from any machine
install over each other.

## iPhone app

```
brew install xcodegen
cd ios && xcodegen && open GlassBridge.xcodeproj
```

Set your Team under Signing & Capabilities and run on an iPhone. A free Apple ID works, but
the install expires after 7 days.

Set up: Personal Hotspot with **Maximize Compatibility** on (Glass is 2.4 GHz only), allow
Local Network, then Glass tab › Pair Glass and check both screens show the same code. The
Tools tab has a setup guide.

## Automated checks

No hardware needed. From the repo root:

```
python3 tools/test_e2e.py                               # stand-ins, framing, pairing, end to end
(cd glass && ./gradlew testDebugUnitTest)               # FramingTest and core tests (LiveLinkTest skips)
python3 tools/fake_phone.py --selftest --port 9191 &
(cd glass && GLASSBRIDGE_TEST_PORT=9191 ./gradlew testDebugUnitTest)   # LiveLinkTest runs too
kill %1
(cd glass && ./gradlew lintDebug)                       # expect no NewApi issues
tools/swift-check/run.sh                                # iPhone Core vs Python (Swift 6.x)
ios/LinuxCheck/run.sh                                   # Linux only: app type-check against framework stand-ins
```

## Stand-ins

Each app can be tested without the other:

- `python3 tools/fake_phone.py` pretends to be the iPhone: listens on 9090 with a console
  (`card`, `notify`, `nav`, `speak`, `loc`, `cast on`, `wifi`, `pair`, `help` and more), and
  saves photos and screencast frames to `./received/`. Point Glass at it with
  `python3 tools/glass_adb.py config <mac-ip>`.
- `python3 tools/fake_glass.py <iphone-ip>` pretends to be Glass: dials the iPhone app,
  prints everything, and can `--upload` a photo or send a `--frame`.

## Not yet built

Phase 2 is every iPhone notification and caller ID through Apple's ANCS over Bluetooth LE,
read by Glass directly; after that, media controls through AMS. See the build brief.
