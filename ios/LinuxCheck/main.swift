// main.swift - runs the real GlassServer, GlassLink and MediaReceiver (with Core) on
// Linux against the scriptable Network/Photos stand-ins in Stubs/, playing Glass.
// It checks the PROTOCOL.md section 4 and 6 behaviour the iPhone app must have.
// This is a simulation, not a device test: it says nothing about real NWListener, iOS
// permissions, Photos or background behaviour.

import Foundation
import Network
import Photos

var checks: Int = 0
var failures: Int = 0

func check(_ condition: Bool, _ message: String) {
    checks += 1
    if condition {
        print("ok    " + message)
    } else {
        failures += 1
        print("FAIL  " + message)
    }
}

func onMain<T>(_ body: @escaping () -> T) -> T {
    return DispatchQueue.main.sync(execute: body)
}

func wait(_ seconds: Double) {
    Thread.sleep(forTimeInterval: seconds)
}

func frames(_ c: NWConnection) -> [GBFrame] {
    let parser = FrameParser()
    for d in c.sentData() {
        parser.append(d)
    }
    var out: [GBFrame] = []
    while let f = try? parser.next() {
        out.append(f)
    }
    return out
}

func types(_ c: NWConnection) -> [String] {
    return frames(c).map { $0.type }
}

func put(_ c: NWConnection, _ object: GBObject, payload: Data? = nil) {
    let data: Data = try! GBEncoder.encode(object, payload: payload)
    c.inject(data)
}

func hello(token: String?) -> GBObject {
    var o = GBObject(type: "hello")
    o.set("device", "glass-explorer")
    o.set("version", 2)
    o.set("model", "Glass 1")
    o.set("firmware", "XE24")
    o.set("app_version", "2.0-sim")
    o.set("token", token)
    return o
}

func object(_ type: String, _ fields: [String: Any]) -> GBObject {
    var all: [String: Any] = fields
    all["type"] = type
    return GBObject(foundation: all)!
}

func connect(_ listener: NWListener, _ remote: String) -> NWConnection {
    let c = NWConnection(remote: remote)
    listener.simulateIncoming(c)
    var n = 0
    while !c.isStarted && n < 100 {
        wait(0.01)
        n += 1
    }
    wait(0.05)
    return c
}

func isHex32(_ s: String?) -> Bool {
    guard let t = s else { return false }
    return Pairing.isValidToken(t)
}

func logContains(_ text: String) -> Bool {
    return onMain { GlassLink.shared.eventLog.contains { $0.text.contains(text) } }
}

