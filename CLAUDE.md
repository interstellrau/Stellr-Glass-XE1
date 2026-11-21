# StellrGlass XE1: notes for Claude

StellrGlass XE1 (formerly GlassBridge) replaces Google's dead MyGlass companion for Glass Explorer Edition on XE24.
There are two apps: an iPhone app (`ios/`, SwiftUI, the TCP server) and a Glass app
(`glass/`, plain Android API 19, the client). Owner: Alexander, Interstellr.

- Glass package: `au.interstellr.glassbridge`
- iPhone bundle ID: `au.interstellr.glassbridge.ios`
- Names: the project is StellrGlass XE1, and both apps show as StellrGlass. Internal
  identifiers keep "GlassBridge" on purpose so new builds install over old ones and stay
  paired: package, bundle ID, Bonjour `_glassbridge._tcp`, logcat tags, `welcome.server`
  (`GlassBridge iOS`), BLE service UUID, the Xcode project/target/scheme, and code names.
- The repo is public under MIT and unmaintained (November 2026).

## Ground rules

- **`PROTOCOL.md` is the contract.** Change it before changing either side.
- **Never TypeScript.** Any JavaScript must be plain JavaScript. Glass is Kotlin, iPhone is
  Swift, and test stand-ins are Python with only the standard library.
- **Keep protocol code free of platform imports.** Glass `core/` has no `android.*` imports, so
  it runs in JVM unit tests. iPhone `Core/` imports Foundation only, so it builds on Linux.
- **There's no hardware in the build environment.** Each app is tested against a Python
  stand-in for the other side (`tools/`).
- **Be honest about verification.** Keep the ledger below current. Never claim behaviour on
  real Glass or a real iPhone that nobody has seen.
- **Sandbox workarounds stay out of the repo.** Maven Central returns HTTP 429 in the cloud
  sandbox. The workaround is an init script in `~/.gradle/init.d/` pointing at Google's mirror.
  The repo itself uses the standard repositories.

## Repo layout

| Path | Contents |
|---|---|
| `PROTOCOL.md` | Wire protocol v2, the contract |
| `glass/` | Android app (Gradle). `core/` package is platform-free. |
| `ios/` | iPhone app (XcodeGen `project.yml`). `GlassBridge/Core/` is Foundation-only. |
| `tools/` | Python stand-ins (`fake_phone.py`, `fake_glass.py`), `gbproto.py`, cross-language checks, adb helpers |
| `dist/` | Prebuilt debug APK |
| `TESTING.md` | Hardware test runbook |

## Owner decisions (October 2026, beyond the build brief)

These were decided by Alexander before the overnight build. They override the brief where
they differ.

1. **Pairing token is in.** `PROTOCOL.md` §6. Pair button on the iPhone (Glass tab) opens a
   2-minute window; it also opens automatically on launch / foreground while nothing is paired.
   Both screens show the same 4-digit code. The token is enforced on every network, hotspot
   included. Forget Glass resets.
2. **Editable phone name.** The Tools tab has a "Name shown on Glass" field, stored in
   `UserDefaults` (`phoneName`), defaulting to `UIDevice.current.name`. It is sent as
   `welcome.phone_name`. (`UIDevice.current.name` returns just "iPhone" on iOS 16+.)
3. **Runtime input switches on Glass.** `config.json` may hold `invert_swipe` (`PROTOCOL.md`
   §8), so swipe direction can be flipped without a rebuild. `host` is optional: a
   `config.json` without `host` doesn't override discovery.
4. **Tap handling.** A tap is accepted as `KEYCODE_DPAD_CENTER`, `KEYCODE_ENTER`, or a touchpad
   tap gesture from `onGenericMotionEvent` (down/up with little movement, short duration).
   Tap actions are debounced (400 ms) so one physical tap that arrives two ways only acts
   once. Every key event and touchpad motion event is logged to logcat under tag
   `GlassBridgeInput`, to settle open questions 4–5 on real hardware.
