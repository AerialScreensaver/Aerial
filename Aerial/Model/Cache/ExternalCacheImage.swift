//
//  ExternalCacheImage.swift
//  Aerial
//
//  Companion-only. Owns the sparsebundle disk image that backs the video
//  cache when the user keeps it on an external drive. The image lives ON
//  the drive; Companion attaches it at `Cache.externalCacheMountPoint`
//  (/Users/Shared/Aerial/ExternalCache) with hdiutil, so both processes
//  see ordinary local paths under /Users/Shared/. The sandboxed wallpaper
//  extension can read /Users/Shared/ but never /Volumes/ (kernel sandbox
//  profile, path based — verified 2026-07-15 and again 2026-09-11), so a
//  mount point on this side of the wall is the only way videos stored on
//  an external volume can play. The volume I/O happens in the disk-image
//  driver, outside the extension's sandbox.
//
//  No root anywhere: `-mountpoint`, `-nobrowse`, `-owners off` and
//  `-noautofsck` are all unprivileged; the mount point is owned by the
//  user. Tahoe prints a deprecation warning for every legacy hdiutil
//  invocation (pointing at `diskutil image …`) — the commands still work,
//  the warning is filtered out of error reports, and every command line
//  is built in one place so the tool can be swapped later.
//
//  All logging is prefixed 💽.
//

import AppKit
import Foundation

final class ExternalCacheImage {

    static let shared = ExternalCacheImage()

    static let bundleName = "Aerial Cache.sparsebundle"
    static let volumeName = "Aerial Cache"

    /// Posted on main after every state change. AppDelegate's observer
    /// runs `refreshConsumers(reason:)`; the settings panel re-reads `state`.
    static let stateDidChangeNotification = Notification.Name("com.glouel.aerial.externalCacheStateDidChange")
    /// Posted on main when a background attach (launch, drive mounted,
    /// Reconnect) fails. `userInfo["error"]` is the human-readable message.
    static let attachFailedNotification = Notification.Name("com.glouel.aerial.externalCacheAttachFailed")

    /// How hard to try when detaching. `.polite` is a single attempt
    /// (fails while anything holds files open — the extension playing
    /// from the image, a download in flight); `.escalate` retries with
    /// `-force` after a second; `.force` goes straight to `-force` (drive
    /// yanked: clear the zombie mount).
    enum DetachMode {
        case polite, escalate, force
    }

    enum State: Equatable {
        /// Not in external image mode.
        case off
        case attached(device: String)
        case detached
        /// The drive holding the image is not mounted.
        case backingVolumeMissing
        case failed(String)
    }

    /// Read on the main thread (settings panel); written through
    /// `setState`, which always hops to main.
    private(set) var state: State = .off

    private let queue = DispatchQueue(label: "com.glouel.aerial.external-cache-image", qos: .userInitiated)
    private let hdiutilPath = "/usr/bin/hdiutil"
    /// Self-heal: re-attach when the image was detached behind our back
    /// (instance handover race, a manual `hdiutil detach`, Finder).
    private var reconcileTimer: DispatchSourceTimer?
    private static let reconcileInterval: TimeInterval = 60

    private init() {}

    struct CommandError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Queries

    static var mountPoint: String { Cache.externalCacheMountPoint }

    /// The configured bundle path, or nil outside external image mode.
    var imagePath: String? {
        Cache.isExternalImageMode ? PrefsCache.externalCacheImagePath : nil
    }

    /// The drive holding the image is mounted (stat of the bundle's
    /// Info.plist — cheap and safe while the drive is asleep).
    var backingVolumeMounted: Bool {
        guard let image = imagePath else { return false }
        return Self.backingVolumeMounted(image: image)
    }

    private static func backingVolumeMounted(image: String) -> Bool {
        FileManager.default.fileExists(atPath: image + "/Info.plist")
    }

    /// True when a volume is mounted at the mount point: its volume
    /// identifier differs from its parent directory's. Two stats, no
    /// process spawn — cheap enough to call from the UI.
    static func isAttached() -> Bool {
        let mp = URL(fileURLWithPath: mountPoint, isDirectory: true)
        let parent = mp.deletingLastPathComponent()
        guard let a = try? mp.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let b = try? parent.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else {
            return false
        }
        return !a.isEqual(b)
    }

