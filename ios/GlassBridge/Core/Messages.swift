// Messages.swift - GlassBridge Core (Foundation only; builds on Linux for tools/swift-check)
//
// Builders for every iPhone -> Glass message (PROTOCOL.md section 5), typed views of the
// Glass -> iPhone messages, Maneuver.classify for MapKit instructions, and the Wi-Fi QR
// payload (PROTOCOL.md section 7).
//
// Every builder returns a GBObject whose first key is "type". Send it with
//     let data = try GBEncoder.encode(Msg.card(id: Msg.newCardID(), title: "Hi", text: "Hello"))
// Optional parameters left nil are left out of the JSON.

import Foundation

/// `card.style`.
enum CardStyle: String {
    case info
    case notification
}

/// `wifi_add.security` and the WIFI: QR code type.
enum WiFiSecurity: String, CaseIterable {
    case wpa = "WPA"
    case wep = "WEP"
    case open = "OPEN"

    /// Parses "WPA", "wpa2", "WEP", "OPEN", "nopass", "none" (case-insensitive).
    init?(wire: String) {
        let s: String = wire.trimmingCharacters(in: .whitespaces).uppercased()
        switch s {
        case "WPA", "WPA2", "WPA3", "WPA/WPA2":
            self = .wpa
        case "WEP":
            self = .wep
        case "OPEN", "NOPASS", "NONE", "":
            self = .open
        default:
            return nil
        }
    }

    /// The `T:` value in a WIFI: QR code.
    var qrType: String {
        switch self {
        case .wpa: return "WPA"
        case .wep: return "WEP"
        case .open: return "nopass"
        }
    }
}

/// `rejected.reason` (PROTOCOL.md section 6).
enum RejectReason: String {
    case pairingRequired = "pairing_required"
    case badToken = "bad_token"

    /// The default `rejected.message`.
    var defaultMessage: String {
        switch self {
        case .pairingRequired:
            return "Pair on your iPhone: StellrGlass › Glass › Pair Glass"
        case .badToken:
            return "This Glass isn't paired with this iPhone. Pair again on your iPhone: StellrGlass › Glass › Pair Glass"
        }
    }
}

/// `ack.event`.
enum AckEvent: String {
    case shown
    case dismissed
    case tapped
}

/// Builders for every iPhone -> Glass message.
enum Msg {
    /// Card ids are `c-<8 lowercase hex>`.
    static func newCardID() -> String {
        var g = SystemRandomNumberGenerator()
        let v: UInt32 = UInt32.random(in: UInt32.min...UInt32.max, using: &g)
        return "c-" + Pairing.hex(UInt64(v), digits: 8)
    }

    /// Reply to an accepted `hello`. `pairToken`/`pairCode` only when this hello was just
    /// paired (PROTOCOL.md section 6).
    static func welcome(server: String = GBProtocol.serverName, phoneName: String,
                        pairToken: String? = nil, pairCode: String? = nil) -> GBObject {
        var o = GBObject(type: "welcome")
        o.set("server", server)
        o.set("version", GBProtocol.version)
        o.set("phone_name", phoneName)
        o.set("pair_token", pairToken)
        o.set("pair_code", pairCode)
        return o
    }

    /// Reply to a `hello` that isn't accepted. Close the connection once it's written.
    /// `message` defaults to the reason's default text; pass "" to leave it out.
    static func rejected(reason: RejectReason, message: String? = nil) -> GBObject {
        var o = GBObject(type: "rejected")
        o.set("reason", reason.rawValue)
        let text: String = message ?? reason.defaultMessage
        if !text.isEmpty {
            o.set("message", text)
        }
        return o
    }

