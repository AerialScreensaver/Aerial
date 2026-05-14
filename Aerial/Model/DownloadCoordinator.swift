//
//  DownloadCoordinator.swift
//  Aerial Companion
//
//  Intelligent download scheduler that replaces opportunistic fillOrRollCache().
//  Handles priority downloads (empty cache), coverage (one per group),
//  variety (best-effort diversity), and maintenance (periodic rolling).
//

import Foundation
import AppKit

class DownloadCoordinator {

    // MARK: - Singleton

    static let shared = DownloadCoordinator()

    // MARK: - Types

    enum Priority {
        case critical   // Zero cached videos match selection
        case coverage   // Some groups have no cached video
        case variety    // Best-effort diversity
        case maintenance // Periodic fill
    }

    // MARK: - Private Properties

    private let workQueue = DispatchQueue(label: "com.glouel.aerial.downloadcoord")
    private var debounceTimer: DispatchWorkItem?
    private var isEvaluating = false

    /// Debounce interval for selection changes (seconds)
    private let debounceInterval: TimeInterval = 3.0

    /// Max videos to queue in variety mode
    private let varietyBatchSize = 3

    /// Track completed count to regenerate playlists per-video, not just per-batch
    private var lastSeenCompleted = 0

    /// Interval between scheduled fill/rotate checks (seconds).
    private let scheduledInterval: TimeInterval = 3600

    /// Repeating timer driving hourly checks. Scheduled on the main runloop.
    private var scheduledTimer: Timer?

    /// Per-video count of MD5-mismatch retries already used. Cleared on
    /// eventual success or once the budget is exhausted, so a future
    /// manifest update can try fresh.
    private var md5RetryCount: [String: Int] = [:]

    /// How many MD5 retries we'll burn before giving up (so 1 + this =
    /// total attempts: 3 by default).
    private static let md5MaxRetries = 2

    /// Per-video count of stale-URL retries already used. A stale URL
    /// (GitHub's 618/jwt:expired and similar) means the resume blob is
    /// dead — one fresh-URL fetch is enough to recover; if that also
    /// fails it's a different problem and we let it bubble up.
    private var staleURLRetryCount: [String: Int] = [:]
    private static let staleURLMaxRetries = 1

    // MARK: - Notifications

    static let downloadDidCompleteNotification = Notification.Name("com.glouel.aerial.downloadDidComplete")
    static let downloadDidStartNotification = Notification.Name("com.glouel.aerial.downloadDidStart")

    // MARK: - Init

    private init() {
        // Observe download completions from VideoManager
        VideoManager.sharedInstance.addCallback { [weak self] completed, total in
            guard let self = self else { return }
            // Regenerate after each individual download so newly cached videos
            // appear in the playlist immediately
            if completed > self.lastSeenCompleted && completed > 0 {
                // Update duration for any freshly downloaded video
                for video in VideoList.instance.videos where video.duration == 0 && video.isAvailableOffline {
                    video.updateDuration()
                }
                debugLog("DownloadCoordinator: video \(completed)/\(total) done, regenerating all playlists")
                PlaylistManager.shared.regenerateAll()
            }
            self.lastSeenCompleted = completed
            // Reset tracking and notify when batch finishes
            if completed == total && total > 0 {
                self.lastSeenCompleted = 0
                self.onDownloadBatchComplete()
            }
        }

        // Per-video completion callback — used to react to MD5 verification
        // failures and stale-URL failures with bounded retry budgets.
        // Non-handled outcomes are ignored here (the queue-progress callback
        // above handles success counting and other failures fall through).
        VideoManager.sharedInstance.addFinishedCallback { [weak self] videoId, success, errorMessage in
            guard let self = self else { return }
            if success {
                // Eventual success — clear any retry state we accumulated.
                self.md5RetryCount[videoId] = nil
                self.staleURLRetryCount[videoId] = nil
                // VoiceOver: announce the completion so users with the
                // popover closed know a download finished. Falls back
                // to a generic phrasing when the video isn't yet in
                // the catalog (rare; shouldn't happen on success).
                let name = VideoList.instance.videos
                    .first(where: { $0.id == videoId })?
                    .secondaryName ?? "A video"
                NSAccessibility.post(
                    element: NSApp as Any,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: "\(name) finished downloading",
                        .priority: NSAccessibilityPriorityLevel.low.rawValue
                    ]
                )
                return
            }
            switch errorMessage {
            case VideoDownload.md5MismatchErrorMessage:
                self.handleMD5Mismatch(videoId: videoId)
            case VideoDownload.staleURLErrorMessage:
                self.handleStaleURL(videoId: videoId)
            default:
                break
            }
        }

