// GlassServer.swift - the TCP server Glass dials into (PROTOCOL.md sections 1, 3, 4 and 6).
//
// * NWListener on port 9090, advertised over Bonjour as _glassbridge._tcp (name: the device
//   name). TCP noDelay, keepalive (idle 10 s), local endpoint reuse, no peer-to-peer.
// * Everything runs on one private serial queue. Callbacks are hopped to the main thread.
// * Two slots: `active` (the accepted session) and `pending` (at most one connection
//   waiting for its hello to be accepted). A newer connection replaces an older pending one;
//   the active session keeps running until a pending hello is accepted (section 6).
// * Before acceptance only `pong` (answering `ping`), `welcome` or `rejected` is sent, and
//   every frame except `hello` and `ping` is ignored (payloads are still consumed by the
//   parser). A pending connection without an accepted hello is closed after 10 s.
// * Heartbeat: every 5 s; `ping` after 15 s of silence, drop the session at 30 s.
// * Recovery: a failed listener is cancelled and restarted after 3 s if it is still the
//   current one; if NWListener init throws, retry after 5 s only if there is still no
//   listener. ensureRunning() restarts a listener iOS tore down while the app was suspended.
// * A failed or closed connection is always cancelled before it is released.

import Foundation
import Network

/// One TCP connection from a Glass. Used only on GlassServer's queue.
final class GlassServerSession {
    let id: Int
    let connection: NWConnection
    let remote: String
    let parser: FrameParser = FrameParser()
    var lastReceived: TimeInterval
    var lastPing: TimeInterval = 0
    /// A hello has been handed to the main thread and its decision is pending.
    var helloInFlight: Bool = false
    /// Being closed (rejected, replaced or dropped): handlers ignore it.
    var closing: Bool = false
    var helloTimer: DispatchWorkItem?

    init(id: Int, connection: NWConnection, remote: String, now: TimeInterval) {
        self.id = id
        self.connection = connection
        self.remote = remote
        self.lastReceived = now
    }
}

final class GlassServer {
    // Callbacks, always called on the main thread. Set them before start().

