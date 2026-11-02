//
//  DirectoryMonitor.swift
//  Aerial Companion
//
//  Minimal DispatchSource-based directory watcher. Opens an O_EVTONLY
//  file descriptor on the requested folder and keeps it open until
//  `stopMonitoring()` is called.
//
//  Companion-only. Used by `MyVideosWatcher`.
//

import Foundation

final class DirectoryMonitor {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    /// Invoked on each `.write` event with the watched directory URL.
    var onChange: ((URL) -> Void)?

    /// Start watching a plain filesystem path — for world-readable
    /// locations (e.g. /Users/Shared/…) that need no security scope.
    func startMonitoring(path: String) throws {
        guard source == nil else { return }
        let watchedURL = URL(fileURLWithPath: path)
        let fd = open(watchedURL.path, O_EVTONLY)
        guard fd >= 0 else {
            throw NSError(domain: "DirectoryMonitor", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "open() failed for \(watchedURL.path)"
            ])
        }
        fileDescriptor = fd
        installSource(fd: fd, watchedURL: watchedURL)
    }

    private func installSource(fd: Int32, watchedURL: URL) {
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
    }

    func stopMonitoring() {
        if let src = source {
            src.cancel()
            source = nil
        }
    }

    deinit {
        stopMonitoring()
    }
}
