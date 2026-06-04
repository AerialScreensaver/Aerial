//
//  MacOSWallpaperVideoCache.swift
//  Aerial Companion
//
//  macOS downloads its own aerial *wallpaper* videos into a user-owned
//  folder and never prunes them. For users who run Aerial instead of a
//  macOS aerial wallpaper, those .mov files are dead disk space. This
//  helper reports and reclaims them.
//
//  Target: ~/Library/Application Support/com.apple.wallpaper/aerials/videos/
//  Each macOS wallpaper aerial is a single <UUID>.mov owned by the user, so
//  we can delete it directly — no security-scoped bookmark needed (unlike
//  WallpaperCacheCleaner, which reaches into the agent's sandbox container).
//
//  Distinct from:
//   - Aerial's own video library (/Users/Shared/Aerial/Cache), and
//   - the macOS wallpaper *image-frame* cache pruned by WallpaperCacheCleaner.
//
//  NOT the system *screensaver* aerials at
//  /Library/Application Support/com.apple.idleassetsd/ — those are
//  root-owned and out of scope.
//
//  Companion-only module.
//

import Foundation

enum MacOSWallpaperVideoCache {

    struct Usage {
        let bytes: Int64
        let count: Int

        static let none = Usage(bytes: 0, count: 0)
    }

    /// ~/Library/Application Support/com.apple.wallpaper/aerials/videos
    static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/videos",
                                    isDirectory: true)
    }

    /// Total size + count of the `.mov` files macOS has downloaded.
    /// Returns `.none` when the folder is absent (macOS aerials never used).
    /// Walks the filesystem — call off the main thread.
    static func currentUsage() -> Usage {
        var total: Int64 = 0
        var count = 0
        for url in movFiles() {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += Int64(size)
            count += 1
        }
        return Usage(bytes: total, count: count)
    }

    /// Delete every `.mov` in the folder. Leaves manifests, thumbnails and
    /// the Store index untouched. Returns what was actually freed.
    /// Performs disk I/O — call off the main thread.
    @discardableResult
    static func reclaim() -> Usage {
        var freed: Int64 = 0
        var deleted = 0
        for url in movFiles() {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            do {
                try FileManager.default.removeItem(at: url)
                freed += Int64(size)
                deleted += 1
            } catch {
                errorLog("MacOSWallpaperVideoCache: failed to delete \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if deleted > 0 {
            infoLog("MacOSWallpaperVideoCache: reclaimed \(deleted) video(s), freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))")
        } else {
            debugLog("MacOSWallpaperVideoCache: nothing to reclaim")
        }
        return Usage(bytes: freed, count: deleted)
    }

    // MARK: - Private

    /// The `.mov` files in the cache directory. Empty when the folder is
    /// missing (the `try?` returns nil) — both callers treat that as "none".
    private static func movFiles() -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return items.filter { $0.pathExtension.lowercased() == "mov" }
    }
}