func runScenarios() {
    let keys: [String] = ["pairToken", "phoneName", "syncEnabled", "shareLocation", "stayAlive",
                          "savedMediaIDs", "lastSeenTime", "lastSeenLat", "lastSeenLon"]
    for k in keys {
        UserDefaults.standard.removeObject(forKey: k)
    }

    // --- Start-up -------------------------------------------------------------------------
    onMain { GlassLink.shared.start() }
    wait(0.3)
    check(onMain { GlassLink.shared.listenerReady }, "listener reports ready after start()")
    check(onMain { GlassLink.shared.listenerState } == "Listening on port 9090", "listener state text is 'Listening on port 9090'")
    guard let listener = NWListener.latest else {
        check(false, "a listener was created")
        return
    }
    check(listener.service?.type == "_glassbridge._tcp" && listener.service?.name == nil, "Bonjour service _glassbridge._tcp with the device name")
    check(onMain { GlassLink.shared.effectivePhoneName } == "iPhone", "phone name defaults to UIDevice.current.name")
    check(!onMain { GlassLink.shared.pairing.isPaired }, "starts unpaired")

    // --- 1. Unpaired, window closed: rejected ---------------------------------------------
    let a = connect(listener, "172.20.10.2")
    put(a, hello(token: nil))
    wait(0.3)
    let fa = frames(a)
    check(fa.count == 1 && fa.first?.type == "rejected", "unpaired hello with pairing closed gets exactly one 'rejected'")
    check(fa.first?.string("reason") == "pairing_required", "reason is pairing_required")
    check(a.isCancelled, "rejected connection is closed after the frame is written")
    check(!onMain { GlassLink.shared.connected }, "not connected after a rejection")
    check(onMain { GlassLink.shared.lastRejection } != nil, "the rejection is shown in the UI state")

    // --- 2. Pair -------------------------------------------------------------------------
    onMain { GlassLink.shared.phoneName = "Alexander's iPhone" }
    onMain { GlassLink.shared.openPairingWindow() }
    check(onMain { GlassLink.shared.pairingStateText(now: Date().timeIntervalSince1970) }.hasPrefix("Pairing open 2:00") ||
          onMain { GlassLink.shared.pairingStateText(now: Date().timeIntervalSince1970) }.hasPrefix("Pairing open 1:5"),
          "Pair Glass opens the 2-minute window (state text 'Pairing open m:ss')")
    let b = connect(listener, "172.20.10.3")
    put(b, Msg.ping())
    wait(0.2)
    check(types(b) == ["pong"], "ping before hello is answered with pong (and nothing else)")
    put(b, hello(token: nil))
    wait(0.3)
    let fb = frames(b)
    check(fb.map { $0.type } == ["pong", "welcome", "sync"], "pairing hello gets welcome then sync")
    let welcome: GBFrame? = fb.count > 1 ? fb[1] : nil
    let pairToken: String? = welcome?.string("pair_token")
    let pairCode: String? = welcome?.string("pair_code")
    check(isHex32(pairToken), "welcome.pair_token is 32 lowercase hex")
    check((pairCode ?? "").count == 4 && Int(pairCode ?? "x") != nil, "welcome.pair_code is 4 digits")
    check(welcome?.string("phone_name") == "Alexander's iPhone", "welcome.phone_name is the Tools tab name")
    check(welcome?.int("version") == 2 && welcome?.string("server") == "GlassBridge iOS", "welcome has server and version 2")
    check(fb.count > 2 && fb[2].bool("enabled") == true, "sync {enabled:true} by default")
    check(onMain { GlassLink.shared.connected }, "connected after pairing")
    check(onMain { GlassLink.shared.pairing.storedToken } == pairToken, "the token is stored")
    check(UserDefaults.standard.string(forKey: "pairToken") == pairToken, "the token is persisted in UserDefaults")
    check(onMain { GlassLink.shared.justPairedCode } == pairCode, "the code is shown on the iPhone")
    check(onMain { GlassLink.shared.pairing.lastPairCode } == pairCode, "lastPairCode is the code")
    check(!onMain { GlassLink.shared.pairing.isWindowOpen(now: Date().timeIntervalSince1970) }, "pairing closes the window")
    check(onMain { GlassLink.shared.pairingStateText(now: Date().timeIntervalSince1970) } == "Paired", "state text is 'Paired'")

    // --- 3. Frames from the accepted session ---------------------------------------------
    put(b, object("status", ["battery": 87, "charging": true, "storage_free_mb": 9000, "storage_total_mb": 12000,
                             "wifi_ssid": "My iPhone", "wifi_rssi": -48, "mock_location": false, "screen_on": true, "uptime_s": 4000]))
    put(b, object("wifi_result", ["ssid": "Home", "ok": true]))
    put(b, Msg.ping())
    wait(0.3)
    check(onMain { GlassLink.shared.status?.battery } == 87, "status updates the Glass tab state")
    check(onMain { GlassLink.shared.lastWiFiResult }?.contains("Home") == true, "wifi_result sets the result text")
    check(types(b).last == "pong", "ping on the accepted session is answered with pong")
    let delivered: Bool = onMain { GlassLink.shared.sendCard(title: "Hi", text: "Hello", notify: true, speak: true, source: "iPhone") }
    wait(0.2)
    let fb2 = frames(b)
    check(delivered, "sendCard returns true while connected")
    let card: GBFrame? = fb2.first { $0.type == "card" }
    check(card?.string("style") == "notification" && card?.bool("chime") == true && card?.bool("wake") == true,
          "a notify card has style notification, chime and wake")
    check((card?.string("id") ?? "").hasPrefix("c-") && (card?.string("id") ?? "").count == 10, "card ids are c-<8 hex>")
    check(fb2.last?.type == "speak", "Also speak sends speak after the card")

    // --- 4. A second connection waits and can't displace the session --------------------
    let c = connect(listener, "192.168.1.50")
    put(c, Msg.ping())
    put(c, object("status", ["battery": 5]))
    put(c, object("file_chunk", ["id": "x:5", "offset": 0]), payload: Data("AB\nCD".utf8))
    put(c, hello(token: String(repeating: "0", count: 32)))
    wait(0.3)
    let fc = frames(c)
    check(fc.map { $0.type } == ["pong", "rejected"], "before acceptance only pong and rejected are sent")
    check(fc.last?.string("reason") == "bad_token", "a wrong token is rejected with bad_token")
    check(c.isCancelled, "the rejected connection is closed")
    check(!b.isCancelled && onMain { GlassLink.shared.connected }, "the accepted session keeps running")
    check(onMain { GlassLink.shared.status?.battery } == 87, "frames from a waiting connection are ignored")

    // --- 5. The paired Glass reconnects: replaces the old session ------------------------
    let d = connect(listener, "172.20.10.4")
    put(d, hello(token: pairToken))
    wait(0.3)
    let fd = frames(d)
    check(fd.map { $0.type } == ["welcome", "sync"], "the right token is accepted: welcome then sync")
    check(fd.first?.string("pair_token") == nil && fd.first?.string("pair_code") == nil, "no pair fields on a normal accept")
    check(b.isCancelled, "the old session is closed once the new hello is accepted")
    check(onMain { GlassLink.shared.connected } && onMain { GlassLink.shared.remoteAddress } == "172.20.10.4", "connected to the new session")

    // --- 6. Only one waiting connection; 10 s hello timeout ------------------------------
    let e = connect(listener, "172.20.10.5")
    let f = connect(listener, "172.20.10.6")
    wait(0.2)
    check(e.isCancelled, "a newer waiting connection replaces the older one")
    check(!f.isCancelled, "the newer waiting connection stays open")
    print("      (waiting 10.5 s for the hello timeout)")
    wait(10.5)
    check(f.isCancelled, "a connection without an accepted hello is closed after 10 s")
    check(types(f).isEmpty, "nothing was sent to it")
    check(!d.isCancelled, "the accepted session is unaffected")

    // --- 7. Uploads ----------------------------------------------------------------------
    let photo = Data((0..<10).map { UInt8($0) })
    put(d, object("file_begin", ["id": "IMG_1.jpg:10", "name": "IMG_1.jpg", "size": 10, "mime": "image/jpeg", "taken": 1_700_000_000_000]))
    put(d, object("file_chunk", ["id": "IMG_1.jpg:10", "offset": 0]), payload: photo.prefix(6))
    put(d, object("file_chunk", ["id": "IMG_1.jpg:10", "offset": 6]), payload: photo.suffix(4))
    put(d, object("file_end", ["id": "IMG_1.jpg:10"]))
    wait(0.8)
    var acks: [GBFrame] = frames(d).filter { $0.type == "file_ack" }
    check(acks.count == 1 && acks.first?.bool("ok") == true && acks.first?.string("id") == "IMG_1.jpg:10", "a complete upload is saved and acked ok:true")
    FakePhotos.lock.lock()
    let saved: [FakeSavedAsset] = FakePhotos.saved
    FakePhotos.lock.unlock()
    check(saved.count == 1 && saved.first?.bytes == 10 && saved.first?.type == .photo, "Photos got the 10-byte file as a .photo resource")
    check(saved.first?.originalFilename == "IMG_1.jpg", "originalFilename is set")
    check(saved.first?.creationDate == Date(timeIntervalSince1970: 1_700_000_000), "creationDate comes from taken")

    put(d, object("file_begin", ["id": "IMG_1.jpg:10", "name": "IMG_1.jpg", "size": 10, "mime": "image/jpeg"]))
    put(d, object("file_chunk", ["id": "IMG_1.jpg:10", "offset": 0]), payload: photo)
    put(d, object("file_end", ["id": "IMG_1.jpg:10"]))
    put(d, object("file_begin", ["id": "VID_2.mp4:10", "name": "VID_2.mp4", "size": 10, "mime": "video/mp4"]))
    put(d, object("file_chunk", ["id": "VID_2.mp4:10", "offset": 0]), payload: photo.prefix(4))
    put(d, object("file_chunk", ["id": "VID_2.mp4:10", "offset": 6]), payload: photo.suffix(4))
    put(d, object("file_end", ["id": "VID_2.mp4:10"]))
    put(d, object("file_begin", ["id": "IMG_3.jpg:10", "name": "IMG_3.jpg", "size": 10]))
    put(d, object("file_chunk", ["id": "IMG_3.jpg:10", "offset": 0]), payload: photo.prefix(4))
    put(d, object("file_end", ["id": "IMG_3.jpg:10"]))
    put(d, object("file_end", ["id": "nope:1"]))
    wait(0.8)
    acks = frames(d).filter { $0.type == "file_ack" }
    check(acks.count == 5, "every file_end gets exactly one file_ack (5 so far)")
    if acks.count == 5 {
        check(acks[1].bool("ok") == true, "a re-upload of a saved id is acked ok:true")
        check(acks[2].bool("ok") == false && acks[2].string("error") == "chunks out of order", "a gap gives 'chunks out of order'")
        check(acks[3].bool("ok") == false && acks[3].string("error") == "size mismatch", "a short file gives 'size mismatch'")
        check(acks[4].bool("ok") == false && acks[4].string("error") == "unknown transfer", "file_end without file_begin gives 'unknown transfer'")
    }
    FakePhotos.lock.lock()
    let savedCount: Int = FakePhotos.saved.count
    FakePhotos.lock.unlock()
    check(savedCount == 1, "the re-upload and the failures were not saved to Photos")
    check(onMain { GlassLink.shared.recentMedia.count } == 3, "recent items: the save and the two failures")
    let leftovers: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
        .filter { $0.hasPrefix("glassbridge-upload-") }
    check(leftovers.isEmpty, "no temporary upload files are left behind")

    // A partial upload when the link drops: the file is deleted.
    put(d, object("file_begin", ["id": "IMG_4.jpg:10", "name": "IMG_4.jpg", "size": 10]))
    put(d, object("file_chunk", ["id": "IMG_4.jpg:10", "offset": 0]), payload: photo.prefix(4))
    wait(0.3)
    d.closeFromPeer()
    wait(0.3)
    check(!onMain { GlassLink.shared.connected }, "the peer closing ends the session")
    let leftovers2: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
        .filter { $0.hasPrefix("glassbridge-upload-") }
    check(leftovers2.isEmpty, "a partial upload's file is deleted when the link drops")

    // --- 8. Queued cards and screencast on reconnect -------------------------------------
    let queuedDelivered: Bool = onMain { GlassLink.shared.sendCard(title: "Later", text: "Queued", notify: false, speak: false, source: nil) }
    check(!queuedDelivered && onMain { GlassLink.shared.queuedCardCount } == 1, "a card sent while away is queued")
    onMain { GlassLink.shared.screencastOn = true }
    let g = connect(listener, "172.20.10.7")
    put(g, hello(token: pairToken))
    wait(0.3)
    let fg = frames(g)
    check(fg.map { $0.type } == ["welcome", "sync", "screencast", "card"], "accept order: welcome, sync, screencast, queued cards")
    check(fg.count > 2 && fg[2].bool("on") == true && fg[2].int("fps") == 2, "screencast {on:true, fps:2}")
    check(fg.count > 3 && fg[3].string("title") == "Later" && fg[3].string("style") == nil, "the queued info card is delivered")
    check(onMain { GlassLink.shared.queuedCardCount } == 0, "the queue is empty afterwards")
    onMain { GlassLink.shared.screencastOn = false }
    wait(0.2)
    check(frames(g).last?.type == "screencast" && frames(g).last?.bool("on") == false, "turning the mirror off sends screencast {on:false}")
    onMain { GlassLink.shared.syncEnabled = false }
    wait(0.2)
    check(frames(g).last?.type == "sync" && frames(g).last?.bool("enabled") == false, "turning Save photos off sends sync {enabled:false}")
    onMain { GlassLink.shared.syncEnabled = true }

    // --- 9. Protocol error drops the session ---------------------------------------------
    g.inject(Data("this is not json\n".utf8))
    wait(0.3)
    check(g.isCancelled && !onMain { GlassLink.shared.connected }, "a malformed line drops the connection")

    // --- 10. Heartbeat -------------------------------------------------------------------
    let h = connect(listener, "172.20.10.8")
    put(h, hello(token: pairToken))
    wait(0.3)
    check(onMain { GlassLink.shared.connected }, "reconnected for the heartbeat test")
    print("      (waiting 36 s of silence for ping at 15 s and the drop at 30 s)")
    wait(21)
    check(types(h).contains("ping"), "ping is sent after 15 s of silence")
    check(!h.isCancelled, "still connected at about 21 s")
    wait(15)
    check(h.isCancelled && !onMain { GlassLink.shared.connected }, "the session is dropped after 30 s of silence")

    // --- 11. Forget Glass ----------------------------------------------------------------
    let i = connect(listener, "172.20.10.9")
    put(i, hello(token: pairToken))
    wait(0.3)
    check(onMain { GlassLink.shared.connected }, "reconnected before Forget Glass")
    onMain { GlassLink.shared.forgetGlass() }
    wait(0.3)
    check(i.isCancelled && !onMain { GlassLink.shared.connected }, "Forget Glass drops the session")
    check(!onMain { GlassLink.shared.pairing.isPaired } && UserDefaults.standard.string(forKey: "pairToken") == nil, "Forget Glass deletes the token")
    check(!onMain { GlassLink.shared.pairing.isWindowOpen(now: Date().timeIntervalSince1970) }, "Forget Glass doesn't open the window")
    let j = connect(listener, "172.20.10.10")
    put(j, hello(token: pairToken))
    wait(0.3)
    check(frames(j).first?.type == "rejected" && frames(j).first?.string("reason") == "pairing_required", "the forgotten Glass is rejected (pairing_required)")

    // --- 12. Auto-open while unpaired; pairing that can't finish is undone -----------------
    onMain { GlassLink.shared.openPairingWindowIfUnpaired() }
    check(onMain { GlassLink.shared.pairing.isWindowOpen(now: Date().timeIntervalSince1970) }, "launch/foreground opens the window while unpaired")
    let k = connect(listener, "172.20.10.11")
    // Keep the main thread busy so the connection closes before GlassLink answers the hello.
    DispatchQueue.main.async { Thread.sleep(forTimeInterval: 0.4) }
    wait(0.05)
    put(k, hello(token: nil))
    k.closeFromPeer()
    wait(0.8)
    check(!onMain { GlassLink.shared.pairing.isPaired }, "a pairing whose connection closed first is undone")
    check(onMain { GlassLink.shared.pairing.isWindowOpen(now: Date().timeIntervalSince1970) }, "and the window is open again")
    check(UserDefaults.standard.string(forKey: "pairToken") == nil, "and no token is stored")

    // --- 13. Listener recovery -------------------------------------------------------------
    listener.simulateFailure()
    wait(0.2)
    check(!onMain { GlassLink.shared.listenerReady }, "a failed listener is reported")
    print("      (waiting 3.5 s for the listener restart)")
    wait(3.5)
    check(onMain { GlassLink.shared.listenerReady } && NWListener.latest !== listener, "the listener restarts after 3 s")
    let countBefore: Int = NWListener.instances.count
    onMain { GlassLink.shared.start() } // ensureRunning on a healthy listener
    wait(0.3)
    check(NWListener.instances.count == countBefore, "ensureRunning doesn't start a second listener")
}

let testThread = Thread {
    runScenarios()
    print("")
    print("ios/LinuxCheck simulation: \(checks) checks, \(failures) failed")
    exit(failures == 0 ? 0 : 1)
}
testThread.start()
dispatchMain()