5. **Shared debug keystore.** `glass/debug.keystore` (store/key password `android`, alias
   `androiddebugkey`) is committed and used for debug builds, so APKs from any machine install
   over each other. It's a debug key only.
6. **Delivery.** Pushed straight to `main`. No CI. The iPhone app outside `Core/` can only be
   compiled on a Mac, so the first Xcode build is the first compile.
7. **Test setup in the morning.** Glass on XE24 with adb working, a Mac with Xcode 26, an iPhone
   on iOS 26 with Personal Hotspot. The prism's mirror lens isn't fitted yet, so the Glass
   screen is checked with adb screencap or screencast.

## Verification ledger

Status of every check. "Verified" means it was run and passed, with the environment named.
Update this when anything is run on real hardware.

### Verified

All in the cloud sandbox (Linux, JDK 21, Android SDK 35, Swift 6.1.2), with no Glass, iPhone or
Mac, on 1 November 2026.

| Check | How | Result |
|---|---|---|
| Python stand-ins, framing, pairing, end to end | `python3 tools/test_e2e.py` | 28/28 pass on Python 3.13 and 3.9; byte-identical upload; every §6 pairing branch |
| Glass JVM tests | `./gradlew testDebugUnitTest` with `fake_phone.py --selftest` on 9191 | 80 tests, 0 failures; LiveLinkTest ran (6) incl. a 600 KB upload with matching SHA-256 |
| Glass APK builds | `./gradlew assembleDebug` (AGP 8.8.0, Kotlin 1.9.22, Gradle 8.10.2) | Pass. `dist/GlassBridge-debug.apk`: minSdk 19, targetSdk 19, versionCode 2 / 2.0 |
| No APIs above 19 | `./gradlew lintDebug`, plus dexdump of the APK against `api-versions.xml` | 0 NewApi; no app call above API 19. Remaining lint errors are deliberate: ExpiredTargetSdkVersion, MockLocation, ProtectedPermissions, WrongConstant ×2 (Criteria) |
| APK signing | `apksigner verify --print-certs` | Signed with `glass/debug.keystore` (SHA-256 f3b974dd…99b6) |
| iPhone Core vs Python | `tools/swift-check/run.sh` | All four parts pass: stream parse at every read size, re-encode verified by Python, NavTracker synthetic routes, classify / Wi-Fi QR / pairing / limits |
| iPhone app syntax | `swiftc -parse` on every file | Pass (syntax only) |
| iPhone app types | `ios/LinuxCheck/run.sh`: type-check against hand-written framework stand-ins that model the SDK's main-actor isolation | No errors; only the 2 expected `placemark` deprecations. Stand-ins are approximations, so this is not a compile. |
| iPhone server logic | `ios/LinuxCheck` simulation: real GlassServer, GlassLink, MediaReceiver, NavigationService against a fake network | 96 checks pass |
| Independent review | 4 iPhone reviewers (SwiftUI, actor isolation, API signatures checked against Apple's documentation JSON, behaviour), 3 Glass reviewers (Dalvik runtime, spec/UI/input, link interop), 2 tools reviewers (macOS use, stand-in parity) | No iPhone compile issues found. 4 iPhone, 5 Glass and 6 tools behaviour issues found and fixed; 1 Glass finding rejected as already covered |

On real hardware, 1 November 2026: Alexander's Mac with Xcode 27.2 (27B48), an iPhone Duo
(iPhone19,4) on iOS 27.2, and Glass Explorer on XE24 (XRH35, Android 4.4.4) over USB. This
is newer than the Xcode 26 / iOS 26 setup planned in owner decision 7.

| Check | How | Result |
|---|---|---|
| iPhone app compiles (question 1) | `xcodegen`, then `xcodebuild` Debug for the device, iPhoneOS 27.2 SDK, signed with team 85TPSUH87S (Mango Digital) | Build succeeded on the first compile: 0 errors and 0 warnings. The deprecation warnings expected in `TESTING.md` didn't appear. |
| iPhone app installs | `xcrun devicectl device install app` | Installed. It hasn't been launched yet. |
| Glass APK installs and starts | `glass_adb.py install`, `mock`, `launch` | Installed `dist/` 2.0 (code 2). Logcat shows BridgeService starting, Mock GPS on, the DCIM watch, Bonjour browsing and TTS ready. Screencap shows "Looking for your iPhone…" with the amber footer "No iPhone found yet". |
| `am startservice` against the DUMP-guarded export | `glass_adb.py wifi` (it runs `start`) | Works from adb shell on XE24 |
| Wi-Fi provisioning with `wifi.json` | `glass_adb.py wifi "Alexander’s iPhone Duo" … WPA` | Saved as network 0. Glass joined the hotspot about 60 s later (2.4 GHz, 172.20.10.3). **Bug:** "Couldn't delete …/wifi.json". The files dir is `root:sdcard_rw` 775 and the app (gids 3003, 1028) isn't in `sdcard_rw`, so the password stayed on the sdcard until it was removed by hand with adb. iOS hotspot SSIDs use a curly apostrophe (U+2019). |
| Real Glass ↔ real iPhone over Personal Hotspot | No `config.json`; the iPhone app in the foreground | Gateway detection, then `172.20.10.1:9090` connected, then `welcome` with pairing (code 8094). Status sent. 9 photo uploads acked `ok`. Glass shows the phone name as "iPhone". The iPhone closed the link twice, after about 15 s and then 2.5 min. Each time Glass re-paired 2 s later with a new code (8094, then 5709, then 9071), so the iPhone had lost the token and had its window open. The iPhone app process didn't restart (same pid throughout). Cause not known yet; the only code path that clears the token is Forget Glass followed by Pair Glass or a return to the foreground. |

Reported by Alexander on 21 November 2026, not observed by Claude, with the same Glass and
iPhone Duo. The Glass build in use wasn't recorded.

| Check | Result |
|---|---|
| Real Glass ↔ real iPhone | Glass is connected and paired with the iPhone, and working. |
| Photo sync | New Glass photos sync into the iPhone's camera roll. |
| iPhone notifications over ANCS (§10) | Not tried yet at the time; tried later that day (below). |

After the StellrGlass rename, on Alexander's Mac (macOS, JDK 21, Android SDK 35, Xcode), 21
November 2026. No hardware involved.

| Check | How | Result |
|---|---|---|
| Python stand-ins | `python3 tools/test_e2e.py` | 28/28 pass |
| Glass JVM tests | `./gradlew testDebugUnitTest` with `fake_phone.py --selftest` on 9191 | 87 tests, 0 failures, LiveLinkTest ran (6) |
| Glass APK rebuilt | `./gradlew assembleDebug`, copied to `dist/StellrGlass-debug.apk` | Label "StellrGlass", package unchanged, 2.0 (code 2), same debug key (SHA-256 f3b974dd…99b6). Includes the ANCS code, which the previous `dist/` APK predated. Replaced later that day by the build installed on Glass in the hardware run below (passkey card, re-pair handling, timeline card, pre-existing events ignored); same version, label and key. |
| iPhone Core vs Python | `tools/swift-check/run.sh` | All four parts pass |
| iPhone app builds | `xcodegen` + `xcodebuild` for generic iOS Simulator, signing off, on a copy of `ios/` | Build succeeded, no warnings. Display name "StellrGlass", bundle ID unchanged. |

On real hardware, 21 November 2026, observed by Claude: Glass (XE24) over USB with `adb`
(logcat, screencap) and the iPhone Duo (iOS 27.2) with `devicectl` (install, launch with
console, screenshots), from Alexander's Mac with Xcode 27.2. Alexander handled the iPhone
prompts and typed the pairing codes.

| Check | How | Result |
|---|---|---|
| iPhone app installs and runs | `xcodebuild` for the device with `DEVELOPMENT_TEAM` on the command line (not committed), `devicectl device install app`, `devicectl device process launch --console` | Runs. Event log: server listening on 9090, "Bluetooth on: advertising for Glass", Glass connected from 172.20.10.3, a Glass photo saved to Photos. The Icon Composer `AppIcon.icon` (XcodeGen 2.46 lists it as `wrapper.icon`) compiled into `Assets.car`. |
| Glass APK with ANCS | Gradle build installed with `glass_adb.py install` | 90 JVM tests pass, lint at its baseline. The link resumes with the stored token after every restart ("token accepted"). |
| ANCS discovery (§10 steps 1–2) | logcat | Glass finds the iPhone by the advertised service UUID. The iPhone offers ANCS (`7905F431`) before bonding. |
| ANCS pairing (§10 step 3) | logcat, screencap | Passkey entry: Glass's IO capability is 4 (KeyboardDisplay). XE24's own pairing screen logs "Unsupported Bluetooth pairing variant: 4" and closes. With the `ancs-pairing` card, codes typed on the iPhone completed bonding at 10:00, 10:04, 10:09 and 10:12. |
| Notification sharing | logcat | No events until Alexander turned on Share System Notifications (iOS Settings › Bluetooth); then 262 pre-existing events on subscribing. The setting carried over later re-pairings. |
| A live text message | logcat, screencap | A Messages (`com.apple.MobileSMS`) notification became a card in under a second of reaching Glass, with chime and wake; `ack shown` reached the iPhone. |
| Reconnects | logcat | The iPhone's address rotated three times in 25 minutes (`5C:A3…`, `6E:DB…`, `4A:BF…`); KitKat doesn't resolve it. At an unchanged address the stored key worked three times (09:48, 10:01, 10:14) and was refused twice (10:03, 10:10). When refused, the stack re-paired by itself at 10:03 and 10:12 but not at 10:10. Cause not known (open question 13). |
| Timeline card | GDK LiveCard by reflection, screencap | Published next to the clock: "Listening for notifications / Connected to iPhone". |
| Touchpad input | `GlassBridgeInput` logcat | Taps and swipes arrive as touchpad motion events (source 0x00100008) and the gesture code recognised them. No `KEYCODE_DPAD_CENTER`; swipe down arrives as `KEYCODE_BACK`. |

### Not verified

- **On the iPhone, beyond pairing, photo sync, the event log and Bluetooth advertising.** Not
  yet checked: directions, Shortcuts, screencast, Wi-Fi push and background keep-alive.
- **ANCS beyond the above.** Not yet checked: finding the iPhone with the iPhone app in the
  background (iOS moves the service UUID out of the advert), long-term link stability, removal
  events dismissing cards, and the latest build's re-pair path (`kickBond`, removing a
  refused bond) and old-bond cleanup, which haven't run since it was installed.
