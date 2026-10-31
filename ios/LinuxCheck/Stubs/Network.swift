// Linux stand-in for Network.framework, used only by ios/LinuxCheck (never by the app).
// Public signatures copy the iOS SDK declarations from developer.apple.com's documentation
// JSON, so the app code type-checks against the same shapes. Behaviour is a scriptable fake:
// tests create NWConnections, hand them to the listener, inject bytes and read what the
// server sent.

import Foundation

public struct NWError: Error, CustomDebugStringConvertible {
    public let text: String
    public init(_ text: String) { self.text = text }
    public var debugDescription: String { return text }
}

public enum NWEndpoint: CustomDebugStringConvertible {
    public enum Host: CustomDebugStringConvertible {
        case name(String, Int?)
        public var debugDescription: String {
            switch self {
            case .name(let n, _): return n
            }
        }
    }

    public struct Port: RawRepresentable, Hashable, CustomDebugStringConvertible, ExpressibleByIntegerLiteral {
        public var rawValue: UInt16
        public init?(rawValue: UInt16) { self.rawValue = rawValue }
        public init?(_ text: String) {
            guard let v = UInt16(text) else { return nil }
            rawValue = v
        }
        public init(integerLiteral value: UInt16) { rawValue = value }
        public var debugDescription: String { return String(rawValue) }
    }

    case hostPort(host: NWEndpoint.Host, port: NWEndpoint.Port)
    case service(name: String, type: String, domain: String, interface: Int?)
    case unix(path: String)
    case url(URL)

    public var debugDescription: String {
        switch self {
        case .hostPort(let h, let p): return "\(h):\(p)"
        default: return "endpoint"
        }
    }
}

public final class NWProtocolTCP {
    public final class Options {
        public init() {}
        public var noDelay: Bool = false
        public var enableKeepalive: Bool = false
        public var keepaliveIdle: Int = 0
    }
}

public final class NWProtocolTLS {
    public final class Options {}
}

public final class NWParameters {
    public init() {}
    public convenience init(tls: NWProtocolTLS.Options?, tcp: NWProtocolTCP.Options = NWProtocolTCP.Options()) {
        self.init()
    }
    public final var allowLocalEndpointReuse: Bool = false
    public final var includePeerToPeer: Bool = false
}

public final class NWTXTRecord {}

public final class NWConnection {
    public enum State {
        case setup
        case waiting(NWError)
        case preparing
        case ready
        case failed(NWError)
        case cancelled
    }

    public final class ContentContext {
        public static let defaultMessage = ContentContext()
    }

    public enum SendCompletion {
        case contentProcessed((NWError?) -> Void)
        case idempotent
    }

