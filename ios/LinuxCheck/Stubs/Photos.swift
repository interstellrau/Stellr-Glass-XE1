// Linux stand-in for PhotoKit, used only by ios/LinuxCheck. Signatures follow the iOS SDK
// (developer.apple.com documentation JSON). Behaviour: access is granted and every save
// "succeeds"; the fake records what would have been saved.

import Foundation

public enum PHAccessLevel: Int {
    case addOnly = 1
    case readWrite = 2
}

public enum PHAuthorizationStatus: Int {
    case notDetermined
    case restricted
    case denied
    case authorized
    case limited
}

public enum PHAssetResourceType: Int {
    case photo = 1
    case video = 2
}

open class PHAssetResourceCreationOptions: NSObject {
    public override init() {}
    open var originalFilename: String?
    open var shouldMoveFile: Bool = false
}

open class PHAssetChangeRequest: NSObject {
    public required override init() {}
    open var creationDate: Date?
}

/// Test API: one record per asset the app asked Photos to create.
public struct FakeSavedAsset {
    public let type: PHAssetResourceType
    public let originalFilename: String?
    public let bytes: Int
    public let creationDate: Date?
}

public final class FakePhotos {
    public static var saved: [FakeSavedAsset] = []
    public static let lock = NSLock()
}

open class PHAssetCreationRequest: PHAssetChangeRequest {
    private var resource: (PHAssetResourceType, URL, String?)?

    open class func forAsset() -> Self {
        let request = self.init()
        PHPhotoLibrary.current = request
        return request
    }

    open func addResource(with type: PHAssetResourceType, fileURL: URL, options: PHAssetResourceCreationOptions?) {
        resource = (type, fileURL, options?.originalFilename)
    }

    func record() {
        guard let r = resource else { return }
        let size: Int = (try? Data(contentsOf: r.1).count) ?? -1
        FakePhotos.lock.lock()
        FakePhotos.saved.append(FakeSavedAsset(type: r.0, originalFilename: r.2, bytes: size, creationDate: creationDate))
        FakePhotos.lock.unlock()
    }
}

open class PHPhotoLibrary: NSObject {
    static var current: PHAssetCreationRequest?
    private static let instance = PHPhotoLibrary()

    open class func shared() -> PHPhotoLibrary {
        return instance
    }

    open class func authorizationStatus(for accessLevel: PHAccessLevel) -> PHAuthorizationStatus {
        return .authorized
    }

    open class func requestAuthorization(for accessLevel: PHAccessLevel,
                                         handler: @escaping @Sendable (PHAuthorizationStatus) -> Void) {
        DispatchQueue.global().async {
            handler(.authorized)
        }
    }

    open class func requestAuthorization(for accessLevel: PHAccessLevel) async -> PHAuthorizationStatus {
        return .authorized
    }

    open func performChanges(_ changeBlock: @escaping () -> Void,
                             completionHandler: (@Sendable (Bool, (any Error)?) -> Void)? = nil) {
        DispatchQueue.global().async {
            changeBlock()
            PHPhotoLibrary.current?.record()
            PHPhotoLibrary.current = nil
            completionHandler?(true, nil)
        }
    }

    open func performChanges(_ changeBlock: @escaping () -> Void) async throws {
        changeBlock()
    }
}
