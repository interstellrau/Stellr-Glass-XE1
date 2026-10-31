# GlassBridge: notes for Claude

GlassBridge replaces Google's dead MyGlass companion for Glass Explorer Edition on XE24.
There are two apps: an iPhone app (`ios/`, SwiftUI, the TCP server) and a Glass app
(`glass/`, plain Android API 19, the client). Owner: Alexander, Interstellr.

- Glass package: `au.interstellr.glassbridge`
- iPhone bundle ID: `au.interstellr.glassbridge.ios`

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

### Not verified

- **Anything on real hardware.** Nothing has run on Glass, on an iPhone, or on a Mac.
- **The iPhone app has never been compiled by Xcode.** The first Xcode 26 build is open
  question 1. XcodeGen, actool and AppIntents metadata extraction have never run.
- **The Glass APK has never run on Android** (no emulator here): UI layout on the prism, Canvas
  arrows, input events, TTS and chime, wake locks and the wake alarm in deep sleep, mock GPS,
  FileObserver on DCIM, NsdManager, Wi-Fi provisioning, and `am startservice` against the
  DUMP-guarded export.
- **Interop between the real apps.** Each was tested only against a Python stand-in, and the
  iPhone side only against a fake network.
- **The tools on macOS.** Only run on Linux; `glass_adb.py` only against a stub adb; the
  `view.html` live views only in headless Chrome, not Safari.

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

## Open questions for real hardware

See the table in `TESTING.md`. Record answers here as they're settled.

| # | Question | Answer |
|---|---|---|
| 1 | Does the full iPhone app compile? | |
| 2 | Does `NWListener` accept Personal Hotspot clients, and does the Local Network prompt appear? | |
| 3 | Does the background keep-alive work? | |
| 4 | Which way is a swipe? | |
| 5 | Does a tap arrive as `KEYCODE_DPAD_CENTER`? | |
| 6 | Does `NsdManager` Bonjour discovery work on KitKat? | |
| 7 | Does XE24's Settings › Wi-Fi still offer the QR scanner? | |
| 8 | Do mock GPS fixes work? | |
| 9 | Does Photos add-only saving work, including videos? | |
| 10 | Does the Shortcuts intent run with the app in the background? | |
| 11 | What phone name does Glass show? | |
| 12 | Is `MKRoute.step.instructions` English? | |
