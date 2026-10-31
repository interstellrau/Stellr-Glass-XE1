// Pairing.swift - GlassBridge Core (Foundation only; builds on Linux for tools/swift-check)
//
// Pure pairing logic for PROTOCOL.md section 6. No storage, no clocks, no UI: the app
// passes in the stored token and "now", and persists `storedToken` when it changes.
//
// On `hello` the iPhone decides, in this order:
//   1. a token is stored and hello.token equals it (constant-time compare) -> accept;
//      reply `welcome` without pair fields;
//   2. otherwise, if the pairing window is open -> pair: new token + code, store the token
//      (replacing any old one), close the window, reply `welcome` with pair_token and
//      pair_code; the session is accepted;
//   3. otherwise -> reject: `bad_token` if hello carried a token and a token is stored,
//      else `pairing_required`. Close the connection once the frame is written.
//
// An empty token (in hello or in storage) counts as no token.

import Foundation

/// What to do with a `hello`.
enum PairingDecision: Equatable {
    case accept
    case pair
    case reject(RejectReason)
}

enum Pairing {
    /// How long the pairing window stays open (2 minutes).
    static let windowDuration: TimeInterval = 120

    /// Frames a connection may send before its hello is accepted; everything else is
    /// ignored (payloads still consumed). `ping` is answered with `pong`.
    static let typesAllowedBeforeAcceptance: Set<String> = ["hello", "ping"]

    /// The section 6 decision table.
    static func decide(storedToken: String?, windowOpen: Bool, helloToken: String?) -> PairingDecision {
        let stored: String? = nonEmpty(storedToken)
        let offered: String? = nonEmpty(helloToken)
        if let s = stored, let o = offered, constantTimeEquals(s, o) {
            return .accept
        }
        if windowOpen {
            return .pair
        }
        if stored != nil && offered != nil {
            return .reject(.badToken)
        }
        return .reject(.pairingRequired)
    }

    /// 16 random bytes from the system CSPRNG as 32 lowercase hex characters.
    static func newToken() -> String {
        var g = SystemRandomNumberGenerator()
        return newToken(using: &g)
    }

    static func newToken<G: RandomNumberGenerator>(using generator: inout G) -> String {
        let a: UInt64 = generator.next()
        let b: UInt64 = generator.next()
        return hex(a, digits: 16) + hex(b, digits: 16)
    }

    /// A 4-digit pairing code, "0000" to "9999".
    static func newCode() -> String {
        var g = SystemRandomNumberGenerator()
        return newCode(using: &g)
    }

    static func newCode<G: RandomNumberGenerator>(using generator: inout G) -> String {
        let n: Int = Int.random(in: 0...9999, using: &generator)
        return zeroPadded(n, width: 4)
    }

    /// True if `token` is 32 lowercase hex characters.
    static func isValidToken(_ token: String) -> Bool {
        let bytes: [UInt8] = Array(token.utf8)
        if bytes.count != 32 { return false }
        for c in bytes {
            let digit: Bool = c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")
            let lowerHex: Bool = c >= UInt8(ascii: "a") && c <= UInt8(ascii: "f")
            if !digit && !lowerHex { return false }
        }
        return true
    }

    /// Compares two strings in time that depends only on their lengths, not on where they
    /// differ.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x: [UInt8] = Array(a.utf8)
        let y: [UInt8] = Array(b.utf8)
        var diff: UInt8 = 0
        if x.count != y.count {
            diff = 1
        }
        let n: Int = max(x.count, y.count)
        var i = 0
        while i < n {
            var p: UInt8 = 0
            var q: UInt8 = 0
            if i < x.count { p = x[i] }
            if i < y.count { q = y[i] }
            diff |= p ^ q
            i += 1
        }
        return diff == 0
    }

    /// Lowercase hex of `value`, left-padded with zeros to `digits` characters.
    static func hex(_ value: UInt64, digits: Int) -> String {
        let table: [Character] = Array("0123456789abcdef")
        var chars: [Character] = []
        var v: UInt64 = value
        while v > 0 {
            let nibble: Int = Int(v & 0xF)
            chars.append(table[nibble])
            v >>= 4
        }
        while chars.count < digits {
            chars.append("0")
        }
        return String(chars.reversed())
    }

    static func zeroPadded(_ n: Int, width: Int) -> String {
        var s: String = String(n)
        while s.count < width {
            s = "0" + s
        }
        return s
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let v = s, !v.isEmpty else { return nil }
        return v
    }
}

