// FrameParser.swift - GlassBridge Core (Foundation only; builds on Linux for tools/swift-check)
//
// Framing for wire protocol v2 (PROTOCOL.md section 3):
//   * each frame is one JSON object line ending in \n; one trailing \r is stripped;
//     blank lines (empty after stripping \r) are skipped;
//   * an integer "bytes": N > 0 means exactly N raw payload bytes follow the \n;
//     "bytes" absent, 0 or not an integer (string, bool, fraction such as 3.0) means no
//     payload; a negative number is a protocol error;
//   * limits: a line is at most 65,536 bytes (not counting \n and one \r), a payload at
//     most 1,048,576 bytes. Exceeding either is a protocol error: drop the connection;
//   * a line that isn't UTF-8 JSON, isn't an object, or has no string "type" is a
//     protocol error;
//   * payloads are always consumed, whatever the type.
//
// Mirrors tools/gbproto.py (FrameReader / encode). Typical use on the server queue:
//
//     parser.append(data)
//     do {
//         while let frame = try parser.next() { handle(frame) }
//     } catch {
//         connection.cancel()   // protocol error: drop the link
//     }

import Foundation

/// Protocol-wide constants (PROTOCOL.md).
enum GBProtocol {
    static let version: Int = 2
    static let port: UInt16 = 9090
    static let bonjourType: String = "_glassbridge._tcp"
    /// `welcome.server`.
    static let serverName: String = "GlassBridge iOS"
    static let maxLine: Int = 65_536
    static let maxPayload: Int = 1_048_576
    /// Largest file chunk a writer should send (256 KiB).
    static let chunkSize: Int = 262_144
    /// Send `ping` after this many seconds without receiving anything.
    static let pingAfter: TimeInterval = 15
    /// Drop the connection after this many seconds without receiving anything.
    static let deadAfter: TimeInterval = 30
    /// Close a new connection that hasn't sent an acceptable `hello` within this time.
    static let helloTimeout: TimeInterval = 10

    /// Current wall-clock time in epoch milliseconds.
    static func nowMs() -> Int64 {
        let ms: Double = Date().timeIntervalSince1970 * 1000.0
        return Int64(ms.rounded())
    }
}

/// The peer broke the framing rules. Drop the connection.
struct GBProtocolError: Error, CustomStringConvertible, Equatable {
    let message: String
    init(_ message: String) {
        self.message = message
    }
    var description: String { return "protocol error: \(message)" }
}

/// One decoded frame: the header object exactly as received (including "bytes" when
/// present) and the payload, or nil when the frame has none.
struct GBFrame: Equatable {
    let header: GBObject
    let payload: Data?

    init(header: GBObject, payload: Data?) {
        self.header = header
        self.payload = payload
    }

    /// The frame type ("card", "hello", ...). Always present on a parsed frame.
    var type: String { return header.type ?? "" }

    /// The header as a plain Foundation dictionary (String, Int, Double, Bool, NSNull,
    /// [Any], [String: Any]). Handy for logging; prefer the typed accessors below.
    var raw: [String: Any] { return header.foundationDictionary }

    subscript(key: String) -> GBJSON? { return header[key] }

    func has(_ key: String) -> Bool { return header.contains(key) }

    /// A JSON string, or nil (numbers are not converted to strings).
    func string(_ key: String) -> String? { return header.string(key) }

    /// A JSON number as Int: integers as-is, fractions truncated toward zero.
    /// nil for booleans, strings, missing keys or values out of range.
    func int(_ key: String) -> Int? { return header.int(key) }

    /// Like `int` but 64-bit on every platform (use for epoch ms, sizes, offsets).
    func int64(_ key: String) -> Int64? { return header.int64(key) }

    /// Any JSON number as Double. nil for booleans, strings and missing keys.
    func double(_ key: String) -> Double? { return header.double(key) }

    /// Only JSON true/false. Numbers are never treated as booleans.
    func bool(_ key: String) -> Bool? { return header.bool(key) }

    /// Payload length in bytes (0 when there is none).
    var payloadCount: Int { return payload?.count ?? 0 }
}

