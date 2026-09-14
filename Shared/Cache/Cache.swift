//
//  Cache.swift
//  Aerial
//
//  Created by Guillaume Louel on 06/06/2020.
//  Copyright © 2020 Guillaume Louel. All rights reserved.
//

import Cocoa
import AVKit

#if canImport(CoreWLAN)
import CoreWLAN
#endif

/**
 Aerial's unified Cache management

 Everything Cache related is managed here.

 - Note: Where is our data?

 **Unified Path System (3.3.0+):**

 All Aerial data is now stored in `/Users/Shared/Aerial/` across all macOS versions:
 - `/Users/Shared/Aerial/` : Base directory for all Aerial data
 - `/Users/Shared/Aerial/Cache/` : Video cache
 - `/Users/Shared/Aerial/Thumbnails/` : Thumbnail cache
 - `/Users/Shared/Aerial/Sources/` : Per-source manifests and files
 - `/Users/Shared/Aerial/Logs/` : Application and screensaver logs

 **Benefits:**
 - No more container issues
 - Accessible to all users on the system
 - Consistent across all macOS versions
 - Simpler code and easier debugging

 **Custom Paths:**
 Users can still override the cache location via `PrefsCache.overrideCache` for advanced use cases.
 */

// swiftlint:disable:next type_body_length
struct Cache {
    /**
     Returns the SSID of the Wi-Fi network the user is currently connected to.
     - Note: Returns an empty string if not connected to Wi-Fi or if CoreWLAN is not available (sandboxed extension)
     */
    static var ssid: String {
        #if canImport(CoreWLAN)
        return CWWiFiClient.shared().interface(withName: nil)?.ssid() ?? ""
        #else
        return ""
        #endif
    }

    /// Guards the memoized paths below (`processedSupportPath`,
    /// `_resolvedCachePath`, `_resolvedExternalSourcesRoot`). They are read
    /// from every queue that touches the cache and first-resolved lazily, so
    /// two threads racing the first access could tear the optional String.
    /// Recursive: resolving one path may read a preference whose store
    /// lives under `supportPath`.
    private static let memoLock = NSRecursiveLock()
    nonisolated(unsafe) private static var processedSupportPath = ""   // memoLock

