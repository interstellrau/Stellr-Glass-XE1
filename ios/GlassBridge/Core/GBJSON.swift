// GBJSON.swift - GlassBridge Core (Foundation only; builds on Linux for tools/swift-check)
//
// A small JSON model, parser and writer used for every header line on the wire
// (PROTOCOL.md section 3).
//
// Why not JSONSerialization: on both Darwin and Linux it returns NSNumber for numbers AND
// booleans, and NSNumber bridges ambiguously (`true as? Int` is 1, `1 as? Bool` is true).
// A header like {"bytes":true} must mean "no payload", and pair_code must stay a string.
// This parser keeps integers, fractional numbers and booleans apart exactly as written,
// keeps key order (so re-encoding writes "type" first like the Python reference), and
// behaves identically on every platform.

import Foundation

/// One JSON value, keeping the int / fraction / bool distinction of the wire text.
enum GBJSON: Equatable {
    case null
    case bool(Bool)
    /// A number written without a fraction or exponent that fits in Int64.
    case int(Int64)
    /// A number written with a fraction or exponent (or an integer too big for Int64).
    case double(Double)
    case string(String)
    case array([GBJSON])
    case object(GBObject)

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Only a JSON true/false. Numbers are never converted to Bool.
    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// Integers as-is; fractional numbers truncated toward zero (PROTOCOL.md section 5:
    /// receivers accept either form and convert). nil for non-numbers, NaN or out of range.
    var int64Value: Int64? {
        switch self {
        case .int(let v):
            return v
        case .double(let d):
            return GBJSON.int64(truncating: d)
        default:
            return nil
        }
    }

    var intValue: Int? {
        guard let v = int64Value else { return nil }
        return Int(exactly: v)
    }

    /// Any JSON number as a Double. Booleans are never converted.
    var doubleValue: Double? {
        switch self {
        case .int(let v):
            return Double(v)
        case .double(let d):
            return d
        default:
            return nil
        }
    }

    var isNumber: Bool {
        switch self {
        case .int, .double:
            return true
        default:
            return false
        }
    }

    var objectValue: GBObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [GBJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Plain Foundation/Swift value: String, Int, Double, Bool, NSNull, [Any] or [String: Any].
    var foundationValue: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let b):
            return b
        case .int(let v):
            if let i = Int(exactly: v) { return i }
            return v
        case .double(let d):
            return d
        case .string(let s):
            return s
        case .array(let a):
            var out: [Any] = []
            out.reserveCapacity(a.count)
            for item in a {
                out.append(item.foundationValue)
            }
            return out
        case .object(let o):
            return o.foundationDictionary
        }
    }

    static func int64(truncating d: Double) -> Int64? {
        guard d.isFinite else { return nil }
        let t: Double = d.rounded(.towardZero)
        return Int64(exactly: t)
    }

    /// Converts a Foundation/Swift value (for example from JSONSerialization, or a
    /// hand-built [String: Any]) into GBJSON. Handles NSNumber carefully: a CFBoolean
    /// (objCType "c") becomes .bool, a float/double NSNumber becomes .double, any other
    /// NSNumber becomes .int. Native Swift Bool/Int/Double values are checked by their
    /// exact type first, so `true` never turns into 1 and 1 never turns into `true`.
    /// Returns nil for values JSON can't hold (Date, Data, non-finite doubles, ...).
    static func fromFoundation(_ value: Any) -> GBJSON? {
        // Unwrap Optional values hidden inside Any.
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let first = mirror.children.first else { return .null }
            return fromFoundation(first.value)
        }
        if let j = value as? GBJSON { return j }
        if let o = value as? GBObject { return .object(o) }
        if value is NSNull { return .null }

        // Exact native Swift types first: `is NSNumber` is true for these through bridging.
        let t: Any.Type = type(of: value)
        if t == Bool.self, let b = value as? Bool { return .bool(b) }
        if t == Int.self, let v = value as? Int { return .int(Int64(v)) }
        if t == Int64.self, let v = value as? Int64 { return .int(v) }
        if t == Int32.self, let v = value as? Int32 { return .int(Int64(v)) }
        if t == Int16.self, let v = value as? Int16 { return .int(Int64(v)) }
        if t == Int8.self, let v = value as? Int8 { return .int(Int64(v)) }
        if t == UInt.self, let v = value as? UInt { return unsignedValue(UInt64(v)) }
        if t == UInt64.self, let v = value as? UInt64 { return unsignedValue(v) }
        if t == UInt32.self, let v = value as? UInt32 { return .int(Int64(v)) }
        if t == UInt16.self, let v = value as? UInt16 { return .int(Int64(v)) }
        if t == UInt8.self, let v = value as? UInt8 { return .int(Int64(v)) }
        if t == Double.self, let v = value as? Double { return finiteDouble(v) }
        if t == Float.self, let v = value as? Float { return finiteDouble(Double(v)) }
        if t == String.self, let s = value as? String { return .string(s) }

        // A real NSNumber object (JSONSerialization output on Darwin and Linux).
        if let n = value as? NSNumber {
            let code: String = String(cString: n.objCType)
            if code == "c" || code == "B" {
                return .bool(n.boolValue)
            }
            if code == "f" || code == "d" {
                return finiteDouble(n.doubleValue)
            }
            if code == "Q" || code == "L" || code == "I" || code == "S" || code == "C" {
                return unsignedValue(n.uint64Value)
            }
            return .int(n.int64Value)
        }
        if let s = value as? String { return .string(s) }
        if let s = value as? Substring { return .string(String(s)) }
        if let a = value as? [Any] {
            var out: [GBJSON] = []
            out.reserveCapacity(a.count)
            for item in a {
                guard let j = fromFoundation(item) else { return nil }
                out.append(j)
            }
            return .array(out)
        }
        if let d = value as? [String: Any] {
            guard let o = GBObject(foundation: d) else { return nil }
            return .object(o)
        }
        return nil
    }

    private static func unsignedValue(_ v: UInt64) -> GBJSON {
        if let i = Int64(exactly: v) { return .int(i) }
        return .double(Double(v))
    }

    private static func finiteDouble(_ d: Double) -> GBJSON? {
        guard d.isFinite else { return nil }
        return .double(d)
    }
}

