// StreamChecks.swift - parts 1 and 2: the Python test stream (tools/make_test_stream.py).

import Foundation

struct ExpectedFrame {
    let index: Int
    let note: String
    let obj: GBObject
    let payload: Data?
    let payloadLen: Int
}

struct ExpectedStream {
    let streamBytes: Int
    let frameCount: Int
    let readSizes: [Int]
    let frames: [ExpectedFrame]
}

/// Loads expected.json. Payloads come from base64 via Foundation, independent of the
/// frame parser under test.
func loadExpected(_ path: String) throws -> ExpectedStream {
    let bytes: [UInt8] = try readFile(path)
    let doc: GBJSON = try GBJSONParser.parse(bytes)
    guard let root = doc.objectValue, root.string("format") == "glassbridge-test-stream" else {
        throw GBProtocolError("\(path) is not a glassbridge-test-stream file")
    }
    var frames: [ExpectedFrame] = []
    for item in root.array("frames") ?? [] {
        guard let f = item.objectValue, let obj = f.object("obj") else {
            throw GBProtocolError("bad frame entry in \(path)")
        }
        var payload: Data?
        if let b64 = f.string("payload_b64") {
            guard let d = Data(base64Encoded: b64) else {
                throw GBProtocolError("bad base64 in frame \(f.int("index") ?? -1)")
            }
            payload = d
        }
        frames.append(ExpectedFrame(index: f.int("index") ?? -1, note: f.string("note") ?? "",
                                    obj: obj, payload: payload, payloadLen: f.int("payload_len") ?? 0))
    }
    var sizes: [Int] = []
    for s in root.array("read_sizes") ?? [] {
        if let v = s.intValue { sizes.append(v) }
    }
    return ExpectedStream(streamBytes: root.int("stream_bytes") ?? -1,
                          frameCount: root.int("frame_count") ?? -1,
                          readSizes: sizes, frames: frames)
}

/// Compares decoded frames with expected.json strictly: same count, same key set
/// (including "bytes" as received), identical values and value kinds
/// (int vs fraction vs bool), identical payload presence and bytes.
func compareFrames(_ got: [GBFrame], _ expected: ExpectedStream, label: String, _ c: Checker) {
    if !c.check(got.count == expected.frames.count, "\(label): frame count",
                "expected \(expected.frames.count), got \(got.count)") {
        return
    }
    var errors = 0
    for (i, exp) in expected.frames.enumerated() {
        if errors >= 10 { break }
        let g: GBFrame = got[i]
        let tag: String = "\(label): frame \(i) (\(exp.obj.type ?? "?"))"
        var ok = true
        // Same key set (expected.json doesn't promise wire key order; the wire order is
        // checked separately for the "bytes"-first frame below).
        if g.header.keys.sorted() != exp.obj.keys.sorted() {
            ok = c.check(false, tag + " keys", "expected \(exp.obj.keys), got \(g.header.keys)") && ok
        }
        for key in exp.obj.keys {
            let e: GBJSON? = exp.obj[key]
            let a: GBJSON? = g.header[key]
            if a != e {
                ok = c.check(false, tag + " field '\(key)'", "expected \(short(e)), got \(short(a))") && ok
            }
        }
        if (g.payload == nil) != (exp.payload == nil) {
            ok = c.check(false, tag + " payload presence",
                         "expected \(exp.payload == nil ? "none" : "payload"), got \(g.payload == nil ? "none" : "payload")") && ok
        } else if let ep = exp.payload, let gp = g.payload, ep != gp {
            ok = c.check(false, tag + " payload bytes", "expected \(ep.count) bytes, got \(gp.count)") && ok
        }
        if g.payloadCount != exp.payloadLen {
            ok = c.check(false, tag + " payload_len", "expected \(exp.payloadLen), got \(g.payloadCount)") && ok
        }
        if ok {
            c.check(true, tag)
        } else {
            errors += 1
        }
    }
}