/// Incremental frame parser over a [UInt8] buffer. Feed it whatever the socket delivers
/// (any split, even single bytes), then pull complete frames with `next()`.
///
/// After a protocol error the parser is dead: every later `next()` throws the same error.
/// Frames completed before the bad bytes are still returned first, in order.
/// Not thread-safe: use it from one queue (the connection's).
final class FrameParser {
    let maxLine: Int
    let maxPayload: Int

    private var buffer: [UInt8] = []
    private var start: Int = 0          // first unconsumed byte in `buffer`
    private var scanFrom: Int = 0       // no "\n" in buffer[start..<scanFrom]
    private var pendingHeader: GBObject?
    private var pendingCount: Int = 0
    private(set) var error: GBProtocolError?

    init(maxLine: Int = GBProtocol.maxLine, maxPayload: Int = GBProtocol.maxPayload) {
        self.maxLine = maxLine
        self.maxPayload = maxPayload
    }

    /// Bytes received but not yet returned as a frame (0 at a clean frame boundary).
    var bufferedCount: Int { return buffer.count - start }

    /// True while a header has been read and its payload is still arriving.
    var isReadingPayload: Bool { return pendingHeader != nil }

    func append(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
    }

    func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    func append<S: Sequence>(contentsOf bytes: S) where S.Element == UInt8 {
        buffer.append(contentsOf: bytes)
    }

    /// The next complete frame, or nil if more bytes are needed.
    /// Throws GBProtocolError when the stream breaks the framing rules.
    func next() throws -> GBFrame? {
        if let e = error { throw e }
        do {
            return try parseNext()
        } catch let e as GBProtocolError {
            error = e
            throw e
        }
    }

    /// Every frame that is complete right now. If a protocol error occurs after some
    /// frames, those frames are lost to the caller: prefer a `next()` loop in the app.
    func drain() throws -> [GBFrame] {
        var out: [GBFrame] = []
        while let f = try next() {
            out.append(f)
        }
        return out
    }

    /// How many payload bytes follow a header (0 = none). Throws for a negative "bytes".
    /// Does not apply the size limit.
    static func payloadLength(of header: GBObject) throws -> Int {
        guard let value = header["bytes"] else { return 0 }
        switch value {
        case .int(let n):
            if n < 0 {
                throw GBProtocolError("negative bytes: \(n)")
            }
            guard let v = Int(exactly: n) else {
                throw GBProtocolError("bytes too large: \(n)")
            }
            return v
        case .double(let d):
            if d < 0 {
                throw GBProtocolError("negative bytes: \(d)")
            }
            return 0 // a fraction is "not an integer": no payload
        default:
            return 0 // string, bool, null, array, object: no payload
        }
    }

    /// Parses one header line (without its line ending). Returns the header object and
    /// its payload length.
    static func parseHeader(_ line: [UInt8], maxPayload: Int = GBProtocol.maxPayload) throws -> (GBObject, Int) {
        let value: GBJSON
        do {
            value = try GBJSONParser.parse(line)
        } catch let e as GBJSONParser.ParseError {
            throw GBProtocolError("line is not valid JSON: \(e.description)")
        }
        guard case .object(let obj) = value else {
            throw GBProtocolError("line is not a JSON object")
        }
        guard obj.type != nil else {
            throw GBProtocolError("frame has no string 'type'")
        }
        let n: Int = try payloadLength(of: obj)
        if n > maxPayload {
            throw GBProtocolError("payload of \(n) bytes exceeds the \(maxPayload) byte limit")
        }
        return (obj, n)
    }

