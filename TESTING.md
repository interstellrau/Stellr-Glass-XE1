# GlassBridge hardware test runbook

This is the first time GlassBridge meets real hardware. Work through the parts in order:
each one settles some of the open questions and narrows down where a failure can come from.
Record what you find in `CLAUDE.md` (Verification ledger and Open questions).

| Part | What it proves | Needs | Time |
|---|---|---|---|
| 0. Prepare | Tools in place | Mac, Glass on USB | 10 min |
| 1. Build the iPhone app | It compiles and installs (question 1) | Mac, iPhone | 15–30 min |
| 2. iPhone vs `fake_glass.py` | Server, pairing, Photos, Shortcuts, background (questions 2, 3, 9, 10, 11) | Mac on the iPhone's hotspot | 30 min |
| 3. Glass vs `fake_phone.py` | Glass UI, input, nav, speech, sync, mock GPS (questions 4, 5, 7, 8) | Mac and Glass on one Wi-Fi | 30–45 min |
| 4. Glass and iPhone together | The real thing on Personal Hotspot (questions 6, 12) | Glass, iPhone, a walk | 30 min |

What's already verified in the cloud sandbox, with no hardware: the Python stand-ins and their
end-to-end tests, the Glass APK build, its JVM unit tests and live link test against
`fake_phone.py`, lint (no APIs above 19), and the iPhone `Core/` code against Python. What
isn't: anything on Glass, anything on an iPhone, and the iPhone app outside `Core/` has never
been compiled by Xcode. See `CLAUDE.md` for the full list.

The prism coating is damaged, so this runbook checks the Glass screen with screenshots
(`glass_adb.py screen`) or the screencast (`fake_phone.py` → `cast on`).

## 0. Prepare (Mac)

1. Get the code: `git clone https://github.com/interstellrau/Stellr-Glass-XE1.git` (or
   `git pull` in an existing clone), then `cd Stellr-Glass-XE1`. Every command below runs from
   the repo root unless it says otherwise.
2. Install XcodeGen: `brew install xcodegen`.
3. Check Python: `python3 --version` (3.9 or later; the tools use only the standard library).
4. Check adb: plug Glass in over USB, then `python3 tools/glass_adb.py devices`. If Glass isn't
   listed, turn on debug mode on Glass: Settings › Device info › Turn on debug.
5. Make two test images for `fake_glass.py`:
   ```
   screencapture -x -t jpg /tmp/gb_photo.jpg
   sips -Z 640 -s format jpeg /tmp/gb_photo.jpg --out /tmp/gb_frame.jpg
   ```
   `gb_frame.jpg` must stay under 1 MiB (the protocol's payload limit); 640 px wide is about 50 KB.

When macOS asks whether `python3` may accept incoming connections, click Allow.
`fake_phone.py` needs it.

## 1. Build and install the iPhone app (question 1)

1. `cd ios && xcodegen && open GlassBridge.xcodeproj`
2. In Xcode: select the GlassBridge target › Signing & Capabilities › Team (your Apple ID).
   The bundle ID is `au.interstellr.glassbridge.ios`.
3. Pick your iPhone as the run destination and press Run.
4. On the iPhone, the first install from a free Apple ID needs Settings › General › VPN &
   Device Management › trust the developer. Free-account installs expire after 7 days.

**Expected warnings (iOS 26 SDK), and nothing else:** `MKMapItem(placemark:)` and `.placemark`
deprecated (NavigationService.swift), `openAppWhenRun` deprecated (SendToGlassIntent.swift).

**If there are compile errors:** this is the first compile ever, so some are possible. Fix in
place, or copy Xcode's issue list (Report navigator › the build › Copy) into a new Claude Code
session in this repo. If `.refreshable` fails on main-actor isolation, wrap its body in
`await MainActor.run { … }`. Record each fix in `CLAUDE.md`.

**First launch:** allow Local Network (without it Glass can never connect: Settings › Privacy &
Security › Local Network › GlassBridge) and location While Using. The Glass tab should show
"Listening on port 9090", and Pairing "Pairing open 1:59" because nothing is paired yet.

## 2. iPhone vs `fake_glass.py` (milestone 6)

The Mac pretends to be Glass. This tests the iPhone app on its own.

1. iPhone: Settings › Personal Hotspot › Allow Others to Join, and turn on **Maximize
   Compatibility** (Glass's radio is 2.4 GHz only; do it now so part 4 just works).
2. Join the Mac to the iPhone's hotspot. The iPhone is `172.20.10.1`.
3. iPhone: GlassBridge › Glass tab › **Pair Glass** (opens 2 minutes).
4. Mac: `python3 tools/fake_glass.py 172.20.10.1 --upload /tmp/gb_photo.jpg --frame /tmp/gb_frame.jpg`

| Check | Do | Expect | Question |
|---|---|---|---|
| Server reachable | Step 4 | `fake_glass` prints the welcome. If it can't connect: Local Network permission, then the Server row in the Glass tab. | 2 |
| Pairing | Step 4 | `fake_glass` prints "Paired with <name>, code NNNN"; the iPhone shows a "Glass paired" alert with the same code. The token goes in `./fake_glass_token.txt`. | |
| Status | Glass tab | Battery 87%, storage, Wi-Fi FakeHotspot. Pull down to refresh: `fake_glass` prints `request_status`. | |
| Cards | Tools › Send a card | `fake_glass` prints the card and acks it. "Also speak" also prints a `speak`. | |
| Photos | Allow Photos when asked | The upload lands in Photos with the Mac's file date; Media tab › Recent shows "saved". | 9 |
| Screencast | Media › Mirror Glass screen | The frame from `gb_frame.jpg` shows. | |
| Wi-Fi | Tools › Wi-Fi for Glass › Send to connected Glass | `fake_glass` prints `wifi_add`; the result line says ok. | |
| Phone name | Tools › Name shown on Glass, then restart `fake_glass` | The welcome carries your name. Without it, iOS reports just "iPhone". | 11 |
| Rejected | Stop `fake_glass`, Glass tab › Forget Glass, start `fake_glass` again | It prints `rejected pairing_required` and retries every 5 s; the Glass tab shows an orange note. Tap Pair Glass: it pairs within 5 s. | |
| Background | Settings › Stay connected in background on, lock the iPhone for 5 minutes | `fake_glass` keeps the link: no disconnects, pings answered. Note how long it survives. | 3 |
| Shortcuts | Shortcuts app › new shortcut › Send to Glass, run it with GlassBridge closed | `fake_glass` prints the card; the dialog says "Sent to Glass." If it doesn't run in the background, the fallback is `openAppWhenRun = true`. | 10 |
| Navigation | Navigate › search › Walk › Start on Glass, then walk around the block | `fake_glass` prints `nav` frames: the depart step, then turns with distances; `announce` near each turn; `nav_end` on arrival or End. Check the instructions are English (Adelaide, English (Australia)). | 12 |

## 3. Glass vs `fake_phone.py` (milestone 7)

The Mac pretends to be the iPhone. This tests the Glass app on its own. Glass and the Mac need
to be on the same 2.4 GHz Wi-Fi: home Wi-Fi, or the iPhone's hotspot (with `config.json`
pointing at the Mac, Glass dials the Mac, not the iPhone).

1. Install the APK: `python3 tools/glass_adb.py install`
   - `INSTALL_FAILED_UPDATE_INCOMPATIBLE` means an older GlassBridge signed with another key is
     installed: `python3 tools/glass_adb.py uninstall`, then install again.
2. If Glass isn't already on that Wi-Fi, give it the network over USB (the app reads and
   deletes `wifi.json`):
   `python3 tools/glass_adb.py wifi "<network>" "<password>" WPA`
