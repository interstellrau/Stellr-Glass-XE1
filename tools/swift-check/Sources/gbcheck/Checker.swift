// Checker.swift - tiny assertion helper for gbcheck (no XCTest, so it runs anywhere).

import Foundation

final class Checker {
    let part: String
    private(set) var passed: Int = 0
    private(set) var failures: [String] = []
    private var section: String = ""

    init(part: String) {
        self.part = part
    }

    func begin(_ name: String) {
        section = name
    }

    private func label(_ name: String) -> String {
        if section.isEmpty { return name }
        return section + ": " + name
    }

    @discardableResult
    func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") -> Bool {
        if condition {
            passed += 1
            return true
        }
        let d: String = detail()
        let line: String = d.isEmpty ? label(name) : label(name) + " -- " + d
        failures.append(line)
        print("  FAIL " + line)
        return false
    }

    @discardableResult
    func equal<T: Equatable>(_ actual: T, _ expected: T, _ name: String) -> Bool {
        return check(actual == expected, name, "expected \(expected), got \(actual)")
    }

    @discardableResult
    func near(_ actual: Double?, _ expected: Double, _ tolerance: Double, _ name: String) -> Bool {
        guard let a = actual else {
            return check(false, name, "expected \(expected), got nil")
        }
        return check(abs(a - expected) <= tolerance, name, "expected \(expected) +/- \(tolerance), got \(a)")
    }

    /// Passes if `body` throws (any error).
    @discardableResult
    func throwsError(_ name: String, _ body: () throws -> Void) -> Bool {
        do {
            try body()
        } catch {
            passed += 1
            return true
        }
        return check(false, name, "expected an error, none was thrown")
    }

    /// Passes if `body` doesn't throw.
    @discardableResult
    func noThrow(_ name: String, _ body: () throws -> Void) -> Bool {
        do {
            try body()
        } catch {
            return check(false, name, "unexpected error: \(error)")
        }
        passed += 1
        return true
    }

    /// Prints the summary and returns the process exit code.
    func finish() -> Int32 {
        if failures.isEmpty {
            print("PASS \(part): \(passed) checks")
            return 0
        }
        print("FAIL \(part): \(failures.count) failed, \(passed) passed")
        return 1
    }
}

/// Deterministic RNG for reproducible tests (SplitMix64).
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z: UInt64 = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func readFile(_ path: String) throws -> [UInt8] {
    let url = URL(fileURLWithPath: path)
    let data: Data = try Data(contentsOf: url)
    return [UInt8](data)
}

func writeFile(_ path: String, _ data: Data) throws {
    let url = URL(fileURLWithPath: path)
    try data.write(to: url)
}

/// Short printable form of a JSON value for failure messages.
func short(_ value: GBJSON?) -> String {
    guard let v = value else { return "nil" }
    let text: String
    if let bytes = try? GBJSONWriter.encode(v) {
        text = String(decoding: bytes, as: UTF8.self)
    } else {
        text = "\(v)"
    }
    if text.count > 80 {
        return String(text.prefix(80)) + "...(\(text.count) chars)"
    }
    return text
}

/// Parses all of `bytes`, feeding `readSize` bytes at a time (0 = everything at once).
/// Returns the frames, or throws the protocol error. Fails if bytes are left over.
func parseAll(_ bytes: [UInt8], readSize: Int) throws -> [GBFrame] {
    let parser = FrameParser()
    var frames: [GBFrame] = []
    if readSize <= 0 {
        parser.append(bytes)
        while let f = try parser.next() {
            frames.append(f)
        }
    } else {
        var i = 0
        while i < bytes.count {
            let end: Int = min(bytes.count, i + readSize)
            parser.append(contentsOf: bytes[i..<end])
            while let f = try parser.next() {
                frames.append(f)
            }
            i = end
        }
    }
    if parser.bufferedCount != 0 {
        throw GBProtocolError("\(parser.bufferedCount) trailing bytes don't form a complete frame")
    }
    return frames
}