- **On Glass, beyond startup, the card screen, touchpad input, Wi-Fi provisioning,
  `am startservice`, ANCS and the timeline card.** Not yet checked: Canvas arrows, the wake
  alarm in deep sleep, mock GPS, NsdManager.
- **Interop between the real apps beyond pairing, photo sync and notifications.** Everything
  else was tested only against a Python stand-in, and the iPhone side only against a fake
  network.
- **The tools on macOS.** `test_e2e.py` and `swift-check` pass on macOS (above), and
  `glass_adb.py` install/mock/launch/wifi ran against real Glass. The `view.html` live views
  have only run in headless Chrome, not Safari.

### Decisions made during the build

Judgement calls beyond the brief and the owner decisions. Revisit them if hardware disagrees.

- `BridgeService` is exported with `android:permission="android.permission.DUMP"` (not
  `exported="false"`), because adb shell can't start a non-exported service on a non-root
  build, and the brief's install steps use `am startservice`. Apps can't hold DUMP.
- Glass's 60 s tick (status, media rescan, redial, link silence check) runs from an exact
  `ELAPSED_REALTIME_WAKEUP` alarm with a short partial wake lock; uploads hold their own wake
  lock. The link watchdog measures silence on `elapsedRealtime`, which keeps running in deep
  sleep.