/// Part 1: parse stream.bin with every read size and check every frame, plus the typed
/// accessors on specific frames.
func runParse(streamPath: String, expectedPath: String) -> Int32 {
    let c = Checker(part: "part 1 (parse the Python stream)")
    let bytes: [UInt8]
    let expected: ExpectedStream
    do {
        bytes = try readFile(streamPath)
        expected = try loadExpected(expectedPath)
    } catch {
        print("ERROR: \(error)")
        return 2
    }
    c.begin("stream")
    c.equal(bytes.count, expected.streamBytes, "stream_bytes")
    c.equal(expected.frames.count, expected.frameCount, "frame_count")
    c.check(!expected.readSizes.isEmpty, "read_sizes present")

    var sizes: [Int] = [0]
    sizes.append(contentsOf: expected.readSizes)
    var frames: [GBFrame] = []
    for size in sizes {
        let label: String = size == 0 ? "whole stream" : "reads of \(size)"
        do {
            let got: [GBFrame] = try parseAll(bytes, readSize: size)
            compareFrames(got, expected, label: label, c)
            if size == 0 { frames = got }
        } catch {
            c.check(false, label, "\(error)")
        }
    }
    print("  parsed \(bytes.count) bytes into \(frames.count) frames with \(sizes.count) read sizes (0 = all at once): \(sizes)")

    // Typed accessors on known frames (the stream is fixed, see make_test_stream.py).
    c.begin("accessors")
    func first(_ type: String, _ match: (GBFrame) -> Bool = { _ in true }) -> GBFrame? {
        for f in frames where f.type == type && match(f) {
            return f
        }
        return nil
    }
    if let hello = first("hello"), let h = GlassHello(hello) {
        c.equal(h.device ?? "", "glass-explorer", "hello.device")
        c.equal(h.version ?? -1, 2, "hello.version")
        c.equal(h.token ?? "", "0123456789abcdef0123456789abcdef", "hello.token")
        c.equal(h.firmware ?? "", "XE24", "hello.firmware")
    } else {
        c.check(false, "hello frame parses as GlassHello")
    }
    if let w = first("welcome") {
        c.equal(w.string("pair_code") ?? "", "0042", "welcome.pair_code keeps leading zeros")
        c.equal(w.string("phone_name") ?? "", "Alexander\u{2019}s iPhone", "welcome.phone_name raw UTF-8")
        c.check(w.int("pair_code") == nil, "string pair_code is not an int")
    } else {
        c.check(false, "welcome frame present")
    }
    if let s = first("status"), let st = GlassStatus(s) {
        c.equal(st.battery ?? -1, 87, "status.battery")
        c.equal(st.charging ?? true, false, "status.charging is Bool false")
        c.equal(st.wifiRSSI ?? 0, -52, "status.wifi_rssi negative")
        c.equal(st.mockLocation ?? false, true, "status.mock_location")
        c.equal(st.uptimeS ?? 0, 3600, "status.uptime_s")
        c.equal(st.storageTotalMB ?? 0, 12288, "status.storage_total_mb")
        c.check(s.int("charging") == nil, "bool charging is not an int")
        c.check(s.bool("battery") == nil, "int battery is not a bool")
        c.check(s.double("charging") == nil, "bool charging is not a double")
        let raw: [String: Any] = s.raw
        c.check((raw["battery"] as? Int) == 87, "raw battery is Int 87")
        c.check(type(of: raw["charging"]!) == Bool.self, "raw charging is a Swift Bool")
        c.check(type(of: raw["battery"]!) == Int.self, "raw battery is a Swift Int")
    } else {
        c.check(false, "status frame parses as GlassStatus")
    }
    if let card = first("card", { $0.string("id") == "c-1a2b3c4d" }) {
        c.equal(card.int64("time") ?? 0, 1793491200123, "card.time epoch ms above 2^32")
        c.equal(card.string("title") ?? "", "Caf\u{e9} \u{2615}", "card.title accents and emoji")
        let text: String = card.string("text") ?? ""
        c.check(text.contains("\u{1F680}"), "card.text emoji outside the BMP")
        c.check(text.contains("\n") && text.contains("\"quoted\"") && text.contains("back\\slash") && text.contains("\t"),
                "card.text escapes decoded")
        c.equal(card.bool("chime") ?? false, true, "card.chime")
        c.equal(card.int("ttl_s") ?? 0, 30, "card.ttl_s")
    } else {
        c.check(false, "card c-1a2b3c4d present")
    }
    if let esc = first("card", { $0.string("id") == "c-esc" }) {
        c.equal(esc.string("title") ?? "", "\u{e9}\u{1F680}", "\\u escapes and surrogate pair")
        c.equal(esc.string("text") ?? "", "\u{2028}\u{2029} line/sep", "U+2028/U+2029 and \\/")
    } else {
        c.check(false, "card c-esc present")
    }
    if let nav = first("nav", { $0.string("instruction") == "Continue" }) {
        c.check(nav["distance_m"] == .double(150), "1.5e2 parses as the fraction 150.0", short(nav["distance_m"]))
        c.equal(nav.int("distance_m") ?? 0, 150, "1.5e2 converts to int 150")
        c.check(nav["eta_min"] == .double(3), "3.0 stays a fraction", short(nav["eta_min"]))
        c.equal(nav.int("eta_min") ?? 0, 3, "3.0 converts to int 3")
        c.equal(nav.double("step") ?? 0, 3, "int step converts to double")
    } else {
        c.check(false, "nav Continue present")
    }
    if let loc = first("location") {
        c.near(loc.double("lat"), -34.928499, 1e-12, "location.lat")
        c.near(loc.double("bearing"), 270.5, 1e-12, "location.bearing")
        c.equal(loc.int64("time") ?? 0, 1793491200999, "location.time")
    } else {
        c.check(false, "location present")
    }
    if let fb = first("file_begin"), let b = GlassFileBegin(fb) {
        c.equal(b.id, "IMG_0001.jpg:300000", "file_begin.id")
        c.equal(b.size, 300000, "file_begin.size")
        c.equal(b.takenMs ?? 0, 1793491200000, "file_begin.taken")
        c.check(b.takenDate != nil, "file_begin.takenDate")
    } else {
        c.check(false, "file_begin parses as GlassFileBegin")
    }
    var chunkBytes = 0
    var chunkCount = 0
    for f in frames where f.type == "file_chunk" && f.string("id") == "IMG_0001.jpg:300000" {
        if let ch = GlassFileChunk(f) {
            c.equal(Int(ch.offset), chunkBytes, "chunk offset \(chunkCount) is contiguous")
            chunkBytes += ch.data.count
            chunkCount += 1
        }
    }
    c.equal(chunkCount, 3, "three IMG_0001 chunks")
    if let zero = first("file_chunk", { $0.string("id") == "empty.jpg:0" }) {
        c.check(zero.payload == nil, "\"bytes\":0 means no payload")
        c.equal(zero.int("bytes") ?? -1, 0, "bytes 0 kept in the header")
    }
    if let k = first("file_chunk", { $0.string("id") == "k.jpg:3" }) {
        c.check(k.payload == Data("abc".utf8), "\"bytes\" as the first key")
        c.equal(k.header.keys.first ?? "", "bytes", "key order kept (bytes first)")
    }
    if let ack = first("ack"), let a = GlassAck(ack) {
        c.equal(a.id, "c-1a2b3c4d", "ack.id")
        c.check(a.knownEvent == .shown, "ack.event shown")
    } else {
        c.check(false, "ack parses as GlassAck")
    }
    if let wr = first("wifi_result"), let r = GlassWiFiResult(wr) {
        c.equal(r.ok, false, "wifi_result.ok")
        c.equal(r.error ?? "", "network not found", "wifi_result.error")
        c.equal(r.ssid, "Caf\u{e9}; \"Net\", :1\\", "wifi_result.ssid")
    } else {
        c.check(false, "wifi_result parses")
    }
    if let fr = first("frame"), let sf = GlassScreenFrame(fr) {
        c.equal(sf.width, 640, "frame.w")
        c.equal(sf.height, 360, "frame.h")
        c.check(sf.jpeg.starts(with: [0xFF, 0xD8, 0xFF]), "frame payload is the JPEG")
    } else {
        c.check(false, "frame parses as GlassScreenFrame")
    }
    if let x = first("x_future_thing") {
        c.equal(x.payloadCount, 7, "unknown type payload consumed")
    } else {
        c.check(false, "unknown type present")
    }
    if let long = first("card", { $0.string("id") == "c-long" }) {
        c.equal((long.string("text") ?? "").count, 50003, "50,003-character text")
    }
    if let last = frames.last {
        c.equal(last.type, "ping", "last frame is ping")
    }
    return c.finish()
}