    /// Whether `volumeURL` (from an NSWorkspace mount notification) is the
    /// drive that holds the image.
    func isBackingVolume(_ volumeURL: URL) -> Bool {
        guard let image = imagePath else { return false }
        let root = volumeURL.path.hasSuffix("/") ? volumeURL.path : volumeURL.path + "/"
        return image.hasPrefix(root)
    }

    // MARK: - Lifecycle entry points

    /// Launch: synchronous so nothing consumes `Cache.path` before the
    /// image is up (attach takes ~1 s; bounded by the command timeout).
    /// No-op for users without the option.
    func attachAtLaunch() {
        guard Cache.isExternalImageMode, let image = imagePath else {
            state = .off
            return
        }
        performAttach(image: image, reason: "launch", notify: false)
        startReconcile()
    }

    /// Periodic + post-launch reconcile. The instance handover
    /// (`terminateOlderInstances`) is the known case: the older instance's
    /// terminate handler runs while the newcomer is still inside
    /// `applicationDidFinishLaunching`, i.e. before LaunchServices lists it,
    /// so the old one may detach believing it is the last user. A quick
    /// re-check 5 s after launch and one stat pair per minute cover that
    /// and every other external detach.
    private func startReconcile() {
        queue.asyncAfter(deadline: .now() + 5) { self.reconcile(reason: "post-launch") }
        guard reconcileTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.reconcileInterval, repeating: Self.reconcileInterval, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in self?.reconcile(reason: "periodic") }
        reconcileTimer = timer
        timer.resume()
    }

    /// On `queue`. Attach if we should be attached and are not.
    private func reconcile(reason: String) {
        guard Cache.isExternalImageMode, let image = imagePath else { return }
        guard !SystemSleepState.shared.isAsleep else { return }
        guard Self.backingVolumeMounted(image: image), !Self.isAttached() else { return }
        debugLog("💽 reconcile (\(reason)): image should be attached but is not — attaching")
        performAttach(image: image, reason: "reconcile/\(reason)", notify: true)
    }

    /// Background attach (drive mounted, Reconnect button). Idempotent.
    func attachIfNeeded(reason: String) {
        guard Cache.isExternalImageMode, let image = imagePath else { return }
        queue.async { self.performAttach(image: image, reason: reason, notify: true) }
    }

    /// Settings panel, step 1 (background): attach `image` without touching
    /// prefs. Returns the device entry for `adopt`.
    func attachCandidate(image: String) throws -> String {
        try attach(image: image)
    }

    /// Settings panel, step 2 (main thread): make the already-attached
    /// `image` the cache. Only reached after `attachCandidate` succeeded,
    /// so a failure never disturbs the previous configuration.
    func adopt(image: String, device: String) {
        PrefsCache.externalCacheImagePath = image
        PrefsCache.cachePath = Self.mountPoint
        PrefsCache.overrideCache = true
        Cache.invalidateCachePath()
        setState(.attached(device: device), notify: true)
        startReconcile()
    }

    /// Detach if a volume is mounted at the mount point. Always runs on the
    /// helper's queue — a busy volume makes `hdiutil detach` spin for many
    /// seconds, which must never happen on the main thread. Returns true
    /// when nothing is mounted at the mount point afterwards.
    @discardableResult
    func detachIfAttached(reason: String, mode: DetachMode = .escalate) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard Self.isAttached() else {
                    self.setState(self.idleState, notify: true)
                    continuation.resume(returning: true)
                    return
                }
                do {
                    try self.detach(mode: mode)
                    debugLog("💽 detached (\(reason))")
                    self.setState(self.idleState, notify: true)
                    continuation.resume(returning: true)
                } catch {
                    errorLog("💽 detach (\(reason)) failed: \(error.localizedDescription)")
                    self.setState(.failed(error.localizedDescription), notify: true)
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Quit: POLITE detach only. "Busy" means someone still uses the
    /// volume — the wallpaper extension playing from it, a download in
    /// flight, or the successor instance of the login item ↔ Xcode-run
    /// handover — and yanking it from under them is worse than leaving
    /// it mounted (the next launch finds it "already attached"; the
    /// reconcile timer covers the reverse case). Never `-force` here.
    func detachOnTerminate() {
        guard Cache.isExternalImageMode, Self.isAttached() else { return }
        if let bundleID = Bundle.main.bundleIdentifier {
            let myPID = ProcessInfo.processInfo.processIdentifier
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != myPID && !$0.isTerminated }
            if let other = others.first {
                debugLog("💽 leaving image attached for pid \(other.processIdentifier) (terminate)")
                return
            }
        }
        // 3 s cap: a free volume detaches in ~1 s; a busy one would make
        // hdiutil spin for ~20 s and hang the quit. Left attached is fine.
        let result = run(["detach", Self.mountPoint], timeout: 3)
        if result.status == 0 && !Self.isAttached() {
            debugLog("💽 detached (terminate)")
        } else {
            debugLog("💽 left attached on terminate — volume busy or detach refused (\(result.status)): \(result.stderr)")
        }
    }

    /// After the cache location or the image state changed: re-resolve
    /// the memoized cache path AND sources roots (packs at the location
    /// appear/disappear with it), rebuild the catalog (its callback chain
    /// regenerates the filter playlists → `playlistGeneration` bump for
    /// the extension), refresh user playlists, and bump
    /// `settingsGeneration` so the extension re-reads prefs and
    /// re-resolves its own `Cache.path`. Main thread.
    /// Coalesced (0.3 s): a settings change and the state notification it
    /// triggers both land here within milliseconds, and each pass costs
    /// ~0.5 s of main-thread catalog + playlist work.
    static func refreshConsumers(reason: String) {
        pendingRefresh?.cancel()
        let item = DispatchWorkItem {
            pendingRefresh = nil
            Cache.invalidateCachePath()
            Cache.invalidateSourcesRoots()
            debugLog("💽 refreshing cache consumers (\(reason)) — path=\(Cache.path) available=\(Cache.isAvailable) expansions=\(Cache.externalSourcesRoot ?? "default root only")")
            SourceList.rescan()
            VideoList.instance.reloadSources()
            PlaylistManager.shared.regenerateAll()
            WallpaperControl.shared.displaysConfigDidChange()
        }
        pendingRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    nonisolated(unsafe) private static var pendingRefresh: DispatchWorkItem?   // main thread only

    // MARK: - hdiutil operations

    /// Create the sparsebundle in `folder` (a folder on the external
    /// drive) unless one already exists there. Returns the bundle path.
    func create(inFolder folder: String) throws -> String {
        let bundle = (folder as NSString).appendingPathComponent(Self.bundleName)
        if Self.backingVolumeMounted(image: bundle) {
            debugLog("💽 reusing existing image at \(bundle)")
            return bundle
        }
        // A network share can only host a disk image when its server
        // supports F_FULLFSYNC — the Time Machine requirement. Without it
        // hdiutil refuses the bundle ("erreur 513"), and an image that
        // does get there (copied in, or a single-file sparseimage) can
        // never be unmounted cleanly and loses every write on the forced
        // detach — verified 2026-09-15 on an SMB share. Refuse up front
        // with a message that names the fix.
        if let problem = Self.imageHostingProblem(folder: folder) {
            errorLog("💽 cannot create an image in \(folder): \(problem)")
            throw CommandError(message: problem)
        }
        let sizeGB = Self.sparseCapGB(forFolder: folder)
        debugLog("💽 creating \(bundle) (sparse cap \(sizeGB) GB, volume: \(Self.volumeDescription(folder)))")
        let result = run(["create", "-type", "SPARSEBUNDLE", "-fs", "APFS",
                          "-volname", Self.volumeName, "-size", "\(sizeGB)g",
                          "-nospotlight", "-plist", bundle], timeout: 60)
        guard result.status == 0, Self.backingVolumeMounted(image: bundle) else {
            errorLog("💽 create failed in \(folder) (hdiutil exit \(result.status)): \(result.stderr)")
            throw CommandError(message: "Could not create the disk image (hdiutil exit \(result.status)): \(result.stderr)")
        }
        return bundle
    }

    /// Sparse cap = the backing volume's total capacity, floored to GB and
    /// clamped to [10, 2000]. Total rather than free: an existing cache
    /// folder on the same drive gets moved INTO the image, so the free
    /// space at creation time is not the ceiling. The image only ever
    /// occupies what the videos need (bands grow on demand) and Aerial's
    /// own cache limit bounds that.
    private static func sparseCapGB(forFolder folder: String) -> Int {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        let total = (try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity) ?? 0
        let gb = total / 1_000_000_000
        return min(max(gb, 10), 2000)
    }

    // MARK: - Backing volume checks

    /// True when `path` sits on a network volume (SMB, AFP, NFS…).
    static func volumeIsNetwork(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let local = (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? true
        return !local
    }

    /// The volume's format as macOS names it ("APFS", "SMB (Unknown)"…),
    /// prefixed with "network" when it is one. Logs and diagnostics.
    static func volumeDescription(_ path: String) -> String {
        let format = volumeFormat(path)
        return volumeIsNetwork(path) ? "network, \(format)" : format
    }

    private static func volumeFormat(_ path: String) -> String {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return (try? url.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey]).volumeLocalizedFormatDescription) ?? "unknown"
    }

    /// Whether files in `folder` accept F_FULLFSYNC — what the disk-image
    /// driver needs to commit writes durably. Local volumes always do; an
    /// SMB server only when the share advertises it (Samba
    /// `fruit:time machine = yes`, "Time Machine" enabled on a NAS share).
    /// Probes with a throwaway file, so `folder` must be writable; when
    /// it isn't, answers true and leaves the verdict to hdiutil.
    static func supportsFullSync(folder: String) -> Bool {
        let probe = (folder as NSString).appendingPathComponent(".aerial-fullsync-probe")
        let fd = open(probe, O_CREAT | O_RDWR | O_TRUNC, 0o600)
        guard fd >= 0 else { return true }
        defer {
            close(fd)
            unlink(probe)
        }
        var byte: UInt8 = 0x78
        _ = write(fd, &byte, 1)
        return fcntl(fd, F_FULLFSYNC, 0) == 0
    }

    /// Why `folder` cannot host the cache image, or nil when it can. Only
    /// network volumes are probed; local drives go straight to hdiutil.
    static func imageHostingProblem(folder: String) -> String? {
        guard volumeIsNetwork(folder), !supportsFullSync(folder: folder) else { return nil }
        return "This folder is on a network share (\(volumeFormat(folder))) whose server does not support full-sync writes, so macOS cannot keep a disk image on it — nothing written to the image would survive. Enable Time Machine support for this share on the NAS (that adds full sync), or choose a folder on a local drive."
    }

    /// Attach `image` at the mount point and return its device entry.
    /// Idempotent when already attached here. Handles the image being
    /// attached elsewhere (user double-clicked the bundle in Finder) and a
    /// dirty volume after a yank (retry with -autofsck).
    private func attach(image: String) throws -> String {
        guard Self.backingVolumeMounted(image: image) else {
            throw CommandError(message: "The drive holding \(image) is not connected")
        }
        let mp = Self.mountPoint
        if Self.isAttached() {
            // Attached by a previous instance (handover) or by hand: the
            // layout still needs checking — idempotent and cheap.
            debugLog("💽 already attached at \(mp)")
            ensureLayout(at: mp)
            return "already-attached"
        }
        try detachForeignMountIfNeeded(image: image)
        try ensureMountPointDirectory(mp)

        var result = run(attachArguments(image: image, mountPoint: mp, fsck: false), timeout: 30)
        if result.status != 0 {
            debugLog("💽 attach failed (\(result.status)): \(result.stderr) — retrying with -autofsck")
            result = run(attachArguments(image: image, mountPoint: mp, fsck: true), timeout: 120)
        }
        guard result.status == 0, Self.isAttached() else {
            errorLog("💽 attach of \(image) failed (hdiutil exit \(result.status)): \(result.stderr)")
            throw CommandError(message: "Could not attach the disk image (hdiutil exit \(result.status)): \(result.stderr)")
        }
        let device = Self.deviceEntry(fromAttachPlist: result.stdout, mountPoint: mp) ?? "?"
        let marker = Cache.externalCacheMarkerPath
        if !FileManager.default.fileExists(atPath: marker) {
            FileManager.default.createFile(atPath: marker, contents: nil)
        }
        ensureLayout(at: mp)
        debugLog("💽 attached \(image) at \(mp) (\(device))")
        return device
    }

    /// Image layout: `Cache/` (videos) and `Expansions/` (packs) side by
    /// side at the mount root — `Cache.path` is `<mount>/Cache` so pack
    /// bytes never count against the cache budget. Creates both and moves
    /// any `.mov` still sitting at the root (pre-layout images) into
    /// `Cache/`. Companion only, right after a successful attach.
    private func ensureLayout(at mountPoint: String) {
        let fm = FileManager.default
        let cacheDir = mountPoint.appending("/Cache")
        let packsDir = mountPoint.appending("/Expansions")
        for dir in [cacheDir, packsDir] where !fm.fileExists(atPath: dir) {
            do {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            } catch {
                errorLog("💽 layout: could not create \(dir): \(error.localizedDescription)")
            }
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: mountPoint) else { return }
        var moved = 0
        for entry in entries where entry.hasSuffix(".mov") {
            let destination = cacheDir.appending("/").appending(entry)
            guard !fm.fileExists(atPath: destination) else { continue }
            do {
                try fm.moveItem(atPath: mountPoint.appending("/").appending(entry), toPath: destination)
                moved += 1
            } catch {
                errorLog("💽 layout: could not move \(entry) into Cache/: \(error.localizedDescription)")
            }
        }
        if moved > 0 {
            debugLog("💽 layout: moved \(moved) video(s) into Cache/")
        }
    }

    // MARK: - Legacy videos next to the image

    /// The `.mov` files sitting at the root of `folder` — the drive folder
    /// that holds (or will hold) the bundle. That is a 4.0-style cache, or
    /// what a "Start fresh" / toggle-off-then-on round trip in Settings
    /// leaves behind next to a freshly created image.
    static func siblingVideos(inFolder folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { $0.hasSuffix(".mov") && !$0.hasPrefix(".") }
            .sorted()
    }

    struct AdoptionResult: Equatable {
        var moved = 0
        var alreadyInImage = 0
        var failed = 0
    }

    /// The Expansion pack folders in `<folder>/Expansions` — where packs
    /// lived while `expansionsAtCacheLocation` pointed at the plain folder.
    static func siblingPacks(inFolder folder: String) -> [String] {
        let root = (folder as NSString).appendingPathComponent("Expansions")
        let url = URL(fileURLWithPath: root, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? [])
            .filter(\.hasDirectoryPath)
            .map(\.lastPathComponent)
            .sorted()
    }

    /// Move the sibling videos of `folder` into `<mount>/Cache`, and its
    /// Expansion packs (`<folder>/Expansions/*`) into `<mount>/Expansions`
    /// — once the image is adopted the Expansions root follows the mount
    /// point, so packs left outside would silently disappear. Requires
    /// the image to be attached (after `adopt`). Helper queue; `progress`
    /// (done, total) is delivered on main. Cross-volume, so each item is
    /// a copy + delete — never on the main thread. Items already present
    /// in the image are left where they are and counted separately; per-
    /// item failures are logged and skipped, nothing is ever deleted.
    func adoptSiblingVideos(inFolder folder: String, progress: ((Int, Int) -> Void)? = nil) async -> AdoptionResult {
        await withCheckedContinuation { continuation in
            queue.async {
                let fm = FileManager.default
                let cacheDir = Self.mountPoint.appending("/Cache")
                let packsDir = Self.mountPoint.appending("/Expansions")
                let packsSource = (folder as NSString).appendingPathComponent("Expansions")
                let videos = Self.siblingVideos(inFolder: folder)
                let packs = Self.siblingPacks(inFolder: folder)
                let jobs: [(src: String, dst: String)] =
                    videos.map { ((folder as NSString).appendingPathComponent($0),
                                  (cacheDir as NSString).appendingPathComponent($0)) }
                    + packs.map { ((packsSource as NSString).appendingPathComponent($0),
                                   (packsDir as NSString).appendingPathComponent($0)) }
                var result = AdoptionResult()
                guard !jobs.isEmpty else {
                    continuation.resume(returning: result)
                    return
                }
                guard Self.isAttached(), fm.fileExists(atPath: Cache.externalCacheMarkerPath) else {
                    errorLog("💽 adopt: image not attached — leaving \(videos.count) video(s) and \(packs.count) pack(s) in \(folder)")
                    result.failed = jobs.count
                    continuation.resume(returning: result)
                    return
                }
                try? fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
                if !packs.isEmpty {
                    try? fm.createDirectory(atPath: packsDir, withIntermediateDirectories: true)
                }
                let total = jobs.count
                for (index, job) in jobs.enumerated() {
                    if fm.fileExists(atPath: job.dst) {
                        result.alreadyInImage += 1
                    } else {
                        do {
                            try fm.moveItem(atPath: job.src, toPath: job.dst)
                            result.moved += 1
                        } catch {
                            result.failed += 1
                            errorLog("💽 adopt: could not move \((job.src as NSString).lastPathComponent) into the image: \(error.localizedDescription)")
                        }
                    }
                    if let progress {
                        let done = index + 1
                        DispatchQueue.main.async { progress(done, total) }
                    }
                }
                debugLog("💽 adopted \(videos.count) video(s) and \(packs.count) pack(s) from \(folder) into the image: \(result.moved) moved, \(result.alreadyInImage) already there, \(result.failed) failed")
                continuation.resume(returning: result)
            }
        }
    }

    /// Create the derived Expansions root (`<location>/Expansions`) when
    /// the location is available. Companion only — the extension reads.
    static func ensureExpansionsRoot() {
        guard Cache.isAvailable, let root = Cache.expansionsRootCandidate else { return }
        guard !FileManager.default.fileExists(atPath: root) else { return }
        do {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            debugLog("💽 created Expansions root \(root)")
        } catch {
            errorLog("💽 could not create Expansions root \(root): \(error.localizedDescription)")
        }
    }

    private func attachArguments(image: String, mountPoint: String, fsck: Bool) -> [String] {
        var args = ["attach", image, "-mountpoint", mountPoint,
                    "-nobrowse", "-owners", "off", "-noverify", "-noautoopen", "-plist"]
        args.append(fsck ? "-autofsck" : "-noautofsck")
        return args
    }

    private func detach(mode: DetachMode) throws {
        let mp = Self.mountPoint
        guard Self.isAttached() else { return }
        var result: Result
        switch mode {
        case .force:
            result = run(["detach", mp, "-force"], timeout: 30)
        case .polite:
            // hdiutil retries internally for ~20 s on a busy volume.
            result = run(["detach", mp], timeout: 25)
        case .escalate:
            result = run(["detach", mp], timeout: 25)
            if result.status != 0 {
                debugLog("💽 detach failed (\(result.status)): \(result.stderr) — forcing")
                Thread.sleep(forTimeInterval: 1)
                result = run(["detach", mp, "-force"], timeout: 30)
            }
        }
        guard !Self.isAttached() else {
            throw CommandError(message: "Could not detach the disk image (hdiutil exit \(result.status)): \(result.stderr)")
        }
    }

    /// If `hdiutil info` shows our bundle attached somewhere other than
    /// our mount point, detach it there first (one image, one mount).
    private func detachForeignMountIfNeeded(image: String) throws {
        let info = run(["info", "-plist"], timeout: 30)
        guard info.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: info.stdout, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return }
        let wanted = URL(fileURLWithPath: image).standardizedFileURL.path
        for entry in images {
            guard let path = entry["image-path"] as? String,
                  URL(fileURLWithPath: path).standardizedFileURL.path == wanted,
                  let entities = entry["system-entities"] as? [[String: Any]] else { continue }
            for entity in entities {
                guard let mp = entity["mount-point"] as? String, mp != Self.mountPoint else { continue }
                debugLog("💽 image is attached at \(mp) — detaching it before mounting at our mount point")
                let result = run(["detach", mp], timeout: 30)
                if result.status != 0 {
                    throw CommandError(message: "The disk image is already open at \(mp) and could not be closed: \(result.stderr)")
                }
            }
        }
    }

    private func ensureMountPointDirectory(_ mp: String) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: mp, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw CommandError(message: "\(mp) exists and is not a directory")
            }
            if let entries = try? fm.contentsOfDirectory(atPath: mp), !entries.isEmpty {
                // Shadowed by the mount, never deleted. Stray files here
                // mean a download slipped past `Cache.isAvailable` gating.
                errorLog("💽 mount point \(mp) is not empty (\(entries.count) entries) — hidden while the image is attached")
            }
        } else {
            try fm.createDirectory(atPath: mp, withIntermediateDirectories: true)
        }
    }

    private static func deviceEntry(fromAttachPlist data: Data, mountPoint: String) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        return entities.first { ($0["mount-point"] as? String) == mountPoint }?["dev-entry"] as? String
    }

    // MARK: - State

    private var idleState: State {
        guard Cache.isExternalImageMode else { return .off }
        return backingVolumeMounted ? .detached : .backingVolumeMissing
    }

    private func performAttach(image: String, reason: String, notify: Bool) {
        guard Self.backingVolumeMounted(image: image) else {
            debugLog("💽 attach (\(reason)) skipped — drive holding \(image) not mounted")
            setState(.backingVolumeMissing, notify: notify)
            return
        }
        do {
            let device = try attach(image: image)
            setState(.attached(device: device), notify: notify)
        } catch {
            let message = error.localizedDescription
            errorLog("💽 attach (\(reason)) failed: \(message)")
            setState(.failed(message), notify: notify)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.attachFailedNotification, object: nil,
                                                userInfo: ["error": message])
            }
        }
    }

    private func setState(_ new: State, notify: Bool) {
        let apply = {
            let changed = (self.state != new)
            self.state = new
            if notify && changed {
                NotificationCenter.default.post(name: Self.stateDidChangeNotification, object: nil)
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    // MARK: - Process runner

    private struct Result {
        let status: Int32
        let stdout: Data
        /// stderr with Tahoe's hdiutil deprecation chatter removed.
        let stderr: String
    }

    /// Separate stdout/stderr pipes: `-plist` output is on stdout and must
    /// not be polluted by the deprecation warning on stderr. Both pipes
    /// are drained concurrently before waiting so a large plist can never
    /// block hdiutil into a timeout.
    private func run(_ args: [String], timeout: TimeInterval) -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: hdiutilPath)
        proc.arguments = args
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do {
            try proc.run()
        } catch {
            return Result(status: -1, stdout: Data(), stderr: "could not launch hdiutil: \(error.localizedDescription)")
        }
        let readers = DispatchGroup()
        var outData = Data()
        var errData = Data()
        DispatchQueue.global(qos: .utility).async(group: readers) {
            outData = out.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global(qos: .utility).async(group: readers) {
            errData = err.fileHandleForReading.readDataToEndOfFile()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            errorLog("💽 hdiutil \(args.first ?? "") timed out after \(Int(timeout)) s — terminating")
            proc.terminate()
            _ = done.wait(timeout: .now() + 5)
        }
        readers.wait()
        let stderr = Self.cleanStderr(String(data: errData, encoding: .utf8) ?? "")
        return Result(status: proc.terminationStatus, stdout: outData, stderr: stderr)
    }

    private static func cleanStderr(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .filter { !$0.contains("is deprecated") && !$0.contains("Please use 'diskutil") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