- Glass forgets its synced-media record when it pairs with a new phone, so the newly paired
  phone gets the backlog.
- After accepting a Glass, the iPhone sends `nav_end` when no guidance is active
  (`PROTOCOL.md` §4).
- The iPhone stores the pairing token in `UserDefaults` (`pairToken`), not the Keychain.
  Forget Glass deletes it and drops the current session.
- A tap on a notification-style card sends `ack tapped`, then `ack dismissed`.
- A file whose `file_ack` times out waits for the next session; an ack that arrives before
  `file_end` is ignored.
- The iPhone Core has its own strict JSON parser (`GBJSON.swift`), because
  `JSONSerialization` can't tell `true` from `1`.
- `fake_phone.py` has sync on by default like the iPhone; `--no-sync` starts with it off.

Made on real hardware, 21 November 2026:

- Glass ignores pre-existing ANCS events: iOS replays the whole Notification Center (262
  events here) on every subscription, which delayed new notifications by over a minute.
- The passkey goes on an `ancs-pairing` card and is spoken, because XE24 can't show it.
  `AncsClient` catches `ACTION_PAIRING_REQUEST` at priority 999 and aborts it only for the
  iPhone it's connecting to, so XE24's "unsupported" screen doesn't cover the card.
- After "insufficient authentication", Glass waits 3 s for the iPhone's security request to
  start pairing; starting it from Glass as well collided. Only then does it call `createBond`,
  or remove a refused bond first (hidden `removeBond`, by reflection). Each new bond removes
  Glass's other LE bonds named `StellrGlass`.
