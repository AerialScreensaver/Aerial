//
//  WallpaperCacheCleaner.swift
//  Aerial Companion
//
//  Prunes macOS's wallpaper-agent cache while wallpaper continuity
//  is on. Aerial writes hundreds of fresh JPEGs per session (per
//  video transition, per Space change, per sleep handoff); on
//  macOS 26 the wallpaper agent never cleans its cache, so without
//  intervention this balloons to gigabytes inside
//  `~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/`.
//
//  Gated on `Preferences.replaceWallpaper` — that's the feature
//  that creates the pressure. macOS 26+ only; older versions don't
//  have the bug.
//
//  Thanks to Joshua Michaels for the original implementation in
//  24 Hour Wallpaper.
//

import AppKit
import UniformTypeIdentifiers

final class WallpaperCacheCleaner {
    static let shared = WallpaperCacheCleaner()

    private static let oneGB: Int64 = 1_073_741_824
    private static let maxCacheSize: Int64 = 2 * oneGB
    private static let minCleanInterval: TimeInterval = 5
    /// How recent a file has to be before the cleaner refuses to touch
    /// it. Lower = more aggressive pruning under high churn; higher =
    /// stronger protection for Mission Control thumbnails and
    /// resume-from-sleep continuity. 6h is a compromise — 24h was the
    /// original value but would leave a heavy-churn session
    /// permanently over cap (the cleaner would find no eligible files).
    private static let protectedWindow: TimeInterval = 6 * 60 * 60

    private static let containerFolderRelativePath =
        "Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/"
    private static let cacheFolderImageDirectoryName =
        "com.apple.wallpaper.caches/extension-com.apple.wallpaper.extension.image"

