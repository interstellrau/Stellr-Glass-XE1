// GlassLink.swift - app-wide link state and actions (main thread).
//
// Owns GlassServer and MediaReceiver, applies the pairing rules (PROTOCOL.md section 6,
// Core's PairingState), and turns Glass frames into published state for the tabs.
// An ObservableObject singleton used from the main thread. Deliberately not @MainActor
// (Swift 5, minimal concurrency checking): every callback into it is hopped to main.
//
// Persisted in UserDefaults: pairToken (the paired Glass's token), phoneName,
// syncEnabled (default true), shareLocation (default true), stayAlive (default false),
// and the Find my Glass time and coordinate.

import Foundation
import Combine
import CoreLocation
import UIKit

/// What Glass said about itself in hello.
struct GlassDeviceInfo {
    let device: String?
    let model: String?
    let firmware: String?
    let appVersion: String?
}

/// One line of the event log.
struct LogEntry: Identifiable {
    let id: Int
    let time: Date
    let text: String
}

final class GlassLink: ObservableObject {
    static let shared = GlassLink()

    static let keyPairToken: String = "pairToken"
    static let keyPhoneName: String = "phoneName"
    static let keySyncEnabled: String = "syncEnabled"
    static let keyShareLocation: String = "shareLocation"
    static let keyStayAlive: String = "stayAlive"
    static let keyLastSeenTime: String = "lastSeenTime"
    static let keyLastSeenLat: String = "lastSeenLat"
    static let keyLastSeenLon: String = "lastSeenLon"

    /// Cards sent while Glass is away are delivered if it reconnects within 10 minutes.
    static let queuedCardLifetime: TimeInterval = 600
    static let maxQueuedCards: Int = 50
    static let maxLogLines: Int = 100
    static let maxRecentMedia: Int = 30
    static let screencastFPS: Int = 2
    static let rejectLogInterval: TimeInterval = 60

    // MARK: Connection

    @Published private(set) var connected: Bool = false
    @Published private(set) var remoteAddress: String?
    @Published private(set) var listenerState: String = "Not started"
    @Published private(set) var listenerReady: Bool = false
    @Published private(set) var device: GlassDeviceInfo?
    @Published private(set) var status: GlassStatus?
    @Published private(set) var statusTime: Date?
    @Published private(set) var connectedSince: Date?

    // MARK: Pairing

    @Published private(set) var pairing: PairingState
    /// Set when a Glass has just paired; the UI shows the code until this is cleared.
    @Published var justPairedCode: String?
    /// The latest rejected hello, explained for the user (cleared when a Glass is accepted).
    @Published private(set) var lastRejection: String?
    @Published private(set) var lastRejectionTime: Date?

    // MARK: Find my Glass

    @Published private(set) var lastSeen: Date?
    @Published private(set) var lastSeenCoordinate: CLLocationCoordinate2D?

    // MARK: Media and screencast

    @Published private(set) var recentMedia: [MediaItem] = []
    @Published private(set) var transfer: TransferProgress?
    @Published private(set) var screencastFrame: UIImage?
    @Published private(set) var screencastFrameTime: Date?
    @Published var screencastOn: Bool = false {
        didSet {
            if screencastOn != oldValue {
                screencastChanged()
            }
        }
    }

    // MARK: Log and results

    @Published private(set) var eventLog: [LogEntry] = []
    @Published private(set) var lastWiFiResult: String?
    @Published private(set) var queuedCardCount: Int = 0

    // MARK: Settings (UserDefaults)

    @Published var syncEnabled: Bool {
        didSet {
            if syncEnabled == oldValue { return }
            UserDefaults.standard.set(syncEnabled, forKey: GlassLink.keySyncEnabled)
            send(Msg.sync(enabled: syncEnabled))
            log(syncEnabled ? "Save photos: on" : "Save photos: off")
        }
    }
    @Published var shareLocation: Bool {
        didSet {
            if shareLocation == oldValue { return }
            UserDefaults.standard.set(shareLocation, forKey: GlassLink.keyShareLocation)
            LocationService.shared.refreshMode()
        }
    }
    @Published var stayAlive: Bool {
        didSet {
            if stayAlive == oldValue { return }
            UserDefaults.standard.set(stayAlive, forKey: GlassLink.keyStayAlive)
            LocationService.shared.refreshMode()
        }
    }
    /// "Name shown on Glass" (Tools tab), sent as welcome.phone_name.
    @Published var phoneName: String {
        didSet {
            if phoneName != oldValue {
                UserDefaults.standard.set(phoneName, forKey: GlassLink.keyPhoneName)
            }
        }
    }