3. Mac IP: `ipconfig getifaddr en0`
4. Terminal A: `python3 tools/fake_phone.py` (its pairing window is open for 120 s at start;
   type `pair` to reopen it)
5. Terminal B: `python3 tools/glass_adb.py setup <mac-ip>`. This runs install again (harmless),
   mock (allow mock locations), config (`config.json` → the Mac), start (the service) and
   launch (the card screen).
   - If `start` fails with a permission error, run `python3 tools/glass_adb.py launch`, which
     starts the service too.
6. Terminal C: `python3 tools/glass_adb.py logs` (tags `GlassBridge` and `GlassBridgeInput`).
7. To see the screen: `python3 tools/glass_adb.py screen --watch 2 --open`, or type `cast on`
   in `fake_phone` and open `received/frames/view.html` in a browser.

| Check | Do (in `fake_phone` unless noted) | Expect on Glass | Question |
|---|---|---|---|
| Link + pairing | Steps 4–5 | A "Paired" card with the same code `fake_phone` prints, with a chime. `fake_phone` prints the status. | |
| Card | `card Hello | First card from the Mac` | The card at the front; `fake_phone` prints `ACK … shown`. | |
| Tap | Tap the touchpad | The card goes; `fake_phone` prints `ACK … dismissed`. Logs show which keycode or gesture arrived. If nothing happens, send the `GlassBridgeInput` lines to Claude. | 5 |
| Swipe | Send 3 cards, then swipe forward | A forward swipe should show an older card (pager `2/3`). Logs print `gesture FORWARD dx=…`. If it's backwards: `python3 tools/glass_adb.py invert-swipe on`, then `python3 tools/glass_adb.py launch`. | 4 |
| Back | Swipe down | Leaves the card screen; the service keeps running. | |
| Notification | `notify Messages | Are you free?` | The screen wakes, chime, the card comes to the front. Tap: `ACK … tapped` then `dismissed`. | |
| Speech | `speak Hello from GlassBridge` | Spoken through the bone-conduction speaker. | |
| Nav | `nav left 120 Turn left onto King William Street`, then `nav left 40 Turn left onto King William Street`, then `nav arrive 0 Arrive at Rundle Mall` | The pinned nav card with a left arrow, "120 m", spoken turn on the first; the distance updates; "Arrived". `navend` removes it. | |
| Photo sync | Take a photo with the camera button | It arrives in `received/` on the Mac (`sync` is on by default). Videos upload when recording ends. | |
| Screencast | `cast on` | Frames in `received/frames/` while the card screen is in front. `cast off` stops. | |
| Mock GPS | `status`, then `loc -34.9285 138.6007`, then take a photo | `fake_phone` prints `mock_location: true`. The photo has a geotag (check in Photos on the Mac). If false: `python3 tools/glass_adb.py mock`, then `python3 tools/glass_adb.py start`. | 8 |
| Wi-Fi push | `wifi "Test Net" testpassword` | `WIFI Test Net: ok`. | |
| Wi-Fi QR | On Glass: Settings › Wi-Fi. On the iPhone: Tools › Wi-Fi for Glass › Show QR code | Does XE24 still offer a QR scanner? If not, `wifi.json` and `wifi_add` cover it. | 7 |
| Pair again | `forget`, then disconnect Glass's Wi-Fi briefly | Glass shows "Pair on your iPhone…" and retries every 5 s; `pair` re-pairs it with a new code. | |

