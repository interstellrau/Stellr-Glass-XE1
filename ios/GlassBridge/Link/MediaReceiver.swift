// MediaReceiver.swift - reassembles Glass uploads and saves them to Photos.
//
// file_begin / file_chunk... / file_end (PROTOCOL.md section 5), one file at a time:
// * Each upload goes into a temp file through a FileHandle. Core's UploadProgress decides
//   what to write: a chunk whose offset isn't the byte count so far marks the upload
//   "chunks out of order"; at file_end the count must equal `size` ("size mismatch").
// * A complete file is saved with PHPhotoLibrary (add-only access) through
//   PHAssetCreationRequest as a .photo or .video resource, with originalFilename and the
//   creation date from `taken`. file_ack is sent after the save.
// * Up to 5,000 saved ids are remembered (UserDefaults). A re-upload of a saved id is
//   consumed, discarded and acked ok:true.
// * The 30 most recent items are kept for the Media tab.
// * When the link drops, the partial file is deleted. Leftovers are cleaned at launch.
// Used from the main thread only.

import Foundation
import Photos
import UIKit

/// One received file, for the Media tab.
struct MediaItem: Identifiable {
    let id: Int
    let name: String
    let size: Int64
    let isVideo: Bool
    let taken: Date?
    let received: Date
    let ok: Bool
    let error: String?
    let thumbnail: UIImage?
}

/// The transfer in progress, for the Media tab.
struct TransferProgress {
    let id: String
    let name: String
    let size: Int64
    let received: Int64
    let fraction: Double
    /// The file is complete and being saved to Photos.
    let saving: Bool
    /// Glass is re-sending a file that is already in Photos.
    let duplicate: Bool
}

final class MediaReceiver {
    static let maxRememberedIDs: Int = 5000
    static let tempPrefix: String = "glassbridge-upload-"
    static let savedIDsKey: String = "savedMediaIDs"
    static let thumbnailSide: CGFloat = 240

    /// Send this frame to Glass (file_ack).
    var onAck: ((GBObject) -> Void)?
    /// Progress for the UI (nil when idle).
    var onProgress: ((TransferProgress?) -> Void)?
    /// A finished (saved or failed) item.
    var onItem: ((MediaItem) -> Void)?
    var onLog: ((String) -> Void)?

    private var upload: UploadProgress?
    private var fileURL: URL?
    private var handle: FileHandle?
    private var writeError: String?
    private var discarding: Bool = false
    private var savedOrder: [String]
    private var savedSet: Set<String>
    private var itemCounter: Int = 0
    private var lastProgressReport: TimeInterval = 0

    init() {
        let list: [String] = UserDefaults.standard.stringArray(forKey: MediaReceiver.savedIDsKey) ?? []
        savedOrder = list
        savedSet = Set(list)
    }

    // MARK: - Protocol events

