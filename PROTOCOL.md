# GlassBridge wire protocol v2

This file is the contract between the Glass app (`glass/`) and the iPhone app (`ios/`).
Change it **before** changing either side. The Python reference in `tools/gbproto.py`
and the stand-ins `tools/fake_phone.py` / `tools/fake_glass.py` implement it too.

Glass and iPhone talk over plain TCP using JSON Lines. Any line can carry a raw binary
payload after it. The iPhone is the server on port 9090.

v2 isn't wire-compatible with v1, where Glass dialled a fixed laptop address and frames
had no binary payloads.

## 1. Roles and transport

| Item | Value |
|---|---|
| Server | iPhone app. Listens on TCP 9090 and advertises Bonjour `_glassbridge._tcp`. |
| Client | Glass. Dials out, then reconnects with backoff that starts at 2 s and doubles to a 30 s cap. After a `rejected` frame (§6) it retries every 5 s instead. |
| Sessions | One Glass at a time. A new connection replaces the current one **once its `hello` is accepted** (§6). Until then the current session carries on. |
| Encoding | UTF-8 |

## 2. Discovery

Glass finds the iPhone by trying these in order on every reconnect:

1. **Override:** `config.json` in the app's external files dir
   (`/sdcard/Android/data/au.interstellr.glassbridge/files/config.json`) with a `host` key,
   for example `{"host":"192.168.1.20","port":9090}`. `port` defaults to 9090. This is for
   development against a laptop. A `config.json` without `host` doesn't override discovery
   (it may hold other settings, see §8).
2. **Personal Hotspot:** if the Wi-Fi DHCP gateway is in `172.20.10.0/28` (the iOS hotspot
   range), the gateway is the iPhone, so dial `<gateway>:9090`.
3. **Bonjour:** browse `_glassbridge._tcp` for up to 8 s and resolve the first result.

If all three fail, wait (backoff) and start over.

## 3. Framing

Each frame is one line of JSON ending in `\n` (0x0A). The line is always an object with a
`type` string. If it has an integer `bytes: N` with N > 0, exactly N raw bytes follow the
newline, and then the next frame starts.

```
{"type":"card","id":"c1","title":"Hi","text":"Hello"}\n
{"type":"file_chunk","id":"f1","offset":0,"bytes":5}\nABCDE
{"type":"ping"}\n
```

- **Limits:** a JSON line is at most 64 KiB (65,536 bytes, excluding the `\n`) and a payload
  at most 1 MiB (1,048,576 bytes). If either is exceeded, the receiver drops the connection.
- **Atomic writes:** writers emit a header and its payload together, with no other frame
  between them. Keep chunks at 256 KiB (262,144 bytes) or less so pings and cards never wait
  behind a long transfer.
- **Always consume the payload,** even for a type you ignore, or the stream desynchronises.
- **Unknown types and fields are ignored.** That's how the protocol grows without version bumps.
- **Parsers must handle any split.** Reads may be as small as one byte; payloads may contain
  newlines and JSON; lines may end in CRLF: strip one trailing `\r`. Blank lines (empty after
  stripping `\r`) are skipped.
- A line that isn't a JSON object, or has no string `type`, is a protocol error: drop the connection.
- `bytes` that is absent, 0 or not an integer means no payload. A negative `bytes` is a protocol error.

## 4. Lifecycle and heartbeat

1. Glass connects and sends `hello` (with `token` if it has one, §6).
2. The iPhone either accepts it and replies `welcome`, or replies `rejected` and closes (§6).
3. After accepting, the iPhone sends `sync`, then `screencast` if it's on, then any queued
   cards, then the current `nav` card if guidance is active (not announced).
4. Glass sends `status` straight after `welcome`.
5. After that, either side can send at any time.

If a side has received nothing for 15 s, it sends `ping` and the other side answers `pong`.
If 30 s pass with nothing received, drop the connection and Glass reconnects. Every received
frame resets the silence timer, not just `pong`. `ping` is answered even before `hello` is
accepted.

## 5. Messages

