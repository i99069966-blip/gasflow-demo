import Foundation

/// Copies recordings and exports into a folder the user picked in the Files app (Google Drive,
/// iCloud Drive, OneDrive, …). The cloud app behind that folder does the upload, so no account or
/// API access is needed in GasCam. The folder is remembered as a bookmark.
enum CloudSync {
    private static let bookmarkKey = "cloud.folderBookmark"
    private static let nameKey = "cloud.folderName"
    private static let afterRecordingKey = "cloud.afterRecording"
    private static let afterExportKey = "cloud.afterExport"
    private static let queue = DispatchQueue(label: "gascam.cloud", qos: .utility)
    private static var d: UserDefaults { .standard }

    /// Name of the chosen folder (nil = none).
    static var folderName: String? { d.data(forKey: bookmarkKey) == nil ? nil : d.string(forKey: nameKey) }
    static var isConfigured: Bool { d.data(forKey: bookmarkKey) != nil }

    static var afterRecording: Bool {
        get { d.object(forKey: afterRecordingKey) == nil ? true : d.bool(forKey: afterRecordingKey) }
        set { d.set(newValue, forKey: afterRecordingKey) }
    }
    static var afterExport: Bool {
        get { d.object(forKey: afterExportKey) == nil ? true : d.bool(forKey: afterExportKey) }
        set { d.set(newValue, forKey: afterExportKey) }
    }

    /// Remember a folder returned by the folder picker.
    static func setFolder(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        d.set(data, forKey: bookmarkKey)
        d.set(url.lastPathComponent, forKey: nameKey)
    }

    static func clear() {
        d.removeObject(forKey: bookmarkKey)
        d.removeObject(forKey: nameKey)
    }

    private static func resolve() -> URL? {
        guard let data = d.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            d.set(fresh, forKey: bookmarkKey)
        }
        return url
    }

    /// Copies files or whole folders into the sync folder (same names; an existing copy is replaced).
    /// `completion` on the main thread with a message for the user.
    static func copy(_ items: [URL], completion: @escaping (String) -> Void) {
        func done(_ m: String) { DispatchQueue.main.async { completion(m) } }
        let list = items.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !list.isEmpty else {
            done(L("没有可复制的文件"))
            return
        }
        queue.async {
            guard let root = resolve() else {
                done(L("同步文件夹不可用，请在设置里重新选择"))
                return
            }
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            let fm = FileManager.default
            var n = 0
            var failed: String?
            for item in list {
                let target = root.appendingPathComponent(item.lastPathComponent)
                var coordError: NSError?
                NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordError) { dst in
                    do {
                        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                        try fm.copyItem(at: item, to: dst)
                        n += 1
                    } catch {
                        failed = error.localizedDescription
                    }
                }
                if let e = coordError { failed = e.localizedDescription }
            }
            let name = root.lastPathComponent
            if let failed {
                done(L("复制到同步文件夹失败") + ": " + failed)
            } else {
                done(String(format: L("已复制 %d 项到同步文件夹“%@”（由网盘 App 上传）"), n, name))
            }
        }
    }

    /// The .mov / .mp4 of a recording together with its .json and .csv.
    static func recordingFiles(_ movie: URL) -> [URL] {
        let base = movie.deletingPathExtension()
        return [movie, base.appendingPathExtension("json"), base.appendingPathExtension("csv")]
    }
}
