//
//  ExtensionVideoLoader.swift
//  Aerial
//
//  Video loader that delegates to the full VideoList/Source subsystem.
//  Reads cached manifests from disk (read-only — no downloads).
//  When a persisted playlist exists (written by Companion), uses it
//  for deterministic playback order with resume support.
//

import Foundation
import AVFoundation

/// Video loader that uses the full playlist/source subsystem
/// to select videos respecting user preferences (rotation, favorites,
/// hidden videos, format, day/night filtering).
class ExtensionVideoLoader {

    static let shared = ExtensionVideoLoader()

    /// The underlying VideoList instance
    private var videoList: VideoList {
        return VideoList.instance
    }

    /// Guards ALL the mutable playlist state below. The wallpaper
    /// extension calls this singleton from EACH renderer's own serial
    /// queue (one per display) at video boundaries — concurrent
    /// `setPlaylist`/`loadPlaylistIfNeeded` corrupted the
    /// `screenPlaylists` dictionary and aborted the process (SIGABRT in
    /// Dictionary.setValue, 2026-07-26 .ips; the agent then never
    /// re-acquired → black desktop). Critical sections stay tiny and
    /// NEVER span callouts — `getNextVideo` must not hold this around
    /// `videoList.randomVideo`, whose override closures write the
    /// `pending*` side-channels below (non-reentrant lock).
    private let stateLock = NSLock()

    /// Loaded playlist state from disk (lazy, loaded once per activation).
    /// Guarded by `stateLock`.
    private var playlistState: PlaylistState?
    private var playlistLoaded = false

    /// True on first video request after activation; plays currentIndex (resume).
    /// After the first video, set to false so subsequent calls advance.
    /// Guarded by `stateLock`.
    private var isFirstVideoThisActivation = true

    /// One-shot self-heal guard for `tryPersistedPlaylist`: when no entry
    /// resolves against the in-memory catalog we refresh it from disk and
    /// retry ONCE per playlist load (reset in `resetPlaylistCache`).
    /// Guarded by `stateLock`.
    private var catalogRefreshAttempted = false

    /// Last presenting asset that failed to resolve to a playlist index,
    /// per scope — the "progress not flushed" line logs once per asset,
    /// not on every 30 s flush (fallback videos can play for a while).
    private var lastUnresolvedProgressPath: [String: String] = [:]

    /// Resume-after-teardown, per scope key (`screenUUID ?? "shared"`).
    /// The handler tears a renderer down after its idle grace (nobody
    /// subscribed for 120 s) and the next acquire builds a fresh one,
    /// whose first pop used to take the NEXT entry — so a saver
    /// restarted 2–5 min after the last one changed video, while a
    /// restart under 2 min continued the old one and a restart after the
    /// process reclaim resumed it from the sidecar (2026-09-21). The
    /// teardown hook records the presenting entry + held position; the
    /// next pop for that scope rewinds the cursor to it and resumes
    /// there. One-shot. Guarded by `stateLock`.
    private var pendingTeardownResume: [String: (index: Int, timestamp: Double?)] = [:]

    /// Saver-launch advance, per scope key ("Don't resume video at launch").
    /// Armed by the extension right before an acquire's FIRST pop; that pop
    /// advances instead of resuming — sidecar position and teardown record
    /// both dropped. Consumed on ENTRY to the next `getNextVideo` for the
    /// scope, whatever it returns, so it can never leak into the renderer's
    /// pre-pop or a later pop. Survives `resetPlaylistCache()`. Guarded by
    /// `stateLock`.
    private var pendingLaunchAdvance: Set<String> = []

    /// Resume timestamp set by PlaylistManager's override closure (Companion only).
    /// Used as a side-channel since the override returns (AerialVideo?, Bool) without timestamp.
    var pendingResumeTimestamp: Double? {
        get { stateLock.withLock { _pendingResumeTimestamp } }
        set { stateLock.withLock { _pendingResumeTimestamp = newValue } }
    }
    private var _pendingResumeTimestamp: Double?

