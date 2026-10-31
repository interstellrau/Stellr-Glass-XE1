import Foundation
open class CGImage {}
open class UIImage: NSObject, @unchecked Sendable {
    public init?(data: Data) { return nil }
    public init(cgImage: CGImage) {}
    open var size: CGSize { return CGSize() }
    open func preparingThumbnail(of size: CGSize) -> UIImage? { return nil }
}
// Deliberately stricter than the SDK (no implicit @preconcurrency): code must not touch it
// from nonisolated contexts except through MainActor.assumeIsolated.
@MainActor open class UIDevice: NSObject { public static let current = UIDevice(); open var name: String { return "iPhone" } }
open class UIPasteboard: NSObject { public static let general = UIPasteboard(); open var string: String? }

// CoreGraphics (re-exported by UIKit on iOS).
public struct CGAffineTransform {
    public init(scaleX sx: CGFloat, y sy: CGFloat) {}
}