        // Hourly scheduler: fills the cache while there's room, rotates once full
        // according to the user's "Replace videos" cadence. Start on the main
        // runloop so the Timer has a live runloop to fire on.
        DispatchQueue.main.async { [weak self] in
            self?.startScheduledChecks()
        }

        // Long sleeps would skew the hourly cadence; tick again immediately on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    // MARK: - Public API

    /// Queue every uncached video belonging to `sourceName` for
    /// download. Skips videos already in `VideoManager`'s queue so a
    /// double-click is a no-op. No-op if the source isn't loaded yet
    /// (e.g. its entries.json hasn't finished downloading). Used by
    /// the post-install thank-you sheet's "Download all videos now"
    /// toggle and by each installed `ExpansionCard`'s download CTA.
    func enqueueAllVideos(forSource sourceName: String) {
        let alreadyQueued = Set(VideoManager.sharedInstance.queuedVideoIds)
        let videos = VideoList.instance.videos.filter {
            $0.source.name == sourceName
                && !$0.isAvailableOffline
                && !alreadyQueued.contains($0.id)
        }
        for video in videos {
            VideoManager.sharedInstance.queueDownload(video)
        }
        if !videos.isEmpty {
            infoLog("Enqueued \(videos.count) video(s) from source '\(sourceName)' for download.")
        }
    }

    /// Called when the user changes video selection in the popover.
    /// Starts a debounce timer; after 3s of inactivity, evaluates downloads.
    func selectionDidChange() {
        workQueue.async { [weak self] in
            guard let self = self else { return }

            // Cancel previous debounce
            self.debounceTimer?.cancel()

            let work = DispatchWorkItem { [weak self] in
                self?.evaluateAndDownload()
            }
            self.debounceTimer = work
            self.workQueue.asyncAfter(deadline: .now() + self.debounceInterval, execute: work)
        }
    }

    /// Trigger an hourly check immediately (e.g. on app wake). Also the entry
    /// point the repeating timer calls. Safe to call from any thread — the
    /// actual work runs on `workQueue`.
    func performScheduledCheck() {
        workQueue.async { [weak self] in
            self?.runScheduledCheck()
        }
    }

    // MARK: - Scheduled Checks

    private func startScheduledChecks() {
        scheduledTimer?.invalidate()
        scheduledTimer = Timer.scheduledTimer(
            withTimeInterval: scheduledInterval,
            repeats: true
        ) { [weak self] _ in
            self?.performScheduledCheck()
        }
    }

    @objc private func handleSystemWake() {
        debugLog("DownloadCoordinator: system woke, running scheduled check")
        performScheduledCheck()
    }

