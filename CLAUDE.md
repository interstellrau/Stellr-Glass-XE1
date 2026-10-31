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

_(filled in by the build)_

### Not verified

_(filled in by the build)_

## Open questions for real hardware

See the table in `TESTING.md`. Record answers here as they're settled.