    public let endpoint: NWEndpoint
    public final var state: NWConnection.State = .setup
    @preconcurrency public final var stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)?

    // Fake internals (touched only on `queue`, or before start).
    private var queue: DispatchQueue?
    private var sent: [Data] = []
    private var inbox = Data()
    private var pendingReceive: ((Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void)?
    private var maxReceive: Int = 65536
    private var peerClosed: Bool = false
    private var cancelledFlag: Bool = false
    private let lock = NSLock()
    private var startedFlag: Bool = false

    /// Test API: a connection "from" this address.
    public init(remote: String) {
        endpoint = .hostPort(host: .name(remote, nil), port: 51000)
    }

    public final func start(queue: DispatchQueue) {
        self.queue = queue
        lock.lock(); startedFlag = true; lock.unlock()
        queue.async {
            if self.cancelledFlag { return }
            self.state = .preparing
            self.stateUpdateHandler?(.preparing)
            self.state = .ready
            self.stateUpdateHandler?(.ready)
            self.pump()
        }
    }

    public final func cancel() {
        guard let q = queue else {
            cancelledFlag = true
            state = .cancelled
            return
        }
        q.async {
            if self.cancelledFlag { return }
            self.cancelledFlag = true
            self.state = .cancelled
            self.pendingReceive = nil
            self.stateUpdateHandler?(.cancelled)
        }
    }

    @preconcurrency
    public final func send(content: Data?, contentContext: NWConnection.ContentContext = .defaultMessage,
                           isComplete: Bool = true, completion: NWConnection.SendCompletion) {
        let wasCancelled: Bool = cancelledFlag
        if let d = content, !wasCancelled {
            sent.append(d)
        }
        if case .contentProcessed(let done) = completion {
            queue?.async {
                done(wasCancelled ? NWError("cancelled") : nil)
            }
        }
    }

    @preconcurrency
    public final func send<Content>(content: Content?, contentContext: NWConnection.ContentContext = .defaultMessage,
                                    isComplete: Bool = true, completion: NWConnection.SendCompletion) where Content: DataProtocol {
        let data: Data? = content.map { Data($0) }
        send(content: data, contentContext: contentContext, isComplete: isComplete, completion: completion)
    }

    @preconcurrency
    public final func receive(minimumIncompleteLength: Int, maximumLength: Int,
                              completion: @escaping @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void) {
        pendingReceive = completion
        maxReceive = maximumLength
        pump()
    }

    private func pump() {
        guard !cancelledFlag, let receiveHandler = pendingReceive else { return }
        if case .ready = state {} else { return }
        if !inbox.isEmpty {
            let n: Int = min(maxReceive, inbox.count)
            let chunk = Data(inbox.prefix(n))
            inbox.removeFirst(n)
            pendingReceive = nil
            receiveHandler(chunk, nil, false, nil)
        } else if peerClosed {
            pendingReceive = nil
            receiveHandler(nil, nil, true, nil)
        }
    }

    // MARK: Test API

    public var isStarted: Bool {
        lock.lock(); defer { lock.unlock() }
        return startedFlag
    }

    /// Bytes arriving from the peer (Glass).
    public func inject(_ data: Data) {
        queue?.async {
            self.inbox.append(data)
            self.pump()
        }
    }

    /// The peer closes its side.
    public func closeFromPeer() {
        queue?.async {
            self.peerClosed = true
            self.pump()
        }
    }

    /// Everything the server sent, in order.
    public func sentData() -> [Data] {
        guard let q = queue else { return sent }
        return q.sync { self.sent }
    }

    public var isCancelled: Bool {
        guard let q = queue else { return cancelledFlag }
        return q.sync { self.cancelledFlag }
    }
}

public final class NWListener {
    public enum State {
        case setup
        case waiting(NWError)
        case ready
        case failed(NWError)
        case cancelled
    }

    public struct Service {
        public let name: String?
        public let type: String
        public init(name: String? = nil, type: String, domain: String? = nil, txtRecord: Data? = nil) {
            self.name = name
            self.type = type
        }
        public init(name: String? = nil, type: String, domain: String? = nil, txtRecord: NWTXTRecord) {
            self.name = name
            self.type = type
        }
    }

    /// Test API: every listener created, newest last.
    public static var instances: [NWListener] = []
    private static let registryLock = NSLock()

    public final var state: NWListener.State = .setup
    public var port: NWEndpoint.Port?
    public var service: NWListener.Service?
    @preconcurrency public var stateUpdateHandler: (@Sendable (NWListener.State) -> Void)?
    @preconcurrency public var newConnectionHandler: (@Sendable (NWConnection) -> Void)?
    private var queue: DispatchQueue?

    public init(using parameters: NWParameters, on port: NWEndpoint.Port) throws {
        self.port = port
        NWListener.registryLock.lock()
        NWListener.instances.append(self)
        NWListener.registryLock.unlock()
    }

    public func start(queue: DispatchQueue) {
        self.queue = queue
        queue.async {
            self.state = .ready
            self.stateUpdateHandler?(.ready)
        }
    }

    public func cancel() {
        queue?.async {
            self.state = .cancelled
            self.stateUpdateHandler?(.cancelled)
        }
    }

    // MARK: Test API

    public static var latest: NWListener? {
        registryLock.lock(); defer { registryLock.unlock() }
        return instances.last
    }

    /// A Glass dials in.
    public func simulateIncoming(_ connection: NWConnection) {
        queue?.async {
            self.newConnectionHandler?(connection)
        }
    }

    /// iOS kills the listener (as when the app is suspended).
    public func simulateFailure() {
        queue?.async {
            self.state = .failed(NWError("simulated failure"))
            self.stateUpdateHandler?(self.state)
        }
    }
}