    /// The hourly check. Two phases:
    ///   1. Fill — cache has room → let `evaluateAndDownload` queue more videos
    ///   2. Rotate — cache is full and cadence has elapsed → evict outdated,
    ///      queue replacements, stamp `lastRotationRun`
    /// In both phases, refresh source manifests so newly released videos surface.
    private func runScheduledCheck() {
        guard PrefsCache.enableManagement, Cache.canNetwork() else {
            debugLog("DownloadCoordinator: scheduled check skipped (management off or offline)")
            return
        }

        // Refresh manifests so any new Apple/community videos are discovered.
        // `reloadSources()` synchronously populates from cache then kicks the
        // network refresh in the background, so this is safe and cheap.
        DispatchQueue.main.async {
            VideoList.instance.reloadSources()
        }

        if Cache.hasSomeFreeSpace() {
            debugLog("DownloadCoordinator: scheduled fill (cache has free space)")
            evaluateAndDownload()
            return
        }

        // Cache is full — only rotate if the user opted into a cadence.
        guard PrefsCache.cachePeriodicity != .never else {
            debugLog("DownloadCoordinator: cache full, Replace=Never, skipping")
            return
        }

        guard cadenceElapsedSinceLastRotation() else {
            debugLog("DownloadCoordinator: cache full, cadence not yet elapsed")
            return
        }

        debugLog("DownloadCoordinator: rotation cycle starting (cadence=\(PrefsCache.cachePeriodicity))")
        Cache.freeCache()                      // Evicts all outdated videos (cadence-aware)
        PrefsCache.lastRotationRun = Date()
        evaluateAndDownload()                  // Queues replacements into freed space
    }

    private func cadenceElapsedSinceLastRotation() -> Bool {
        let last = PrefsCache.lastRotationRun ?? .distantPast
        let elapsed = Date().timeIntervalSince(last)
        switch PrefsCache.cachePeriodicity {
        case .daily:   return elapsed >= 24 * 3600
        case .weekly:  return elapsed >= 7 * 24 * 3600
        case .monthly: return elapsed >= 30 * 24 * 3600
        case .never:   return false
        }
    }

    // MARK: - Core Logic

    private func evaluateAndDownload() {
        guard !isEvaluating else { return }
        isEvaluating = true
        defer { isEvaluating = false }

        guard PrefsCache.enableManagement, Cache.canNetwork() else { return }

        // Union the matching videos across every active playlist filter
        // (shared + per-screen). A per-screen selection change in independent
        // mode must produce downloads just like a global change does.
        var filters = PlaylistManager.shared.activeFilters()
        if filters.isEmpty {
            // No playlists have been generated yet (first launch); fall back
            // to global prefs so fresh installs still queue the initial batch.
            filters = [(PrefsVideos.newShouldPlay, PrefsVideos.newShouldPlayString)]
        }

        var matchingIds = Set<String>()
        for filter in filters {
            let matches = VideoList.instance.videosMatchingFilter(
                mode: filter.mode,
                filterStrings: filter.filterStrings
            )
            for video in matches { matchingIds.insert(video.id) }
        }
        let allMatching = VideoList.instance.videos.filter { matchingIds.contains($0.id) }

        let cached = allMatching.filter { $0.isAvailableOffline }
        let uncached = allMatching.filter { !$0.isAvailableOffline }

        // Priority classification is mode-sensitive only for the coverage
        // heuristic (<=5 locations). With a union of filters we may have many
        // modes at play; pick the first active mode for the heuristic, or the
        // global one as a final fallback.
        let priorityMode = filters.first?.mode ?? PrefsVideos.newShouldPlay
        let priority = determinePriority(cached: cached, uncached: uncached, mode: priorityMode)

        debugLog("DownloadCoordinator: priority=\(priority) cached=\(cached.count) uncached=\(uncached.count) filters=\(filters.count)")

        switch priority {
        case .critical:
            downloadCritical(uncached: uncached)
        case .coverage:
            downloadCoverage(cached: cached, uncached: uncached)
        case .variety:
            downloadVariety(uncached: uncached)
        case .maintenance:
            // Nothing urgent, just regenerate playlist
            break
        }

        notifyIfDownloading()

        // Always regenerate playlists after evaluation
        PlaylistManager.shared.regenerate()
    }