    /// Per-video play-duration override set by PlaylistManager's override closure
    /// (Companion only). Side-channel mirroring `pendingResumeTimestamp`: the override
    /// returns (AerialVideo?, Bool) and can't carry the popped entry's playDuration.
    var pendingPlayDuration: Double? {
        get { stateLock.withLock { _pendingPlayDuration } }
        set { stateLock.withLock { _pendingPlayDuration = newValue } }
    }
    private var _pendingPlayDuration: Double?

    private init() {
        // Explicitly trigger video list loading after VideoList.instance is initialized.
        // Cannot happen during VideoList.init() due to dispatch_once re-entrancy
        // from SourceInfo.findDuplicate accessing VideoList.instance.
        videoList.reloadSources()
        let cachedCount = videoList.videos.filter { $0.isAvailableOffline }.count
        debugLog("ExtensionVideoLoader: Initialized with \(videoList.videos.count) videos (\(cachedCount) cached)")
    }

    // MARK: - Video Selection

    /// Result of a next-video selection. Carries the per-pop metadata that can't
    /// ride the `nextVideoOverride` closure return (which is only (AerialVideo?, Bool)):
    /// the resume timestamp and the entry's optional play-duration override.
    struct LoaderResult {
        let video: AerialVideo?
        let shouldLoop: Bool
        let resumeTimestamp: Double?
        let playDuration: Double?
    }

    /// Get the next video to play, respecting persisted playlist if available.
    /// resumeTimestamp is non-nil only on first video resume; playDuration is the
    /// popped entry's optional per-video play-duration override (nil otherwise).
    func getNextVideo(isVertical: Bool, screenUUID: String? = nil) -> LoaderResult {
        // A saver-launch advance request is consumed by this call whatever
        // it returns, so it can never leak into the renderer's pre-pop.
        let advanceRequested = stateLock.withLock { pendingLaunchAdvance.remove(screenUUID ?? "shared") != nil }
        // In Companion mode (override installed), PlaylistManager is the single source of truth.
        // Skip tryPersistedPlaylist() so we go through videoList.randomVideo() → the override.
        if videoList.nextVideoOverride != nil {
            pendingResumeTimestamp = nil
            pendingPlayDuration = nil
            let (video, loop) = videoList.randomVideo(excluding: [], isVertical: isVertical, screenUUID: screenUUID)
            let timestamp = pendingResumeTimestamp
            let playDuration = pendingPlayDuration
            pendingResumeTimestamp = nil
            pendingPlayDuration = nil
            return LoaderResult(video: video, shouldLoop: loop, resumeTimestamp: timestamp, playDuration: playDuration)
        }

        // Extension mode: use persisted playlist directly from disk
        if let pop = tryPersistedPlaylist(screenUUID: screenUUID, advanceRequested: advanceRequested) {
            debugLog("ExtensionVideoLoader: Using persisted playlist → \(pop.video.secondaryName), shouldLoop=\(pop.shouldLoop), resumeAt=\(pop.resumeTimestamp.map { String(format: "%.1fs", $0) } ?? "nil"), playFor=\(pop.playDuration.map { String(format: "%.0fs", $0) } ?? "nil")")
            return LoaderResult(video: pop.video, shouldLoop: pop.shouldLoop, resumeTimestamp: pop.resumeTimestamp, playDuration: pop.playDuration)
        }

        debugLog("ExtensionVideoLoader: No persisted playlist, falling back to VideoList")
        let (video, loop) = videoList.randomVideo(excluding: [], isVertical: isVertical)
        return LoaderResult(video: video, shouldLoop: loop, resumeTimestamp: nil, playDuration: nil)
    }

    /// "Don't resume video at launch" (saver-only installs): the next pop
    /// for this scope advances instead of resuming — see
    /// `pendingLaunchAdvance`. The extension arms it right before an
    /// acquire's first pop; the renderer's pre-pop that follows is an
    /// ordinary advance.
    func requestAdvanceOnNextPop(screenUUID: String?) {
        let scopeKey = screenUUID ?? "shared"
        stateLock.withLock { _ = pendingLaunchAdvance.insert(scopeKey) }
        debugLog("ExtensionVideoLoader: launch advance armed (scope=\(scopeKey.prefix(8)))")
    }