/// A JSON object that remembers key order (first insertion wins the position, like a
/// Python dict). Equality ignores order.
struct GBObject: Equatable {
    private(set) var keys: [String] = []
    private var values: [String: GBJSON] = [:]

    init() {}

    /// A message object whose first key is "type".
    init(type: String) {
        self["type"] = .string(type)
    }

    /// From a Foundation dictionary. "type" goes first, the other keys sorted, so the
    /// encoding is deterministic. nil if any value can't be represented as JSON.
    init?(foundation dict: [String: Any]) {
        if let t = dict["type"] {
            guard let j = GBJSON.fromFoundation(t) else { return nil }
            self["type"] = j
        }
        let sortedKeys: [String] = dict.keys.sorted()
        for key in sortedKeys where key != "type" {
            guard let raw = dict[key], let j = GBJSON.fromFoundation(raw) else { return nil }
            self[key] = j
        }
    }

    static func == (lhs: GBObject, rhs: GBObject) -> Bool {
        return lhs.values == rhs.values
    }

    var count: Int { return keys.count }
    var isEmpty: Bool { return keys.isEmpty }

    subscript(key: String) -> GBJSON? {
        get { return values[key] }
        set {
            if let v = newValue {
                if values.updateValue(v, forKey: key) == nil {
                    keys.append(key)
                }
            } else if values.removeValue(forKey: key) != nil {
                keys.removeAll(where: { $0 == key })
            }
        }
    }

    func contains(_ key: String) -> Bool {
        return values[key] != nil
    }

    /// Key/value pairs in wire order.
    var pairs: [(key: String, value: GBJSON)] {
        var out: [(key: String, value: GBJSON)] = []
        out.reserveCapacity(keys.count)
        for k in keys {
            if let v = values[k] {
                out.append((key: k, value: v))
            }
        }
        return out
    }

    /// A copy without `key`.
    func removing(_ key: String) -> GBObject {
        var copy = self
        copy[key] = nil
        return copy
    }

    /// The "type" string, if present.
    var type: String? { return values["type"]?.stringValue }

