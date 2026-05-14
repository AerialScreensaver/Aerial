//
//  DirectoryMonitor.swift
//  Aerial Companion
//
//  Minimal DispatchSource-based directory watcher. Resolves a
//  security-scoped bookmark, opens an O_EVTONLY file descriptor on
//  the requested subfolder, and keeps both the FD and the security
//  scope alive for the monitor's lifetime — the kernel revokes
//  access on `stopAccessingSecurityScopedResource()`, so we hold it
//  open until `stopMonitoring()` is called.
//
//  Companion-only. Used by `WallpaperCacheCleaner`.
//

import Foundation

final class DirectoryMonitor {
    private let bookmarkData: Data?

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var scopedURL: URL?

    /// Invoked on each `.write` event with the watched directory URL.
    var onChange: ((URL) -> Void)?

    init(bookmarkData: Data?) {
        self.bookmarkData = bookmarkData
    }

    /// Start watching `<bookmarkURL>/<bookmarkSubpath>`. Returns the
    /// resolved watched URL (caller may use it for first-pass scans).
    @discardableResult
    func startMonitoring(bookmarkSubpath: String) throws -> URL {
        if source != nil {
            return scopedURL?.appendingPathComponent(bookmarkSubpath)
                ?? URL(fileURLWithPath: bookmarkSubpath)
        }
        guard let bookmarkData = bookmarkData else {
            throw NSError(domain: "DirectoryMonitor", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No bookmark data"
            ])
        }

        var isStale = false
        let containerURL = try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        guard containerURL.startAccessingSecurityScopedResource() else {
            throw NSError(domain: "DirectoryMonitor", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not start security-scoped access"
            ])
        }
        scopedURL = containerURL

        let watchedURL = containerURL.appendingPathComponent(bookmarkSubpath)
        let fd = open(watchedURL.path, O_EVTONLY)
        guard fd >= 0 else {
            containerURL.stopAccessingSecurityScopedResource()
            scopedURL = nil
            throw NSError(domain: "DirectoryMonitor", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "open() failed for \(watchedURL.path)"
            ])
        }
        fileDescriptor = fd

        let queue = DispatchQueue(label: "com.glouel.aerial.directorymonitor", qos: .utility)
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: queue
        )

        src.setEventHandler { [weak self, watchedURL] in
            self?.onChange?(watchedURL)
        }
        src.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }
        src.resume()
        source = src
        return watchedURL
    }

    func stopMonitoring() {
        if let src = source {
            src.cancel()
            source = nil
        }
        if let scoped = scopedURL {
            scoped.stopAccessingSecurityScopedResource()
            scopedURL = nil
        }
    }

    deinit {
        stopMonitoring()
    }

    /// Total size in bytes of all regular files reachable from `url`.
    static func calculateDirectorySize(_ url: URL) -> Int64? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}