    /// Get the local file path for a video
    func localPathFor(video: AerialVideo) -> String {
        return videoList.localPathFor(video: video)
    }

    /// filename → (name, id) lookup cache. The status reporter resolves
    /// the same asset path on every write, and each miss is a LINEAR
    /// scan of the whole catalog building a cache path per video —
    /// that scan showed up as a per-flush CPU burst in the 2026-07-24
    /// profile. Negative results are cached too; the cache clears when
    /// the catalog count changes (list reloads are rare). Lock-guarded:
    /// callers arrive from several queues.
    private let pathInfoLock = NSLock()
    private var pathInfoCacheCount = -1
    private var pathInfoCache: [String: (name: String?, id: String?)] = [:]

    /// Name + id of the video whose cache file lives at `localPath`,
    /// resolved together (one catalog scan per NEW path, cached after).
    /// Name feeds the dashboard's now-playing line; id lets Companion
    /// sync each display's playlist position to what's rendering.
    func videoInfo(forLocalPath localPath: String) -> (name: String?, id: String?) {
        let filename = (localPath as NSString).lastPathComponent
        let videoCount = videoList.videos.count

        pathInfoLock.lock()
        if pathInfoCacheCount != videoCount {
            pathInfoCacheCount = videoCount
            pathInfoCache.removeAll()
        } else if let cached = pathInfoCache[filename] {
            pathInfoLock.unlock()
            return cached
        }
        pathInfoLock.unlock()

        var result: (name: String?, id: String?) = (nil, nil)
        for video in videoList.videos {
            if (videoList.localPathFor(video: video) as NSString).lastPathComponent == filename {
                result = (video.secondaryName, video.id)
                break
            }
        }

        pathInfoLock.lock()
        pathInfoCache[filename] = result
        pathInfoLock.unlock()
        return result
    }

    /// Display name of the video whose cache file lives at `localPath`,
    /// or nil if it doesn't map to a known video.
    func videoName(forLocalPath localPath: String) -> String? {
        videoInfo(forLocalPath: localPath).name
    }

    /// Video id of the video whose cache file lives at `localPath`, or
    /// nil.
    func videoId(forLocalPath localPath: String) -> String? {
        videoInfo(forLocalPath: localPath).id
    }

    /// Verdict on whether the video at `localPath` survives the persisted
    /// playlist for a screen. The wallpaper extension uses this when a
    /// playlist-changed signal arrives.
    ///
    /// - `survives`: still listed — no reason to cut it.
    /// - `removed`: the playlist loaded, is non-empty and resolvable, but
    ///   no longer lists this video — a legitimate cut.
    /// - `unavailable`: no playlist, an empty playlist, or none of its
    ///   entries resolve to known videos. That's no EVIDENCE the current
    ///   video was removed, so don't cut. (A former bool version conflated
    ///   this with `removed`, which turned a transient empty regeneration
    ///   mid-Companion-reload into a visible cut on paused wallpapers.)
    ///
    /// Call after `resetPlaylistCache()` so the comparison sees the
    /// fresh on-disk playlist.
    enum PlaylistVerdict {
        case survives
        case removed
        case unavailable
    }

    func playlistVerdict(forLocalPath localPath: String, screenUUID: String?) -> PlaylistVerdict {
        loadPlaylistIfNeeded()
        guard let playlist = resolvePlaylist(screenUUID), !playlist.entries.isEmpty else {
            return .unavailable
        }
        let filename = (localPath as NSString).lastPathComponent
        var resolvedAny = false
        for entry in playlist.entries {
            guard let video = videoList.videos.first(where: { $0.id == entry.videoId }) else { continue }
            resolvedAny = true
            if (videoList.localPathFor(video: video) as NSString).lastPathComponent == filename {
                return .survives
            }
        }
        return resolvedAny ? .removed : .unavailable
    }