/// Part 1 (differential fuzz): runs FrameParser.parseHeader on every line of a
/// parser_fuzz.py corpus and writes the verdicts for `parser_fuzz.py compare`.
func runFuzz(corpusPath: String, resultsPath: String) -> Int32 {
    let corpus: GBJSON
    do {
        corpus = try GBJSONParser.parse(try readFile(corpusPath))
    } catch {
        print("ERROR: can't read \(corpusPath): \(error)")
        return 2
    }
    guard let cases = corpus.objectValue?.array("cases") else {
        print("ERROR: \(corpusPath) has no cases")
        return 2
    }
    var results: [GBJSON] = []
    results.reserveCapacity(cases.count)
    var accepted = 0
    for item in cases {
        guard let entry = item.objectValue, let index = entry.int("i"),
              let b64 = entry.string("line_b64"), let data = Data(base64Encoded: b64) else {
            print("ERROR: bad corpus entry")
            return 2
        }
        var r = GBObject()
        r.set("i", index)
        do {
            let parsed: (GBObject, Int) = try FrameParser.parseHeader([UInt8](data))
            r.set("ok", true)
            r.set("payload_len", parsed.1)
            if (try? GBJSONWriter.encode(.object(parsed.0))) != nil {
                r["obj"] = .object(parsed.0)
            } else {
                r["obj"] = .null // holds +/-infinity, which JSON text can't carry
            }
            accepted += 1
        } catch {
            r.set("ok", false)
            r.set("why", "\(error)")
        }
        results.append(.object(r))
    }
    var root = GBObject()
    root["results"] = .array(results)
    do {
        let bytes: [UInt8] = try GBJSONWriter.encode(.object(root))
        try writeFile(resultsPath, Data(bytes))
    } catch {
        print("FAIL fuzz: \(error)")
        return 1
    }
    print("Swift parsed \(cases.count) header lines (\(accepted) accepted, \(cases.count - accepted) rejected)")
    return 0
}