    /// A card. A card with an existing `id` replaces the old one in place on Glass.
    /// `timeMs` is epoch ms (Glass uses "now" when absent). `ttlS` makes it expire.
    static func card(id: String, title: String, text: String, source: String? = nil,
                     timeMs: Int64? = nil, style: CardStyle? = nil, chime: Bool? = nil,
                     wake: Bool? = nil, ttlS: Int? = nil) -> GBObject {
        var o = GBObject(type: "card")
        o.set("id", id)
        o.set("title", title)
        o.set("text", text)
        o.set("source", source)
        o.set("time", timeMs)
        if let s = style {
            o.set("style", s.rawValue)
        }
        o.set("chime", chime)
        o.set("wake", wake)
        o.set("ttl_s", ttlS)
        return o
    }

    static func dismiss(id: String) -> GBObject {
        var o = GBObject(type: "dismiss")
        o.set("id", id)
        return o
    }

    /// Text-to-speech on Glass.
    static func speak(text: String) -> GBObject {
        var o = GBObject(type: "speak")
        o.set("text", text)
        return o
    }

    /// The pinned nav card. `distanceM` is to the next maneuver. `announce: true` means
    /// "speak now". Prefer `NavCard.message()`, which fills this from NavTracker.
    static func nav(instruction: String, maneuver: Maneuver, distanceM: Double,
                    street: String? = nil, step: Int, stepsTotal: Int, etaMin: Int? = nil,
                    remainingM: Double? = nil, destination: String? = nil,
                    arrived: Bool? = nil, announce: Bool? = nil) -> GBObject {
        var o = GBObject(type: "nav")
        o.set("instruction", instruction)
        o.set("maneuver", maneuver.rawValue)
        let distance: Double = distanceM.isFinite ? max(0, distanceM) : 0
        o.set("distance_m", distance)
        o.set("street", street)
        o.set("step", step)
        o.set("steps_total", stepsTotal)
        o.set("eta_min", etaMin)
        o.set("remaining_m", remainingM)
        o.set("destination", destination)
        o.set("arrived", arrived)
        o.set("announce", announce)
        return o
    }

    /// Removes the nav card.
    static func navEnd() -> GBObject {
        return GBObject(type: "nav_end")
    }

    /// Phone GPS for Glass's mock location provider. `timeMs` is epoch ms.
    /// Pass `altM` only when the fix's verticalAccuracy >= 0. A negative `speedMps` or
    /// `bearing` (CoreLocation's "invalid" value) is left out automatically.
    static func location(lat: Double, lon: Double, accM: Double, altM: Double? = nil,
                         speedMps: Double? = nil, bearing: Double? = nil,
                         timeMs: Int64) -> GBObject {
        var o = GBObject(type: "location")
        o.set("lat", lat)
        o.set("lon", lon)
        o.set("acc_m", accM)
        o.set("alt_m", altM)
        if let s = speedMps, s >= 0 {
            o.set("speed_mps", s)
        }
        if let b = bearing, b >= 0 {
            o.set("bearing", b)
        }
        o.set("time", timeMs)
        return o
    }

    /// Glass uploads nothing until it receives `sync {enabled:true}`.
    static func sync(enabled: Bool) -> GBObject {
        var o = GBObject(type: "sync")
        o.set("enabled", enabled)
        return o
    }

    static func requestStatus() -> GBObject {
        return GBObject(type: "request_status")
    }

    /// Answer to a finished (or failed) upload. `sha256`/`received` are optional extras
    /// (fake_phone.py sends them; Glass ignores unknown fields).
    static func fileAck(id: String, ok: Bool, error: String? = nil,
                        sha256: String? = nil, received: Int64? = nil) -> GBObject {
        var o = GBObject(type: "file_ack")
        o.set("id", id)
        o.set("ok", ok)
        o.set("error", error)
        o.set("sha256", sha256)
        o.set("received", received)
        return o
    }

    /// Screencast on/off. `fps` is clamped to 1...5 (Glass defaults to 2).
    static func screencast(on: Bool, fps: Int? = nil) -> GBObject {
        var o = GBObject(type: "screencast")
        o.set("on", on)
        if let f = fps {
            let clamped: Int = min(5, max(1, f))
            o.set("fps", clamped)
        }
        return o
    }