    private static var containerFolderURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(containerFolderRelativePath)
    }

    private var directoryMonitor: DirectoryMonitor?
    private var isCleaning = false
    private var lastCleanDate: Date = .distantPast

    private init() {}

    /// Persisted security-scoped bookmark to the wallpaper-agent
    /// container folder. `nil` means we haven't been granted access.
    /// Stored alongside other companion prefs in `companion.json`
    /// (base64-encoded by JSONEncoder).
    private var bookmarkData: Data? {
        get { Preferences.wallpaperCacheBookmark }
        set { Preferences.wallpaperCacheBookmark = newValue }
    }

    /// True if the user has granted access and we hold a usable bookmark.
    /// Used by Settings UI to choose between "active" status and a
    /// "Grant access" CTA.
    var hasBookmark: Bool { bookmarkData != nil }

    // MARK: - Lifecycle

    /// Called from `WallpaperContinuity.start()` at app launch.
    /// Silently activates monitoring if both prefs are on AND the
    /// user has already granted access in a prior session. Never
    /// prompts here — a surprise NSOpenPanel at launch is jarring.
    func bootstrap() {
        guard #available(macOS 26.0, *) else { return }
        guard Preferences.replaceWallpaper else { return }
        guard Preferences.cleanWallpaperCache else { return }
        guard bookmarkData != nil else { return }
        startMonitoring()
    }

    /// Called whenever `replaceWallpaper` or `cleanWallpaperCache`
    /// might have just changed — settings toggles, the first-launch
    /// wizard's apply, or an explicit "Grant access" button. If both
    /// prefs are on and we lack a bookmark, this is where the
    /// NSOpenPanel fires.
    func reevaluate() {
        guard #available(macOS 26.0, *) else { return }
        let shouldRun = Preferences.replaceWallpaper && Preferences.cleanWallpaperCache
        if shouldRun {
            if bookmarkData != nil {
                startMonitoring()
            } else {
                Task { @MainActor in
                    if await requestAccess() {
                        self.startMonitoring()
                    }
                }
            }
        } else {
            stopMonitoring()
        }
    }

    // MARK: - User access prompt

    /// Presents an NSOpenPanel pre-pointed at the wallpaper-agent
    /// container, asks the user to grant access, and stores a
    /// security-scoped bookmark on success. Exposed so Settings can
    /// also offer a "Grant access" affordance.
    @MainActor
    func requestAccess() async -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        let panel = NSOpenPanel()
        panel.message = "To automatically clean macOS's wallpaper cache, click \"Allow Access\" below."
        panel.prompt = "Allow Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.directoryURL = Self.containerFolderURL
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            warnLog("WallpaperCacheCleaner: user did not grant access")
            return false
        }
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            bookmarkData = data
            debugLog("WallpaperCacheCleaner: saved security-scoped bookmark")
            return true
        } catch {
            errorLog("WallpaperCacheCleaner: failed to create bookmark: \(error)")
            return false
        }
    }

    // MARK: - Monitor

    private func startMonitoring() {
        guard directoryMonitor == nil else { return }
        guard bookmarkData != nil else { return }

        let monitor = DirectoryMonitor(bookmarkData: bookmarkData)
        monitor.onChange = { [weak self] _ in
            self?.cleanIfNeeded()
        }
        do {
            let watchedURL = try monitor.startMonitoring(
                bookmarkSubpath: Self.cacheFolderImageDirectoryName
            )
            self.directoryMonitor = monitor
            debugLog("WallpaperCacheCleaner: monitoring \(watchedURL.path)")
            cleanIfNeeded()
        } catch {
            errorLog("WallpaperCacheCleaner: startMonitoring failed: \(error)")
            // Bookmark likely stale or revoked. Clear so next opt-in
            // re-prompts the user.
            bookmarkData = nil
        }
    }

    private func stopMonitoring() {
        directoryMonitor?.stopMonitoring()
        directoryMonitor = nil
        debugLog("WallpaperCacheCleaner: stopped monitoring")
    }

    // MARK: - Clean pass

    private func cleanIfNeeded() {
        guard !isCleaning else { return }
        guard Date.now.timeIntervalSince(lastCleanDate) > Self.minCleanInterval else { return }
        guard let bookmarkData = bookmarkData else { return }
        isCleaning = true

        let subpath = Self.cacheFolderImageDirectoryName
        DispatchQueue.global(qos: .utility).async { [weak self] in
            Self.performClean(bookmarkData: bookmarkData, subpath: subpath)
            DispatchQueue.main.async {
                self?.lastCleanDate = .now
                self?.isCleaning = false
            }
        }
    }

    /// File-system work, off the main thread. Re-resolves the bookmark
    /// and opens its own short security-scoped access window —
    /// independent from `DirectoryMonitor`'s long-lived one. Both work
    /// because `start/stopAccessingSecurityScopedResource` is
    /// reference-counted.
    private static func performClean(bookmarkData: Data, subpath: String) {
        var isStale = false
        guard let containerURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            errorLog("WallpaperCacheCleaner: failed to resolve bookmark")
            return
        }
        guard containerURL.startAccessingSecurityScopedResource() else {
            errorLog("WallpaperCacheCleaner: failed to start security-scoped access")
            return
        }
        defer { containerURL.stopAccessingSecurityScopedResource() }

        let watchedURL = containerURL.appendingPathComponent(subpath)

        guard var currentSize = DirectoryMonitor.calculateDirectorySize(watchedURL) else { return }
        let startSize = currentSize

        guard currentSize > Self.maxCacheSize else {
            debugLog("WallpaperCacheCleaner: cache size \(ByteCountFormatter.string(fromByteCount: currentSize, countStyle: .file)) under cap, no prune")
            return
        }

        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey,
            .creationDateKey, .contentModificationDateKey,
            .addedToDirectoryDateKey, .contentTypeKey,
        ]
        let keySet = Set(resourceKeys)

        guard let enumerator = FileManager.default.enumerator(
            at: watchedURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        struct Candidate { let url: URL; let date: Date; let size: Int64 }
        var candidates: [Candidate] = []

        while let item = enumerator.nextObject() as? URL {
            guard let values = try? item.resourceValues(forKeys: keySet),
                  values.isRegularFile == true,
                  let contentType = values.contentType,
                  contentType.conforms(to: .image),
                  let fileSize = values.fileSize else { continue }
            let dates = [
                values.creationDate,
                values.contentModificationDate,
                values.addedToDirectoryDate
            ].compactMap { $0 }
            guard let maxDate = dates.max() else { continue }
            candidates.append(Candidate(url: item, date: maxDate, size: Int64(fileSize)))
        }
        candidates.sort { $0.date < $1.date }

        // Don't touch anything younger than `protectedWindow` —
        // keeps recent wallpapers around so resume-from-sleep /
        // Mission Control still finds something fresh to display.
        let cutoff = Date(timeIntervalSinceNow: -Self.protectedWindow)
        var removed = 0
        var bytesRemoved: Int64 = 0
        for candidate in candidates {
            if currentSize <= Self.maxCacheSize { break }
            if candidate.date >= cutoff { break }
            do {
                try FileManager.default.removeItem(at: candidate.url)
                currentSize -= candidate.size
                bytesRemoved += candidate.size
                removed += 1
            } catch {
                warnLog("WallpaperCacheCleaner: failed to remove \(candidate.url.lastPathComponent): \(error)")
            }
        }
        debugLog("WallpaperCacheCleaner: cache size \(ByteCountFormatter.string(fromByteCount: startSize, countStyle: .file)) → pruned \(removed) files (\(ByteCountFormatter.string(fromByteCount: bytesRemoved, countStyle: .file))); now \(ByteCountFormatter.string(fromByteCount: currentSize, countStyle: .file))")
    }
}