    /**
     Returns Aerial's unified path.

     All data is now stored in `/Users/Shared/Aerial/` across all macOS versions.
     Only the Cache subfolder is relocatable via `PrefsCache.overrideCache`.

     - Note: Returns `/` on failure (extremely rare - would indicate permissions issue)
     */
    static var supportPath: String {
        memoLock.lock(); defer { memoLock.unlock() }
        // Cache the computed value
        if processedSupportPath != "" {
            return processedSupportPath
        }

        let appPath = "/Users/Shared/Aerial"

        // Ensure directory exists
        if FileManager.default.fileExists(atPath: appPath) {
            processedSupportPath = appPath
            return processedSupportPath
        } else {
            debugLog("Creating support directory at \(appPath)")
            do {
                try FileManager.default.createDirectory(
                    atPath: appPath,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                processedSupportPath = appPath
                return appPath
            } catch let error {
                errorLog("FATAL: Couldn't create directory at \(appPath): \(error)")
                return "/"
            }
        }
    }

    /**
     Returns Aerial's video cache path.

     By default returns `/Users/Shared/Aerial/Cache/`. When `PrefsCache.overrideCache` is
     enabled with a valid `cachePath`, returns the custom location instead.

     - Note: Returns `/` on failure (extremely rare).
     */
    nonisolated(unsafe) private static var _resolvedCachePath: String?   // memoLock

    static var path: String {
        memoLock.lock(); defer { memoLock.unlock() }
        if let p = _resolvedCachePath { return p }
        let p = resolveCachePath()
        _resolvedCachePath = p
        return p
    }

    // MARK: - External cache disk image (mount point under /Users/Shared/Aerial)

    /// Where Companion attaches the external-drive sparsebundle. Fixed and
    /// under `supportPath` on purpose: the sandboxed wallpaper extension
    /// can read /Users/Shared/ but never /Volumes/, so the image's contents
    /// are only reachable through a mount point on this side of the wall.
    static var externalCacheMountPoint: String {
        supportPath.appending("/ExternalCache")
    }

    /// Marker written INSIDE the image at creation. Its presence at the
    /// mount point means the image is attached (stat-only, works in the
    /// extension sandbox); it vanishes with the volume on detach.
    static var externalCacheMarkerPath: String {
        externalCacheMountPoint.appending("/.aerial-cache-image")
    }

    /// True when the cache lives in an external disk image (Companion is
    /// responsible for attaching it at `externalCacheMountPoint`).
    static var isExternalImageMode: Bool {
        PrefsCache.overrideCache && !(PrefsCache.externalCacheImagePath ?? "").isEmpty
    }

    /// Where the cache lives, classified once so every gate agrees.
    enum LocationKind: Equatable {
        /// `/Users/Shared/Aerial/Cache`.
        case internalFolder
        /// A user-chosen folder the extension can read (not under /Volumes).
        case customFolder(String)
        /// A 4.0-style plain folder on an external volume. Companion reads
        /// it fine; the sandboxed extension never can. This is what 4.0
        /// users arrive with — Companion offers to convert it into a disk
        /// image (`LegacyExternalCacheMigration`).
        case legacyExternalFolder(String)
        /// Sparsebundle on an external drive, attached at the mount point.
        case externalImage(String)
    }

    /// Pure classifier (unit-tested); `locationKind` feeds it the prefs.
    static func classify(overrideCache: Bool, cachePath: String?, externalCacheImagePath: String?,
                         mountPoint: String) -> LocationKind {
        guard overrideCache else { return .internalFolder }
        if let image = externalCacheImagePath, !image.isEmpty { return .externalImage(image) }
        guard let custom = cachePath, !custom.isEmpty else { return .internalFolder }
        let resolved = URL(fileURLWithPath: custom).standardizedFileURL.path
        if resolved.hasPrefix("/Volumes/"), resolved != mountPoint, !resolved.hasPrefix(mountPoint + "/") {
            return .legacyExternalFolder(custom)
        }
        return .customFolder(custom)
    }

    static var locationKind: LocationKind {
        classify(overrideCache: PrefsCache.overrideCache, cachePath: PrefsCache.cachePath,
                 externalCacheImagePath: PrefsCache.externalCacheImagePath, mountPoint: externalCacheMountPoint)
    }

    /// The 4.0-style external folder, when that is the configuration.
    static var legacyExternalFolderPath: String? {
        if case .legacyExternalFolder(let folder) = locationKind { return folder }
        return nil
    }

    /// Live (never memoized). False in external image mode while the
    /// image is not attached, and for a legacy external folder while its
    /// drive is not connected. Both processes must then treat the cache
    /// as unavailable — no downloads into the bare mount point or onto
    /// the boot drive, no fallback to the internal Cache folder, no
    /// reaping, no rotation.
    static var isAvailable: Bool {
        switch locationKind {
        case .externalImage:
            return FileManager.default.fileExists(atPath: externalCacheMarkerPath)
        case .legacyExternalFolder(let folder):
            return FileManager.default.fileExists(atPath: folder)
        case .internalFolder, .customFolder:
            return true
        }
    }

    private static func resolveCachePath() -> String {
        let effectivePath: String
        switch locationKind {
        case .externalImage:
            // Image layout: `Cache/` (videos) beside `Expansions/` (packs)
            // at the mount root. The constant, not `PrefsCache.cachePath`:
            // a stale or foreign value must never redirect the extension.
            effectivePath = externalCacheMountPoint.appending("/Cache")
            if !isAvailable {
                debugLog("💽 External cache image not attached at \(externalCacheMountPoint) — cache unavailable")
                // Do NOT create `Cache/` inside the bare mount point.
                return effectivePath
            }
        case .legacyExternalFolder(let folder):
            // 4.0 layout on an external volume. Same contract as image
            // mode: the folder IS the cache whether or not the drive is
            // here — never fall back to the internal folder (that is how
            // boot drives silently filled up while a drive was unplugged),
            // never create anything. `isAvailable` follows the drive;
            // Companion offers the conversion; the extension can't read
            // it either way.
            let mounted = FileManager.default.fileExists(atPath: folder)
            warnLog("💽 legacy external cache folder \(folder) (4.0 layout, \(mounted ? "mounted" : "drive not connected")) — the wallpaper extension cannot read it; conversion pending")
            return folder
        case .customFolder(let custom):
            if FileManager.default.fileExists(atPath: custom) {
                effectivePath = custom
            } else {
                debugLog("Custom cache path \(custom) not found, falling back to default")
                effectivePath = supportPath.appending("/Cache")
            }
        case .internalFolder:
            effectivePath = supportPath.appending("/Cache")
        }

        if !FileManager.default.fileExists(atPath: effectivePath) {
            do {
                try FileManager.default.createDirectory(atPath: effectivePath,
                    withIntermediateDirectories: true, attributes: nil)
            } catch {
                errorLog("FATAL: Couldn't create Cache directory: \(error)")
                return "/"
            }
        }
        return effectivePath
    }

    /// Invalidate cached path values (call after changing cache location settings).
    static func invalidateCachePath() {
        memoLock.lock(); defer { memoLock.unlock() }
        _resolvedCachePath = nil
    }

    // MARK: - Sources roots (default + optional external Expansions root)

    /// The default, always-present Sources root: `/Users/Shared/Aerial/Sources`.
    static var defaultSourcesRoot: String {
        supportPath.appending("/Sources")
    }

    nonisolated(unsafe) private static var _resolvedExternalSourcesRoot: String??   // memoLock

    /// The custom cache LOCATION (as opposed to the cache folder): the
    /// image's mount point in image mode, the chosen folder for a plain
    /// custom cache, nil for the default location. Expansion packs kept
    /// "at the cache location" live in `<locationRoot>/Expansions`.
    static var locationRoot: String? {
        guard PrefsCache.overrideCache else { return nil }
        if isExternalImageMode { return externalCacheMountPoint }
        guard let custom = PrefsCache.cachePath, !custom.isEmpty else { return nil }
        return custom
    }

    /// Where packs go when `expansionsAtCacheLocation` is on, whether or
    /// not the folder exists yet (Companion creates it; the extension only
    /// reads). nil without a custom location.
    static var expansionsRootCandidate: String? {
        locationRoot.map { $0.appending("/Expansions") }
    }

    /// The external root for non-cacheable Expansion sources — derived
    /// from the cache location (`<location>/Expansions`) when the user
    /// enabled the sub-option, or nil. Memoized; call
    /// `invalidateSourcesRoots()` after settings changes or image
    /// attach/detach. No fallback location: while the image is detached
    /// the packs stored in it are simply hidden.
    ///
    /// Inside the disk image the sandboxed wallpaper extension CAN read
    /// them (mount point under /Users/Shared/); packs stored directly on
    /// a /Volumes path never were playable there — see
    /// `ExternalCacheImage`.
    static var externalSourcesRoot: String? {
        memoLock.lock(); defer { memoLock.unlock() }
        if let resolved = _resolvedExternalSourcesRoot { return resolved }
        let resolved = resolveExternalSourcesRoot()
        _resolvedExternalSourcesRoot = resolved
        return resolved
    }

    private static func resolveExternalSourcesRoot() -> String? {
        guard PrefsCache.expansionsAtCacheLocation, let root = expansionsRootCandidate else { return nil }
        guard isAvailable else {
            debugLog("💽 Expansions root \(root) hidden — cache location unavailable (image not attached)")
            return nil
        }
        guard FileManager.default.fileExists(atPath: root) else {
            debugLog("💽 Expansions root \(root) does not exist yet — nothing to scan")
            return nil
        }
        debugLog("💽 Expansions at \(root)")
        return root
    }

    /// Every root to scan for source folders, default root first (it wins
    /// on name collisions).
    static var sourcesRoots: [String] {
        var roots = [defaultSourcesRoot]
        if let external = externalSourcesRoot {
            roots.append(external)
        }
        return roots
    }

    /// Invalidate the memoized external root (settings change, drive
    /// mount/unmount).
    static func invalidateSourcesRoots() {
        memoLock.lock(); defer { memoLock.unlock() }
        _resolvedExternalSourcesRoot = nil
    }
    /**
     Returns Aerial's thumbnail cache path, creating it if needed.

     Always returns `/Users/Shared/Aerial/Thumbnails/` across all macOS versions.

     - Note: Returns `/` on failure (extremely rare).
     */
    static let thumbnailsPath: String = {
        let path = Cache.supportPath.appending("/Thumbnails")

        if FileManager.default.fileExists(atPath: path as String) {
            return path
        } else {
            do {
                try FileManager.default.createDirectory(atPath: path,
                                                withIntermediateDirectories: true, attributes: nil)
                return path
            } catch let error {
                errorLog("FATAL : Couldn't create Thumbnails directory in Aerial's AppSupport directory: \(error)")
                return "/"
            }
        }
    }()

    /// This clears the whole cache. User beware !
    static func clearCache() {
        guard isAvailable else {
            debugLog("💽 clearCache skipped — external cache image not attached")
            return
        }
        let pathURL = URL(fileURLWithPath: path)
        do {
            let directoryContent = try FileManager.default.contentsOfDirectory(at: pathURL, includingPropertiesForKeys: nil)
            let videoURLs = directoryContent.filter { $0.pathExtension == "mov" }

            for video in videoURLs {
                try? FileManager.default.removeItem(at: video)
            }
        } catch {
            errorLog("Error during removal of videos in wrong format, please report")
            errorLog(error.localizedDescription)
        }
    }

    static func clearNonCacheableSources() {
        // Then we need to look at individual online sources
        // let onlineVideos = VideoList.instance.videos.filter({ !$0.source.isCachable })

        for source in SourceList.foundSources.filter({!$0.isCachable}) {
            let pathSource = URL(fileURLWithPath: source.folderPath)
            if FileManager.default.fileExists(atPath: pathSource.path) {
                do {
                    let directoryContent = try FileManager.default.contentsOfDirectory(at: pathSource, includingPropertiesForKeys: nil)

                    let videoURLs = directoryContent.filter { $0.pathExtension == "mov" }

                    for video in videoURLs {
                        debugLog("Removing file : \(video)")
                        try? FileManager.default.removeItem(at: video)
                    }

                } catch {
                    errorLog("Error during removing of videos in wrong format, please report")
                    errorLog(error.localizedDescription)
                }
            }
        }

    }

    // MARK: - About the cache

    /**
     Do we still have a bit of free space (0.5 GB)

     Returns `true` unconditionally when `PrefsCache.unlimitedCache` is set,
     so eviction paths short-circuit and `freeCache()` becomes a no-op.
     */
    static func hasSomeFreeSpace() -> Bool {
        if PrefsCache.unlimitedCache { return true }
        return size() < PrefsCache.cacheLimit - 0.5
    }

    /**
     Returns the cache size in GB as a string (eg. 5.1 GB)
     */
    static func sizeString() -> String {
        let pathURL = Foundation.URL(fileURLWithPath: path)

        // check if the url is a directory
        if (try? pathURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let folderSize = shallowAllocatedSize(of: pathURL)
            let byteCountFormatter =  ByteCountFormatter()
            byteCountFormatter.allowedUnits = .useGB
            byteCountFormatter.countStyle = .file
            let sizeToDisplay = byteCountFormatter.string(for: folderSize) ?? ""
            return sizeToDisplay
        }

        // In case it fails somehow
        return "No cache found"
    }

    // MARK: - Helpers

    /**
     Returns cache size in GB
     */
    /// Allocated bytes of the regular files directly inside `url`. The
    /// cache folder is flat (`.mov` files); subfolders such as
    /// `Expansions/` beside a custom cache are NOT part of the cache and
    /// must not count against its budget (`hasSomeFreeSpace` would
    /// otherwise evict cacheable videos to make room for packs it can
    /// never reclaim). Matches `clearCache` / the reaper, both shallow.
    private static func shallowAllocatedSize(of url: URL) -> Int {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return 0 }
        return entries.reduce(0) { total, entry in
            guard let values = try? entry.resourceValues(forKeys: keys), values.isRegularFile == true else { return total }
            return total + (values.totalFileAllocatedSize ?? 0)
        }
    }

