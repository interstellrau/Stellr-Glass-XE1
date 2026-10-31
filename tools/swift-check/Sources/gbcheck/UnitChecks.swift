// UnitChecks.swift - part 4: Maneuver.classify, WiFiQR, pairing, split reads, limits,
// accessors, the JSON layer and the message builders.

import Foundation

private func bytesOf(_ s: String) -> [UInt8] {
    return Array(s.utf8)
}

/// Parses one complete header line + optional payload stream and returns the frames.
private func frames(_ bytes: [UInt8], readSize: Int = 0) throws -> [GBFrame] {
    return try parseAll(bytes, readSize: readSize)
}

private func roundTrip(_ obj: GBObject, payload: Data? = nil) throws -> GBFrame {
    let data: Data = try GBEncoder.encode(obj, payload: payload)
    let got: [GBFrame] = try parseAll([UInt8](data), readSize: 0)
    guard got.count == 1 else {
        throw GBProtocolError("expected 1 frame, got \(got.count)")
    }
    return got[0]
}

private func lineText(_ obj: GBObject) -> String {
    guard let line = try? GBEncoder.headerLine(obj) else { return "" }
    return String(decoding: line, as: UTF8.self)
}

func runUnit() -> Int32 {
    let c = Checker(part: "part 4 (classify, Wi-Fi QR, pairing, split reads, limits, builders)")
    checkClassify(c)
    checkWiFiQR(c)
    checkPairing(c)
    checkSplitReads(c)
    checkLimits(c)
    checkAccessors(c)
    checkJSON(c)
    checkEncoder(c)
    checkBuilders(c)
    checkFoundationBridging(c)
    checkUploads(c)
    return c.finish()
}

// MARK: - Maneuver.classify

private func checkClassify(_ c: Checker) {
    c.begin("Maneuver.classify")
    let table: [(String, Bool, Maneuver)] = [
        ("Arrive at the destination", false, .arrive),
        ("The destination is on your left", false, .arrive),
        ("Arrive at King William St", true, .arrive),
        ("Make a U-turn", false, .uturn),
        ("Make a U-turn and turn left", false, .uturn),
        ("Make a sharp left onto Grote St", false, .sharpLeft),
        ("Sharp right onto Pirie St", false, .sharpRight),
        ("Slight left onto North Terrace", false, .slightLeft),
        ("Slight right", false, .slightRight),
        ("Bear left onto Main North Rd", false, .slightLeft),
        ("Bear right at the fork", false, .slightRight),
        ("Keep left at the fork", false, .slightLeft),
        ("Keep right to stay on M1", false, .slightRight),
        ("Keep straight", false, .straight),
        ("Turn left onto Rundle Mall", false, .left),
        ("Turn right onto King William St", false, .right),
        ("TURN LEFT", false, .left),
        ("Left onto Hindley St", false, .left),
        ("Go right at the roundabout", false, .right),
        ("At the end of the road, turn left", false, .left),
        ("Make a left", false, .left),
        ("Make a right", false, .right),
        ("Turn right, then turn left", false, .right),
        ("Turn right onto Left Bank Rd", false, .right),
        ("Continue onto Anzac Hwy", false, .straight),
        ("Proceed to the route", true, .depart),
        ("Head north on Test Street", true, .depart),
        ("", true, .depart),
        ("", false, .straight),
        ("Take the exit", false, .straight),
        ("Gehen Sie nach links", false, .straight),
    ]
    for (text, first, expected) in table {
        let got: Maneuver = Maneuver.classify(text, isFirstStep: first)
        c.equal(got, expected, "'\(text)' (first: \(first))")
    }
    let wire: [String] = Maneuver.allCases.map { $0.rawValue }
    c.equal(wire, ["depart", "straight", "left", "right", "slight_left", "slight_right",
                   "sharp_left", "sharp_right", "uturn", "arrive"], "wire values")
}

// MARK: - WiFiQR

