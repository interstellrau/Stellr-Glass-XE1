// Linux stand-in for the CoreImage API the app uses (QR codes), for ios/LinuxCheck only.
// On iOS, CIFilter.qrCodeGenerator() comes from `import CoreImage.CIFilterBuiltins`; the
// check strips that import line because a Swift stub module can't provide a Clang submodule.
// Objective-C protocols are class-bound, hence AnyObject below.

import Foundation
import UIKit

public protocol CIFilterProtocol: AnyObject {
    var outputImage: CIImage? { get }
}

public protocol CIQRCodeGenerator: CIFilterProtocol {
    var message: Data { get set }
    var correctionLevel: String { get set }
}

open class CIImage: NSObject {
    open func transformed(by matrix: CGAffineTransform) -> CIImage { return self }
    open var extent: CGRect { return .zero }
}

open class CIFilter: NSObject {
    open var outputImage: CIImage? { return nil }
}

final class _QRCodeGenerator: CIFilter, CIQRCodeGenerator {
    var message: Data = Data()
    var correctionLevel: String = "M"
}

extension CIFilter {
    public class func qrCodeGenerator() -> CIFilter & CIQRCodeGenerator {
        return _QRCodeGenerator()
    }
}

open class CIContext: NSObject {
    public override init() {}
    open func createCGImage(_ image: CIImage, from fromRect: CGRect) -> CGImage? { return nil }
}