    /// Listener state text for the UI, and whether it is listening.
    var onListenerState: ((String, Bool) -> Void)?
    /// A pending connection sent `hello`: (session id, remote address, frame).
    /// Answer with accept(sessionID:reply:followUps:) or reject(sessionID:reply:).
    var onHello: ((Int, String, GBFrame) -> Void)?
    /// A frame from the accepted session: (session id, frame). `ping`/`pong` are handled here.
    var onFrame: ((Int, GBFrame) -> Void)?
    /// The accepted session ended: (session id, reason).
    var onDisconnected: ((Int, String) -> Void)?
    /// Something worth putting in the event log.
    var onLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "au.interstellr.glassbridge.server")
    private var listener: NWListener?
    private var active: GlassServerSession?
    private var pending: GlassServerSession?
    private var heartbeat: DispatchSourceTimer?
    private var nextSessionID: Int = 1
    private var started: Bool = false

    static let heartbeatInterval: Int = 5
    static let listenerRestartDelay: Double = 3
    static let listenerInitRetryDelay: Double = 5
    static let rejectCloseTimeout: Double = 5

    // MARK: - API (call from the main thread)

    /// Starts the listener and heartbeat. Safe to call more than once.
    func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.started = true
            self.startHeartbeat()
            self.startListener()
        }
    }

    /// Restarts the listener if iOS tore it down (call on launch and when the app becomes
    /// active).
    func ensureRunning() {
        queue.async { [weak self] in
            guard let self = self, self.started else { return }
            self.startHeartbeat()
            guard let l = self.listener else {
                self.startListener()
                return
            }
            switch l.state {
            case .failed, .cancelled:
                self.log("Restarting the listener")
                l.cancel()
                self.listener = nil
                self.startListener()
            default:
                break
            }
        }
    }

    /// Sends a frame to the accepted session. False unless it is connected and ready.
    @discardableResult
    func send(_ object: GBObject, payload: Data? = nil) -> Bool {
        return queue.sync { () -> Bool in
            guard let s = self.active, !s.closing else { return false }
            return self.sendNow(object, payload: payload, to: s)
        }
    }

    /// Accepts a pending connection: sends `reply` (welcome), replaces the old session, then
    /// sends `followUps` in order (sync, screencast, queued cards, nav). False if the
    /// connection is gone or no longer pending.
    func accept(sessionID: Int, reply: GBObject, followUps: [GBObject]) -> Bool {
        return queue.sync { () -> Bool in
            return self.acceptNow(sessionID: sessionID, reply: reply, followUps: followUps)
        }
    }

    /// Rejects a pending connection: sends `reply` (rejected), then closes the connection
    /// once the frame has been written.
    func reject(sessionID: Int, reply: GBObject) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let s = self.pending, s.id == sessionID else { return }
            self.pending = nil
            s.closing = true
            s.helloTimer?.cancel()
            s.helloTimer = nil
            let connection: NWConnection = s.connection
            let data: Data? = try? GBEncoder.encode(reply)
            guard let bytes = data, case .ready = connection.state else {
                connection.cancel()
                return
            }
            connection.send(content: bytes, completion: .contentProcessed { _ in
                connection.cancel()
            })
            // In case the send never completes.
            self.queue.asyncAfter(deadline: .now() + GlassServer.rejectCloseTimeout) {
                connection.cancel()
            }
        }
    }

    /// Closes the accepted session (onDisconnected follows).
    func disconnectActive(reason: String) {
        queue.async { [weak self] in
            guard let self = self, let s = self.active else { return }
            self.drop(s, reason: reason)
        }
    }

    // MARK: - Listener (queue only)

    private func startListener() {
        if listener != nil { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        guard let port = NWEndpoint.Port(rawValue: GBProtocol.port) else { return }

        let l: NWListener
        do {
            l = try NWListener(using: parameters, on: port)
        } catch {
            reportListener("Couldn't open port \(GBProtocol.port): \(error). Retrying in 5 s.", ready: false)
            queue.asyncAfter(deadline: .now() + GlassServer.listenerInitRetryDelay) { [weak self] in
                guard let self = self else { return }
                // ensureRunning may have started one meanwhile: never run two.
                if self.listener == nil {
                    self.startListener()
                }
            }
            return
        }
        l.service = NWListener.Service(name: nil, type: GBProtocol.bonjourType)
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self = self, let l = l else { return }
            self.listenerStateChanged(state, listener: l)
        }
        l.newConnectionHandler = { [weak self, weak l] connection in
            guard let self = self, let l = l, l === self.listener else {
                connection.cancel()
                return
            }
            self.adopt(connection)
        }
        listener = l
        reportListener("Starting", ready: false)
        l.start(queue: queue)
    }

    private func listenerStateChanged(_ state: NWListener.State, listener l: NWListener) {
        guard l === listener else { return }
        switch state {
        case .setup:
            reportListener("Starting", ready: false)
        case .waiting(let error):
            reportListener("Waiting (\(error)). Check Settings › Privacy & Security › Local Network › StellrGlass.", ready: false)
        case .ready:
            var portText: String = String(GBProtocol.port)
            if let p = l.port {
                portText = String(p.rawValue)
            }
            reportListener("Listening on port " + portText, ready: true)
        case .failed(let error):
            reportListener("Failed (\(error)). Restarting in 3 s.", ready: false)
            l.cancel()
            queue.asyncAfter(deadline: .now() + GlassServer.listenerRestartDelay) { [weak self, weak l] in
                guard let self = self, let l = l, self.listener === l else { return }
                self.listener = nil
                self.startListener()
            }
        case .cancelled:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Connections (queue only)

    private func adopt(_ connection: NWConnection) {
        let now: TimeInterval = GlassServer.uptime()
        let id: Int = nextSessionID
        nextSessionID += 1
        let remote: String = GlassServer.describe(connection.endpoint)
        let s = GlassServerSession(id: id, connection: connection, remote: remote, now: now)

        if let old = pending {
            log("A newer connection from \(remote) replaced the one waiting from \(old.remote)")
            old.closing = true
            old.helloTimer?.cancel()
            old.helloTimer = nil
            old.connection.cancel()
        }
        pending = s

        connection.stateUpdateHandler = { [weak self, weak s] state in
            guard let self = self, let s = s else { return }
            self.connectionStateChanged(state, session: s)
        }
        let timer = DispatchWorkItem { [weak self, weak s] in
            guard let self = self, let s = s, self.pending === s else { return }
            self.log("Closed the connection from \(s.remote): no accepted hello within 10 s")
            self.pending = nil
            s.closing = true
            s.connection.cancel()
        }
        s.helloTimer = timer
        queue.asyncAfter(deadline: .now() + GBProtocol.helloTimeout, execute: timer)
        connection.start(queue: queue)
        receive(on: s)
    }

    private func connectionStateChanged(_ state: NWConnection.State, session s: GlassServerSession) {
        switch state {
        case .waiting(let error):
            // An inbound connection that can't proceed won't recover: drop it.
            drop(s, reason: "connection waiting (\(error))")
        case .failed(let error):
            drop(s, reason: "connection failed (\(error))")
        case .cancelled:
            drop(s, reason: "connection closed")
        default:
            break
        }
    }

    /// Removes a session from its slot and cancels its connection. Reports a disconnect if
    /// it was the accepted session.
    private func drop(_ s: GlassServerSession, reason: String) {
        s.helloTimer?.cancel()
        s.helloTimer = nil
        s.closing = true
        // Cancel before releasing, or the connection leaks.
        s.connection.cancel()
        if s === pending {
            pending = nil
        }
        if s === active {
            active = nil
            let id: Int = s.id
            DispatchQueue.main.async { [weak self] in
                self?.onDisconnected?(id, reason)
            }
        }
    }

    private func receive(on s: GlassServerSession) {
        s.connection.receive(minimumIncompleteLength: 1, maximumLength: GBProtocol.chunkSize) { [weak self, weak s] content, _, isComplete, error in
            guard let self = self, let s = s else { return }
            self.received(content, isComplete: isComplete, error: error, on: s)
        }
    }

    private func received(_ content: Data?, isComplete: Bool, error: NWError?, on s: GlassServerSession) {
        // A rejected connection is closed by its send completion: just stop reading.
        if s.closing { return }
        guard s === active || s === pending else {
            s.closing = true
            s.connection.cancel()
            return
        }
        if let data = content, !data.isEmpty {
            s.lastReceived = GlassServer.uptime()
            s.parser.append(data)
            do {
                while let frame = try s.parser.next() {
                    handle(frame, from: s)
                    if s.closing { return }
                }
            } catch {
                log("Dropped the connection from \(s.remote): \(error)")
                drop(s, reason: "protocol error")
                return
            }
        }
        if let e = error {
            drop(s, reason: "receive failed (\(e))")
            return
        }
        if isComplete {
            drop(s, reason: "Glass closed the connection")
            return
        }
        receive(on: s)
    }

    private func handle(_ frame: GBFrame, from s: GlassServerSession) {
        let type: String = frame.type
        if type == "ping" {
            // Answered even before hello is accepted.
            sendNow(Msg.pong(), to: s)
            return
        }
        if s === pending {
            // Before acceptance only hello matters; everything else is ignored.
            if type == "hello" && !s.helloInFlight {
                s.helloInFlight = true
                let id: Int = s.id
                let remote: String = s.remote
                DispatchQueue.main.async { [weak self] in
                    self?.onHello?(id, remote, frame)
                }
            }
            return
        }
        guard s === active else { return }
        switch type {
        case "pong":
            return
        case "hello":
            log("Ignored a second hello from \(s.remote)")
            return
        default:
            let id: Int = s.id
            DispatchQueue.main.async { [weak self] in
                self?.onFrame?(id, frame)
            }
        }
    }

    private func acceptNow(sessionID: Int, reply: GBObject, followUps: [GBObject]) -> Bool {
        guard let s = pending, s.id == sessionID, !s.closing else { return false }
        guard sendNow(reply, to: s) else {
            drop(s, reason: "couldn't send welcome")
            return false
        }
        s.helloTimer?.cancel()
        s.helloTimer = nil
        pending = nil
        let old: GlassServerSession? = active
        // Promote first, so the old connection's cancel isn't reported as a disconnect.
        active = s
        if let o = old {
            log("Replaced the previous Glass connection from \(o.remote)")
            o.closing = true
            o.helloTimer?.cancel()
            o.connection.cancel()
        }
        s.lastReceived = GlassServer.uptime()
        for message in followUps {
            sendNow(message, to: s)
        }
        return true
    }

    /// Encodes and sends one frame (header and payload in one send). Queue only: never
    /// call queue.sync from here.
    @discardableResult
    private func sendNow(_ object: GBObject, payload: Data? = nil, to s: GlassServerSession) -> Bool {
        guard case .ready = s.connection.state else { return false }
        let data: Data
        do {
            data = try GBEncoder.encode(object, payload: payload)
        } catch {
            let type: String = object.type ?? "?"
            log("Couldn't encode \(type): \(error)")
            return false
        }
        s.connection.send(content: data, completion: .contentProcessed { [weak self, weak s] sendError in
            guard let e = sendError, let self = self, let s = s else { return }
            if s.closing { return }
            self.log("Sending to \(s.remote) failed: \(e)")
            self.drop(s, reason: "send failed")
        })
        return true
    }

    // MARK: - Heartbeat (queue only)

    private func startHeartbeat() {
        if heartbeat != nil { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval: Int = GlassServer.heartbeatInterval
        t.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        t.setEventHandler { [weak self] in
            self?.heartbeatTick()
        }
        heartbeat = t
        t.resume()
    }

    private func heartbeatTick() {
        guard let s = active, !s.closing else { return }
        let now: TimeInterval = GlassServer.uptime()
        let silence: TimeInterval = now - s.lastReceived
        if silence >= GBProtocol.deadAfter {
            log("Nothing from Glass for 30 s: dropping the link")
            drop(s, reason: "heartbeat timeout")
            return
        }
        if silence >= GBProtocol.pingAfter && now - s.lastPing >= GBProtocol.pingAfter {
            s.lastPing = now
            sendNow(Msg.ping(), to: s)
        }
    }

    // MARK: - Helpers

    private func log(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onLog?(text)
        }
    }

    private func reportListener(_ text: String, ready: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onListenerState?(text, ready)
        }
    }

    static func uptime() -> TimeInterval {
        return ProcessInfo.processInfo.systemUptime
    }

    /// "172.20.10.2" for a host/port endpoint, otherwise the endpoint's description.
    static func describe(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, _):
            return "\(host)"
        default:
            return "\(endpoint)"
        }
    }
}