    static func size() -> Double {
        let pathURL = URL(fileURLWithPath: path)

        // check if the url is a directory
        if (try? pathURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let folderSize = shallowAllocatedSize(of: pathURL)

            return Double(folderSize) / 1000000000
        }

        return 0
    }

    static func getDirectorySize(directory: String) -> Double {
        if FileManager.default.fileExists(atPath: directory) {
            let pathURL = URL(fileURLWithPath: directory)

            // check if the url is a directory
            if (try? pathURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                var folderSize = 0
                (FileManager.default.enumerator(at: pathURL, includingPropertiesForKeys: nil)?.allObjects as? [URL])?.lazy.forEach {
                    folderSize += (try? $0.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
                }

                return Double(folderSize) / 1000000000
            }

            return 0
        } else {
            return 0
        }
    }

    /// Total size of the installed Expansion packs (their own folders,
    /// beside the cache). Never part of the cache budget — see
    /// `hasSomeFreeSpace()`, which compares the cache folder alone.
    static func packsSize() -> Double {
        var totalSize: Double = 0
        for source in SourceList.foundSources where source.isExpansionPack {
            totalSize += getDirectorySize(directory: source.folderPath)
        }

        return totalSize
    }

    /**
    Can we safely use network ?
    
    Depending on user's settings, they may not be on a trusted network.
    - Note: If a user disabled cache management (full manual mode), this will always be true.
    */
    static func canNetwork() -> Bool {
        if !PrefsCache.enableManagement {
            return true
        }

        if PrefsCache.restrictOnWiFi {
            // If we are not connected to WiFi we allow
            if Cache.ssid == "" || PrefsCache.allowedNetworks.contains(ssid) {
                return true
            } else {
                return false
            }
        } else {
            return true
        }
    }

    // MARK: - Eviction

    /// Cached videos that are safe to evict — from a cacheable source and
    /// not a favourite — oldest file first (creation date). `cutoff`
    /// restricts the list to files older than that date (the Replace
    /// cadence); nil means every candidate, which is what a manual trim
    /// needs. Hidden videos are included (they go first in every evictor).
    static func evictionCandidates(olderThan cutoff: Date?) -> [AerialVideo] {
        let currentlyCached = VideoList.instance.videos.filter {
            $0.isAvailableOffline && $0.source.isCachable && !PrefsVideos.favorites.contains($0.id)
        }
        var dated: [(date: Date, video: AerialVideo)] = []
        for video in currentlyCached {
            // A video can vanish between enumeration and stat (another
            // eviction pass, the user clearing the cache, Time Machine
            // pruning) — skip it rather than crash.
            guard let path = VideoCache.cachePath(forVideo: video),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let creationDate = attributes[.creationDate] as? Date
            else { continue }
            if let cutoff, creationDate >= cutoff { continue }
            dated.append((date: creationDate, video: video))
        }
        // Stable on equal dates — two downloads finishing in the same
        // second used to collide in a dictionary and one silently vanished.
        return dated.enumerated()
            .sorted { lhs, rhs in
                lhs.element.date != rhs.element.date
                    ? lhs.element.date < rhs.element.date
                    : lhs.offset < rhs.offset
            }
            .map(\.element.video)
    }

    /// The Replace-cadence cutoff, or nil for "Never".
    static func rotationCutoffDate(now: Date = Date()) -> Date? {
        switch PrefsCache.cachePeriodicity {
        case .daily: return Calendar.current.date(byAdding: .day, value: -1, to: now)
        case .weekly: return Calendar.current.date(byAdding: .day, value: -7, to: now)
        case .monthly: return Calendar.current.date(byAdding: .month, value: -1, to: now)
        case .never: return nil
        }
    }

    static func outdatedVideos() -> [AerialVideo] {
        guard PrefsCache.enableManagement else {
            return []
        }
        guard isAvailable else {
            debugLog("💽 outdatedVideos skipped — external cache image not attached")
            return []
        }
        guard let cutoffDate = rotationCutoffDate() else {
            return []
        }
        let outdated = evictionCandidates(olderThan: cutoffDate)
        debugLog("Cache rotation: cutoff=\(cutoffDate), \(outdated.count) outdated candidate(s)")
        return outdated
    }

    /// Delete every cached video the user hid. Returns the count removed.
    @discardableResult
    static func deleteHiddenCachedVideos() -> Int {
        var removed = 0
        for video in VideoList.instance.videos.filter({ PrefsVideos.hidden.contains($0.id) && $0.isAvailableOffline }) {
            debugLog("Deleting hidden video \(video.secondaryName)")
            do {
                let path = VideoList.instance.localPathFor(video: video)
                try FileManager.default.removeItem(atPath: path)
                removed += 1
            } catch {
                errorLog("Could not delete video : \(video.secondaryName)")
            }
        }
        return removed
    }

    /// Scheduled rotation: hidden videos first, then outdated ones (out of
    /// rotation before in rotation), oldest first, until under the limit.
    /// `protecting` = ids that must survive — the videos on screen right
    /// now (callers read them from the wallpaper status echo).
    static func freeCache(protecting protected: Set<String> = []) {
        guard PrefsCache.enableManagement else {
            return
        }
        guard isAvailable else {
            debugLog("💽 freeCache skipped — external cache image not attached")
            return
        }

        // One summary line per rotation pass, on every exit path, so a field
        // log tells "nothing older than the cutoff" from "catalog empty".
        var removed = 0
        defer {
            debugLog("Cache rotation: removed \(removed) video(s), size now \(String(format: "%.1f", size())) GB (limit \(String(format: "%.1f", PrefsCache.cacheLimit)) GB)")
        }

        // Step 1 : Delete hidden videos
        debugLog("Looking for hidden videos to delete...")
        removed += deleteHiddenCachedVideos()

        // We may be good ?
        if hasSomeFreeSpace() {
            return
        }

        // Step 2 + 3 : outdated videos, out of rotation first, then the rest
        let evictables = outdatedVideos()
        if evictables.isEmpty {
            debugLog("No outdated videos, we won't delete anything")
            return
        }
        removed += evict(evictables, protecting: protected, reason: "outdated")
        // At this point we can't do more
    }

    /// Two passes over `candidates` (already oldest first): videos out of
    /// the current rotation, then the ones still in rotation, skipping
    /// `protecting`; stops as soon as `hasSomeFreeSpace()`. Returns the
    /// count removed.
    private static func evict(_ candidates: [AerialVideo], protecting protected: Set<String>, reason: String) -> Int {
        var removed = 0
        let inRotation = Set(VideoList.instance.currentRotation().map(\.id))
        debugLog("Looking for \(reason) videos to remove (candidates : \(candidates.count))")
        for pass in 0..<2 {
            for video in candidates {
                if hasSomeFreeSpace() {
                    return removed
                }
                let rotating = inRotation.contains(video.id)
                // First pass spares in-rotation videos; the second takes them.
                if (pass == 0) == rotating {
                    continue
                }
                if protected.contains(video.id) {
                    debugLog("\(video.secondaryName) is currently playing, keeping")
                    continue
                }
                guard let path = VideoCache.cachePath(forVideo: video) else { continue }
                debugLog("Removing \(reason) video \(rotating ? "that was in rotation" : "not in rotation"): \(video.secondaryName)")
                do {
                    try FileManager.default.removeItem(atPath: path)
                    removed += 1
                } catch {
                    errorLog("Could not delete video : \(video.secondaryName)")
                }
            }
        }
        return removed
    }

    // MARK: - Manual trim (Settings → "Trim Cache to Limit")

    struct TrimPlan {
        let videos: [AerialVideo]
        let bytes: Int
        /// The size the trim aims for: the limit minus the same 0.5 GB
        /// headroom `hasSomeFreeSpace()` uses.
        let targetGB: Double
        var isEmpty: Bool { videos.isEmpty }
    }

    /// What a manual trim would delete, without touching disk, so the UI
    /// can say exactly what will go. Same candidate rules as the rotation
    /// (cacheable, not favourite) but no cadence cutoff; hidden first, out
    /// of rotation before in rotation, oldest first; `protecting` never
    /// selected. Empty when unlimited, unavailable, or already under target.
    static func trimPlan(protecting protected: Set<String>) -> TrimPlan {
        let targetGB = PrefsCache.cacheLimit - 0.5
        let empty = TrimPlan(videos: [], bytes: 0, targetGB: targetGB)
        guard !PrefsCache.unlimitedCache, isAvailable else { return empty }
        let currentBytes = shallowAllocatedSize(of: URL(fileURLWithPath: path))
        let targetBytes = Int(max(0, targetGB) * 1_000_000_000)
        guard currentBytes > targetBytes else { return empty }

        let hidden = Set(PrefsVideos.hidden)
        let inRotation = Set(VideoList.instance.currentRotation().map(\.id))
        var byId: [String: AerialVideo] = [:]
        var candidates: [CacheTrimPlanner.Candidate] = []
        for (order, video) in evictionCandidates(olderThan: nil).enumerated() {
            guard let cachePath = VideoCache.cachePath(forVideo: video),
                  let bytes = try? URL(fileURLWithPath: cachePath)
                      .resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize
            else { continue }
            byId[video.id] = video
            candidates.append(CacheTrimPlanner.Candidate(
                id: video.id, bytes: bytes,
                isHidden: hidden.contains(video.id), inRotation: inRotation.contains(video.id),
                order: order
            ))
        }
        let picked = CacheTrimPlanner.plan(currentBytes: currentBytes, targetBytes: targetBytes,
                                           candidates: candidates, protecting: protected)
        let videos = picked.ids.compactMap { byId[$0] }
        debugLog("Cache trim: plan \(videos.count) video(s) / \(String(format: "%.1f", Double(picked.bytes) / 1e9)) GB (size \(String(format: "%.1f", Double(currentBytes) / 1e9)) GB → target \(String(format: "%.1f", targetGB)) GB, reached=\(picked.reachedTarget))")
        return TrimPlan(videos: videos, bytes: picked.bytes, targetGB: targetGB)
    }

    /// Delete the planned files; returns what was actually removed. The
    /// caller regenerates playlists and notifies; a manual trim deliberately
    /// does NOT stamp `lastRotationRun` (it must not push the scheduled
    /// rotation out by a whole cadence).
    static func applyTrim(_ plan: TrimPlan) -> (removed: Int, bytes: Int) {
        var removed = 0
        var bytes = 0
        for video in plan.videos {
            guard let cachePath = VideoCache.cachePath(forVideo: video) else { continue }
            let size = (try? URL(fileURLWithPath: cachePath)
                .resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
            do {
                try FileManager.default.removeItem(atPath: cachePath)
                removed += 1
                bytes += size
            } catch {
                errorLog("Cache trim: could not delete \(video.secondaryName): \(error.localizedDescription)")
            }
        }
        debugLog("Cache trim: removed \(removed) video(s) / \(String(format: "%.1f", Double(bytes) / 1e9)) GB, size now \(String(format: "%.1f", size())) GB (limit \(String(format: "%.1f", PrefsCache.cacheLimit)) GB)")
        return (removed, bytes)
    }

}

/// Pure "what to delete" for a manual cache trim — no filesystem, no
/// singletons, so it can be unit tested. Tiers: hidden first, then out of
/// rotation, then in rotation; oldest first within a tier (`order` is the
/// caller's oldest-first rank); protected ids never selected; stops once
/// the projected size is under the target.
enum CacheTrimPlanner {
    struct Candidate {
        let id: String
        let bytes: Int
        let isHidden: Bool
        let inRotation: Bool
        let order: Int
    }

    struct Result: Equatable {
        let ids: [String]
        let bytes: Int
        /// False when every eligible candidate was taken and the size is
        /// still above the target (everything else is protected).
        let reachedTarget: Bool
    }

    static func plan(currentBytes: Int, targetBytes: Int, candidates: [Candidate], protecting: Set<String>) -> Result {
        guard currentBytes > targetBytes else {
            return Result(ids: [], bytes: 0, reachedTarget: true)
        }
        let eligible = candidates.filter { !protecting.contains($0.id) }
        let tiers: [[Candidate]] = [
            eligible.filter { $0.isHidden },
            eligible.filter { !$0.isHidden && !$0.inRotation },
            eligible.filter { !$0.isHidden && $0.inRotation },
        ].map { tier in tier.sorted { $0.order < $1.order } }

        var remaining = currentBytes
        var ids: [String] = []
        var freed = 0
        for tier in tiers {
            for candidate in tier where remaining > targetBytes {
                ids.append(candidate.id)
                freed += candidate.bytes
                remaining -= candidate.bytes
            }
        }
        return Result(ids: ids, bytes: freed, reachedTarget: remaining <= targetBytes)
    }
}

#if COMPANION_APP
extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
#endif