    /// Cycle mode of the persisted playlist for a screen (shared playlist
    /// when nil). Drives the renderer's repeat-one flag.
    func cycleMode(for screenUUID: String?) -> PlaylistCycleMode {
        loadPlaylistIfNeeded()
        return resolvePlaylist(screenUUID)?.cycleMode ?? .loop
    }

    // MARK: - Persisted Playlist

    private func tryPersistedPlaylist(screenUUID: String?, advanceRequested: Bool = false) -> (video: AerialVideo, shouldLoop: Bool, resumeTimestamp: Double?, playDuration: Double?)? {
        loadPlaylistIfNeeded()

        guard var playlist = resolvePlaylist(screenUUID) else { return nil }

        // User playlists (filterMode == -1): load fresh entries from Playlists/<uuid>.json
        if playlist.filterMode == -1,
           let sentinel = playlist.filterStrings.first,
           sentinel.hasPrefix("userPlaylist:"),
           let uuid = UUID(uuidString: String(sentinel.dropFirst("userPlaylist:".count))) {
            // Reload entries from the user playlist file on disk
            let fileURL = UserPlaylistIndex.playlistURL(for: uuid)
            if let data = try? Data(contentsOf: fileURL),
               let manifest = try? JSONDecoder().decode(UserPlaylistManifest.self, from: data) {
                playlist.entries = manifest.entries
                debugLog("ExtensionVideoLoader: Loaded user playlist \"\(manifest.name)\" with \(manifest.entries.count) entries")
            } else {
                debugLog("ExtensionVideoLoader: Failed to load user playlist file for \(uuid)")
                return nil
            }
        } else {
            // For shared playlists (cloned/mirrored/spanned mode), validate that
            // the stored filter matches current settings to catch stale playlists
            let isSharedPlaylist = (screenUUID == nil) || !hasScreenPlaylist(screenUUID!)
            if isSharedPlaylist {
                let currentMode = PrefsVideos.newShouldPlay.rawValue
                let currentStrings = Set(PrefsVideos.newShouldPlayString)
                if playlist.filterMode != currentMode || Set(playlist.filterStrings) != currentStrings {
                    debugLog("ExtensionVideoLoader: Shared playlist filter mismatch (stored mode=\(playlist.filterMode) vs current=\(currentMode)), skipping")
                    return nil
                }
            }
        }

        // Capture resume timestamp before popNextVideo() clears it.
        // Snapshot the activation flag once (locked) — the pop below
        // runs outside the lock.
        let scopeKey = screenUUID ?? "shared"
        let teardownResume = stateLock.withLock { pendingTeardownResume.removeValue(forKey: scopeKey) }
        let isFirstActivation = stateLock.withLock { isFirstVideoThisActivation }
        let decision = PlaylistPopRule.decide(
            isFirstActivation: isFirstActivation,
            sidecarTimestamp: playlist.playbackTimestamp,
            teardownResume: teardownResume.flatMap { playlist.entries.indices.contains($0.index) ? $0 : nil },
            advanceRequested: advanceRequested
        )
        if let cursor = decision.cursorOverride {
            // A renderer for this scope was torn down after its idle grace:
            // put the cursor back on the entry that was on screen (the
            // stored cursor is one ahead of it — the pre-pop).
            playlist.currentIndex = cursor
        }
        let isResume = decision.isResume
        let resumeTimestamp = decision.resumeTimestamp
        switch decision.path {
        case .teardownResume:
            debugLog("ExtensionVideoLoader: resuming after renderer teardown → index \(playlist.currentIndex) at \(resumeTimestamp.map { String(format: "%.1fs", $0) } ?? "start") (scope=\(scopeKey.prefix(8)))")
        case .launchAdvance(let overrode):
            let what: String
            switch overrode {
            case .coldResume: what = "cold resume"
            case .teardownResume: what = "teardown resume"
            case .nothing: what = "plain advance"
            }
            debugLog("⏭ ExtensionVideoLoader: launch advance — popping next instead of \(what) (scope=\(scopeKey.prefix(8)), cursor=\(playlist.currentIndex))")
        case .coldResume, .advance:
            break
        }

        debugLog("ExtensionVideoLoader: Playlist has \(playlist.entries.count) entries, currentIndex=\(playlist.currentIndex), resume=\(isResume)")

        let resolveVideo: (String) -> AerialVideo? = { [self] id in
            videoList.videos.first(where: { $0.id == id && $0.isAvailableOffline })
        }
        let shouldPlay: (AerialVideo) -> Bool = { TimeManagement.videoMatchesCurrentTime($0) }
        let shouldPlayFallback: (AerialVideo) -> Bool = { TimeManagement.videoMatchesCurrentTimeWithFallback($0) }

        var popped = playlist.popNextVideo(
            isResume: isResume,
            resolveVideo: resolveVideo,
            shouldPlay: shouldPlay,
            shouldPlayFallback: shouldPlayFallback
        )

        // Self-heal (once per playlist load): nothing resolving usually
        // means the CATALOG is stale, not the playlist — SourceList/
        // VideoList are load-once in this process, so a source created
        // after launch (My Videos on first launch) or a file added to it
        // mid-session is invisible until a respawn. 2026-08-25 bundle: a
        // "My Videos" playlist fell back to random rotation videos for
        // two days for exactly this reason. Refresh from disk and retry
        // before giving up; the claim flag keeps this bounded. Runs
        // outside `stateLock` (the refresh is a callout).
        if popped == nil, !playlist.entries.isEmpty, claimCatalogRefreshAttempt() {
            debugLog("ExtensionVideoLoader: no playlist entry resolved — refreshing catalog from disk and retrying once")
            videoList.refreshCatalogFromDisk(reason: "playlist-resolve")
            popped = playlist.popNextVideo(
                isResume: isResume,
                resolveVideo: resolveVideo,
                shouldPlay: shouldPlay,
                shouldPlayFallback: shouldPlayFallback
            )
        }

        guard let pop = popped else {
            debugLog("ExtensionVideoLoader: No valid offline entries found in playlist, reshuffled")
            setPlaylist(playlist, for: screenUUID)
            return nil
        }

        stateLock.withLock { isFirstVideoThisActivation = false }
        // The popped entry is at playlist.currentIndex (popNextVideo set it). Read its
        // optional per-video play-duration override directly from the (freshly-loaded) entry.
        let playDuration = playlist.entries.indices.contains(playlist.currentIndex)
            ? playlist.entries[playlist.currentIndex].playDuration : nil
        debugLog("ExtensionVideoLoader: Selected \(pop.video.secondaryName) at index \(playlist.currentIndex)")
        setPlaylist(playlist, for: screenUUID)
        // No sidecar write here: this pop is usually the renderer's
        // PRE-pop for its pipelined next reader, so `currentIndex` is
        // one ahead of the screen. The progress flush (`updateProgress`)
        // records the video actually presenting.
        return (video: pop.video, shouldLoop: pop.shouldLoop, resumeTimestamp: resumeTimestamp, playDuration: playDuration)
    }