    func string(_ key: String) -> String? { return values[key]?.stringValue }
    func bool(_ key: String) -> Bool? { return values[key]?.boolValue }
    func int(_ key: String) -> Int? { return values[key]?.intValue }
    func int64(_ key: String) -> Int64? { return values[key]?.int64Value }
    func double(_ key: String) -> Double? { return values[key]?.doubleValue }
    func object(_ key: String) -> GBObject? { return values[key]?.objectValue }
    func array(_ key: String) -> [GBJSON]? { return values[key]?.arrayValue }

    /// Plain Foundation dictionary (String, Int, Double, Bool, NSNull, [Any], [String: Any]).
    var foundationDictionary: [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in values {
            out[k] = v.foundationValue
        }
        return out
    }

    // MARK: Builders. A nil value leaves the key out.

    mutating func set(_ key: String, _ value: String?) {
        guard let v = value else { return }
        self[key] = .string(v)
    }

    mutating func set(_ key: String, _ value: Bool?) {
        guard let v = value else { return }
        self[key] = .bool(v)
    }

    mutating func set(_ key: String, _ value: Int?) {
        guard let v = value else { return }
        self[key] = .int(Int64(v))
    }

    mutating func set(_ key: String, _ value: Int64?) {
        guard let v = value else { return }
        self[key] = .int(v)
    }

    /// Non-finite doubles (NaN, infinity) are left out: JSON can't carry them.
    mutating func set(_ key: String, _ value: Double?) {
        guard let v = value, v.isFinite else { return }
        self[key] = .double(v)
    }

    mutating func set(_ key: String, json value: GBJSON?) {
        guard let v = value else { return }
        self[key] = v
    }
}

// MARK: - Parser

/// Strict JSON parser over UTF-8 bytes (RFC 8259, like Python's json.loads in strict
/// mode): no NaN/Infinity literals, no trailing commas, no control characters in strings,
/// invalid UTF-8 rejected. Lone \u surrogates become U+FFFD (Swift strings can't hold
/// them). Nesting is limited to `maxDepth` to protect the stack of a network thread.
struct GBJSONParser {
    static let maxDepth: Int = 200

    struct ParseError: Error, CustomStringConvertible {
        let message: String
        let offset: Int
        var description: String { return "\(message) at byte \(offset)" }
    }

    private let bytes: [UInt8]
    private var i: Int = 0
    private var depth: Int = 0

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Parses one complete JSON text (surrounding whitespace allowed).
    static func parse(_ bytes: [UInt8]) throws -> GBJSON {
        if let bad = firstInvalidUTF8(bytes) {
            throw ParseError(message: "invalid UTF-8", offset: bad)
        }
        var p = GBJSONParser(bytes: bytes)
        p.skipWhitespace()
        let value: GBJSON = try p.parseValue()
        p.skipWhitespace()
        if p.i != bytes.count {
            throw ParseError(message: "unexpected data after the JSON value", offset: p.i)
        }
        return value
    }

    static func parse(_ text: String) throws -> GBJSON {
        return try parse(Array(text.utf8))
    }

    /// Index of the first byte that isn't valid UTF-8, or nil if the bytes are valid.
    /// Rejects overlong forms, surrogates (U+D800-U+DFFF) and values above U+10FFFF.
    static func firstInvalidUTF8(_ b: [UInt8]) -> Int? {
        let n = b.count
        var i = 0
        while i < n {
            let b0 = b[i]
            if b0 < 0x80 {
                i += 1
                continue
            }
            var need = 0
            var lo: UInt8 = 0x80
            var hi: UInt8 = 0xBF
            if b0 >= 0xC2 && b0 <= 0xDF {
                need = 1
            } else if b0 >= 0xE0 && b0 <= 0xEF {
                need = 2
                if b0 == 0xE0 { lo = 0xA0 }
                if b0 == 0xED { hi = 0x9F }
            } else if b0 >= 0xF0 && b0 <= 0xF4 {
                need = 3
                if b0 == 0xF0 { lo = 0x90 }
                if b0 == 0xF4 { hi = 0x8F }
            } else {
                return i
            }
            if i + need >= n {
                return i
            }
            let b1 = b[i + 1]
            if b1 < lo || b1 > hi { return i }
            var k = 2
            while k <= need {
                let c = b[i + k]
                if c < 0x80 || c > 0xBF { return i }
                k += 1
            }
            i += need + 1
        }
        return nil
    }