    func begin(_ b: GlassFileBegin) {
        if upload != nil {
            discardCurrent(reason: "a new upload started before it finished")
        }
        upload = UploadProgress(b)
        writeError = nil
        discarding = savedSet.contains(b.id)
        let sizeText: String = GBFormat.bytes(b.size)
        if discarding {
            onLog?("Glass is re-sending \(b.name), which is already in Photos")
            report(force: true)
            return
        }
        let ext: String = URL(fileURLWithPath: b.name).pathExtension.lowercased()
        var fileName: String = MediaReceiver.tempPrefix + UUID().uuidString
        if !ext.isEmpty {
            fileName += "." + ext
        }
        let url: URL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try Data().write(to: url)
            handle = try FileHandle(forWritingTo: url)
            fileURL = url
        } catch {
            writeError = "couldn't create a temporary file (\(error.localizedDescription))"
            try? FileManager.default.removeItem(at: url)
        }
        onLog?("Receiving \(b.name) (\(sizeText))")
        report(force: true)
    }

    func chunk(_ c: GlassFileChunk) {
        guard var u = upload, u.id == c.id else { return }
        let accepted: Bool = u.accept(c)
        upload = u
        if accepted && !discarding && writeError == nil, let h = handle {
            do {
                try h.write(contentsOf: c.data)
            } catch {
                writeError = "couldn't write the file (\(error.localizedDescription))"
            }
        }
        report(force: false)
    }

    func end(_ e: GlassFileEnd) {
        guard let u = upload, u.id == e.id else {
            onAck?(Msg.fileAck(id: e.id, ok: false, error: UploadProgress.errorUnknown))
            onLog?("file_end for an unknown transfer: \(e.id)")
            return
        }
        let result: (ok: Bool, error: String?) = u.finish(id: e.id)
        closeHandle()
        let url: URL? = fileURL
        let wasDuplicate: Bool = discarding
        let failedWrite: String? = writeError
        upload = nil
        fileURL = nil
        discarding = false
        writeError = nil

        if wasDuplicate {
            onAck?(Msg.fileAck(id: u.id, ok: true))
            onLog?("\(u.name) was already saved: acknowledged without saving again")
            onProgress?(nil)
            return
        }
        if !result.ok || failedWrite != nil {
            if let f = url {
                try? FileManager.default.removeItem(at: f)
            }
            let message: String = failedWrite ?? (result.error ?? "upload failed")
            onAck?(Msg.fileAck(id: u.id, ok: false, error: message))
            onLog?("Upload of \(u.name) failed: \(message)")
            addItem(upload: u, ok: false, error: message, thumbnail: nil)
            onProgress?(nil)
            return
        }
        guard let fileOnDisk = url else {
            let message: String = "no temporary file"
            onAck?(Msg.fileAck(id: u.id, ok: false, error: message))
            onProgress?(nil)
            return
        }
        let progress = TransferProgress(id: u.id, name: u.name, size: u.size, received: u.received,
                                        fraction: 1, saving: true, duplicate: false)
        onProgress?(progress)
        save(fileOnDisk, upload: u)
    }

    /// The link dropped: delete the partial file. A save already under way finishes.
    func linkDropped() {
        if upload != nil {
            discardCurrent(reason: "the link dropped")
        }
    }

    /// Shows the Photos (add only) prompt if the user hasn't been asked yet. Call while the
    /// app is in front.
    func requestPhotosAccessIfNeeded() {
        if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
        }
    }

    /// Deletes temp files left by a previous run.
    func cleanLeftovers() {
        let dir: URL = FileManager.default.temporaryDirectory
        let items: [URL] = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])) ?? []
        for item in items where item.lastPathComponent.hasPrefix(MediaReceiver.tempPrefix) {
            try? FileManager.default.removeItem(at: item)
        }
    }

    // MARK: - Photos

    private func save(_ url: URL, upload u: UploadProgress) {
        let isVideo: Bool = MediaReceiver.isVideo(name: u.name, mime: u.mime)
        let name: String = u.name
        var taken: Date? = nil
        if let ms = u.takenMs, ms > 0 {
            taken = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        }
        let creationDate: Date? = taken
        let resourceType: PHAssetResourceType = isVideo ? .video : .photo
        DispatchQueue.global(qos: .userInitiated).async {
            var thumb: UIImage? = nil
            if !isVideo {
                thumb = MediaReceiver.thumbnail(of: url)
            }
            let thumbnail: UIImage? = thumb
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    DispatchQueue.main.async {
                        self.finishSave(url: url, upload: u, ok: false,
                                        error: "Photos access isn't allowed (Settings › StellrGlass › Photos)",
                                        thumbnail: thumbnail)
                    }
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = name
                    request.addResource(with: resourceType, fileURL: url, options: options)
                    if let d = creationDate {
                        request.creationDate = d
                    }
                }, completionHandler: { success, error in
                    var message: String? = nil
                    if !success {
                        message = error?.localizedDescription ?? "Photos couldn't save it"
                    }
                    let failure: String? = message
                    DispatchQueue.main.async {
                        self.finishSave(url: url, upload: u, ok: success, error: failure, thumbnail: thumbnail)
                    }
                })
            }
        }
    }

    private func finishSave(url: URL, upload u: UploadProgress, ok: Bool, error: String?, thumbnail: UIImage?) {
        try? FileManager.default.removeItem(at: url)
        if ok {
            remember(u.id)
            onLog?("Saved \(u.name) to Photos")
        } else {
            let reason: String = error ?? "unknown error"
            onLog?("Couldn't save \(u.name) to Photos: \(reason)")
        }
        onAck?(Msg.fileAck(id: u.id, ok: ok, error: ok ? nil : error))
        addItem(upload: u, ok: ok, error: error, thumbnail: thumbnail)
        if upload == nil {
            onProgress?(nil)
        }
    }

    // MARK: - Helpers

    private func addItem(upload u: UploadProgress, ok: Bool, error: String?, thumbnail: UIImage?) {
        itemCounter += 1
        var taken: Date? = nil
        if let ms = u.takenMs, ms > 0 {
            taken = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        }
        let item = MediaItem(id: itemCounter, name: u.name, size: u.size,
                             isVideo: MediaReceiver.isVideo(name: u.name, mime: u.mime),
                             taken: taken, received: Date(), ok: ok, error: error, thumbnail: thumbnail)
        onItem?(item)
    }

    private func remember(_ id: String) {
        if savedSet.contains(id) { return }
        savedSet.insert(id)
        savedOrder.append(id)
        if savedOrder.count > MediaReceiver.maxRememberedIDs {
            let extra: Int = savedOrder.count - MediaReceiver.maxRememberedIDs
            for old in savedOrder.prefix(extra) {
                savedSet.remove(old)
            }
            savedOrder.removeFirst(extra)
        }
        UserDefaults.standard.set(savedOrder, forKey: MediaReceiver.savedIDsKey)
    }

    private func discardCurrent(reason: String) {
        closeHandle()
        if let f = fileURL {
            try? FileManager.default.removeItem(at: f)
        }
        if let u = upload {
            onLog?("Discarded the partial upload of \(u.name): \(reason)")
        }
        upload = nil
        fileURL = nil
        writeError = nil
        discarding = false
        onProgress?(nil)
    }

    private func closeHandle() {
        if let h = handle {
            try? h.close()
        }
        handle = nil
    }

    private func report(force: Bool) {
        guard let u = upload else { return }
        let now: TimeInterval = ProcessInfo.processInfo.systemUptime
        if !force && now - lastProgressReport < 0.25 { return }
        lastProgressReport = now
        let progress = TransferProgress(id: u.id, name: u.name, size: u.size, received: u.received,
                                        fraction: u.fraction, saving: false, duplicate: discarding)
        onProgress?(progress)
    }

    static func isVideo(name: String, mime: String?) -> Bool {
        if let m = mime?.lowercased() {
            if m.hasPrefix("video/") { return true }
            if m.hasPrefix("image/") { return false }
        }
        let ext: String = URL(fileURLWithPath: name).pathExtension.lowercased()
        let videoExtensions: Set<String> = ["mp4", "3gp", "mov", "m4v"]
        return videoExtensions.contains(ext)
    }

    /// A small preview of a photo file (runs off the main thread).
    static func thumbnail(of url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
        let w: CGFloat = image.size.width
        let h: CGFloat = image.size.height
        guard w > 0, h > 0 else { return nil }
        let scale: CGFloat = thumbnailSide / max(w, h)
        let size = CGSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
        return image.preparingThumbnail(of: size)
    }
}
