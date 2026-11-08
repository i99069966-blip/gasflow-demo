import Foundation
import AVFoundation
import Photos
import UIKit

/// Recordings in Documents (.mov + .json + .csv share one base name) and their Photos copies.
enum RecordingStore {
    struct Item: Identifiable, Hashable {
        let url: URL
        let date: Date
        var id: URL { url }
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    static var directory: URL { FramePipeline.documentsURL }

    static func list() -> [Item] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls
            .filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }
            .map { u in
                Item(url: u, date: (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            .sorted { $0.date > $1.date }
    }

    // MARK: Thumbnails

    private static let cache = NSCache<NSURL, UIImage>()

    /// First frame, upright, small.
    static func thumbnail(_ url: URL) async -> UIImage? {
        if let c = cache.object(forKey: url as NSURL) { return c }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 240)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        guard let cg = try? await gen.image(at: .zero).image else { return nil }
        let img = UIImage(cgImage: cg)
        cache.setObject(img, forKey: url as NSURL)
        return img
    }

    // MARK: Rename

    enum RenameError: LocalizedError {
        case invalidName, exists, failed(String)
        var errorDescription: String? {
            switch self {
            case .invalidName: return L("名字不能为空，也不能包含 / 或 :")
            case .exists: return L("已有同名的录像")
            case .failed(let m): return m
            }
        }
    }

    static func sanitized(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for ext in [".mov", ".MOV", ".mp4", ".MP4"] where t.hasSuffix(ext) { t = String(t.dropLast(ext.count)) }
        guard !t.isEmpty, !t.contains("/"), !t.contains(":"), !t.hasPrefix(".") else { return nil }
        return t
    }

    /// Renames the .mov / .mp4 and its .json / .csv. Returns the new movie URL.
    static func renameFiles(_ item: Item, to newName: String) throws -> URL {
        guard let name = sanitized(newName) else { throw RenameError.invalidName }
        let fm = FileManager.default
        let oldBase = item.url.deletingPathExtension()
        let newBase = oldBase.deletingLastPathComponent().appendingPathComponent(name)
        let ext = item.url.pathExtension
        if name == item.name { return item.url }
        let newMovie = newBase.appendingPathExtension(ext)
        if fm.fileExists(atPath: newMovie.path) { throw RenameError.exists }
        do {
            try fm.moveItem(at: item.url, to: newMovie)
            for side in ["json", "csv"] {
                let a = oldBase.appendingPathExtension(side), b = newBase.appendingPathExtension(side)
                if fm.fileExists(atPath: a.path) && !fm.fileExists(atPath: b.path) { try fm.moveItem(at: a, to: b) }
            }
        } catch {
            throw RenameError.failed(error.localizedDescription)
        }
        cache.removeObject(forKey: item.url as NSURL)
        return newMovie
    }

    /// Replaces the Photos copy of a recording: adds the renamed file as a new video, then deletes the
    /// old one (iOS asks the user to confirm the deletion). The old asset is found through the link
    /// stored when it was saved, or (older recordings) by its original file name.
    /// Main-thread completion with a message for the user.
    static func renamePhotosCopy(oldFileName: String, newURL: URL, completion: @escaping (String) -> Void) {
        func done(_ m: String) { DispatchQueue.main.async { completion(m) } }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized || status == .limited else {
                done(L("文件已改名。没有相册的读取权限，相册里的那份没有改。"))
                return
            }
            guard let old = findAsset(fileName: oldFileName) else {
                done(L("文件已改名。相册里没有找到这段录像（可能没有存入相册），相册未改动。"))
                return
            }
            var newID: String?
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                let opts = PHAssetResourceCreationOptions()
                opts.shouldMoveFile = false
                opts.originalFilename = newURL.lastPathComponent
                req.addResource(with: .video, fileURL: newURL, options: opts)
                req.creationDate = old.creationDate
                newID = req.placeholderForCreatedAsset?.localIdentifier
            }, completionHandler: { ok, error in
                guard ok else {
                    done(L("文件已改名，但相册新副本保存失败") + ": \(error?.localizedDescription ?? "")")
                    return
                }
                PhotoLinks.set(nil, for: oldFileName)
                PhotoLinks.set(newID, for: newURL.lastPathComponent)
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.deleteAssets([old] as NSArray)
                }, completionHandler: { deleted, _ in
                    done(deleted ? L("已改名（文件和相册）")
                         : L("已改名。相册里已存新名字的副本，旧的那份没有删除。"))
                })
            })
        }
    }

    // MARK: Delete

    /// Deletes the recordings' .mov / .mp4 + .json + .csv; optionally also their Photos copies
    /// (iOS asks the user to confirm). Main-thread completion with a message.
    static func delete(_ items: [Item], includePhotos: Bool, completion: @escaping (String) -> Void) {
        func done(_ m: String) { DispatchQueue.main.async { completion(m) } }
        let fm = FileManager.default
        var names: [String] = []
        for it in items {
            let base = it.url.deletingPathExtension()
            try? fm.removeItem(at: it.url)
            for side in ["json", "csv"] { try? fm.removeItem(at: base.appendingPathExtension(side)) }
            cache.removeObject(forKey: it.url as NSURL)
            names.append(it.url.lastPathComponent)
        }
        let n = items.count
        guard includePhotos else {
            names.forEach { PhotoLinks.set(nil, for: $0) }
            done(String(format: L("已删除 %d 段录像"), n))
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized || status == .limited else {
                done(L("文件已删除。没有相册的读取权限，相册里的没有删除。"))
                return
            }
            let assets = names.compactMap { findAsset(fileName: $0) }
            names.forEach { PhotoLinks.set(nil, for: $0) }
            guard !assets.isEmpty else {
                done(L("文件已删除。相册里没有找到对应的录像。"))
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }, completionHandler: { ok, _ in
                done(ok ? String(format: L("已删除 %d 段录像（含相册）"), n)
                        : L("文件已删除。相册里的没有删除（已取消）。"))
            })
        }
    }

    private static func findAsset(fileName: String) -> PHAsset? {
        if let id = PhotoLinks.id(for: fileName),
           let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
            return a
        }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = 400
        let assets = PHAsset.fetchAssets(with: .video, options: opts)
        var found: PHAsset?
        assets.enumerateObjects { a, _, stop in
            if PHAssetResource.assetResources(for: a).contains(where: { $0.originalFilename == fileName }) {
                found = a
                stop.pointee = true
            }
        }
        return found
    }
}