    /// Saves a Wi-Fi network on Glass. The password is left out for open networks.
    static func wifiAdd(ssid: String, password: String?, security: WiFiSecurity) -> GBObject {
        var o = GBObject(type: "wifi_add")
        o.set("ssid", ssid)
        if security != .open {
            o.set("password", password)
        }
        o.set("security", security.rawValue)
        return o
    }

    static func ping() -> GBObject {
        return GBObject(type: "ping")
    }

    static func pong() -> GBObject {
        return GBObject(type: "pong")
    }
}

// MARK: - Glass -> iPhone messages

/// `hello`: the first frame Glass sends.
struct GlassHello: Equatable {
    let device: String?
    let version: Int?
    let model: String?
    let firmware: String?
    let appVersion: String?
    /// The pairing token, nil when Glass has none (an empty string is treated as none).
    let token: String?

    init?(_ frame: GBFrame) {
        guard frame.type == "hello" else { return nil }
        device = frame.string("device")
        version = frame.int("version")
        model = frame.string("model")
        firmware = frame.string("firmware")
        appVersion = frame.string("app_version")
        let t: String? = frame.string("token")
        if let tok = t, !tok.isEmpty {
            token = tok
        } else {
            token = nil
        }
    }
}

/// `status`. Every field is optional so a partial status never fails to parse.
struct GlassStatus: Equatable {
    let battery: Int?
    let charging: Bool?
    let storageFreeMB: Int?
    let storageTotalMB: Int?
    let wifiSSID: String?
    let wifiRSSI: Int?
    let mockLocation: Bool?
    let screenOn: Bool?
    let uptimeS: Int64?

    init?(_ frame: GBFrame) {
        guard frame.type == "status" else { return nil }
        battery = frame.int("battery")
        charging = frame.bool("charging")
        storageFreeMB = frame.int("storage_free_mb")
        storageTotalMB = frame.int("storage_total_mb")
        wifiSSID = frame.string("wifi_ssid")
        wifiRSSI = frame.int("wifi_rssi")
        mockLocation = frame.bool("mock_location")
        screenOn = frame.bool("screen_on")
        uptimeS = frame.int64("uptime_s")
    }
}

/// `ack`: Glass showed, dismissed or tapped a card.
struct GlassAck: Equatable {
    let id: String
    /// "shown", "dismissed" or "tapped" (kept as text so new events don't fail).
    let event: String

    init?(_ frame: GBFrame) {
        guard frame.type == "ack", let i = frame.string("id"), let e = frame.string("event") else {
            return nil
        }
        id = i
        event = e
    }

    var knownEvent: AckEvent? { return AckEvent(rawValue: event) }
}

/// `file_begin`. `id` is `<name>:<size>`, stable across retries.
struct GlassFileBegin: Equatable {
    let id: String
    let name: String
    let size: Int64
    let mime: String?
    /// Epoch ms when the photo/video was taken.
    let takenMs: Int64?

    init?(_ frame: GBFrame) {
        guard frame.type == "file_begin",
              let i = frame.string("id"),
              let n = frame.string("name"),
              let s = frame.int64("size"), s >= 0 else {
            return nil
        }
        id = i
        name = n
        size = s
        mime = frame.string("mime")
        takenMs = frame.int64("taken")
    }

    /// The date the photo/video was taken, if Glass sent it.
    var takenDate: Date? {
        guard let ms = takenMs else { return nil }
        let seconds: Double = Double(ms) / 1000.0
        return Date(timeIntervalSince1970: seconds)
    }
}

/// `file_chunk` with its payload. A chunk with no payload has empty `data`.
struct GlassFileChunk: Equatable {
    let id: String
    let offset: Int64
    let data: Data

    init?(_ frame: GBFrame) {
        guard frame.type == "file_chunk",
              let i = frame.string("id"),
              let o = frame.int64("offset"), o >= 0 else {
            return nil
        }
        id = i
        offset = o
        data = frame.payload ?? Data()
    }
}

/// `file_end`.
struct GlassFileEnd: Equatable {
    let id: String