/// Part 2 (builders): writes one frame per iPhone -> Glass builder, in a fixed order, for
/// tools/swift-check/check_messages.py to validate with the Python reference parser.
func runEmit(outPath: String) -> Int32 {
    var rng = SplitMix64(seed: 5)
    var pairing = PairingState(storedToken: nil)
    pairing.openWindow(now: 0)
    let paired: PairingOutcome = pairing.handleHello(token: nil, now: 1, using: &rng)
    let route: [NavStep] = [
        NavStep(instruction: "Head north on Test St", points: [GeoPoint(lat: -34.9285, lon: 138.6007),
                                                                GeoPoint(lat: -34.9270, lon: 138.6007)], distance: 167),
        NavStep(instruction: "Turn left onto King William St", points: [GeoPoint(lat: -34.9270, lon: 138.6007),
                                                                         GeoPoint(lat: -34.9270, lon: 138.5990)], distance: 155),
    ]
    let tracker = NavTracker(steps: route, transport: .walking, destinationName: "Rundle Mall", expectedTravelTime: 300)
    var navCard: NavCard?
    for action in tracker.start(now: 0, at: GeoPoint(lat: -34.9285, lon: 138.6007)) {
        if case .send(let card) = action { navCard = card }
    }
    guard let nav = navCard else {
        print("FAIL emit: NavTracker produced no card")
        return 1
    }
    let messages: [GBObject] = [
        Msg.welcome(phoneName: "Alexander\u{2019}s iPhone"),
        paired.reply(phoneName: "Alexander\u{2019}s iPhone"),
        Msg.rejected(reason: .pairingRequired),
        Msg.rejected(reason: .badToken),
        Msg.card(id: Msg.newCardID(), title: "Messages", text: "Hi \u{1F680}", source: "Shortcuts",
                 timeMs: GBProtocol.nowMs(), style: .notification, chime: true, wake: true, ttlS: 600),
        Msg.card(id: "c-00000001", title: "T", text: "X"),
        Msg.dismiss(id: "c-00000001"),
        Msg.speak(text: "In 100 metres, turn left"),
        nav.message(),
        Msg.navEnd(),
        Msg.location(lat: -34.928499, lon: 138.600746, accM: 5, altM: 48.2, speedMps: 1.4, bearing: 270,
                     timeMs: 1793491200999),
        Msg.sync(enabled: true),
        Msg.requestStatus(),
        Msg.fileAck(id: "IMG_0001.jpg:300000", ok: true),
        Msg.fileAck(id: "IMG_0002.jpg:5", ok: false, error: "size mismatch"),
        Msg.screencast(on: true, fps: 2),
        Msg.wifiAdd(ssid: "My iPhone", password: "secret pw", security: .wpa),
        Msg.wifiAdd(ssid: "Cafe", password: nil, security: .open),
        Msg.ping(),
        Msg.pong(),
    ]
    var out = Data()
    do {
        for m in messages {
            out.append(try GBEncoder.encode(m))
        }
        try writeFile(outPath, out)
    } catch {
        print("FAIL emit: \(error)")
        return 1
    }
    print("Wrote \(messages.count) builder frames to \(outPath) (\(out.count) bytes)")
    return 0
}

/// Part 2 (Swift half): re-encode every frame of stream.bin with GBEncoder. Python's
/// `make_test_stream.py verify` then checks the output.
func runReencode(inPath: String, outPath: String) -> Int32 {
    do {
        let bytes: [UInt8] = try readFile(inPath)
        let frames: [GBFrame] = try parseAll(bytes, readSize: 0)
        var out = Data()
        for f in frames {
            out.append(try GBEncoder.encode(f))
        }
        try writeFile(outPath, out)
        // Sanity: our own parser reads our own output back to the same frames.
        let back: [GBFrame] = try parseAll([UInt8](out), readSize: 7)
        guard back.count == frames.count else {
            print("FAIL re-encode: read back \(back.count) frames, expected \(frames.count)")
            return 1
        }
        for (i, f) in frames.enumerated() {
            let a: GBObject = f.header.removing("bytes")
            let b: GBObject = back[i].header.removing("bytes")
            if a != b || (f.payload ?? Data()) != (back[i].payload ?? Data()) {
                print("FAIL re-encode: frame \(i) (\(f.type)) differs after a Swift round trip")
                return 1
            }
        }
        print("Re-encoded \(frames.count) frames to \(outPath) (\(out.count) bytes); Swift reads them back identically")
        return 0
    } catch {
        print("FAIL re-encode: \(error)")
        return 1
    }
}