    private mutating func skipWhitespace() {
        while i < bytes.count {
            let c = bytes[i]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                i += 1
            } else {
                break
            }
        }
    }

    private func fail(_ message: String) -> ParseError {
        return ParseError(message: message, offset: i)
    }

    private mutating func parseValue() throws -> GBJSON {
        guard i < bytes.count else { throw fail("unexpected end of JSON") }
        let c = bytes[i]
        switch c {
        case UInt8(ascii: "{"):
            return try parseObject()
        case UInt8(ascii: "["):
            return try parseArray()
        case UInt8(ascii: "\""):
            return .string(try parseString())
        case UInt8(ascii: "t"):
            try expectLiteral("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try expectLiteral("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try expectLiteral("null")
            return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try parseNumber()
        default:
            throw fail("unexpected character")
        }
    }

    private mutating func expectLiteral(_ word: String) throws {
        let w: [UInt8] = Array(word.utf8)
        if i + w.count > bytes.count {
            throw fail("invalid literal")
        }
        var k = 0
        while k < w.count {
            if bytes[i + k] != w[k] { throw fail("invalid literal") }
            k += 1
        }
        i += w.count
    }

    private mutating func enter() throws {
        depth += 1
        if depth > GBJSONParser.maxDepth {
            throw fail("JSON nested too deeply")
        }
    }

    private mutating func parseObject() throws -> GBJSON {
        try enter()
        i += 1 // {
        var obj = GBObject()
        skipWhitespace()
        if i < bytes.count && bytes[i] == UInt8(ascii: "}") {
            i += 1
            depth -= 1
            return .object(obj)
        }
        while true {
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else {
                throw fail("expected a string key")
            }
            let key: String = try parseString()
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else {
                throw fail("expected ':'")
            }
            i += 1
            skipWhitespace()
            let value: GBJSON = try parseValue()
            obj[key] = value
            skipWhitespace()
            guard i < bytes.count else { throw fail("unterminated object") }
            if bytes[i] == UInt8(ascii: ",") {
                i += 1
                continue
            }
            if bytes[i] == UInt8(ascii: "}") {
                i += 1
                break
            }
            throw fail("expected ',' or '}'")
        }
        depth -= 1
        return .object(obj)
    }

    private mutating func parseArray() throws -> GBJSON {
        try enter()
        i += 1 // [
        var items: [GBJSON] = []
        skipWhitespace()
        if i < bytes.count && bytes[i] == UInt8(ascii: "]") {
            i += 1
            depth -= 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            let value: GBJSON = try parseValue()
            items.append(value)
            skipWhitespace()
            guard i < bytes.count else { throw fail("unterminated array") }
            if bytes[i] == UInt8(ascii: ",") {
                i += 1
                continue
            }
            if bytes[i] == UInt8(ascii: "]") {
                i += 1
                break
            }
            throw fail("expected ',' or ']'")
        }
        depth -= 1
        return .array(items)
    }

    private static func hexValue(_ c: UInt8) -> UInt32? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return UInt32(c - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return UInt32(c - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return UInt32(c - UInt8(ascii: "A") + 10)
        default:
            return nil
        }
    }

    private mutating func parseHex4() throws -> UInt32 {
        if i + 4 > bytes.count { throw fail("short \\u escape") }
        var v: UInt32 = 0
        var k = 0
        while k < 4 {
            guard let h = GBJSONParser.hexValue(bytes[i + k]) else {
                throw fail("bad \\u escape")
            }
            v = v * 16 + h
            k += 1
        }
        i += 4
        return v
    }

    /// UTF-8 continuation byte for bits `shift...shift+5` of `scalar`.
    private static func continuation(_ scalar: UInt32, shift: UInt32) -> UInt8 {
        let bits: UInt32 = (scalar >> shift) & 0x3F
        let byte: UInt32 = bits | 0x80
        return UInt8(truncatingIfNeeded: byte)
    }

    /// UTF-8 lead byte: `marker` ORed with `scalar >> shift`.
    private static func lead(_ scalar: UInt32, shift: UInt32, marker: UInt32) -> UInt8 {
        let byte: UInt32 = (scalar >> shift) | marker
        return UInt8(truncatingIfNeeded: byte)
    }

    private static func appendUTF8(_ scalar: UInt32, to out: inout [UInt8]) {
        if scalar < 0x80 {
            out.append(UInt8(truncatingIfNeeded: scalar))
        } else if scalar < 0x800 {
            out.append(lead(scalar, shift: 6, marker: 0xC0))
            out.append(continuation(scalar, shift: 0))
        } else if scalar < 0x10000 {
            out.append(lead(scalar, shift: 12, marker: 0xE0))
            out.append(continuation(scalar, shift: 6))
            out.append(continuation(scalar, shift: 0))
        } else {
            out.append(lead(scalar, shift: 18, marker: 0xF0))
            out.append(continuation(scalar, shift: 12))
            out.append(continuation(scalar, shift: 6))
            out.append(continuation(scalar, shift: 0))
        }
    }

    /// Parses a string starting at the opening quote. The input is already valid UTF-8.
    private mutating func parseString() throws -> String {
        i += 1 // opening quote
        let start = i
        // Fast path: no escapes.
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "\"") {
                let s = String(decoding: bytes[start..<i], as: UTF8.self)
                i += 1
                return s
            }
            if c == UInt8(ascii: "\\") {
                break
            }
            if c < 0x20 {
                throw fail("control character in string")
            }
            i += 1
        }
        guard i < bytes.count else { throw fail("unterminated string") }
        // Slow path: there is at least one escape.
        var out: [UInt8] = Array(bytes[start..<i])
        while true {
            guard i < bytes.count else { throw fail("unterminated string") }
            let c = bytes[i]
            if c == UInt8(ascii: "\"") {
                i += 1
                break
            }
            if c < 0x20 {
                throw fail("control character in string")
            }
            if c != UInt8(ascii: "\\") {
                out.append(c)
                i += 1
                continue
            }
            i += 1
            guard i < bytes.count else { throw fail("unterminated escape") }
            let e = bytes[i]
            i += 1
            switch e {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                let unit: UInt32 = try parseHex4()
                var scalar: UInt32 = unit
                if unit >= 0xD800 && unit <= 0xDBFF {
                    // High surrogate: combine with a following \uDC00-\uDFFF if present.
                    var combined = false
                    if i + 6 <= bytes.count && bytes[i] == UInt8(ascii: "\\") && bytes[i + 1] == UInt8(ascii: "u") {
                        let save = i
                        i += 2
                        let low: UInt32 = try parseHex4()
                        if low >= 0xDC00 && low <= 0xDFFF {
                            let high10: UInt32 = (unit - 0xD800) << 10
                            scalar = 0x10000 + high10 + (low - 0xDC00)
                            combined = true
                        } else {
                            i = save
                        }
                    }
                    if !combined {
                        scalar = 0xFFFD
                    }
                } else if unit >= 0xDC00 && unit <= 0xDFFF {
                    scalar = 0xFFFD
                }
                GBJSONParser.appendUTF8(scalar, to: &out)
            default:
                throw fail("bad escape")
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func isDigit(_ c: UInt8) -> Bool {
        return c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")
    }

    private mutating func parseNumber() throws -> GBJSON {
        let start = i
        var isInteger = true
        if bytes[i] == UInt8(ascii: "-") {
            i += 1
        }
        guard i < bytes.count, GBJSONParser.isDigit(bytes[i]) else {
            throw fail("bad number")
        }
        if bytes[i] == UInt8(ascii: "0") {
            i += 1
        } else {
            while i < bytes.count && GBJSONParser.isDigit(bytes[i]) { i += 1 }
        }
        if i < bytes.count && bytes[i] == UInt8(ascii: ".") {
            isInteger = false
            i += 1
            guard i < bytes.count, GBJSONParser.isDigit(bytes[i]) else {
                throw fail("bad number fraction")
            }
            while i < bytes.count && GBJSONParser.isDigit(bytes[i]) { i += 1 }
        }
        if i < bytes.count && (bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E")) {
            isInteger = false
            i += 1
            if i < bytes.count && (bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-")) {
                i += 1
            }
            guard i < bytes.count, GBJSONParser.isDigit(bytes[i]) else {
                throw fail("bad number exponent")
            }
            while i < bytes.count && GBJSONParser.isDigit(bytes[i]) { i += 1 }
        }
        let text = String(decoding: bytes[start..<i], as: UTF8.self)
        if isInteger, let v = Int64(text) {
            return .int(v)
        }
        // An exponent too large for a Double (1e400) becomes +/-infinity, like Python's
        // json.loads in the reference. It can't be re-encoded; int/int64 return nil for it.
        guard let d = Double(text), !d.isNaN else {
            throw ParseError(message: "bad number", offset: start)
        }
        return .double(d)
    }
}

// MARK: - Writer

/// Compact JSON writer (no spaces, raw UTF-8, "/" not escaped), like the Python
/// reference `json.dumps(ensure_ascii=False, separators=(",", ":"))`.
enum GBJSONWriter {
    struct WriteError: Error, CustomStringConvertible {
        let message: String
        var description: String { return message }
    }

    /// Encodes an object with "type" first (if present), then the other keys in order.
    static func encodeMessage(_ object: GBObject) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(128)
        try writeObject(object, typeFirst: true, into: &out)
        return out
    }

    static func encode(_ value: GBJSON) throws -> [UInt8] {
        var out: [UInt8] = []
        try write(value, into: &out)
        return out
    }

    static func write(_ value: GBJSON, into out: inout [UInt8]) throws {
        switch value {
        case .null:
            out.append(contentsOf: Array("null".utf8))
        case .bool(let b):
            if b {
                out.append(contentsOf: Array("true".utf8))
            } else {
                out.append(contentsOf: Array("false".utf8))
            }
        case .int(let v):
            out.append(contentsOf: Array(String(v).utf8))
        case .double(let d):
            guard d.isFinite else {
                throw WriteError(message: "JSON can't carry a non-finite number")
            }
            // Swift's description is the shortest text that round-trips, e.g. "150.0",
            // "1e-05", "1.5e+20". All of these are valid JSON numbers.
            out.append(contentsOf: Array(d.description.utf8))
        case .string(let s):
            writeString(s, into: &out)
        case .array(let a):
            out.append(UInt8(ascii: "["))
            var first = true
            for item in a {
                if !first { out.append(UInt8(ascii: ",")) }
                first = false
                try write(item, into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let o):
            try writeObject(o, typeFirst: false, into: &out)
        }
    }

    private static func writeObject(_ o: GBObject, typeFirst: Bool, into out: inout [UInt8]) throws {
        out.append(UInt8(ascii: "{"))
        var first = true
        if typeFirst, let t = o["type"] {
            writeString("type", into: &out)
            out.append(UInt8(ascii: ":"))
            try write(t, into: &out)
            first = false
        }
        for pair in o.pairs {
            if typeFirst && pair.key == "type" { continue }
            if !first { out.append(UInt8(ascii: ",")) }
            first = false
            writeString(pair.key, into: &out)
            out.append(UInt8(ascii: ":"))
            try write(pair.value, into: &out)
        }
        out.append(UInt8(ascii: "}"))
    }

    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    static func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for c in s.utf8 {
            switch c {
            case 0x22:
                out.append(0x5C)
                out.append(0x22)
            case 0x5C:
                out.append(0x5C)
                out.append(0x5C)
            case 0x0A:
                out.append(0x5C)
                out.append(UInt8(ascii: "n"))
            case 0x0D:
                out.append(0x5C)
                out.append(UInt8(ascii: "r"))
            case 0x09:
                out.append(0x5C)
                out.append(UInt8(ascii: "t"))
            case 0x08:
                out.append(0x5C)
                out.append(UInt8(ascii: "b"))
            case 0x0C:
                out.append(0x5C)
                out.append(UInt8(ascii: "f"))
            case 0x00..<0x20:
                out.append(0x5C)
                out.append(UInt8(ascii: "u"))
                out.append(UInt8(ascii: "0"))
                out.append(UInt8(ascii: "0"))
                out.append(hexDigits[Int(c >> 4)])
                out.append(hexDigits[Int(c & 0x0F)])
            default:
                out.append(c)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}