- The timeline card is a GDK `LiveCard` reached by reflection, with
  `<uses-library android:name="com.google.android.glass" android:required="false">`, so the
  build needs no GDK and the app still installs without it.
- Device builds of the iPhone app take the team on the command line
  (`DEVELOPMENT_TEAM=… -allowProvisioningUpdates`); `project.yml` keeps it empty for forks.

## Open questions for real hardware

See the table in `TESTING.md`. Record answers here as they're settled.

| # | Question | Answer |
|---|---|---|
| 1 | Does the full iPhone app compile? | Yes. Xcode 27.2 / iOS 27.2 SDK, 0 errors, 0 warnings, no fixes needed (1 Nov 2026) |
| 2 | Does `NWListener` accept Personal Hotspot clients, and does the Local Network prompt appear? | Accepts: yes. Real Glass linked through 172.20.10.1:9090 (1 Nov 2026). The prompt itself wasn't seen by Claude. |
| 3 | Does the background keep-alive work? | |
| 4 | Which way is a swipe? | As touchpad motion: positive dx is FORWARD, which moves to an older card by default. Whether that feels right on the head wasn't confirmed (21 Nov 2026). |
| 5 | Does a tap arrive as `KEYCODE_DPAD_CENTER`? | No. Touchpad motion events (source 0x00100008), recognised as a tap by the gesture code; no key event. Swipe down arrives as `KEYCODE_BACK` (21 Nov 2026). |
| 6 | Does `NsdManager` Bonjour discovery work on KitKat? | |
| 7 | Does XE24's Settings › Wi-Fi still offer the QR scanner? | |
| 8 | Do mock GPS fixes work? | |
| 9 | Does Photos add-only saving work, including videos? | Photos: yes, they land in the camera roll (Alexander, 21 Nov 2026). Videos not checked. |
| 10 | Does the Shortcuts intent run with the app in the background? | |
| 11 | What phone name does Glass show? | "iPhone", with the Tools name unset (iOS 27.2, 1 Nov 2026) |
| 12 | Is `MKRoute.step.instructions` English? | |
| 13 | Why does the iPhone sometimes refuse Glass's stored LE key at an unchanged address? | Not known. An HCI capture of one reconnect would show whether Glass offers the key and how the iPhone answers. |
