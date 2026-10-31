// Scratch-only: Darwin Foundation API missing from swift-corelibs-foundation on Linux.
import Foundation
final class RelativeDateTimeFormatter {
    enum UnitsStyle { case full, spellOut, short, abbreviated }
    var unitsStyle: UnitsStyle = .full
    func localizedString(for date: Date, relativeTo referenceDate: Date) -> String { return "" }
}