    let server = GlassServer()
    let media = MediaReceiver()

    private struct QueuedCard {
        let message: GBObject
        let expires: Date
    }

    private var activeSessionID: Int?
    private var queuedCards: [QueuedCard] = []
    private var started: Bool = false
    private var logCounter: Int = 0
    private var lastRejectLog: TimeInterval = 0
    private var rejectsSinceLog: Int = 0
    private var lastSeenSaved: TimeInterval = 0
    private var lastLoggedListenerState: String = ""

    private init() {
        // Read settings through a local, not self (every stored property must be set first).
        let defaults = UserDefaults.standard
        pairing = PairingState(storedToken: defaults.string(forKey: GlassLink.keyPairToken))
        syncEnabled = (defaults.object(forKey: GlassLink.keySyncEnabled) as? Bool) ?? true
        shareLocation = (defaults.object(forKey: GlassLink.keyShareLocation) as? Bool) ?? true
        stayAlive = (defaults.object(forKey: GlassLink.keyStayAlive) as? Bool) ?? false
        phoneName = defaults.string(forKey: GlassLink.keyPhoneName) ?? GlassLink.deviceName()

        let seen: Double = defaults.double(forKey: GlassLink.keyLastSeenTime)
        if seen > 0 {
            lastSeen = Date(timeIntervalSince1970: seen)
            if defaults.object(forKey: GlassLink.keyLastSeenLat) != nil {
                let lat: Double = defaults.double(forKey: GlassLink.keyLastSeenLat)
                let lon: Double = defaults.double(forKey: GlassLink.keyLastSeenLon)
                lastSeenCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
    }

    /// UIDevice is main-actor isolated; GlassLink is only used on the main thread.
    static func deviceName() -> String {
        return MainActor.assumeIsolated { () -> String in
            return UIDevice.current.name
        }
    }

    // MARK: - Lifecycle

    /// Starts the server the first time; afterwards restarts the listener if iOS tore it
    /// down. Called from the App's init (so background launches from Shortcuts bring the
    /// server up), from the Shortcuts intent, and whenever the scene becomes active.
    func start() {
        if started {
            server.ensureRunning()
            return
        }
        started = true
        wireCallbacks()
        media.cleanLeftovers()
        server.start()
        LocationService.shared.start()
        log("GlassBridge started")
    }

    /// The scene became active: make sure the server runs, open pairing if nothing is
    /// paired (section 6), and ask for location permission the first time.
    func appDidBecomeActive() {
        start()
        openPairingWindowIfUnpaired()
        LocationService.shared.requestPermissionIfNeeded()
        LocationService.shared.refreshMode()
        if syncEnabled {
            // Ask for Photos (add only) while the app is in front, not when the first photo
            // arrives with the app in the background.
            media.requestPhotosAccessIfNeeded()
        }
    }

    private func wireCallbacks() {
        server.onListenerState = { [weak self] text, ready in
            guard let self = self else { return }
            self.listenerState = text
            self.listenerReady = ready
            // A listener that keeps failing alternates Starting/Failed every 3 s: log each
            // distinct state once.
            if text != "Starting" && text != self.lastLoggedListenerState {
                self.lastLoggedListenerState = text
                self.log("Server: " + text)
            }
        }
        server.onHello = { [weak self] sessionID, remote, frame in
            self?.handleHello(sessionID: sessionID, remote: remote, frame: frame)
        }
        server.onFrame = { [weak self] sessionID, frame in
            self?.handleFrame(sessionID: sessionID, frame: frame)
        }
        server.onDisconnected = { [weak self] sessionID, reason in
            self?.handleDisconnect(sessionID: sessionID, reason: reason)
        }
        server.onLog = { [weak self] text in
            self?.log(text)
        }
        media.onAck = { [weak self] message in
            self?.send(message)
        }
        media.onProgress = { [weak self] progress in
            self?.transfer = progress
        }
        media.onItem = { [weak self] item in
            self?.addRecentMedia(item)
        }
        media.onLog = { [weak self] text in
            self?.log(text)
        }
    }

    // MARK: - Pairing (section 6)

    /// The name Glass shows: the Tools tab setting, or the device name if that is empty.
    var effectivePhoneName: String {
        let trimmed: String = phoneName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return GlassLink.deviceName()
        }
        return trimmed
    }

    /// Pair Glass button: open (or restart) the 2-minute window.
    func openPairingWindow() {
        pairing.openWindow(now: Date().timeIntervalSince1970)
        log("Pairing open for 2 minutes")
    }

    /// On launch and on every return to the foreground: open the window only while no
    /// Glass is paired.
    func openPairingWindowIfUnpaired() {
        let now: TimeInterval = Date().timeIntervalSince1970
        let wasOpen: Bool = pairing.isWindowOpen(now: now)
        let opened: Bool = pairing.openWindowIfUnpaired(now: now)
        if opened && !wasOpen {
            log("No Glass paired yet: pairing open for 2 minutes")
        }
    }

    func closePairingWindow() {
        pairing.closeWindow()
        log("Pairing closed")
    }

    /// Forget Glass: delete the stored token (doesn't open the window) and drop the current
    /// session, so the next hello from that Glass is rejected until it pairs again.
    func forgetGlass() {
        pairing.forget()
        UserDefaults.standard.removeObject(forKey: GlassLink.keyPairToken)
        justPairedCode = nil
        log("Forgot the paired Glass")
        if connected {
            server.disconnectActive(reason: "Glass was forgotten on this iPhone")
        }
    }

    /// "Paired", "Not paired" or "Pairing open 1:43".
    func pairingStateText(now: TimeInterval) -> String {
        if pairing.isWindowOpen(now: now) {
            let remaining: Int = Int(pairing.windowRemaining(now: now).rounded(.up))
            return "Pairing open " + GlassLink.minutesSeconds(remaining)
        }
        return pairing.isPaired ? "Paired" : "Not paired"
    }

    static func minutesSeconds(_ seconds: Int) -> String {
        let s: Int = max(0, seconds)
        let minutes: Int = s / 60
        let rest: Int = s % 60
        let pad: String = rest < 10 ? "0" : ""
        return String(minutes) + ":" + pad + String(rest)
    }

    private func handleHello(sessionID: Int, remote: String, frame: GBFrame) {
        let hello: GlassHello? = GlassHello(frame)
        let now: TimeInterval = Date().timeIntervalSince1970
        let outcome: PairingOutcome = pairing.handleHello(token: hello?.token, now: now)
        if outcome.tokenChanged {
            UserDefaults.standard.set(pairing.storedToken, forKey: GlassLink.keyPairToken)
        }
        let reply: GBObject = outcome.reply(phoneName: effectivePhoneName)

        guard outcome.accepted else {
            server.reject(sessionID: sessionID, reply: reply)
            noteRejection(remote: remote, decision: outcome.decision)
            return
        }

        let followUps: [GBObject] = acceptedFollowUps()
        let ok: Bool = server.accept(sessionID: sessionID, reply: reply, followUps: followUps)
        guard ok else {
            if outcome.decision == .pair {
                // Glass never got its token: undo, so the next hello can pair again.
                pairing.forget()
                pairing.openWindow(now: now)
                UserDefaults.standard.removeObject(forKey: GlassLink.keyPairToken)
                log("Pairing with \(remote) didn't finish (the connection closed first). Pairing is open again.")
            } else {
                log("Glass at \(remote) went away before it could be accepted")
            }
            return
        }

        if activeSessionID != nil {
            // The new session replaced an old one: its partial upload is gone.
            media.linkDropped()
        }
        activeSessionID = sessionID
        queuedCards.removeAll()
        queuedCardCount = 0
        connected = true
        connectedSince = Date()
        remoteAddress = remote
        status = nil
        statusTime = nil
        lastRejection = nil
        lastRejectionTime = nil
        rejectsSinceLog = 0
        lastRejectLog = 0
        if let h = hello {
            device = GlassDeviceInfo(device: h.device, model: h.model, firmware: h.firmware, appVersion: h.appVersion)
        } else {
            device = nil
        }
        markSeen()

        if outcome.decision == .pair {
            let code: String = outcome.pairCode ?? "----"
            justPairedCode = code
            log("Paired with the Glass at \(remote). Code \(code): check that Glass shows the same code.")
        } else {
            let model: String = hello?.model ?? "Glass"
            let firmware: String = hello?.firmware ?? "?"
            log("Glass connected from \(remote) (\(model), \(firmware))")
        }
        // After sync, screencast, queued cards and nav (sent by accept), the phone's latest fix.
        LocationService.shared.sendLatestFixToGlass()
    }

    /// Section 4 step 3: sync, then screencast if on, then queued cards, then the current
    /// nav card (never announced).
    private func acceptedFollowUps() -> [GBObject] {
        var out: [GBObject] = [Msg.sync(enabled: syncEnabled)]
        if screencastOn {
            out.append(Msg.screencast(on: true, fps: GlassLink.screencastFPS))
        }
        pruneQueue()
        for card in queuedCards {
            out.append(card.message)
        }
        if let nav = NavigationService.shared.currentCardMessage() {
            out.append(nav)
        }
        return out
    }

    private func noteRejection(remote: String, decision: PairingDecision) {
        guard case .reject(let reason) = decision else { return }
        let text: String
        switch reason {
        case .pairingRequired:
            text = "A Glass at \(remote) tried to connect but isn't paired. Tap Pair Glass."
        case .badToken:
            text = "A Glass at \(remote) has a token from another pairing. Tap Pair Glass to pair it again."
        }
        lastRejection = text
        lastRejectionTime = Date()
        rejectsSinceLog += 1
        let now: TimeInterval = ProcessInfo.processInfo.systemUptime
        if lastRejectLog == 0 || now - lastRejectLog >= GlassLink.rejectLogInterval {
            var line: String = "Rejected (" + reason.rawValue + "): " + text
            if rejectsSinceLog > 1 {
                line += " (" + String(rejectsSinceLog) + " attempts)"
            }
            log(line)
            lastRejectLog = now
            rejectsSinceLog = 0
        }
    }

    // MARK: - Frames from the accepted session

    private func handleFrame(sessionID: Int, frame: GBFrame) {
        guard sessionID == activeSessionID else { return }
        switch frame.type {
        case "status":
            if let s = GlassStatus(frame) {
                let first: Bool = status == nil
                status = s
                statusTime = Date()
                markSeen()
                if first {
                    let battery: String = s.battery.map { String($0) + "%" } ?? "?"
                    log("Status from Glass: battery " + battery)
                }
            }
        case "ack":
            if let ack = GlassAck(frame) {
                log("Glass: card \(ack.id) \(ack.event)")
            }
        case "file_begin":
            if let begin = GlassFileBegin(frame) {
                media.begin(begin)
            }
        case "file_chunk":
            if let chunk = GlassFileChunk(frame) {
                media.chunk(chunk)
            }
        case "file_end":
            if let end = GlassFileEnd(frame) {
                media.end(end)
            }
        case "frame":
            if let f = GlassScreenFrame(frame), let image = UIImage(data: f.jpeg) {
                screencastFrame = image
                screencastFrameTime = Date()
            }
        case "wifi_result":
            if let r = GlassWiFiResult(frame) {
                let text: String
                if r.ok {
                    text = "Glass saved the network “\(r.ssid)”."
                } else {
                    let reason: String = r.error ?? "unknown error"
                    text = "Glass couldn't save “\(r.ssid)”: \(reason)"
                }
                lastWiFiResult = text
                log(text)
            }
        default:
            break // unknown types are ignored
        }
    }

    private func handleDisconnect(sessionID: Int, reason: String) {
        guard sessionID == activeSessionID else { return }
        activeSessionID = nil
        connected = false
        connectedSince = nil
        remoteAddress = nil
        transfer = nil
        media.linkDropped()
        markSeen()
        log("Glass disconnected (\(reason))")
    }

    // MARK: - Sending

    /// Sends a frame to the connected Glass. False when not connected.
    @discardableResult
    func send(_ object: GBObject, payload: Data? = nil) -> Bool {
        guard connected else { return false }
        return server.send(object, payload: payload)
    }

    /// Sends a card, or queues it for 10 minutes if Glass isn't connected. Returns true if
    /// it was delivered now. Notification cards chime and wake the display.
    @discardableResult
    func sendCard(title: String, text: String, notify: Bool, speak: Bool, source: String?) -> Bool {
        let id: String = Msg.newCardID()
        let now: Int64 = GBProtocol.nowMs()
        let message: GBObject
        if notify {
            message = Msg.card(id: id, title: title, text: text, source: source, timeMs: now,
                               style: .notification, chime: true, wake: true)
        } else {
            message = Msg.card(id: id, title: title, text: text, source: source, timeMs: now)
        }
        let delivered: Bool = send(message)
        if delivered {
            if speak {
                send(Msg.speak(text: GlassLink.spokenText(title: title, text: text)))
            }
            log("Sent card “\(title)”")
        } else {
            enqueue(message)
            log("Glass isn't connected: card “\(title)” queued for 10 minutes")
        }
        return delivered
    }

    static func spokenText(title: String, text: String) -> String {
        let t: String = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return text }
        return t + ". " + text
    }