/// Result of `PairingState.handleHello`.
struct PairingOutcome: Equatable {
    let decision: PairingDecision
    /// Set only when `decision == .pair`: send as `welcome.pair_token`.
    let pairToken: String?
    /// Set only when `decision == .pair`: send as `welcome.pair_code` and show it on the
    /// iPhone with "Check that Glass shows the same code".
    let pairCode: String?

    /// True for `.accept` and `.pair`: the connection becomes the session.
    var accepted: Bool {
        switch decision {
        case .accept, .pair:
            return true
        case .reject:
            return false
        }
    }

    /// True when the stored token changed (persist `PairingState.storedToken`).
    var tokenChanged: Bool { return decision == .pair }

    /// The frame to send back: `welcome` (with pair fields when just paired) or
    /// `rejected`. After `rejected`, close the connection once it's written.
    func reply(phoneName: String, server: String = GBProtocol.serverName) -> GBObject {
        switch decision {
        case .accept:
            return Msg.welcome(server: server, phoneName: phoneName)
        case .pair:
            return Msg.welcome(server: server, phoneName: phoneName, pairToken: pairToken, pairCode: pairCode)
        case .reject(let reason):
            return Msg.rejected(reason: reason)
        }
    }
}

/// The iPhone's pairing state: at most one stored token and a pairing window deadline.
/// A value type, so it can live in an ObservableObject's @Published property. Use the
/// same clock for every `now` (for example `Date().timeIntervalSince1970`).
struct PairingState: Equatable {
    /// The paired Glass's token (persist it, e.g. in UserDefaults), or nil.
    private(set) var storedToken: String?
    /// When the pairing window closes, or nil if it isn't open.
    private(set) var windowDeadline: TimeInterval?
    /// The code from the most recent pairing, for display. Cleared by `forget()`.
    private(set) var lastPairCode: String?

    init(storedToken: String?) {
        self.storedToken = Pairing.nonEmpty(storedToken)
    }

    var isPaired: Bool { return storedToken != nil }

    func isWindowOpen(now: TimeInterval) -> Bool {
        guard let d = windowDeadline else { return false }
        return now < d
    }

    /// Seconds until the window closes (0 when closed).
    func windowRemaining(now: TimeInterval) -> TimeInterval {
        guard let d = windowDeadline, now < d else { return 0 }
        return d - now
    }

    /// The user tapped Pair Glass: open (or restart) the 2-minute window.
    mutating func openWindow(now: TimeInterval) {
        windowDeadline = now + Pairing.windowDuration
    }

    mutating func closeWindow() {
        windowDeadline = nil
    }

    /// Call on app launch and on every return to the foreground: opens the window for
    /// 2 minutes only while no Glass is paired. Returns true if it opened (or restarted)
    /// the window.
    @discardableResult
    mutating func openWindowIfUnpaired(now: TimeInterval) -> Bool {
        if storedToken != nil {
            return false
        }
        openWindow(now: now)
        return true
    }

    /// Forget Glass: deletes the stored token. It doesn't open the window.
    mutating func forget() {
        storedToken = nil
        lastPairCode = nil
    }

    /// Decides what to do with a hello (section 6) and applies it: on `.pair` a new token
    /// and code are generated, the token is stored and the window closes.
    mutating func handleHello(token: String?, now: TimeInterval) -> PairingOutcome {
        var g = SystemRandomNumberGenerator()
        return handleHello(token: token, now: now, using: &g)
    }

    mutating func handleHello<G: RandomNumberGenerator>(token: String?, now: TimeInterval,
                                                        using generator: inout G) -> PairingOutcome {
        let open: Bool = isWindowOpen(now: now)
        let decision: PairingDecision = Pairing.decide(storedToken: storedToken, windowOpen: open, helloToken: token)
        switch decision {
        case .pair:
            let newToken: String = Pairing.newToken(using: &generator)
            let code: String = Pairing.newCode(using: &generator)
            storedToken = newToken
            lastPairCode = code
            windowDeadline = nil
            return PairingOutcome(decision: .pair, pairToken: newToken, pairCode: code)
        case .accept, .reject:
            return PairingOutcome(decision: decision, pairToken: nil, pairCode: nil)
        }
    }
}