→G is iPhone to Glass. →P is Glass to iPhone. A field ending in `?` is optional.

| type | dir | fields | notes |
|---|---|---|---|
| `hello` | →P | `device` (`"glass-explorer"`), `version` (2), `model`, `firmware`, `app_version`, `token?` | First frame Glass sends. `token` is the pairing token, omitted when Glass has none (§6). |
| `welcome` | →G | `server`, `version` (2), `phone_name`, `pair_token?`, `pair_code?` | Reply to an accepted `hello`. `phone_name` is the name the user set in the iPhone app (defaults to the device name). `pair_token`/`pair_code` only when this `hello` was just paired (§6). |
| `rejected` | →G | `reason` (`pairing_required`, `bad_token`), `message?` | Reply to a `hello` that isn't accepted. The iPhone closes the connection straight after. |
| `ping` / `pong` | both | none | Heartbeat |
| `status` | →P | `battery` (0–100), `charging`, `storage_free_mb`, `storage_total_mb`, `wifi_ssid?`, `wifi_rssi?`, `mock_location`, `screen_on`, `uptime_s` | Sent after `welcome`, every 60 s, when the battery % changes, and on request. `mock_location:false` means the one-off adb command hasn't been run. |
| `request_status` | →G | none |  |
| `card` | →G | `id`, `title`, `text`, `source?`, `time?` (epoch ms), `style?` (`info` by default, or `notification`), `chime?`, `wake?`, `ttl_s?` | A card with an existing `id` is replaced in place. `wake` turns the display on. |
| `dismiss` | →G | `id` |  |
| `speak` | →G | `text` | Text-to-speech on Glass |
| `ack` | →P | `id`, `event` (`shown`, `dismissed`, `tapped`) |  |
| `nav` | →G | `instruction`, `maneuver`, `distance_m`, `street?`, `step`, `steps_total`, `eta_min?`, `remaining_m?`, `destination?`, `arrived?`, `announce?` | One pinned nav card, updated in place. `distance_m` is to the next maneuver. `announce:true` means speak now. Glass also wakes and chimes when `step` changes. |
| `nav_end` | →G | none | Removes the nav card |
| `location` | →G | `lat`, `lon`, `acc_m`, `alt_m?`, `speed_mps?`, `bearing?`, `time` (epoch ms) | Phone GPS. Glass injects it as a mock GPS fix. |
| `sync` | →G | `enabled` | Glass uploads nothing until it receives `sync {enabled:true}` |
| `file_begin` | →P | `id`, `name`, `size`, `mime`, `taken` (epoch ms) | `id` is `<name>:<size>`, stable across retries |
| `file_chunk` | →P | `id`, `offset`, `bytes` + payload | In order, 256 KiB or less each |
| `file_end` | →P | `id` |  |
| `file_ack` | →G | `id`, `ok`, `error?` | Glass marks the file synced only on `ok:true`. With no ack after 60 s, Glass retries next session. One file at a time. |
| `screencast` | →G | `on`, `fps?` (1–5, default 2) |  |
| `frame` | →P | `w`, `h`, `bytes` + JPEG payload | Only while screencast is on and GlassBridge is in front. About 20–40 KiB at 640×360, quality 60. |
| `wifi_add` | →G | `ssid`, `password?`, `security` (`WPA`, `WEP`, `OPEN`) | Saves a network on Glass |
| `wifi_result` | →P | `ssid`, `ok`, `error?` |  |

`maneuver` is one of `depart`, `straight`, `left`, `right`, `slight_left`, `slight_right`,
`sharp_left`, `sharp_right`, `uturn`, `arrive`. Glass treats an unknown value as `straight`.

Numbers: `battery`, `step`, `steps_total`, `eta_min`, `offset`, `size`, `bytes`, `w`, `h`,
`fps`, `ttl_s`, `uptime_s`, `storage_*_mb`, `wifi_rssi`, `time`, `taken` are integers.
`lat`, `lon`, `acc_m`, `alt_m`, `speed_mps`, `bearing`, `distance_m`, `remaining_m` may be
fractional. Receivers accept either an integer or a fractional JSON number for any numeric
field and convert.