    private func determinePriority(cached: [AerialVideo], uncached: [AerialVideo], mode: NewShouldPlay) -> Priority {
        if cached.isEmpty && !uncached.isEmpty {
            return .critical
        }

        if uncached.isEmpty {
            return .maintenance
        }

        // Check coverage: group by location name
        let cachedLocations = Set(cached.map { $0.name })
        let allLocations = Set((cached + uncached).map { $0.name })
        let uncoveredLocations = allLocations.subtracting(cachedLocations)

        if !uncoveredLocations.isEmpty && allLocations.count <= 5 {
            return .coverage
        }

        return .variety
    }

    // MARK: - Download Strategies

    /// Critical: download smallest video immediately for fastest first playback.
    private func downloadCritical(uncached: [AerialVideo]) {
        guard let smallest = uncached.first else { return }

        // Only gate the global-cache space for cacheable downloads.
        // Non-cacheable sources write to `<supportPath>/Sources/<name>/`,
        // which is outside the global cache and not subject to its
        // limit — applying the gate here would (incorrectly) block
        // non-cacheable Expansion downloads when the global cache
        // happens to be full and nothing's evictable.
        if smallest.source.isCachable {
            ensureSpace()

            // If the cadence-aware eviction didn't free anything (e.g. Replace =
            // Never, or nothing is outdated yet), force one eviction anyway. The
            // user just picked a filter with zero cached matches — having nothing
            // to play is worse than breaking the "don't rotate on a schedule"
            // promise for a single video.
            if !Cache.hasSomeFreeSpace() {
                forceEvictOneForCritical()
            }

            guard Cache.hasSomeFreeSpace() else {
                debugLog("DownloadCoordinator: critical mode but couldn't make space")
                return
            }
        }

        debugLog("DownloadCoordinator: critical download \(smallest.secondaryName)")
        VideoManager.sharedInstance.queueDownload(smallest)
    }