    private func parseNext() throws -> GBFrame? {
        while true {
            if let header = pendingHeader {
                let available = buffer.count - start
                if available < pendingCount {
                    return nil
                }
                let count = pendingCount
                let from = start
                let payload: Data = buffer.withUnsafeBufferPointer { (p: UnsafeBufferPointer<UInt8>) -> Data in
                    guard let base = p.baseAddress, count > 0 else { return Data() }
                    return Data(bytes: base + from, count: count)
                }
                start += count
                scanFrom = start
                pendingHeader = nil
                pendingCount = 0
                compact()
                return GBFrame(header: header, payload: payload)
            }

            // Look for the end of the header line.
            var nl = max(scanFrom, start)
            let end = buffer.count
            while nl < end && buffer[nl] != 0x0A {
                nl += 1
            }
            if nl >= end {
                scanFrom = end
                // +1 leaves room for a trailing "\r" that will be stripped.
                if end - start > maxLine + 1 {
                    throw GBProtocolError("line exceeds the \(maxLine) byte limit")
                }
                compact()
                return nil
            }
            var lineEnd = nl
            if lineEnd > start && buffer[lineEnd - 1] == 0x0D {
                lineEnd -= 1
            }
            let lineStart = start
            start = nl + 1
            scanFrom = start
            let length = lineEnd - lineStart
            if length > maxLine {
                throw GBProtocolError("line of \(length) bytes exceeds the \(maxLine) byte limit")
            }
            if length == 0 {
                continue // blank line
            }
            let line: [UInt8] = Array(buffer[lineStart..<lineEnd])
            let parsed: (GBObject, Int) = try FrameParser.parseHeader(line, maxPayload: maxPayload)
            if parsed.1 > 0 {
                pendingHeader = parsed.0
                pendingCount = parsed.1
                continue
            }
            compact()
            return GBFrame(header: parsed.0, payload: nil)
        }
    }

    /// Drops consumed bytes without moving data on every frame.
    private func compact() {
        if start == 0 { return }
        if start >= buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
            scanFrom = 0
            return
        }
        if start >= 65_536 && start * 2 >= buffer.count {
            buffer.removeFirst(start)
            scanFrom = max(0, scanFrom - start)
            start = 0
        }
    }
}

/// Encodes frames: one compact JSON line ("type" first), "\n", then the payload.
enum GBEncoder {
    /// Encodes one frame. With a payload (may be empty), "bytes" is set to its length.
    /// Without one, a positive integer "bytes" in `object` is refused (it would desync
    /// the stream). Throws GBProtocolError if there is no string "type", a limit is
    /// exceeded, or a value can't be written as JSON.
    static func encode(_ object: GBObject, payload: Data? = nil) throws -> Data {
        var obj = object
        guard obj.type != nil else {
            throw GBProtocolError("a frame needs a string 'type'")
        }
        if let p = payload {
            obj["bytes"] = .int(Int64(p.count))
            if p.count > GBProtocol.maxPayload {
                throw GBProtocolError("payload of \(p.count) bytes exceeds the \(GBProtocol.maxPayload) byte limit")
            }
        } else {
            let declared: Int = try FrameParser.payloadLength(of: obj)
            if declared > 0 {
                throw GBProtocolError("header has bytes=\(declared) but no payload was given")
            }
        }
        let line: [UInt8] = try headerLine(obj)
        var data = Data()
        let payloadCount: Int = payload?.count ?? 0
        data.reserveCapacity(line.count + 1 + payloadCount)
        data.append(contentsOf: line)
        data.append(0x0A)
        if let p = payload, !p.isEmpty {
            data.append(p)
        }
        return data
    }

    /// Re-encodes a parsed frame (its "bytes" field is recomputed from the payload).
    static func encode(_ frame: GBFrame) throws -> Data {
        return try encode(frame.header.removing("bytes"), payload: frame.payload)
    }

    /// Encodes a Foundation dictionary ("type" first, other keys sorted).
    static func encode(dictionary: [String: Any], payload: Data? = nil) throws -> Data {
        guard let obj = GBObject(foundation: dictionary) else {
            throw GBProtocolError("dictionary holds a value JSON can't represent")
        }
        return try encode(obj, payload: payload)
    }

    /// The JSON header line without its "\n". Enforces the 64 KiB line limit.
    static func headerLine(_ object: GBObject) throws -> [UInt8] {
        let line: [UInt8]
        do {
            line = try GBJSONWriter.encodeMessage(object)
        } catch let e as GBJSONWriter.WriteError {
            throw GBProtocolError(e.message)
        }
        if line.count > GBProtocol.maxLine {
            throw GBProtocolError("line of \(line.count) bytes exceeds the \(GBProtocol.maxLine) byte limit")
        }
        return line
    }
}