## 6. Pairing

Phase 1 had no authentication. v2 adds a pairing token so that only a Glass the user paired
can hold the link. The token is required on every network, Personal Hotspot included.

**Token and code.** The token is 32 lowercase hex characters (16 random bytes from a
cryptographically secure generator). The pairing code is 4 decimal digits (`0000`–`9999`),
chosen at random alongside it. The code is only shown to people; it never has to be derived
from the token.

**iPhone state.** The iPhone stores at most one paired token (one Glass), persistently. It
also has a pairing window: a deadline, open or closed.

- The window opens for 2 minutes when the user taps **Pair Glass**.
- It also opens for 2 minutes automatically when the app launches or returns to the
  foreground while no Glass is paired.
- **Forget Glass** deletes the stored token. It doesn't open the window.

**On `hello`**, the iPhone decides in this order:

1. A token is stored and `hello.token` equals it (compare in constant time): **accept**.
   Reply `welcome` without pair fields.
2. Otherwise, if the pairing window is open: **pair**. Generate a new token and code, store
   the token (replacing any old one), close the window, and reply `welcome` with
   `pair_token` and `pair_code`. The session is accepted. The iPhone shows the code to the
   user with "Check that Glass shows the same code".
3. Otherwise: **reject**. Reply `rejected` with `reason` `bad_token` if `hello` carried a
   token and a token is stored, or `pairing_required` in every other case. Then close the
   connection once the frame is written.

**Before acceptance**, the iPhone:

- ignores every frame except `hello` and `ping` (answering `pong`), still consuming payloads;
- sends nothing except `pong`, `welcome` or `rejected` (no cards, `sync`, `location`, `nav`
  or `screencast`);
- closes the connection if no acceptable `hello` arrives within 10 s;
- keeps the current accepted session running. At most one connection waits for
  acceptance; a newer one replaces an older waiting one.

**Glass** stores the token in `SharedPreferences` (`link` / `token`) and sends it in every
`hello`. When `welcome` carries `pair_token`, Glass replaces its stored token and shows a card
titled `Paired` whose text is `<phone_name>` and `Code <pair_code>`, with `wake` and `chime`.
When it receives `rejected`, Glass shows "Pair on your iPhone: GlassBridge › Glass › Pair
Glass" in place of the empty-state text, and retries every 5 s until a `welcome` arrives.
A Glass paired with one iPhone (or `fake_phone.py`) must be paired again to use another.

## 7. Wi-Fi provisioning formats

Glass's first Wi-Fi network, before any link exists, comes from a standard QR code:
`WIFI:T:<WPA|WEP|nopass>;S:<ssid>;P:<password>;;`. Escape `\ ; , : "` in the SSID and
password with a backslash. Leave out `P:` for open networks.

The fallback is `wifi.json`, pushed over adb into the app's external files dir
(`/sdcard/Android/data/au.interstellr.glassbridge/files/wifi.json`). It holds one object or an
array, for example `[{"ssid":"My iPhone","password":"…","security":"WPA"}]`. Glass reads it
when the service starts and on every `onStartCommand`, then deletes it so the password doesn't
sit on the SD card. Once linked, the iPhone can send `wifi_add` instead.

## 8. Glass `config.json`

Optional. Lives at `/sdcard/Android/data/au.interstellr.glassbridge/files/config.json` and is
read on every reconnect (discovery) and every time the card screen opens (input). It is not
deleted. Every key is optional:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `host` | string | none | Dial this host instead of discovering the iPhone (§2) |
| `port` | integer | 9090 | Port used with `host` |
| `invert_swipe` | boolean | false | Flip the touchpad swipe direction (open question 4) |

## 9. Compatibility

- `version` stays 2. Unknown types and fields are ignored, so new optional fields don't need
  a bump.
- An iPhone that requires pairing rejects a v2 Glass build that predates §6, because its
  `hello` has no `token` and it can't store one. Update both sides together.