    /// Locked value-copy read (PersistedPlaylist is a struct — callers
    /// mutate their copy and write it back via `setPlaylist`).
    private func resolvePlaylist(_ screenUUID: String?) -> PersistedPlaylist? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let state = playlistState else { return nil }
        if let uuid = screenUUID, let perScreen = state.screenPlaylists[uuid] {
            return perScreen
        }
        return state.sharedPlaylist
    }

    /// Locked write — this was the 2026-07-26 crash site (concurrent
    /// dictionary mutation from two renderer queues).
    private func setPlaylist(_ playlist: PersistedPlaylist, for screenUUID: String?) {
        stateLock.lock(); defer { stateLock.unlock() }
        if let uuid = screenUUID {
            playlistState?.screenPlaylists[uuid] = playlist
        } else {
            playlistState?.sharedPlaylist = playlist
        }
    }

    /// Whether a per-screen playlist exists for `uuid` (locked read).
    private func hasScreenPlaylist(_ uuid: String) -> Bool {
        stateLock.withLock { playlistState?.screenPlaylists[uuid] != nil }
    }

    private func loadPlaylistIfNeeded() {
        // Whole body under the lock: runs once per activation, and a
        // second queue arriving mid-load must wait for the loaded state
        // rather than race the decode. No re-entrant callouts inside
        // (mergeSidecarProgress is lock-held-only, see below).
        stateLock.lock(); defer { stateLock.unlock() }
        guard !playlistLoaded else { return }
        playlistLoaded = true

        let fileURL = PlaylistState.fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            playlistState = try decoder.decode(PlaylistState.self, from: data)
            debugLog("ExtensionVideoLoader: Loaded persisted playlist")
        } catch {
            debugLog("ExtensionVideoLoader: Failed to load playlist: \(error.localizedDescription)")
            playlistState = nil
            return
        }

        // Merge own sidecar for cross-activation resumption
        // (handles the case where extension activates multiple times
        // without the Companion restarting to consume the sidecar)
        mergeSidecarProgress()
    }

    /// Merge the progress sidecar into in-memory playlistState.
    /// This lets the extension resume from where it left off across activations.
    /// Called ONLY from `loadPlaylistIfNeeded` with `stateLock` held —
    /// do not lock here, and do not call from anywhere else.
    private func mergeSidecarProgress() {
        let fileURL = PlaylistProgressState.fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let progress = try? JSONDecoder().decode(PlaylistProgressState.self, from: data) else {
            return
        }

        if let sharedProgress = progress.sharedProgress, var shared = playlistState?.sharedPlaylist {
            if sharedProgress.updatedAt > shared.generatedAt {
                shared.currentIndex = min(sharedProgress.currentIndex, max(shared.entries.count - 1, 0))
                shared.playbackTimestamp = sharedProgress.playbackTimestamp
                playlistState?.sharedPlaylist = shared
            }
        }

        for (uuid, screenProgress) in progress.screenProgress {
            if var playlist = playlistState?.screenPlaylists[uuid] {
                if screenProgress.updatedAt > playlist.generatedAt {
                    playlist.currentIndex = min(screenProgress.currentIndex, max(playlist.entries.count - 1, 0))
                    playlist.playbackTimestamp = screenProgress.playbackTimestamp
                    playlistState?.screenPlaylists[uuid] = playlist
                }
            }
        }

        debugLog("ExtensionVideoLoader: Merged sidecar progress")
    }

    /// A renderer for `screenUUID`'s scope is being torn down after its
    /// idle grace. Remember the entry on screen and its held position so
    /// the next pop for that scope resumes it (see `pendingTeardownResume`).
    /// Unresolvable assets (random fallback, not in this playlist) record
    /// nothing — the next pop advances as before.
    func noteRendererTornDown(presentingLocalPath: String, timestamp: Double?, screenUUID: String?) {
        let scopeKey = screenUUID ?? "shared"
        guard let playlist = resolvePlaylist(screenUUID),
              let videoId = videoId(forLocalPath: presentingLocalPath),
              let index = playlist.index(ofVideoId: videoId) else {
            debugLog("ExtensionVideoLoader: teardown resume not recorded — presenting asset not in playlist (\(URL(fileURLWithPath: presentingLocalPath).lastPathComponent), scope=\(scopeKey.prefix(8)))")
            return
        }
        stateLock.withLock { pendingTeardownResume[scopeKey] = (index, timestamp) }
        debugLog("ExtensionVideoLoader: renderer torn down — next pop resumes index \(index) at \(timestamp.map { String(format: "%.1fs", $0) } ?? "start") (scope=\(scopeKey.prefix(8)))")
    }

    /// Update the progress sidecar with the video ON SCREEN and its
    /// playback position. Called from the periodic / video-change /
    /// invalidate flushes. `presentingLocalPath` is the renderer's
    /// current asset; its playlist index is resolved from there — NOT
    /// from `currentIndex`, which is the cursor and runs one entry ahead
    /// (the pre-popped next reader). Unresolvable (random fallback
    /// video, live feed, id not in this playlist) → no write, so the
    /// sidecar never carries a wrong index.
    func updateProgress(timestamp: Double?, presentingLocalPath: String, screenUUID: String?) {
        guard let playlist = resolvePlaylist(screenUUID) else { return }
        guard let videoId = videoId(forLocalPath: presentingLocalPath),
              let index = playlist.index(ofVideoId: videoId) else {
            let scopeKey = screenUUID ?? "shared"
            let firstTime = stateLock.withLock { () -> Bool in
                guard lastUnresolvedProgressPath[scopeKey] != presentingLocalPath else { return false }
                lastUnresolvedProgressPath[scopeKey] = presentingLocalPath
                return true
            }
            if firstTime {
                debugLog("ExtensionVideoLoader: progress not flushed — presenting asset not in playlist (\(URL(fileURLWithPath: presentingLocalPath).lastPathComponent), scope=\(scopeKey.prefix(8)))")
            }
            return
        }
        writeProgressSidecar(index: index, timestamp: timestamp, screenUUID: screenUUID)
    }

    /// Write the extension's position to the sidecar file. `index` is the
    /// entry ON SCREEN — never the cursor. Read back by
    /// `mergeSidecarProgress` on respawn (resume the same video at
    /// `timestamp`) and by the Companion's PlaylistManager (highlight /
    /// position sync).
    private func writeProgressSidecar(index: Int, timestamp: Double? = nil, screenUUID: String?) {
        let progress = PlaylistProgress(
            currentIndex: index,
            playbackTimestamp: timestamp,
            updatedAt: Date()
        )

        // Read existing sidecar or create new
        var state: PlaylistProgressState
        let fileURL = PlaylistProgressState.fileURL

        if let data = try? Data(contentsOf: fileURL),
           let existing = try? JSONDecoder().decode(PlaylistProgressState.self, from: data) {
            state = existing
        } else {
            state = PlaylistProgressState(sharedProgress: nil, screenProgress: [:])
        }

        if let uuid = screenUUID {
            state.screenProgress[uuid] = progress
        } else {
            state.sharedProgress = progress
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            debugLog("ExtensionVideoLoader: Failed to write progress sidecar: \(error.localizedDescription)")
        }
    }

    /// Update in-memory playlist position for immediate skip (called from Companion).
    func seekPlaylist(to index: Int, screenUUID: String?) {
        // Force reload from disk to pick up any playlist changes (e.g. after download)
        resetPlaylistCache()
        loadPlaylistIfNeeded()
        if var playlist = resolvePlaylist(screenUUID) {
            playlist.currentIndex = max(0, min(index, playlist.entries.count - 1))
            setPlaylist(playlist, for: screenUUID)
        }
        stateLock.withLock { isFirstVideoThisActivation = true }
    }

    /// Pop the previous video from the persisted playlist, scanning backward.
    /// Returns (video, shouldLoop), or nil if no playlist or no valid entry found.
    func popPreviousFromPlaylist(screenUUID: String?) -> (video: AerialVideo, shouldLoop: Bool, playDuration: Double?)? {
        // Companion mode: PlaylistManager owns the in-memory currentIndex
        // and persists it. Defer to its override so backward navigation
        // stays in sync with `nextVideoOverride`. Without this, the two
        // managers' currentIndex diverge whenever the user mixes
        // next / previous and we get "skipped two ahead" / "refuses to
        // skip" symptoms.
        if let override = videoList.previousVideoOverride {
            pendingPlayDuration = nil
            let (video, shouldLoop) = override(screenUUID)
            let playDuration = pendingPlayDuration
            pendingPlayDuration = nil
            if let video = video {
                return (video: video, shouldLoop: shouldLoop, playDuration: playDuration)
            }
            return nil
        }

        loadPlaylistIfNeeded()

        guard var playlist = resolvePlaylist(screenUUID) else { return nil }

        // User playlists: reload entries from disk (same as tryPersistedPlaylist)
        if playlist.filterMode == -1,
           let sentinel = playlist.filterStrings.first,
           sentinel.hasPrefix("userPlaylist:"),
           let uuid = UUID(uuidString: String(sentinel.dropFirst("userPlaylist:".count))) {
            let fileURL = UserPlaylistIndex.playlistURL(for: uuid)
            if let data = try? Data(contentsOf: fileURL),
               let manifest = try? JSONDecoder().decode(UserPlaylistManifest.self, from: data) {
                playlist.entries = manifest.entries
            } else {
                return nil
            }
        }

        // No time-of-day filter for user-initiated backward navigation:
        // the user explicitly asked to go back, so just find the nearest
        // cached video in reverse playlist order.
        guard let pop = playlist.popPreviousVideo(
            resolveVideo: { [self] id in
                videoList.videos.first(where: { $0.id == id && $0.isAvailableOffline })
            }
        ) else {
            debugLog("ExtensionVideoLoader: No valid previous entry found in playlist")
            return nil
        }

        let playDuration = playlist.entries.indices.contains(playlist.currentIndex)
            ? playlist.entries[playlist.currentIndex].playDuration : nil
        debugLog("ExtensionVideoLoader: Previous → \(pop.video.secondaryName) at index \(playlist.currentIndex)")
        setPlaylist(playlist, for: screenUUID)
        // Sidecar follows on the video-change flush once this entry is
        // presenting (see `updateProgress`).
        return (video: pop.video, shouldLoop: pop.shouldLoop, playDuration: playDuration)
    }

    /// Reset loaded state (call on each screensaver activation to pick up fresh playlist)
    func resetPlaylistCache() {
        stateLock.lock(); defer { stateLock.unlock() }
        playlistLoaded = false
        playlistState = nil
        isFirstVideoThisActivation = true
        catalogRefreshAttempted = false
    }

    /// Claims the single catalog-refresh retry for the current playlist
    /// load: true the first time, false until `resetPlaylistCache()`.
    private func claimCatalogRefreshAttempt() -> Bool {
        stateLock.withLock {
            if catalogRefreshAttempted { return false }
            catalogRefreshAttempted = true
            return true
        }
    }

    // MARK: - Status

    /// Whether any videos are cached locally for offline playback
    var hasCachedVideos: Bool {
        return videoList.videos.contains(where: { $0.isAvailableOffline })
    }

}