    func requestStatus() {
        if send(Msg.requestStatus()) {
            log("Asked Glass for its status")
        }
    }

    /// wifi_add to the connected Glass. False when not connected.
    @discardableResult
    func sendWiFi(ssid: String, password: String, security: WiFiSecurity) -> Bool {
        lastWiFiResult = nil
        let ok: Bool = send(Msg.wifiAdd(ssid: ssid, password: password, security: security))
        if ok {
            log("Sent Wi-Fi network “\(ssid)” to Glass")
        }
        return ok
    }

    /// Location to Glass (LocationService throttles it). False if not sent.
    @discardableResult
    func sendLocation(_ location: CLLocation) -> Bool {
        guard connected, shareLocation else { return false }
        let altitude: Double? = location.verticalAccuracy >= 0 ? location.altitude : nil
        let speed: Double? = location.speed >= 0 ? location.speed : nil
        let bearing: Double? = location.course >= 0 ? location.course : nil
        let ms: Double = location.timestamp.timeIntervalSince1970 * 1000.0
        let message: GBObject = Msg.location(lat: location.coordinate.latitude,
                                             lon: location.coordinate.longitude,
                                             accM: location.horizontalAccuracy,
                                             altM: altitude, speedMps: speed, bearing: bearing,
                                             timeMs: Int64(ms.rounded()))
        return send(message)
    }