    init?(_ frame: GBFrame) {
        guard frame.type == "file_end", let i = frame.string("id") else { return nil }
        id = i
    }
}

/// `wifi_result`: answer to `wifi_add`.
struct GlassWiFiResult: Equatable {
    let ssid: String
    let ok: Bool
    let error: String?

    init?(_ frame: GBFrame) {
        guard frame.type == "wifi_result", let s = frame.string("ssid"), let k = frame.bool("ok") else {
            return nil
        }
        ssid = s
        ok = k
        error = frame.string("error")
    }
}

/// `frame`: one screencast JPEG.
struct GlassScreenFrame: Equatable {
    let width: Int
    let height: Int
    let jpeg: Data

    init?(_ frame: GBFrame) {
        guard frame.type == "frame", let p = frame.payload, !p.isEmpty else { return nil }
        width = frame.int("w") ?? 0
        height = frame.int("h") ?? 0
        jpeg = p
    }
}

// MARK: - Upload bookkeeping

/// Pure bookkeeping for one Glass upload (file_begin, file_chunk..., file_end), matching
/// the brief's MediaReceiver rules and tools/fake_phone.py. The app owns the temp file
/// and Photos; this only decides what to write and what to ack.
///
///     // file_begin
///     upload = UploadProgress(begin)              // create/truncate the temp file
///     // file_chunk
///     if upload?.id == chunk.id, upload!.accept(chunk) { fileHandle.write(chunk.data) }
///     // file_end
///     let result = upload?.finish(id: end.id) ?? UploadProgress.unknown
///     // result.ok -> save to Photos, then send Msg.fileAck(id:ok:true); else ack the error
struct UploadProgress: Equatable {
    static let errorOutOfOrder: String = "chunks out of order"
    static let errorSizeMismatch: String = "size mismatch"
    static let errorUnknown: String = "unknown transfer"

    /// The result for a chunk or file_end whose id has no file_begin.
    static let unknown: (ok: Bool, error: String?) = (ok: false, error: errorUnknown)

    let id: String
    let name: String
    let size: Int64
    let mime: String?
    let takenMs: Int64?
    /// Bytes accepted so far.
    private(set) var received: Int64 = 0
    /// Set once a chunk arrived out of order; later chunks are ignored.
    private(set) var failure: String?

    init(_ begin: GlassFileBegin) {
        id = begin.id
        name = begin.name
        size = begin.size
        mime = begin.mime
        takenMs = begin.takenMs
    }

    /// 0...1 for a progress bar.
    var fraction: Double {
        if size <= 0 { return failure == nil ? 1 : 0 }
        let f: Double = Double(received) / Double(size)
        return min(1, max(0, f))
    }

    /// True when the chunk's bytes should be written: same id, and its offset equals the
    /// bytes received so far. Otherwise the upload is marked "chunks out of order".
    mutating func accept(_ chunk: GlassFileChunk) -> Bool {
        if chunk.id != id { return false }
        if failure != nil { return false }
        if chunk.offset != received {
            failure = UploadProgress.errorOutOfOrder
            return false
        }
        received += Int64(chunk.data.count)
        return true
    }

    /// The file_ack result at file_end: ok only if every chunk was in order and the byte
    /// count equals `size`.
    func finish(id endID: String) -> (ok: Bool, error: String?) {
        if endID != id { return UploadProgress.unknown }
        if let f = failure { return (ok: false, error: f) }
        if received != size { return (ok: false, error: UploadProgress.errorSizeMismatch) }
        return (ok: true, error: nil)
    }

    static func == (lhs: UploadProgress, rhs: UploadProgress) -> Bool {
        return lhs.id == rhs.id && lhs.size == rhs.size && lhs.received == rhs.received && lhs.failure == rhs.failure
    }
}

// MARK: - Maneuver