// MARK: - Pop rule (pure)

/// How a playlist pop treats the cursor: resume the entry under it (cold
/// start from the sidecar, or a renderer torn down after its idle grace),
/// advance past it (every later pop), or — the saver's "Don't resume video
/// at launch" — advance even where a resume was due. Pure so the override
/// is testable without the loader's file IO.
enum PlaylistPopRule {
    enum Overrode: Equatable { case nothing, coldResume, teardownResume }
    enum Path: Equatable {
        case coldResume, teardownResume, advance
        case launchAdvance(overrode: Overrode)
    }
    struct Decision: Equatable {
        let isResume: Bool
        let resumeTimestamp: Double?
        /// Cursor to install before popping — the teardown record's ON-SCREEN
        /// index (the stored cursor is one ahead after the pre-pop, so
        /// advancing from it would skip an entry). nil = keep the cursor.
        let cursorOverride: Int?
        let path: Path
    }

    /// `teardownResume`: nil when there is no record or its index is out of
    /// range for the playlist.
    static func decide(isFirstActivation: Bool, sidecarTimestamp: Double?,
                       teardownResume: (index: Int, timestamp: Double?)?,
                       advanceRequested: Bool) -> Decision {
        // A record only applies to a pop that is not the activation's
        // first: a playlist reset in between makes its index meaningless.
        let teardown = isFirstActivation ? nil : teardownResume
        if advanceRequested {
            let overrode: Overrode = isFirstActivation ? .coldResume : (teardown != nil ? .teardownResume : .nothing)
            return Decision(isResume: false, resumeTimestamp: nil, cursorOverride: teardown?.index,
                            path: .launchAdvance(overrode: overrode))
        }
        if isFirstActivation {
            return Decision(isResume: true, resumeTimestamp: sidecarTimestamp, cursorOverride: nil, path: .coldResume)
        }
        if let teardown {
            return Decision(isResume: true, resumeTimestamp: teardown.timestamp, cursorOverride: teardown.index,
                            path: .teardownResume)
        }
        return Decision(isResume: false, resumeTimestamp: nil, cursorOverride: nil, path: .advance)
    }
}