    /// Evict the single oldest cached video that's safe to remove (not a
    /// favorite, not hidden, from a cacheable source). Only called from the
    /// critical-download path when the cadence-gated `freeCache()` declined
    /// to free anything but the user needs at least one playable video.
    private func forceEvictOneForCritical() {
        let candidates = VideoList.instance.videos.filter {
            $0.isAvailableOffline
                && $0.source.isCachable
                && !PrefsVideos.favorites.contains($0.id)
                && !PrefsVideos.hidden.contains($0.id)
        }
        guard !candidates.isEmpty else { return }

        var oldestVideo: AerialVideo?
        var oldestPath: String?
        var oldestDate = Date.distantFuture

        for video in candidates {
            guard let path = VideoCache.cachePath(forVideo: video),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let creationDate = attrs[.creationDate] as? Date
            else { continue }
            if creationDate < oldestDate {
                oldestDate = creationDate
                oldestVideo = video
                oldestPath = path
            }
        }

        guard let video = oldestVideo, let path = oldestPath else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
            debugLog("DownloadCoordinator: force-evicted \(video.secondaryName) to make room for a critical download")
        } catch {
            errorLog("DownloadCoordinator: force-evict failed for \(video.secondaryName): \(error.localizedDescription)")
        }
    }

    /// Coverage: ensure at least one cached video per location/group.
    private func downloadCoverage(cached: [AerialVideo], uncached: [AerialVideo]) {
        let cachedLocations = Set(cached.map { $0.name })

        // Group uncached by location, pick one from each uncovered
        var byLocation: [String: [AerialVideo]] = [:]
        for video in uncached {
            byLocation[video.name, default: []].append(video)
        }

        for (location, videos) in byLocation {
            if !cachedLocations.contains(location), let video = videos.first {
                if video.source.isCachable {
                    ensureSpace()
                    // Use `continue` (not `break`) so later non-cacheable
                    // videos in the loop can still be queued even when
                    // the global cache is saturated.
                    guard Cache.hasSomeFreeSpace() else { continue }
                }
                debugLog("DownloadCoordinator: coverage download \(video.secondaryName) for \(location)")
                VideoManager.sharedInstance.queueDownload(video)
            }
        }
    }

    /// Variety: shuffle uncached, download up to N, weighted toward uncovered locations.
    private func downloadVariety(uncached: [AerialVideo]) {
        var shuffled = uncached.shuffled()

        // Weight toward locations with 0 cached videos
        let cachedLocations = Set(
            VideoList.instance.videos
                .filter { $0.isAvailableOffline && !PrefsVideos.hidden.contains($0.id) }
                .map { $0.name }
        )
        shuffled.sort { a, b in
            let aUncovered = !cachedLocations.contains(a.name)
            let bUncovered = !cachedLocations.contains(b.name)
            if aUncovered != bUncovered { return aUncovered }
            return false // stable sort
        }

        var queued = 0
        for video in shuffled {
            guard queued < varietyBatchSize else { break }
            if video.source.isCachable {
                ensureSpace()
                // `continue` rather than `break` — non-cacheable
                // videos later in the shuffle still get a chance
                // when the global cache is saturated.
                guard Cache.hasSomeFreeSpace() else { continue }
            }
            debugLog("DownloadCoordinator: variety download \(video.secondaryName)")
            VideoManager.sharedInstance.queueDownload(video)
            queued += 1
        }
    }

    // MARK: - Helpers

    private func notifyIfDownloading() {
        if !VideoManager.sharedInstance.queuedVideoIds.isEmpty {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.downloadDidStartNotification, object: nil)
            }
        }
    }

    private func ensureSpace() {
        if !Cache.hasSomeFreeSpace() {
            Cache.freeCache()
        }
    }

    private func onDownloadBatchComplete() {
        debugLog("DownloadCoordinator: batch complete, regenerating all playlists")
        PlaylistManager.shared.regenerateAll()
        NotificationCenter.default.post(name: Self.downloadDidCompleteNotification, object: nil)
    }

    /// Bounded retry on MD5 verification failure. Re-queues the same
    /// video up to `md5MaxRetries` times before giving up; the next
    /// attempt downloads at the user's currently-effective format
    /// (which is what the verifier checks against), so a manifest
    /// update mid-flight that fixes the published checksum will let
    /// the next retry succeed.
    private func handleMD5Mismatch(videoId: String) {
        let used = (md5RetryCount[videoId] ?? 0) + 1
        md5RetryCount[videoId] = used

        guard used <= Self.md5MaxRetries else {
            errorLog("DownloadCoordinator: MD5 retry budget exhausted for \(videoId) — giving up")
            md5RetryCount[videoId] = nil
            return
        }

        guard let video = VideoList.instance.videos.first(where: { $0.id == videoId }) else {
            errorLog("DownloadCoordinator: cannot re-queue \(videoId) — not in catalog")
            md5RetryCount[videoId] = nil
            return
        }

        debugLog("DownloadCoordinator: MD5 retry \(used)/\(Self.md5MaxRetries) for \(videoId)")
        VideoManager.sharedInstance.queueDownload(video)
    }

    /// Bounded retry on stale-URL failure (e.g. GitHub's 618/jwt:expired).
    /// `VideoDownload` already cleared the resume blob, so the next
    /// `startDownload()` falls back to `video.url` fresh — for redirector
    /// URLs (github.com/.../releases/download/...) that produces a new
    /// signed redirect with a fresh JWT.
    private func handleStaleURL(videoId: String) {
        let used = (staleURLRetryCount[videoId] ?? 0) + 1
        staleURLRetryCount[videoId] = used

        guard used <= Self.staleURLMaxRetries else {
            errorLog("DownloadCoordinator: stale-URL retry budget exhausted for \(videoId) — giving up")
            staleURLRetryCount[videoId] = nil
            return
        }

        guard let video = VideoList.instance.videos.first(where: { $0.id == videoId }) else {
            errorLog("DownloadCoordinator: cannot re-queue \(videoId) — not in catalog")
            staleURLRetryCount[videoId] = nil
            return
        }

        debugLog("DownloadCoordinator: stale-URL retry \(used)/\(Self.staleURLMaxRetries) for \(videoId)")
        VideoManager.sharedInstance.queueDownload(video)
    }
}
