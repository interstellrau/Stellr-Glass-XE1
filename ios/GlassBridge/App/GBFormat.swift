// GBFormat.swift - display strings shared by the tabs (Foundation only).

import Foundation

enum GBFormat {
    /// Like Glass's formatDistance: 5 m steps under 50 m, 10 m steps under 1 km,
    /// "x.x km" under 10 km, whole km above.
    static func distance(_ metres: Double) -> String {
        guard metres.isFinite else { return "–" }
        let m: Double = max(0, metres)
        if m < 50 {
            let rounded: Int = Int((m / 5).rounded()) * 5
            return String(rounded) + " m"
        }
        if m < 1000 {
            let rounded: Int = Int((m / 10).rounded()) * 10
            if rounded >= 1000 {
                return "1.0 km"
            }
            return String(rounded) + " m"
        }
        if m < 10_000 {
            return String(format: "%.1f km", m / 1000)
        }
        let km: Int = Int((m / 1000).rounded())
        return String(km) + " km"
    }

    /// "1 min", "12 min", "1 h 5 min".
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "–" }
        let totalMinutes: Int = max(1, Int((seconds / 60).rounded()))
        if totalMinutes < 60 {
            return String(totalMinutes) + " min"
        }
        let hours: Int = totalMinutes / 60
        let minutes: Int = totalMinutes % 60
        if minutes == 0 {
            return String(hours) + " h"
        }
        return String(hours) + " h " + String(minutes) + " min"
    }

    static func minutes(_ value: Int) -> String {
        return String(value) + " min"
    }

    static func bytes(_ count: Int64) -> String {
        return ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func megabytes(_ mb: Int) -> String {
        let bytes: Int64 = Int64(mb) * 1_048_576
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "5 min ago".
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// "14:03:27".
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Date and time, medium/short.
    static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// "2:15:07" or "4 min" style uptime.
    static func uptime(_ seconds: Int64) -> String {
        let s: Int64 = max(0, seconds)
        let days: Int64 = s / 86_400
        let hours: Int64 = (s % 86_400) / 3600
        let minutes: Int64 = (s % 3600) / 60
        if days > 0 {
            return String(days) + " d " + String(hours) + " h"
        }
        if hours > 0 {
            return String(hours) + " h " + String(minutes) + " min"
        }
        return String(minutes) + " min"
    }
}

extension String {
    /// The string without leading and trailing whitespace and newlines.
    var gbTrimmed: String {
        return trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