## 4. Glass and iPhone together (milestone 8)

1. Remove the Mac override: `python3 tools/glass_adb.py config-clear`, then stop `fake_phone`.
2. Put Glass on the iPhone's hotspot:
   `python3 tools/glass_adb.py wifi "<iPhone hotspot name>" "<hotspot password>" WPA`
   (or show the QR from Tools › Wi-Fi for Glass).
3. Glass was paired with `fake_phone`, so the iPhone rejects its old token: tap **Pair Glass**
   on the iPhone. Glass pairs within 5 s; both screens show the same code.

| Check | Expect | Question |
|---|---|---|
| Discovery without `config.json` | The Glass footer says "Connected to <your name>". Logs: "Wi-Fi gateway is a Personal Hotspot". | |
| Cards, status, Find my Glass | Glass tab shows real battery and storage; Last seen updates. | |
| Mock GPS from the phone | Share location on; `status.mock_location` true in the Glass tab. | 8 |
| Navigation on a real walk | Turn cards with arrows, spoken turns at about 40 m, rerouting when you go off route, "Arrived". | 12 |
| Glass photo to Photos | A Glass photo or video lands in iPhone Photos with the right date. | 9 |
| Locked phone | Lock the iPhone with Stay connected on: Glass stays linked (footer "Connected"), and Last seen keeps updating. | 3 |
| Bonjour (optional) | Hotspot off; Glass and iPhone on the same home Wi-Fi; no `config.json`. Glass finds the iPhone through `_glassbridge._tcp` within 8 s. | 6 |

## Open questions to settle

| # | Question | Where | If it fails |
|---|---|---|---|
| 1 | Does the full iPhone app compile? | Part 1 | Fix in place. Only the deprecation warnings above are expected. |
| 2 | Does `NWListener` accept Personal Hotspot clients, and does the Local Network prompt appear? | Part 2 | Check `NSBonjourServices` and `NSLocalNetworkUsageDescription`, then the Server row and event log. |
| 3 | Does the background keep-alive work? | Parts 2 and 4 | Log how long iOS keeps the app alive. BLE keep-alive is the phase 2 alternative. |
| 4 | Which way is a swipe? | Part 3 | `glass_adb.py invert-swipe on` (no rebuild). |
| 5 | Does a tap arrive as `KEYCODE_DPAD_CENTER` in a plain Activity on XE24? | Part 3 | The app also accepts ENTER and a touchpad tap gesture; the logs show which arrives. |
| 6 | Does `NsdManager` Bonjour discovery work on KitKat? | Part 4 (optional) | The hotspot gateway and `config.json` paths don't need it. |
| 7 | Does XE24's Settings › Wi-Fi still offer the QR scanner? | Part 3 | `wifi.json` over adb, or `wifi_add` once linked. |
| 8 | Do mock GPS fixes work? | Parts 3 and 4 | Check `addTestProvider` arguments and `elapsedRealtimeNanos`. |
| 9 | Does Photos add-only saving work, including videos? | Parts 2 and 4 | Check the `.photo` / `.video` resource types and the `taken` date. |
| 10 | Does the Shortcuts intent run with the app in the background? | Part 2 | Set `openAppWhenRun = true`. |
| 11 | What phone name does Glass show? | Part 2 | Tools › Name shown on Glass (already built). |
| 12 | Is `MKRoute.step.instructions` English? | Parts 2 and 4 | `Maneuver.classify` is English keyword matching; other languages fall back to `straight`. |

## Troubleshooting

| Symptom | Check |
|---|---|
| Glass shows "Looking for your iPhone…" forever | `python3 tools/glass_adb.py status` (Wi-Fi, `config.json`). On the hotspot, Maximize Compatibility must be on. Logs show each discovery step. |
| Glass shows "Pair on your iPhone…" | Tap Pair Glass on the iPhone (or `pair` in `fake_phone`). Glass retries every 5 s. |
| iPhone Server row says Waiting or Failed | Settings › Privacy & Security › Local Network › GlassBridge must be on. |
| No speech | TTS may still be starting; `speak` is dropped until it's ready. Try again after a few seconds. |
| Install fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | `python3 tools/glass_adb.py uninstall`, then install again. |
| Want the raw protocol | `fake_phone.py` and `fake_glass.py` print every frame. |