private func checkWiFiQR(_ c: Checker) {
    c.begin("WiFiQR")
    let tricky: String = WiFiQR.payload(ssid: "Caf\u{e9}; \"Net\", :1\\", password: "p@ss;word,:\"\\", security: .wpa)
    c.equal(tricky, #"WIFI:T:WPA;S:Café\; \"Net\"\, \:1\\;P:p@ss\;word\,\:\"\\;;"#, "escapes \\ ; , : \" in SSID and password")
    c.equal(WiFiQR.payload(ssid: "Open Net", password: "ignored", security: .open), "WIFI:T:nopass;S:Open Net;;", "open: nopass and no P:")
    c.equal(WiFiQR.payload(ssid: "Open", password: nil, security: .open), "WIFI:T:nopass;S:Open;;", "open without a password")
    c.equal(WiFiQR.payload(ssid: "Old", password: "abcde", security: .wep), "WIFI:T:WEP;S:Old;P:abcde;;", "WEP")
    c.equal(WiFiQR.payload(ssid: "My iPhone", password: "hunter22", security: .wpa), "WIFI:T:WPA;S:My iPhone;P:hunter22;;", "plain WPA")
    c.equal(WiFiQR.payload(ssid: "X", password: nil, security: .wpa), "WIFI:T:WPA;S:X;P:;;", "WPA without a password keeps an empty P:")
    c.equal(WiFiQR.escape("a\\b;c,d:e\"f"), #"a\\b\;c\,d\:e\"f"#, "escape()")
    c.equal(WiFiSecurity(wire: "wpa2"), .wpa, "WiFiSecurity wpa2")
    c.equal(WiFiSecurity(wire: "WEP"), .wep, "WiFiSecurity WEP")
    c.equal(WiFiSecurity(wire: "nopass"), .open, "WiFiSecurity nopass")
    c.equal(WiFiSecurity(wire: "OPEN"), .open, "WiFiSecurity OPEN")
    c.check(WiFiSecurity(wire: "802.1x") == nil, "WiFiSecurity unknown")
}

// MARK: - Pairing

private func checkPairing(_ c: Checker) {
    c.begin("Pairing.decide")
    let tok = "0123456789abcdef0123456789abcdef"
    let other = "fedcba9876543210fedcba9876543210"
    c.equal(Pairing.decide(storedToken: tok, windowOpen: false, helloToken: tok), .accept, "1: stored token matches -> accept")
    c.equal(Pairing.decide(storedToken: tok, windowOpen: true, helloToken: tok), .accept, "1: matching token wins over an open window")
    c.equal(Pairing.decide(storedToken: tok, windowOpen: true, helloToken: other), .pair, "2: wrong token, window open -> pair")
    c.equal(Pairing.decide(storedToken: tok, windowOpen: true, helloToken: nil), .pair, "2: no token, window open -> pair")
    c.equal(Pairing.decide(storedToken: nil, windowOpen: true, helloToken: nil), .pair, "2: nothing stored, window open -> pair")
    c.equal(Pairing.decide(storedToken: nil, windowOpen: true, helloToken: other), .pair, "2: unknown token, nothing stored, window open -> pair")
    c.equal(Pairing.decide(storedToken: tok, windowOpen: false, helloToken: other), .reject(.badToken), "3: wrong token, stored token, closed -> bad_token")
    c.equal(Pairing.decide(storedToken: tok, windowOpen: false, helloToken: nil), .reject(.pairingRequired), "3: no token, closed -> pairing_required")
    c.equal(Pairing.decide(storedToken: tok, windowOpen: false, helloToken: ""), .reject(.pairingRequired), "3: empty token counts as none")
    c.equal(Pairing.decide(storedToken: nil, windowOpen: false, helloToken: other), .reject(.pairingRequired), "3: token but nothing stored -> pairing_required")
    c.equal(Pairing.decide(storedToken: nil, windowOpen: false, helloToken: nil), .reject(.pairingRequired), "3: nothing at all -> pairing_required")
    c.equal(Pairing.decide(storedToken: "", windowOpen: false, helloToken: ""), .reject(.pairingRequired), "3: empty stored token counts as none")
    c.equal(Pairing.decide(storedToken: tok, windowOpen: false, helloToken: tok.uppercased()), .reject(.badToken), "token compare is exact")

    c.begin("Pairing tokens")
    var seen = Set<String>()
    var allValid = true
    for _ in 0..<500 {
        let t: String = Pairing.newToken()
        if !Pairing.isValidToken(t) { allValid = false }
        seen.insert(t)
    }
    c.check(allValid, "newToken is 32 lowercase hex characters")
    c.equal(seen.count, 500, "500 tokens are all different")
    var g1 = SplitMix64(seed: 42)
    var g2 = SplitMix64(seed: 42)
    let det: String = Pairing.newToken(using: &g1)
    let a: UInt64 = g2.next()
    let b: UInt64 = g2.next()
    c.equal(det, Pairing.hex(a, digits: 16) + Pairing.hex(b, digits: 16), "token is 16 random bytes as hex")
    c.equal(Pairing.hex(0, digits: 8), "00000000", "hex pads with zeros")
    c.equal(Pairing.hex(0xDEAD_BEEF, digits: 8), "deadbeef", "hex lowercase")
    c.equal(Pairing.hex(UInt64.max, digits: 16), "ffffffffffffffff", "hex of UInt64.max")
    var codesOK = true
    var gc = SplitMix64(seed: 7)
    var codeSet = Set<String>()
    for _ in 0..<2000 {
        let code: String = Pairing.newCode(using: &gc)
        let digitsOnly: Bool = code.allSatisfy { $0 >= "0" && $0 <= "9" }
        if code.count != 4 || !digitsOnly { codesOK = false }
        codeSet.insert(code)
    }
    c.check(codesOK, "pairing codes are 4 digits")
    c.check(codeSet.count > 1500, "pairing codes vary", "\(codeSet.count) distinct of 2000")
    c.check(codeSet.contains { $0.hasPrefix("0") }, "codes keep leading zeros")
    c.equal(Pairing.newCode().count, 4, "newCode() uses the system RNG")
    c.equal(Pairing.zeroPadded(42, width: 4), "0042", "zeroPadded")
    c.check(Pairing.constantTimeEquals(tok, tok), "constantTimeEquals equal")
    c.check(!Pairing.constantTimeEquals(tok, String(tok.dropLast()) + "0"), "constantTimeEquals last char differs")
    c.check(!Pairing.constantTimeEquals(tok, tok + "0"), "constantTimeEquals length differs")
    c.check(!Pairing.constantTimeEquals("", "a"), "constantTimeEquals empty vs one char")
    c.check(Pairing.constantTimeEquals("", ""), "constantTimeEquals both empty")
    c.check(Pairing.isValidToken(tok), "isValidToken accepts lowercase hex")
    c.check(!Pairing.isValidToken(tok.uppercased()), "isValidToken rejects uppercase")
    c.check(!Pairing.isValidToken(String(tok.dropLast())), "isValidToken rejects 31 chars")
    c.equal(Pairing.typesAllowedBeforeAcceptance, Set(["hello", "ping"]), "only hello and ping before acceptance")
    c.equal(Pairing.windowDuration, 120, "window is 2 minutes")

    c.begin("PairingState")
    var s = PairingState(storedToken: nil)
    c.equal(s.isPaired, false, "starts unpaired")
    c.equal(s.isWindowOpen(now: 0), false, "window starts closed")
    c.equal(s.openWindowIfUnpaired(now: 100), true, "launch while unpaired opens the window")
    c.equal(s.isWindowOpen(now: 100), true, "open at 0 s")
    c.equal(s.isWindowOpen(now: 219.999), true, "open at 119.999 s")
    c.equal(s.isWindowOpen(now: 220), false, "closed at 120 s")
    c.near(s.windowRemaining(now: 160), 60, 1e-9, "60 s remaining")
    c.equal(s.windowRemaining(now: 300), 0, "0 remaining when closed")
    var rng = SplitMix64(seed: 99)
    let paired: PairingOutcome = s.handleHello(token: nil, now: 101, using: &rng)
    c.equal(paired.decision, .pair, "hello without a token in the window pairs")
    c.check(paired.accepted && paired.tokenChanged, "pairing accepts and changes the token")
    let newTok: String = paired.pairToken ?? ""
    c.check(Pairing.isValidToken(newTok), "pair_token is 32 lowercase hex", newTok)
    c.equal(paired.pairCode?.count ?? 0, 4, "pair_code has 4 digits")
    c.equal(s.storedToken ?? "", newTok, "token stored")
    c.equal(s.lastPairCode ?? "", paired.pairCode ?? "-", "code kept for display")
    c.equal(s.isWindowOpen(now: 102), false, "pairing closes the window")
    let welcome: GBObject = paired.reply(phoneName: "Alexander's iPhone")
    c.equal(welcome.type ?? "", "welcome", "pair reply is welcome")
    c.equal(welcome.string("pair_token") ?? "", newTok, "welcome.pair_token")
    c.equal(welcome.string("pair_code") ?? "", paired.pairCode ?? "-", "welcome.pair_code")
    c.equal(welcome.string("phone_name") ?? "", "Alexander's iPhone", "welcome.phone_name")
    c.equal(welcome.int("version") ?? 0, 2, "welcome.version")

    let again: PairingOutcome = s.handleHello(token: newTok, now: 103)
    c.equal(again.decision, .accept, "the stored token is accepted")
    c.check(again.pairToken == nil && again.pairCode == nil && !again.tokenChanged, "accept has no pair fields")
    let plain: GBObject = again.reply(phoneName: "P")
    c.equal(plain.keys, ["type", "server", "version", "phone_name"], "welcome without pair fields")

    let wrong: PairingOutcome = s.handleHello(token: "ffffffffffffffffffffffffffffffff", now: 104)
    c.equal(wrong.decision, .reject(.badToken), "wrong token with the window closed: bad_token")
    c.equal(wrong.accepted, false, "rejected is not accepted")
    let rej: GBObject = wrong.reply(phoneName: "P")
    c.equal(rej.type ?? "", "rejected", "reply is rejected")
    c.equal(rej.string("reason") ?? "", "bad_token", "rejected.reason")
    c.check((rej.string("message") ?? "").contains("Pair Glass"), "rejected.message tells the user what to do")
    c.equal(s.handleHello(token: nil, now: 105).decision, .reject(.pairingRequired), "no token, closed: pairing_required")
    c.equal(s.storedToken ?? "", newTok, "rejections don't touch the stored token")

    c.equal(s.openWindowIfUnpaired(now: 106), false, "foreground while paired doesn't open the window")
    c.equal(s.isWindowOpen(now: 107), false, "still closed")
    s.openWindow(now: 200)
    let repair: PairingOutcome = s.handleHello(token: "ffffffffffffffffffffffffffffffff", now: 210)
    c.equal(repair.decision, .pair, "Pair Glass then another Glass: pairs")
    c.check(repair.pairToken != newTok, "new token replaces the old one")
    c.equal(s.handleHello(token: newTok, now: 211).decision, .reject(.badToken), "the old Glass is now rejected")

    s.forget()
    c.equal(s.isPaired, false, "forget deletes the token")
    c.equal(s.isWindowOpen(now: 212), false, "forget doesn't open the window")
    c.equal(s.handleHello(token: repair.pairToken, now: 213).decision, .reject(.pairingRequired), "after forget: pairing_required")
    s.openWindow(now: 300)
    c.equal(s.handleHello(token: nil, now: 420).decision, .reject(.pairingRequired), "window closed exactly at 120 s")
    s.openWindow(now: 500)
    s.closeWindow()
    c.equal(s.isWindowOpen(now: 501), false, "closeWindow")
    c.equal(PairingState(storedToken: "").isPaired, false, "empty stored token means unpaired")
    c.equal(PairingState(storedToken: tok).isPaired, true, "stored token means paired")
}

// MARK: - Split reads

private func checkSplitReads(_ c: Checker) {
    c.begin("split reads")
    var stream = Data()
    var expected: [(String, Data?)] = []
    func add(_ obj: GBObject, _ payload: Data? = nil) {
        if let d = try? GBEncoder.encode(obj, payload: payload) {
            stream.append(d)
            expected.append((obj.type ?? "", payload))
        }
    }
    stream.append(Data("\r\n\n\r\n".utf8))
    add(Msg.card(id: "c-1", title: "T", text: "line1\nline2 {\"type\":\"ping\"}"))
    add(GBObject(type: "file_chunk"), Data("\n{\"type\":\"ping\"}\r\n\r\n\r".utf8))
    stream.append(Data("\r\n".utf8))
    stream.append(Data("{\"type\":\"crlf\",\"bytes\":4}\r\n\n\n\r\n".utf8))
    expected.append(("crlf", Data("\n\n\r\n".utf8)))
    stream.append(Data("\n".utf8))
    add(Msg.ping())
    var all = [UInt8](repeating: 0, count: 256)
    for i in 0..<256 { all[i] = UInt8(i) }
    add(GBObject(type: "binary"), Data(all + all))
    stream.append(Data("{\"type\":\"empty\",\"bytes\":0}\n".utf8))
    expected.append(("empty", nil))
    add(Msg.pong())
    let bytes: [UInt8] = [UInt8](stream)

    func matches(_ got: [GBFrame]) -> Bool {
        if got.count != expected.count { return false }
        for (i, e) in expected.enumerated() {
            if got[i].type != e.0 { return false }
            if got[i].payload != e.1 { return false }
        }
        return true
    }
    var okSizes = true
    var badSize = 0
    for size in 0...17 {
        if let got = try? frames(bytes, readSize: size), matches(got) {
            continue
        }
        okSizes = false
        badSize = size
    }
    c.check(okSizes, "reads of 1...17 bytes and all at once", "read size \(badSize) failed")

    // Random split points.
    var rng = SplitMix64(seed: 2026)
    var okRandom = true
    for _ in 0..<200 {
        let parser = FrameParser()
        var got: [GBFrame] = []
        var i = 0
        do {
            while i < bytes.count {
                let n: Int = Int.random(in: 1...40, using: &rng)
                let end: Int = min(bytes.count, i + n)
                parser.append(contentsOf: bytes[i..<end])
                while let f = try parser.next() { got.append(f) }
                i = end
            }
        } catch {
            okRandom = false
        }
        if !matches(got) || parser.bufferedCount != 0 { okRandom = false }
    }
    c.check(okRandom, "200 random splits")

    // Byte-by-byte: nothing comes out early, and the parser is clean between frames.
    let parser = FrameParser()
    var count = 0
    var early = false
    for (i, byte) in bytes.enumerated() {
        parser.append([byte])
        do {
            while let _ = try parser.next() { count += 1 }
        } catch {
            early = true
        }
        if i == 0 && count > 0 { early = true }
    }
    c.check(!early, "one byte at a time")
    c.equal(count, expected.count, "every frame from one-byte feeds")
    c.equal(parser.bufferedCount, 0, "nothing left over")

    // Data input works the same as [UInt8].
    let p2 = FrameParser()
    p2.append(stream)
    let drained: [GBFrame]? = try? p2.drain()
    c.check(drained.map(matches) ?? false, "append(Data) + drain()")

    // A payload split across appends.
    let p3 = FrameParser()
    p3.append(bytesOf("{\"type\":\"file_chunk\",\"bytes\":10}\n01234"))
    let none: GBFrame?? = try? p3.next()
    c.check(none == .some(nil), "half a payload: no frame yet")
    c.equal(p3.isReadingPayload, true, "isReadingPayload")
    p3.append(bytesOf("56789{\"type\":\"ping\"}\n"))
    let chunk: GBFrame?? = try? p3.next()
    c.check(chunk??.payload == Data("0123456789".utf8), "payload completed by the next append")
    let ping: GBFrame?? = try? p3.next()
    c.equal(ping??.type ?? "", "ping", "frame after the payload")
}

// MARK: - Limits and protocol errors

private func checkLimits(_ c: Checker) {
    c.begin("limits")
    let prefix = "{\"type\":\"x\",\"t\":\""
    let suffix = "\"}"
    let fill: Int = GBProtocol.maxLine - prefix.utf8.count - suffix.utf8.count
    let exact: String = prefix + String(repeating: "a", count: fill) + suffix
    c.equal(exact.utf8.count, 65_536, "test line is exactly 64 KiB")
    c.noThrow("a 65,536-byte line + CRLF is accepted (1-byte reads)") {
        let got: [GBFrame] = try frames(bytesOf(exact + "\r\n"), readSize: 1)
        if got.count != 1 { throw GBProtocolError("expected 1 frame") }
    }
    c.noThrow("a 65,536-byte line + LF is accepted") {
        _ = try frames(bytesOf(exact + "\n"), readSize: 0)
    }
    let over: String = prefix + String(repeating: "a", count: fill + 1) + suffix
    c.throwsError("a 65,537-byte line is a protocol error") {
        _ = try frames(bytesOf(over + "\n"), readSize: 0)
    }
    // A line with no newline is rejected as soon as it can't fit any more.
    let p = FrameParser()
    p.append([UInt8](repeating: 0x61, count: 65_537))
    var earlyError = false
    do { _ = try p.next() } catch { earlyError = true }
    c.check(!earlyError, "65,537 bytes without a newline: still waiting (room for \\r)")
    p.append([0x61])
    c.throwsError("65,538 bytes without a newline: protocol error") { _ = try p.next() }
    p.append(bytesOf("\n{\"type\":\"ping\"}\n"))
    c.throwsError("a parser stays dead after an error") { _ = try p.next() }
    c.check(p.error != nil, "error is recorded")

    c.throwsError("bytes above 1 MiB is a protocol error") {
        _ = try frames(bytesOf("{\"type\":\"file_chunk\",\"bytes\":1048577}\n"), readSize: 0)
    }
    c.noThrow("a payload of exactly 1 MiB is accepted") {
        var b: [UInt8] = bytesOf("{\"type\":\"file_chunk\",\"bytes\":1048576}\n")
        b.append(contentsOf: [UInt8](repeating: 0x0A, count: 1_048_576))
        let got: [GBFrame] = try frames(b, readSize: 65_536)
        if got.count != 1 || got[0].payloadCount != 1_048_576 { throw GBProtocolError("bad 1 MiB frame") }
    }
    c.throwsError("negative bytes is a protocol error") {
        _ = try frames(bytesOf("{\"type\":\"x\",\"bytes\":-1}\n"), readSize: 0)
    }
    c.throwsError("negative fractional bytes is a protocol error") {
        _ = try frames(bytesOf("{\"type\":\"x\",\"bytes\":-1.5}\n"), readSize: 0)
    }
    let noPayload: [String] = ["\"5\"", "true", "2.5", "3.0", "null", "[3]", "1e1"]
    for v in noPayload {
        let text = "{\"type\":\"x\",\"bytes\":\(v)}\n{\"type\":\"ping\"}\n"
        let got: [GBFrame]? = try? frames(bytesOf(text), readSize: 1)
        let ok: Bool = got?.count == 2 && got?[0].payload == nil && got?[1].type == "ping"
        c.check(ok, "\"bytes\":\(v) means no payload")
    }
    let bad: [(String, String)] = [
        ("[1,2]", "not an object"),
        ("\"text\"", "a bare string"),
        ("{\"a\":1}", "no type"),
        ("{\"type\":5}", "type not a string"),
        ("{\"type\":null}", "type null"),
        ("{\"type\":\"x\",}", "trailing comma"),
        ("{\"type\":\"x\"} x", "data after the object"),
        ("{'type':'x'}", "single quotes"),
        ("{\"type\":\"x\",\"n\":NaN}", "NaN"),
        ("{\"type\":\"x\",\"n\":Infinity}", "Infinity"),
        ("{\"type\":\"x\",\"n\":-Infinity}", "-Infinity"),
        ("not json", "garbage"),
    ]
    for (line, why) in bad {
        c.throwsError("protocol error: \(why)") {
            _ = try frames(bytesOf(line + "\n"), readSize: 0)
        }
    }
    var invalidUTF8: [UInt8] = bytesOf("{\"type\":\"")
    invalidUTF8.append(contentsOf: [0xC0, 0xAF])
    invalidUTF8.append(contentsOf: bytesOf("\"}\n"))
    c.throwsError("protocol error: invalid UTF-8") { _ = try frames(invalidUTF8, readSize: 0) }

    // Frames before the bad line still come out, in order, then the error.
    let p2 = FrameParser()
    p2.append(bytesOf("{\"type\":\"ping\"}\nbad line\n{\"type\":\"pong\"}\n"))
    let firstFrame: GBFrame?? = try? p2.next()
    c.equal(firstFrame??.type ?? "", "ping", "frames before an error are returned first")
    c.throwsError("then the error") { _ = try p2.next() }
    c.throwsError("and again") { _ = try p2.next() }
}

// MARK: - Accessors

private func checkAccessors(_ c: Checker) {
    c.begin("accessors")
    let line = "{\"type\":\"t\",\"b\":true,\"f\":false,\"i\":1,\"z\":0,\"d\":1.0,\"x\":2.75,\"neg\":-3.9," +
        "\"big\":1793491200123,\"huge\":12345678901234567890,\"s\":\"7\",\"n\":null,\"o\":{\"k\":[1,\"a\"]}}\n"
    guard let fs = try? frames(bytesOf(line)), let f = fs.first else {
        c.check(false, "accessor frame parses")
        return
    }
    c.equal(f.type, "t", "type")
    c.equal(f.bool("b"), true, "bool true")
    c.equal(f.bool("f"), false, "bool false")
    c.check(f.int("b") == nil, "true is not an int")
    c.check(f.double("b") == nil, "true is not a double")
    c.check(f.bool("i") == nil, "1 is not a bool")
    c.check(f.bool("z") == nil, "0 is not a bool")
    c.equal(f.int("i"), 1, "int 1")
    c.equal(f.double("i"), 1.0, "int as double")
    c.check(f["d"] == .double(1.0), "1.0 stays a fraction")
    c.equal(f.int("d"), 1, "1.0 converts to int")
    c.equal(f.int("x"), 2, "2.75 truncates to 2")
    c.equal(f.int("neg"), -3, "-3.9 truncates to -3")
    c.equal(f.int64("big"), 1793491200123, "epoch ms as int64")
    c.equal(f.int("big"), 1793491200123, "epoch ms as Int (64-bit)")
    c.check(f["huge"] == .double(12345678901234567890.0), "integer above Int64 becomes a double")
    c.check(f.int64("huge") == nil, "out-of-range number has no int64")
    c.equal(f.string("s"), "7", "string")
    c.check(f.int("s") == nil, "string is not converted to int")
    c.check(f.string("n") == nil && f["n"] == .null && f.has("n"), "null")
    c.check(f.string("missing") == nil && !f.has("missing"), "missing key")
    c.equal(f.header.object("o")?.array("k")?.count ?? 0, 2, "nested object and array")
    let raw: [String: Any] = f.raw
    c.check(raw["b"] is Bool && type(of: raw["b"]!) == Bool.self, "raw true is a Swift Bool")
    c.check(type(of: raw["i"]!) == Int.self, "raw 1 is a Swift Int")
    c.check(type(of: raw["d"]!) == Double.self, "raw 1.0 is a Swift Double")
    c.check(raw["n"] is NSNull, "raw null is NSNull")
    c.check(((raw["o"] as? [String: Any])?["k"] as? [Any])?.count == 2, "raw nested")
}

// MARK: - JSON layer

private func checkJSON(_ c: Checker) {
    c.begin("JSON parser")
    func parse(_ s: String) -> GBJSON? {
        return try? GBJSONParser.parse(s)
    }
    c.equal(parse("\"\\u00e9\"")?.stringValue ?? "", "\u{e9}", "\\u00e9")
    c.equal(parse("\"\\ud83d\\ude80\"")?.stringValue ?? "", "\u{1F680}", "surrogate pair")
    c.equal(parse("\"\\ud83d\"")?.stringValue ?? "", "\u{FFFD}", "lone high surrogate becomes U+FFFD")
    c.equal(parse("\"\\ude80x\"")?.stringValue ?? "", "\u{FFFD}x", "lone low surrogate becomes U+FFFD")
    c.equal(parse("\"\\ud83d\\u0041\"")?.stringValue ?? "", "\u{FFFD}A", "high surrogate followed by a non-surrogate")
    c.equal(parse("\"\\/\\b\\f\\n\\r\\t\\\"\\\\\"")?.stringValue ?? "", "/\u{8}\u{c}\n\r\t\"\\", "simple escapes")
    c.equal(parse("\"\u{1F680} raw\"")?.stringValue ?? "", "\u{1F680} raw", "raw 4-byte UTF-8")
    c.check(parse("-0") == .int(0), "-0 is int 0")
    c.check(parse("-0.0") == .double(-0.0), "-0.0 is a fraction")
    c.check(parse("1E+2") == .double(100), "1E+2")
    c.check(parse("123456789012345678901234") == .double(123456789012345678901234.0), "huge integer becomes a double")
    c.check(parse("9223372036854775807") == .int(Int64.max), "Int64.max stays an int")
    c.check(parse("1e400") == .double(Double.infinity), "1e400 overflows to infinity (accepted like Python json)")
    c.check(parse("-1e400") == .double(-Double.infinity), "-1e400 overflows to -infinity")
    c.check(parse("1e400")?.int64Value == nil, "infinity has no int value")
    c.check(parse("-9223372036854775808") == .int(Int64.min), "Int64.min stays an int")
    c.check(parse(" \t\r\n {\"type\" : \"x\" ,\t\"a\" : [ 1 , 2.5 , true , null , { \"b\" : \"c\" } ] } \r") != nil,
            "whitespace everywhere")
    if case .object(let dup)? = parse("{\"type\":\"x\",\"a\":1,\"b\":2,\"a\":3}") {
        c.check(dup["a"] == .int(3), "duplicate key: last value wins")
        c.equal(dup.keys, ["type", "a", "b"], "duplicate key keeps its first position")
    } else {
        c.check(false, "duplicate keys parse")
    }
    let invalid: [String] = ["\"\\x\"", "\"\\u12\"", "\"abc", "\"a\tb\"", "01", "1.", ".5", "-", "+1", "1e",
                             "[1,]", "{,}", "{\"a\" 1}", "tru", "nul", "[1 2]", "{\"a\":}", "", "  "]
    for s in invalid {
        c.check(parse(s) == nil, "rejects \(s.debugDescription)")
    }
    let deepOK: String = String(repeating: "[", count: 150) + String(repeating: "]", count: 150)
    c.check(parse(deepOK) != nil, "150 levels of nesting")
    let deepBad: String = String(repeating: "[", count: 201) + String(repeating: "]", count: 201)
    c.check(parse(deepBad) == nil, "201 levels of nesting is rejected")
    let badUTF8: [[UInt8]] = [[0x22, 0xC0, 0xAF, 0x22], [0x22, 0xED, 0xA0, 0x80, 0x22], [0x22, 0xF5, 0x80, 0x80, 0x80, 0x22],
                              [0x22, 0xE2, 0x82, 0x22], [0x22, 0x80, 0x22], [0x22, 0xF4, 0x90, 0x80, 0x80, 0x22]]
    for b in badUTF8 {
        c.check((try? GBJSONParser.parse(b)) == nil, "rejects invalid UTF-8 \(b.map { String($0, radix: 16) })")
    }
    c.check((try? GBJSONParser.parse([0x22, 0xF0, 0x9F, 0x9A, 0x80, 0x22])) == .string("\u{1F680}"), "accepts valid 4-byte UTF-8")

    c.begin("JSON writer")
    var all = ""
    for v in 0..<0x80 {
        all.unicodeScalars.append(Unicode.Scalar(UInt8(v)))
    }
    all += "\u{e9}\u{1F680}\u{2028}/"
    var o = GBObject(type: "w")
    o.set("s", all)
    let text: String = lineText(o)
    c.check(text.hasPrefix("{\"type\":\"w\","), "type first, compact")
    c.check(!text.utf8.contains(where: { $0 < 0x20 }), "no raw control characters in the line")
    c.check(text.contains("\\u0001") && text.contains("\\n") && text.contains("\\t") && text.contains("\\u001f"), "control characters escaped")
    c.check(text.contains("/\"}") && !text.contains("\\/"), "slash not escaped")
    c.check(text.contains("\u{e9}\u{1F680}"), "non-ASCII written as raw UTF-8")
    if let back = try? roundTrip(o) {
        c.equal(back.string("s") ?? "", all, "every ASCII character round-trips")
    } else {
        c.check(false, "string round trip parses")
    }
    let doubles: [Double] = [0.1, 1e-7, 1e21, -0.0, 123.456, Double.leastNonzeroMagnitude, 1.7976931348623157e308, 150.0, -34.928499, 0.30000000000000004]
    for d in doubles {
        var od = GBObject(type: "d")
        od.set("v", d)
        let back: GBFrame? = try? roundTrip(od)
        c.check(back?["v"] == .double(d), "double \(d) round-trips exactly", short(back?["v"]))
    }
    var nan = GBObject(type: "d")
    nan.set("v", Double.nan)
    nan.set("w", Double.infinity)
    c.check(!nan.contains("v") && !nan.contains("w"), "set() leaves out NaN and infinity")
    var inf = GBObject(type: "d")
    inf["v"] = .double(Double.infinity)
    c.throwsError("encoding infinity throws") { _ = try GBEncoder.encode(inf) }
}

// MARK: - Encoder

private func checkEncoder(_ c: Checker) {
    c.begin("encoder")
    var o = GBObject()
    o.set("a", 1)
    o.set("type", "late")
    c.check(lineText(o).hasPrefix("{\"type\":\"late\",\"a\":1}"), "type is written first", lineText(o))
    if let d = try? GBEncoder.encode(Msg.ping()) {
        c.equal(String(decoding: d, as: UTF8.self), "{\"type\":\"ping\"}\n", "ping encodes compactly")
    }
    var withBytes = GBObject(type: "file_chunk")
    withBytes.set("bytes", 999)
    withBytes.set("id", "a")
    if let d = try? GBEncoder.encode(withBytes, payload: Data("xyz".utf8)) {
        c.equal(String(decoding: d, as: UTF8.self), "{\"type\":\"file_chunk\",\"bytes\":3,\"id\":\"a\"}\nxyz", "bytes recomputed from the payload")
    } else {
        c.check(false, "encode with payload")
    }
    if let d = try? GBEncoder.encode(GBObject(type: "e"), payload: Data()) {
        c.equal(String(decoding: d, as: UTF8.self), "{\"type\":\"e\",\"bytes\":0}\n", "empty payload: bytes 0")
    }
    c.throwsError("positive bytes without a payload throws") { _ = try GBEncoder.encode(withBytes) }
    var zero = GBObject(type: "z")
    zero.set("bytes", 0)
    c.noThrow("bytes 0 without a payload is fine") { _ = try GBEncoder.encode(zero) }
    c.throwsError("missing type throws") {
        var x = GBObject()
        x.set("a", 1)
        _ = try GBEncoder.encode(x)
    }
    c.throwsError("line over 64 KiB throws") {
        _ = try GBEncoder.encode(Msg.card(id: "c", title: "t", text: String(repeating: "x", count: 70_000)))
    }
    c.throwsError("payload over 1 MiB throws") {
        _ = try GBEncoder.encode(GBObject(type: "f"), payload: Data(count: 1_048_577))
    }
    c.noThrow("payload of exactly 1 MiB encodes") {
        _ = try GBEncoder.encode(GBObject(type: "f"), payload: Data(count: 1_048_576))
    }
    // Re-encoding a parsed frame keeps every field, including unknown ones.
    let src = "{\"bytes\":2,\"type\":\"x_new\",\"x_extra\":\"kept\",\"n\":3.0}\nhi"
    if let f = try? frames(bytesOf(src)).first, let d = try? GBEncoder.encode(f) {
        c.equal(String(decoding: d, as: UTF8.self), "{\"type\":\"x_new\",\"x_extra\":\"kept\",\"n\":3.0,\"bytes\":2}\nhi", "re-encode keeps unknown fields and number kinds")
    } else {
        c.check(false, "re-encode a parsed frame")
    }
    if let d = try? GBEncoder.encode(dictionary: ["type": "card", "chime": true, "ttl_s": 30, "x": 1.5,
                                                  "n": NSNull(), "arr": [1, "a"] as [Any]]) {
        c.equal(String(decoding: d, as: UTF8.self),
                "{\"type\":\"card\",\"arr\":[1,\"a\"],\"chime\":true,\"n\":null,\"ttl_s\":30,\"x\":1.5}\n",
                "encode(dictionary:) puts type first, sorts the rest, keeps Bool and Int apart")
    } else {
        c.check(false, "encode(dictionary:)")
    }
    c.throwsError("encode(dictionary:) rejects a Date") {
        _ = try GBEncoder.encode(dictionary: ["type": "x", "d": Date()])
    }
}

// MARK: - Builders

private func checkBuilders(_ c: Checker) {
    c.begin("Msg builders")
    func rt(_ o: GBObject, _ name: String) -> GBFrame? {
        do {
            let f: GBFrame = try roundTrip(o)
            c.check(lineText(o).hasPrefix("{\"type\":\"\(o.type ?? "")\""), name + " line starts with type")
            return f
        } catch {
            c.check(false, name + " round trip", "\(error)")
            return nil
        }
    }
    let id: String = Msg.newCardID()
    let idHex: Bool = id.dropFirst(2).allSatisfy { ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") }
    c.check(id.hasPrefix("c-") && id.count == 10 && idHex, "card id is c-<8 hex>", id)

    if let f = rt(Msg.welcome(phoneName: "Alex"), "welcome") {
        c.equal(f.header.keys, ["type", "server", "version", "phone_name"], "welcome keys")
        c.equal(f.string("server") ?? "", "GlassBridge iOS", "welcome.server")
        c.check(f["version"] == .int(2), "welcome.version int 2")
    }
    if let f = rt(Msg.welcome(phoneName: "Alex", pairToken: "0123456789abcdef0123456789abcdef", pairCode: "0042"), "welcome paired") {
        c.equal(f.string("pair_code") ?? "", "0042", "pair_code string with leading zeros")
        c.equal(f.string("pair_token") ?? "", "0123456789abcdef0123456789abcdef", "pair_token")
    }
    if let f = rt(Msg.rejected(reason: .pairingRequired), "rejected") {
        c.equal(f.string("reason") ?? "", "pairing_required", "rejected.reason")
        c.check(f.string("message") != nil, "rejected.message default")
    }
    if let f = rt(Msg.rejected(reason: .badToken, message: ""), "rejected no message") {
        c.equal(f.header.keys, ["type", "reason"], "empty message is left out")
    }
    let full: GBObject = Msg.card(id: "c-1", title: "Hi", text: "Hello", source: "Messages", timeMs: 1793491200123,
                                  style: .notification, chime: true, wake: true, ttlS: 30)
    if let f = rt(full, "card") {
        c.equal(f.header.keys, ["type", "id", "title", "text", "source", "time", "style", "chime", "wake", "ttl_s"], "card keys")
        c.check(f["time"] == .int(1793491200123), "card.time int")
        c.equal(f.string("style") ?? "", "notification", "card.style")
        c.check(f["chime"] == .bool(true) && f["wake"] == .bool(true), "card booleans")
        c.check(f["ttl_s"] == .int(30), "card.ttl_s int")
    }
    if let f = rt(Msg.card(id: "c-2", title: "T", text: "X"), "card minimal") {
        c.equal(f.header.keys, ["type", "id", "title", "text"], "optional card fields left out")
    }
    if let f = rt(Msg.dismiss(id: "c-1"), "dismiss") {
        c.equal(f.string("id") ?? "", "c-1", "dismiss.id")
    }
    if let f = rt(Msg.speak(text: "Turn left"), "speak") {
        c.equal(f.string("text") ?? "", "Turn left", "speak.text")
    }
    let navMsg: GBObject = Msg.nav(instruction: "Turn left onto X", maneuver: .slightLeft, distanceM: 123.5,
                                   street: "X", step: 2, stepsTotal: 7, etaMin: 4, remainingM: 1234.25,
                                   destination: "Rundle Mall", arrived: false, announce: true)
    if let f = rt(navMsg, "nav") {
        c.equal(f.header.keys, ["type", "instruction", "maneuver", "distance_m", "street", "step", "steps_total",
                                "eta_min", "remaining_m", "destination", "arrived", "announce"], "nav keys")
        c.equal(f.string("maneuver") ?? "", "slight_left", "nav.maneuver wire value")
        c.check(f["distance_m"] == .double(123.5), "nav.distance_m")
        c.check(f["step"] == .int(2) && f["steps_total"] == .int(7) && f["eta_min"] == .int(4), "nav ints")
        c.check(f["arrived"] == .bool(false) && f["announce"] == .bool(true), "nav booleans")
    }
    if let f = rt(Msg.nav(instruction: "Go", maneuver: .straight, distanceM: -5, step: 1, stepsTotal: 2), "nav minimal") {
        c.equal(f.header.keys, ["type", "instruction", "maneuver", "distance_m", "step", "steps_total"], "nav optional fields left out")
        c.check(f["distance_m"] == .double(0), "negative distance clamps to 0")
    }
    if let f = rt(Msg.navEnd(), "nav_end") {
        c.equal(f.type, "nav_end", "nav_end")
    }
    if let f = rt(Msg.location(lat: -34.928499, lon: 138.600746, accM: 4.5, altM: -5, speedMps: -1, bearing: -1, timeMs: 1793491200999), "location") {
        c.equal(f.header.keys, ["type", "lat", "lon", "acc_m", "alt_m", "time"], "negative speed/bearing left out, negative altitude kept")
        c.check(f["time"] == .int(1793491200999), "location.time int")
        c.check(f["lat"] == .double(-34.928499), "location.lat")
    }
    if let f = rt(Msg.location(lat: 1, lon: 2, accM: 3, speedMps: 0, bearing: 0, timeMs: 5), "location zero speed") {
        c.check(f["speed_mps"] == .double(0) && f["bearing"] == .double(0), "speed and bearing 0 are kept")
        c.check(f["lat"] == .double(1), "whole-number lat is still written as a number")
    }
    if let f = rt(Msg.sync(enabled: true), "sync") {
        c.check(f["enabled"] == .bool(true), "sync.enabled")
    }
    if let f = rt(Msg.requestStatus(), "request_status") {
        c.equal(f.header.keys, ["type"], "request_status has no fields")
    }
    if let f = rt(Msg.fileAck(id: "a.jpg:3", ok: false, error: "size mismatch"), "file_ack") {
        c.equal(f.header.keys, ["type", "id", "ok", "error"], "file_ack keys")
        c.check(f["ok"] == .bool(false), "file_ack.ok")
    }
    if let f = rt(Msg.fileAck(id: "a.jpg:3", ok: true, sha256: "ab", received: 3), "file_ack extras") {
        c.check(f["received"] == .int(3) && f.string("sha256") == "ab", "file_ack optional extras")
    }
    if let f = rt(Msg.screencast(on: true, fps: 9), "screencast") {
        c.check(f["fps"] == .int(5), "fps clamps to 5")
        c.check(f["on"] == .bool(true), "screencast.on")
    }
    if let f = rt(Msg.screencast(on: true, fps: 0), "screencast low") {
        c.check(f["fps"] == .int(1), "fps clamps to 1")
    }
    if let f = rt(Msg.screencast(on: false), "screencast off") {
        c.equal(f.header.keys, ["type", "on"], "fps left out when nil")
    }
    if let f = rt(Msg.wifiAdd(ssid: "Net", password: "pw", security: .wpa), "wifi_add") {
        c.equal(f.header.keys, ["type", "ssid", "password", "security"], "wifi_add keys")
        c.equal(f.string("security") ?? "", "WPA", "wifi_add.security")
    }
    if let f = rt(Msg.wifiAdd(ssid: "Open", password: "pw", security: .open), "wifi_add open") {
        c.equal(f.header.keys, ["type", "ssid", "security"], "no password for an open network")
        c.equal(f.string("security") ?? "", "OPEN", "OPEN")
    }
    if let f = rt(Msg.pong(), "pong") {
        c.equal(f.type, "pong", "pong")
    }

    c.begin("Glass messages")
    let helloEmpty: GBFrame? = try? frames(bytesOf("{\"type\":\"hello\",\"device\":\"glass-explorer\",\"version\":2,\"token\":\"\"}\n")).first
    if let h = helloEmpty.flatMap({ GlassHello($0) }) {
        c.check(h.token == nil, "empty hello.token is nil")
        c.check(h.model == nil, "missing model is nil")
    } else {
        c.check(false, "hello parses")
    }
    let partial: GBFrame? = try? frames(bytesOf("{\"type\":\"status\",\"battery\":55.0}\n")).first
    if let s = partial.flatMap({ GlassStatus($0) }) {
        c.equal(s.battery ?? 0, 55, "battery 55.0 converts to 55")
        c.check(s.charging == nil && s.wifiSSID == nil, "missing status fields are nil")
    } else {
        c.check(false, "partial status parses")
    }
    let ping: GBFrame? = try? frames(bytesOf("{\"type\":\"ping\"}\n")).first
    c.check(ping.flatMap({ GlassStatus($0) }) == nil, "GlassStatus needs type status")
    c.check(ping.flatMap({ GlassHello($0) }) == nil, "GlassHello needs type hello")
    let ackBad: GBFrame? = try? frames(bytesOf("{\"type\":\"ack\",\"id\":\"c-1\"}\n")).first
    c.check(ackBad.flatMap({ GlassAck($0) }) == nil, "ack without event is rejected")
    let endF: GBFrame? = try? frames(bytesOf("{\"type\":\"file_end\",\"id\":\"a:1\"}\n")).first
    c.equal(endF.flatMap({ GlassFileEnd($0) })?.id ?? "", "a:1", "file_end id")
    let negChunk: GBFrame? = try? frames(bytesOf("{\"type\":\"file_chunk\",\"id\":\"a\",\"offset\":-1}\n")).first
    c.check(negChunk.flatMap({ GlassFileChunk($0) }) == nil, "negative offset is rejected")
    let noPayloadFrame: GBFrame? = try? frames(bytesOf("{\"type\":\"frame\",\"w\":640,\"h\":360}\n")).first
    c.check(noPayloadFrame.flatMap({ GlassScreenFrame($0) }) == nil, "frame without a payload is rejected")
}

// MARK: - Foundation bridging (NSNumber from JSONSerialization)

private func checkFoundationBridging(_ c: Checker) {
    c.begin("Foundation bridging")
    c.check(GBJSON.fromFoundation(true) == .bool(true), "Swift Bool")
    c.check(GBJSON.fromFoundation(1) == .int(1), "Swift Int 1 is not a Bool")
    c.check(GBJSON.fromFoundation(0) == .int(0), "Swift Int 0 is not a Bool")
    c.check(GBJSON.fromFoundation(1.5) == .double(1.5), "Swift Double")
    c.check(GBJSON.fromFoundation(Float(2.5)) == .double(2.5), "Swift Float")
    c.check(GBJSON.fromFoundation(Int64(1793491200123)) == .int(1793491200123), "Swift Int64")
    c.check(GBJSON.fromFoundation(UInt64.max) == .double(Double(UInt64.max)), "UInt64.max becomes a double")
    c.check(GBJSON.fromFoundation(NSNumber(value: true)) == .bool(true), "NSNumber(true) is a Bool")
    c.check(GBJSON.fromFoundation(NSNumber(value: false)) == .bool(false), "NSNumber(false) is a Bool")
    c.check(GBJSON.fromFoundation(NSNumber(value: 1)) == .int(1), "NSNumber(1) is an int")
    c.check(GBJSON.fromFoundation(NSNumber(value: 1.5)) == .double(1.5), "NSNumber(1.5) is a double")
    c.check(GBJSON.fromFoundation("s") == .string("s"), "String")
    c.check(GBJSON.fromFoundation(NSNull()) == .null, "NSNull")
    let none: Int? = nil
    c.check(GBJSON.fromFoundation(none as Any) == .null, "nil Optional is null")
    let some: Int? = 4
    c.check(GBJSON.fromFoundation(some as Any) == .int(4), "Optional(4) is 4")
    c.check(GBJSON.fromFoundation(Date()) == nil, "Date is not JSON")
    c.check(GBJSON.fromFoundation(Double.nan) == nil, "NaN is not JSON")

    // JSONSerialization output: NSNumber for numbers and booleans on Darwin and Linux.
    let text = "{\"type\":\"t\",\"b\":true,\"f\":false,\"i\":1,\"z\":0,\"d\":1.5,\"e\":3.0,\"big\":1793491200123,\"neg\":-52,\"s\":\"x\"}"
    guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)), let dict = obj as? [String: Any] else {
        c.check(false, "JSONSerialization parses the sample")
        return
    }
    guard let g = GBObject(foundation: dict) else {
        c.check(false, "GBObject(foundation:) converts JSONSerialization output")
        return
    }
    c.check(g["b"] == .bool(true), "JSONSerialization true -> bool", short(g["b"]))
    c.check(g["f"] == .bool(false), "JSONSerialization false -> bool", short(g["f"]))
    c.check(g["i"] == .int(1), "JSONSerialization 1 -> int (not bool)", short(g["i"]))
    c.check(g["z"] == .int(0), "JSONSerialization 0 -> int (not bool)", short(g["z"]))
    c.check(g["d"] == .double(1.5), "JSONSerialization 1.5 -> double", short(g["d"]))
    c.equal(g.double("e") ?? 0, 3.0, "JSONSerialization 3.0 -> number 3")
    c.check(g["big"] == .int(1793491200123), "JSONSerialization epoch ms -> int", short(g["big"]))
    c.check(g["neg"] == .int(-52), "JSONSerialization -52 -> int", short(g["neg"]))
    c.equal(g.keys.first ?? "", "type", "type first")
    if let data = try? GBEncoder.encode(dictionary: dict), let back = try? frames([UInt8](data)).first {
        c.check(back["b"] == .bool(true) && back["i"] == .int(1), "JSONSerialization dictionary encodes with kinds intact")
    } else {
        c.check(false, "encode JSONSerialization dictionary")
    }
}

// MARK: - Upload bookkeeping

private func checkUploads(_ c: Checker) {
    c.begin("UploadProgress")
    func frame(_ text: String, _ payload: [UInt8]? = nil) -> GBFrame? {
        var b: [UInt8] = Array(text.utf8)
        if let p = payload { b.append(contentsOf: p) }
        return (try? parseAll(b, readSize: 0))?.first
    }
    guard let beginFrame = frame("{\"type\":\"file_begin\",\"id\":\"a.jpg:600\",\"name\":\"a.jpg\",\"size\":600,\"mime\":\"image/jpeg\",\"taken\":1793491200000}\n"),
          let begin = GlassFileBegin(beginFrame) else {
        c.check(false, "file_begin parses")
        return
    }
    func chunk(_ id: String, _ offset: Int, _ n: Int) -> GlassFileChunk? {
        let f: GBFrame? = frame("{\"type\":\"file_chunk\",\"id\":\"\(id)\",\"offset\":\(offset),\"bytes\":\(n)}\n",
                                [UInt8](repeating: 0x41, count: n))
        return f.flatMap { GlassFileChunk($0) }
    }
    var up = UploadProgress(begin)
    c.equal(up.fraction, 0, "starts at 0")
    if let c1 = chunk("a.jpg:600", 0, 256), let c2 = chunk("a.jpg:600", 256, 256), let c3 = chunk("a.jpg:600", 512, 88) {
        c.check(up.accept(c1) && up.accept(c2), "in-order chunks are accepted")
        c.near(up.fraction, 512.0 / 600.0, 1e-9, "fraction")
        c.check(up.accept(c3), "last chunk accepted")
        c.equal(up.received, 600, "received 600")
        let r = up.finish(id: "a.jpg:600")
        c.check(r.ok && r.error == nil, "file_end with every byte: ok")
    } else {
        c.check(false, "chunks parse")
    }
    var gap = UploadProgress(begin)
    if let c1 = chunk("a.jpg:600", 0, 100), let c3 = chunk("a.jpg:600", 200, 100), let c2 = chunk("a.jpg:600", 100, 100) {
        c.check(gap.accept(c1), "first chunk")
        c.check(!gap.accept(c3), "a gap is refused")
        c.check(!gap.accept(c2), "chunks after a failure are ignored")
        let r = gap.finish(id: "a.jpg:600")
        c.check(!r.ok && r.error == "chunks out of order", "out of order is reported at file_end", "\(r)")
    }
    var short = UploadProgress(begin)
    if let c1 = chunk("a.jpg:600", 0, 100) {
        _ = short.accept(c1)
        let r = short.finish(id: "a.jpg:600")
        c.check(!r.ok && r.error == "size mismatch", "short upload: size mismatch", "\(r)")
    }
    var other = UploadProgress(begin)
    if let x = chunk("b.jpg:5", 0, 5) {
        c.check(!other.accept(x), "a chunk for another id isn't written")
        c.equal(other.received, 0, "...and doesn't count")
    }
    let r = other.finish(id: "b.jpg:5")
    c.check(!r.ok && r.error == "unknown transfer", "file_end for another id: unknown transfer")
    c.check(!UploadProgress.unknown.ok && UploadProgress.unknown.error == "unknown transfer", "unknown constant")
    if let ackFrame = try? roundTrip(Msg.fileAck(id: begin.id, ok: false, error: UploadProgress.errorOutOfOrder)) {
        c.equal(ackFrame.string("error") ?? "", "chunks out of order", "file_ack carries the error text")
    }
    var empty = UploadProgress(GlassFileBegin(frame("{\"type\":\"file_begin\",\"id\":\"e:0\",\"name\":\"e\",\"size\":0}\n")!)!)
    c.equal(empty.fraction, 1, "empty file is complete")
    c.check(empty.finish(id: "e:0").ok, "empty file acks ok")
    if let z = chunk("e:0", 5, 1) {
        c.check(!empty.accept(z), "wrong offset on an empty file is refused")
    }
}