/// `nav.maneuver`. Glass treats an unknown value as `straight`.
enum Maneuver: String, CaseIterable {
    case depart
    case straight
    case left
    case right
    case slightLeft = "slight_left"
    case slightRight = "slight_right"
    case sharpLeft = "sharp_left"
    case sharpRight = "sharp_right"
    case uturn
    case arrive

    /// Classifies an English MapKit step instruction (MapKit gives text only, no enum).
    /// Rules, in order (case-insensitive substring matching):
    ///   1. "arrive" or "destination is"                  -> arrive
    ///   2. "u-turn"                                      -> uturn
    ///   3. "sharp left" / "sharp right"                  -> sharp_left / sharp_right
    ///   4. "slight", "bear" or "keep" with a direction   -> slight_left / slight_right
    ///   5. "turn left", "left onto", "left at", or ending in " left" -> left; same for right
    ///   6. the first step                                -> depart; anything else -> straight
    /// When both directions appear in rule 3, 4 or 5, the one written first wins.
    /// Other languages fall back to straight (open question 12).
    static func classify(_ instruction: String, isFirstStep: Bool) -> Maneuver {
        let s: String = instruction.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("arrive") || s.contains("destination is") {
            return .arrive
        }
        if s.contains("u-turn") {
            return .uturn
        }
        let sharpLeft: Int? = firstIndex(of: ["sharp left"], in: s)
        let sharpRight: Int? = firstIndex(of: ["sharp right"], in: s)
        if let side = earlier(sharpLeft, sharpRight) {
            return side == .left ? .sharpLeft : .sharpRight
        }
        if s.contains("slight") || s.contains("bear") || s.contains("keep") {
            let l: Int? = firstIndex(of: ["left"], in: s)
            let r: Int? = firstIndex(of: ["right"], in: s)
            if let side = earlier(l, r) {
                return side == .left ? .slightLeft : .slightRight
            }
        }
        var left: Int? = firstIndex(of: ["turn left", "left onto", "left at"], in: s)
        var right: Int? = firstIndex(of: ["turn right", "right onto", "right at"], in: s)
        if left == nil && s.hasSuffix(" left") {
            left = s.count - 5
        }
        if right == nil && s.hasSuffix(" right") {
            right = s.count - 6
        }
        if let side = earlier(left, right) {
            return side == .left ? .left : .right
        }
        if isFirstStep {
            return .depart
        }
        return .straight
    }

    private enum Side {
        case left
        case right
    }

    /// Which of two optional positions comes first (left wins a tie).
    private static func earlier(_ l: Int?, _ r: Int?) -> Side? {
        if let a = l, let b = r {
            return a <= b ? .left : .right
        }
        if l != nil { return .left }
        if r != nil { return .right }
        return nil
    }

    /// Character offset of the earliest occurrence of any needle, or nil.
    private static func firstIndex(of needles: [String], in s: String) -> Int? {
        var best: Int?
        for needle in needles {
            if let range = s.range(of: needle) {
                let offset: Int = s.distance(from: s.startIndex, to: range.lowerBound)
                if let b = best {
                    if offset < b { best = offset }
                } else {
                    best = offset
                }
            }
        }
        return best
    }
}

// MARK: - Wi-Fi QR

/// The standard Wi-Fi QR payload (PROTOCOL.md section 7):
/// `WIFI:T:<WPA|WEP|nopass>;S:<ssid>;P:<password>;;`
enum WiFiQR {
    /// `\ ; , : "` in the SSID and password are escaped with a backslash. `P:` is left
    /// out for open networks (and any password given for one is ignored).
    static func payload(ssid: String, password: String?, security: WiFiSecurity) -> String {
        var out: String = "WIFI:T:" + security.qrType + ";S:" + escape(ssid) + ";"
        if security != .open {
            let pw: String = password ?? ""
            out += "P:" + escape(pw) + ";"
        }
        out += ";"
        return out
    }

    /// The characters a WIFI: QR code escapes with a backslash.
    static let specialCharacters: Set<Character> = ["\\", ";", ",", ":", "\""]

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            if specialCharacters.contains(ch) {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
    }
}