    /// Every phone fix: while linked, it is where Glass was last seen.
    func phoneFix(_ location: CLLocation) {
        if connected {
            markSeen()
        }
    }

    private func screencastChanged() {
        let fps: Int? = screencastOn ? GlassLink.screencastFPS : nil
        send(Msg.screencast(on: screencastOn, fps: fps))
        if !screencastOn {
            screencastFrame = nil
            screencastFrameTime = nil
        }
        log(screencastOn ? "Mirror Glass screen: on" : "Mirror Glass screen: off")
    }

    private func enqueue(_ message: GBObject) {
        pruneQueue()
        let entry = QueuedCard(message: message, expires: Date().addingTimeInterval(GlassLink.queuedCardLifetime))
        queuedCards.append(entry)
        if queuedCards.count > GlassLink.maxQueuedCards {
            queuedCards.removeFirst(queuedCards.count - GlassLink.maxQueuedCards)
        }
        queuedCardCount = queuedCards.count
    }

    private func pruneQueue() {
        let now = Date()
        queuedCards.removeAll { (card: QueuedCard) -> Bool in
            return card.expires <= now
        }
        if queuedCardCount != queuedCards.count {
            queuedCardCount = queuedCards.count
        }
    }

    // MARK: - Find my Glass

    /// Stores the time and the phone's latest coordinate as where Glass was last seen.
    private func markSeen() {
        let now = Date()
        lastSeen = now
        if let c = LocationService.shared.location?.coordinate {
            lastSeenCoordinate = c
        }
        // Persist at most every 10 s (phone fixes can arrive every second while navigating).
        let t: TimeInterval = now.timeIntervalSince1970
        if t - lastSeenSaved < 10 { return }
        lastSeenSaved = t
        let defaults = UserDefaults.standard
        defaults.set(t, forKey: GlassLink.keyLastSeenTime)
        if let c = lastSeenCoordinate {
            defaults.set(c.latitude, forKey: GlassLink.keyLastSeenLat)
            defaults.set(c.longitude, forKey: GlassLink.keyLastSeenLon)
        }
    }

    // MARK: - Media and log

    private func addRecentMedia(_ item: MediaItem) {
        recentMedia.insert(item, at: 0)
        if recentMedia.count > GlassLink.maxRecentMedia {
            recentMedia.removeLast(recentMedia.count - GlassLink.maxRecentMedia)
        }
    }

    /// Appends to the 100-line event log (Tools tab).
    func log(_ text: String) {
        logCounter += 1
        eventLog.append(LogEntry(id: logCounter, time: Date(), text: text))
        if eventLog.count > GlassLink.maxLogLines {
            eventLog.removeFirst(eventLog.count - GlassLink.maxLogLines)
        }
        #if DEBUG
        print("[GlassBridge] " + text)
        #endif
    }

    /// The whole log as text, oldest first (for Copy).
    var eventLogText: String {
        var lines: [String] = []
        for entry in eventLog {
            lines.append(GBFormat.clock(entry.time) + "  " + entry.text)
        }
        return lines.joined(separator: "\n")
    }
}
