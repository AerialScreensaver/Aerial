//
//  PlaylistManager.swift
//  Aerial Companion
//
//  Central manager for persistent playlists.
//  Generates playlists from the current rotation, persists to playlists.json,
//  and provides the next-video API for both desktop and screensaver modes.
//

import Foundation

class PlaylistManager {

    // MARK: - Singleton

    static let shared = PlaylistManager()

    // MARK: - Private Properties

    private var state: PlaylistState
    private let queue = DispatchQueue(label: "com.glouel.aerial.playlist", attributes: .concurrent)
    private let store = JSONPreferencesStore.shared

    /// True until the first video is popped; plays currentIndex (resume).
    /// After the first pop, set to false so subsequent calls advance.
    private var needsResume = true

    // MARK: - Notifications

    static let playlistDidChangeNotification = Notification.Name("com.glouel.aerial.playlistDidChange")

    // MARK: - Init

    private init() {
        // Load persisted state or start fresh
        if let loaded = JSONPreferencesStore.shared.read(PlaylistState.self, from: PlaylistState.fileURL) {
            state = loaded
        } else {
            state = PlaylistState(version: 1, sharedPlaylist: nil, screenPlaylists: [:])
        }

        // Incorporate extension progress sidecar if present
        incorporateExtensionProgress()
    }

    // MARK: - Companion Integration

    /// Install the playlist override on VideoList so the active video player uses our managed playlist.
    /// Call this once after VideoList has loaded its videos.
    func installVideoOverride() {
        VideoList.instance.nextVideoOverride = { [weak self] _, _, screenUUID in
            guard let self = self else { return (nil, false) }

            // Try popping from existing playlist
            let (video, shouldLoop) = self.popNextVideo(for: screenUUID)
            if video != nil {
                return (video, shouldLoop)
            }

            // No playlist or all entries stale — regenerate and try again
            // Don't regenerate user playlists (they're explicit, not filter-derived)
            if self.isUserPlaylistActive(for: screenUUID) {
                return (nil, false)
            }
            self.regenerate(for: screenUUID)
            return self.popNextVideo(for: screenUUID)
        }

        // Sibling override for backward navigation. Without this, the
        // extension-side `popPreviousFromPlaylist` would update its own
        // playlistState (not PlaylistManager's), causing the two
        // currentIndex values to diverge and producing the "skipped
        // two ahead / refuses to skip" bug when the user mixes
        // next / previous in Companion mode.
        VideoList.instance.previousVideoOverride = { [weak self] screenUUID in
            guard let self = self else { return (nil, false) }
            return self.popPreviousVideo(for: screenUUID)
        }
        //debugLog("PlaylistManager: installed video override on VideoList")
    }

    /// Atomically get the next video and update in-memory position.
    /// Position is ephemeral in desktop mode — only the extension persists position.
    func popNextVideo(for screenUUID: String? = nil) -> (AerialVideo?, Bool) {
        refreshIfFilterDrifted(for: screenUUID)

        var didReshuffle = false
        var nextEntryID: String?

        let result: (AerialVideo?, Bool) = queue.sync(flags: .barrier) {
            guard var playlist = resolvePlaylist(screenUUID),
                  !playlist.entries.isEmpty else {
                return (nil, false)
            }

            // Capture resume timestamp before popNextVideo() clears it
            let savedTimestamp = needsResume ? playlist.playbackTimestamp : nil

            guard let pop = playlist.popNextVideo(
                isResume: needsResume,
                resolveVideo: { id in
                    VideoList.instance.videos.first(where: { $0.id == id && $0.isAvailableOffline })
                },
                shouldPlay: { video in
                    TimeManagement.videoMatchesCurrentTime(video)
                },
                shouldPlayFallback: { video in
                    TimeManagement.videoMatchesCurrentTimeWithFallback(video)
                }
            ) else {
                debugLog("📋 Playlist exhausted: all \(playlist.entries.count) entries stale (mode: \(playlist.cycleMode))")
                didReshuffle = playlist.cycleMode == .shuffle
                setPlaylist(playlist, for: screenUUID)
                persist()
                return (nil, false)
            }

            didReshuffle = pop.didReshuffle
            if didReshuffle {
                debugLog("📋 Playlist wrap-around reshuffle (\(playlist.entries.count) entries, mode: \(playlist.cycleMode))")
            }
            needsResume = false
            ExtensionVideoLoader.shared.pendingResumeTimestamp = savedTimestamp
            // Mirror the resume side-channel for the popped entry's play-duration override.
            // Written on every pop (incl. nil) so a later video never inherits a stale value.
            ExtensionVideoLoader.shared.pendingPlayDuration = playlist.entries.indices.contains(playlist.currentIndex)
                ? playlist.entries[playlist.currentIndex].playDuration : nil
            setPlaylist(playlist, for: screenUUID)
            persist()
            debugLog("📋 Playlist pop: [\(playlist.currentIndex + 1)/\(playlist.entries.count)] \"\(pop.video.name)\" (loop=\(pop.shouldLoop), mode=\(playlist.cycleMode))")
            // Peek at the entry that will play after this one so we can
            // pre-warm live feeds (yt-dlp resolve, ffmpeg transmux start)
            // while the current video is still on screen.
            if !playlist.entries.isEmpty {
                let peekIdx = (playlist.currentIndex + 1) % playlist.entries.count
                nextEntryID = playlist.entries[peekIdx].videoId
            }
            return (pop.video, pop.shouldLoop)
        }

        if didReshuffle {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.playlistDidChangeNotification, object: screenUUID)
            }
        }

        if let id = nextEntryID {
            prewarmIfLiveFeed(videoID: id)
        }

        return result
    }

    /// Atomically step back to the previous entry and update in-memory
    /// position. No time-of-day filter is applied — matches the
    /// extension-side `popPreviousFromPlaylist` semantics: backward is
    /// user-initiated, the user wants the immediately-previous cached
    /// entry regardless of whether it matches the current time slice.
    func popPreviousVideo(for screenUUID: String? = nil) -> (AerialVideo?, Bool) {
        refreshIfFilterDrifted(for: screenUUID)

        return queue.sync(flags: .barrier) {
            guard var playlist = resolvePlaylist(screenUUID),
                  !playlist.entries.isEmpty else {
                return (nil, false)
            }

            guard let pop = playlist.popPreviousVideo(
                resolveVideo: { id in
                    VideoList.instance.videos.first(where: { $0.id == id && $0.isAvailableOffline })
                }
            ) else {
                debugLog("📋 Playlist popPrevious: no valid entry found")
                return (nil, false)
            }

            // Backward navigation clears any pending resume timestamp:
            // we're explicitly jumping somewhere new, not resuming.
            needsResume = false
            ExtensionVideoLoader.shared.pendingResumeTimestamp = nil
            ExtensionVideoLoader.shared.pendingPlayDuration = playlist.entries.indices.contains(playlist.currentIndex)
                ? playlist.entries[playlist.currentIndex].playDuration : nil
            setPlaylist(playlist, for: screenUUID)
            persist()
            debugLog("📋 Playlist popPrevious: [\(playlist.currentIndex + 1)/\(playlist.entries.count)] \"\(pop.video.name)\" (loop=\(pop.shouldLoop))")
            return (pop.video, pop.shouldLoop)
        }
    }

    /// If `videoID` matches a live feed, trigger its async resolution
    /// (yt-dlp URL refresh, RTSP ffmpeg transmux start) so the URL is
    /// hot by the time the playlist rotates to it.
    private func prewarmIfLiveFeed(videoID: String) {
        guard let feedID = UUID(uuidString: videoID),
              let feed = LiveFeedManager.shared.feed(id: feedID) else {
            return
        }
        LiveFeedResolver.shared.resolveIfNeeded(feed)
    }

    // MARK: - Position Persistence

    /// Update the playback timestamp for the current video (called by desktop position timer).
    func updatePlaybackTimestamp(_ timestamp: Double?, for screenUUID: String? = nil) {
        queue.sync(flags: .barrier) {
            guard var playlist = resolvePlaylist(screenUUID) else { return }
            playlist.playbackTimestamp = timestamp
            setPlaylist(playlist, for: screenUUID)
            persist()
        }
    }

    /// Get the stored playback timestamp for a screen's playlist.
    func currentPlaybackTimestamp(for screenUUID: String? = nil) -> Double? {
        return queue.sync {
            resolvePlaylist(screenUUID)?.playbackTimestamp
        }
    }

    /// Mark the playlist for resume on next pop (used for screensaver handoff).
    func markForResume() {
        needsResume = true
    }

    // MARK: - Public API

    /// If the *shared* playlist's stored filter has drifted from the current
    /// `PrefsVideos.newShouldPlay` / `newShouldPlayString` (e.g. the user
    /// changed the filter from a UI path that wrote the prefs but didn't
    /// regenerate — the global popover branch is one such path), regenerate
    /// it from current prefs before the next pop. Mirrors the defensive
    /// check `ExtensionVideoLoader.tryPersistedPlaylist` does on its side
    /// so both extension and desktop reach the same playlist for the same
    /// prefs.
    ///
    /// Per-screen playlists are intentionally exempt: they carry their own
    /// filter chosen explicitly by the user and don't track global prefs.
    /// User playlists (`filterMode == -1`) are also exempt.
    private func refreshIfFilterDrifted(for screenUUID: String?) {
        let needsRegen: Bool = queue.sync {
            guard let playlist = resolvePlaylist(screenUUID),
                  playlist.filterMode != -1 else { return false }
            // Shared playlist iff: no screenUUID, OR the screen has no
            // dedicated entry (resolvePlaylist falls back to sharedPlaylist).
            let isShared = screenUUID == nil || state.screenPlaylists[screenUUID!] == nil
            guard isShared else { return false }
            let currentMode = PrefsVideos.newShouldPlay.rawValue
            let currentStrings = Set(PrefsVideos.newShouldPlayString)
            return playlist.filterMode != currentMode
                || Set(playlist.filterStrings) != currentStrings
        }
        if needsRegen {
            debugLog("📋 Shared playlist filter drift detected — regenerating from current prefs")
            regenerate(for: screenUUID,
                       mode: PrefsVideos.newShouldPlay,
                       filterStrings: PrefsVideos.newShouldPlayString)
        }
    }

    /// Regenerate the playlist for a screen (nil = shared playlist).
    /// If a per-screen playlist already has a stored filter, preserve it so
    /// app restarts don't clobber the user's per-screen choice with global
    /// prefs. Fall back to global `PrefsVideos` only when no prior filter
    /// exists (fresh screen, or shared playlist has never been generated).
    func regenerate(for screenUUID: String? = nil) {
        let preserved: (mode: NewShouldPlay, filterStrings: [String])? = queue.sync {
            guard let existing = resolvePlaylist(screenUUID),
                  let mode = NewShouldPlay(rawValue: existing.filterMode) else { return nil }
            return (mode, existing.filterStrings)
        }

        if let preserved = preserved {
            regenerate(for: screenUUID, mode: preserved.mode, filterStrings: preserved.filterStrings)
        } else {
            regenerate(for: screenUUID,
                       mode: PrefsVideos.newShouldPlay,
                       filterStrings: PrefsVideos.newShouldPlayString)
        }
    }

    /// Regenerate with explicit filter parameters (for per-screen overrides).
    func regenerate(for screenUUID: String? = nil, mode: NewShouldPlay, filterStrings: [String]) {
        queue.sync(flags: .barrier) {
            // Re-merge extension sidecar so the latest position overrides
            // any ephemeral desktop-mode drift before we rebuild
            if mergeExtensionProgress() {
                store.delete(at: PlaylistProgressState.fileURL)
            }

            let existing = resolvePlaylist(screenUUID)

            let playlist: PersistedPlaylist
            if let existing = existing,
               existing.filterMode == mode.rawValue,
               existing.filterStrings == filterStrings {
                playlist = refreshPlaylist(existing, mode: mode, filterStrings: filterStrings)
            } else {
                playlist = buildFreshPlaylist(mode: mode, filterStrings: filterStrings)
            }

            setPlaylist(playlist, for: screenUUID)

            // Clear stale per-screen playlists when regenerating the shared playlist
            // in non-independent mode (they're leftovers from a previous viewing mode)
            if screenUUID == nil && PrefsDisplays.viewingMode != .independent {
                state.screenPlaylists.removeAll()
            }

            needsResume = true
            persist()
        }

        NotificationCenter.default.post(name: Self.playlistDidChangeNotification, object: screenUUID)
    }

    /// Regenerate all playlists (shared + per-screen) using each playlist's stored filter.
    /// Use this when a download completes so every playlist picks up the newly cached video.
    func regenerateAll() {
        queue.sync(flags: .barrier) {
            if mergeExtensionProgress() {
                store.delete(at: PlaylistProgressState.fileURL)
            }

            // Regenerate shared playlist
            if let shared = state.sharedPlaylist,
               let mode = NewShouldPlay(rawValue: shared.filterMode) {
                state.sharedPlaylist = refreshPlaylist(shared, mode: mode, filterStrings: shared.filterStrings)
            }

            // Regenerate each per-screen playlist
            for (uuid, playlist) in state.screenPlaylists {
                if let mode = NewShouldPlay(rawValue: playlist.filterMode) {
                    state.screenPlaylists[uuid] = refreshPlaylist(playlist, mode: mode, filterStrings: playlist.filterStrings)
                }
            }

            needsResume = true
            persist()
        }

        NotificationCenter.default.post(name: Self.playlistDidChangeNotification, object: nil)
    }

    /// Immediately reshuffle every playlist's order, keeping the currently
    /// playing video at the front so live playback isn't interrupted and the
    /// strip highlight stays in sync. Called when the user switches the popover
    /// into shuffle mode. Unlike `regenerateAll()` (which preserves order and is
    /// fired on every download completion), this produces a visible, immediate
    /// reshuffle.
    func reshuffleAll() {
        queue.sync(flags: .barrier) {
            if mergeExtensionProgress() {
                store.delete(at: PlaylistProgressState.fileURL)
            }

            if let shared = state.sharedPlaylist {
                state.sharedPlaylist = reshufflePreservingCurrent(shared)
            }

            for (uuid, playlist) in state.screenPlaylists {
                state.screenPlaylists[uuid] = reshufflePreservingCurrent(playlist)
            }

            persist()
        }

        NotificationCenter.default.post(name: Self.playlistDidChangeNotification, object: nil)
    }

    /// Shuffle a playlist's entries while keeping the current video at the
    /// front (currentIndex 0) and setting cycleMode to `.shuffle`.
    /// Must be called inside the barrier queue.
    private func reshufflePreservingCurrent(_ playlist: PersistedPlaylist) -> PersistedPlaylist {
        var p = playlist
        p.cycleMode = .shuffle
        guard p.entries.count > 1 else { return p }
        let idx = p.entries.indices.contains(p.currentIndex) ? p.currentIndex : 0
        let current = p.entries[idx]
        var rest = p.entries
        rest.remove(at: idx)
        rest.shuffle()
        p.entries = [current] + rest
        p.currentIndex = 0
        return p
    }

    // MARK: - User Playlist Activation

    /// Activate a user-created playlist for playback.
    /// Loads the manifest and converts to a PersistedPlaylist with sentinel filterMode = -1.
    func activateUserPlaylist(id: UUID, for screenUUID: String? = nil) {
        guard let manifest = UserPlaylistManager.shared.playlist(id: id) else { return }

        let playlist = PersistedPlaylist(
            entries: manifest.entries,
            currentIndex: 0,
            playbackTimestamp: nil,
            filterMode: -1,
            filterStrings: ["userPlaylist:\(id.uuidString)"],
            generatedAt: Date(),
            cycleMode: manifest.cycleMode
        )

        queue.sync(flags: .barrier) {
            setPlaylist(playlist, for: screenUUID)
            needsResume = true
            persist()
        }

        NotificationCenter.default.post(name: Self.playlistDidChangeNotification, object: screenUUID)
    }

    /// Whether the active playlist is a user playlist (filterMode == -1).
    func isUserPlaylistActive(for screenUUID: String? = nil) -> Bool {
        return queue.sync {
            resolvePlaylist(screenUUID)?.filterMode == -1
        }
    }

    /// The UUID of the active user playlist, if any.
    func activeUserPlaylistId(for screenUUID: String? = nil) -> UUID? {
        return queue.sync {
            guard let playlist = resolvePlaylist(screenUUID),
                  playlist.filterMode == -1,
                  let first = playlist.filterStrings.first,
                  first.hasPrefix("userPlaylist:") else { return nil }
            return UUID(uuidString: String(first.dropFirst("userPlaylist:".count)))
        }
    }

    /// Reload the active user playlist from disk (called when user edits the playlist).
    func reloadActiveUserPlaylistIfNeeded(for screenUUID: String? = nil) {
        guard let activeId = activeUserPlaylistId(for: screenUUID) else { return }
        guard let manifest = UserPlaylistManager.shared.playlist(id: activeId) else { return }

        queue.sync(flags: .barrier) {
            guard var playlist = resolvePlaylist(screenUUID),
                  playlist.filterMode == -1 else { return }
            // Preserve current position if possible
            let currentVideoId = playlist.entries.indices.contains(playlist.currentIndex)
                ? playlist.entries[playlist.currentIndex].videoId
                : nil
            playlist.entries = manifest.entries
            if let cvid = currentVideoId,
               let newIdx = manifest.entries.firstIndex(where: { $0.videoId == cvid }) {
                playlist.currentIndex = newIdx
            } else {
                playlist.currentIndex = min(playlist.currentIndex, max(manifest.entries.count - 1, 0))
            }
            setPlaylist(playlist, for: screenUUID)
            persist()
        }

        NotificationCenter.default.post(name: Self.playlistDidChangeNotification, object: screenUUID)
    }

    // MARK: - Live Sync

    /// Merge extension progress sidecar and notify observers.
    /// Unlike incorporateExtensionProgress(), does NOT delete the sidecar
    /// (the extension is still running and may write again).
    func syncFromExtension() {
        queue.sync(flags: .barrier) {
            if mergeExtensionProgress() {
                persist()
            }
        }
        NotificationCenter.default.post(name: Self.playlistDidChangeNotification, object: nil)
    }

    /// Merge the extension progress sidecar, persist, and delete the
    /// sidecar. Intended for the "extension just stopped, Companion is
    /// about to take over" handoff points (manual desktop launch, etc.)
    /// where the extension is not going to write again and we don't
    /// want a stale sidecar leaking into the next round trip.
    func consumeExtensionProgressIfAvailable() {
        queue.sync(flags: .barrier) {
            if mergeExtensionProgress() {
                persist()
                store.delete(at: PlaylistProgressState.fileURL)
            }
        }
    }

    // MARK: - Direct Navigation

    /// Jump to a specific index in the playlist, persist, and notify.
    func setCurrentIndex(_ index: Int, for screenUUID: String? = nil) {
        queue.sync(flags: .barrier) {
            guard var playlist = resolvePlaylist(screenUUID),
                  !playlist.entries.isEmpty else { return }
            playlist.currentIndex = max(0, min(index, playlist.entries.count - 1))
            playlist.playbackTimestamp = nil
            needsResume = true
            setPlaylist(playlist, for: screenUUID)
            persist()
            // Delete stale sidecar — the Companion's explicit index takes precedence
            store.delete(at: PlaylistProgressState.fileURL)
        }
        NotificationCenter.default.post(name: Self.playlistDidChangeNotification, object: screenUUID)
    }

    // MARK: - Query API

    /// Get the current playlist entry for a screen (nil = shared).
    func currentEntry(for screenUUID: String? = nil) -> PlaylistEntry? {
        return queue.sync {
            guard let playlist = resolvePlaylist(screenUUID),
                  !playlist.entries.isEmpty else { return nil }
            let index = playlist.currentIndex % playlist.entries.count
            return playlist.entries[index]
        }
    }

    /// Get all entries for a screen's playlist (nil = shared).
    func allEntries(for screenUUID: String? = nil) -> [PlaylistEntry] {
        return queue.sync {
            return resolvePlaylist(screenUUID)?.entries ?? []
        }
    }

    /// Get the current index for a screen's playlist. Returns 0 if no playlist exists.
    func currentIndex(for screenUUID: String? = nil) -> Int {
        return queue.sync {
            return resolvePlaylist(screenUUID)?.currentIndex ?? 0
        }
    }

    // (Index helpers removed — global next/previous now go through
    // dedicated playNextVideo / playPreviousVideo paths in
    // `PlayerCoordinator`, which handle filter-aware backward scan.)

    /// Get the stored filter state from a per-screen playlist.
    func filterInfo(for screenUUID: String? = nil) -> (mode: NewShouldPlay, filterStrings: [String])? {
        return queue.sync {
            guard let playlist = resolvePlaylist(screenUUID),
                  let mode = NewShouldPlay(rawValue: playlist.filterMode) else { return nil }
            return (mode, playlist.filterStrings)
        }
    }

    /// All filter selections currently driving playback: shared playlist plus
    /// any per-screen playlists. Used by DownloadCoordinator to evaluate what
    /// videos need to be cached across every active selection (so per-screen
    /// filter changes also trigger downloads, not just global ones).
    /// User-playlist entries (`filterMode == -1`) are skipped — those videos
    /// are managed by UserPlaylistManager.
    func activeFilters() -> [(mode: NewShouldPlay, filterStrings: [String])] {
        return queue.sync {
            var result: [(NewShouldPlay, [String])] = []
            if let shared = state.sharedPlaylist,
               let mode = NewShouldPlay(rawValue: shared.filterMode) {
                result.append((mode, shared.filterStrings))
            }
            for playlist in state.screenPlaylists.values {
                if let mode = NewShouldPlay(rawValue: playlist.filterMode) {
                    result.append((mode, playlist.filterStrings))
                }
            }
            return result
        }
    }

    /// Resolve the AerialVideo for the current playlist entry, verifying it's available offline.
    /// Returns nil if nothing has played yet or the video is missing from cache.
    func currentVideo(for screenUUID: String? = nil) -> AerialVideo? {
        guard let entry = currentEntry(for: screenUUID) else { return nil }
        guard let video = VideoList.instance.videos.first(where: { $0.id == entry.videoId }) else { return nil }
        guard video.isAvailableOffline else { return nil }
        return video
    }

    // MARK: - Private Helpers

    /// Full rebuild: shuffled playlist from scratch with currentIndex 0 (first video to play).
    /// Must be called inside the barrier queue.
    private func buildFreshPlaylist(mode: NewShouldPlay, filterStrings: [String]) -> PersistedPlaylist {
        let allMatching = VideoList.instance.videosMatchingFilter(
            mode: mode,
            filterStrings: filterStrings
        )

        let cached = allMatching.filter { $0.isAvailableOffline }
        var shuffled = cached.shuffled()

        // Fall back to the global cache ONLY when the filter resolves
        // to no videos at all (empty Expansion, deleted source, etc.).
        // If the filter HAS videos but none are downloaded yet — the
        // typical "Set to play now on a fresh Expansion without
        // pre-download" case — leave the playlist empty and let the
        // post-download `regenerateAll` hook backfill it once the
        // first critical download lands. Falling back here would
        // silently play unrelated content while the user waits.
        if shuffled.isEmpty && allMatching.isEmpty {
            shuffled = VideoList.instance.videos
                .filter { $0.isAvailableOffline && !PrefsVideos.hidden.contains($0.id) }
                .shuffled()
        }

        let entries = shuffled.map { video in
            PlaylistEntry(
                videoId: video.id,
                videoName: video.name,
                secondaryName: video.secondaryName,
                duration: video.duration > 0 ? video.duration : nil
            )
        }

        return PersistedPlaylist(
            entries: entries,
            currentIndex: 0,
            playbackTimestamp: nil,
            filterMode: mode.rawValue,
            filterStrings: filterStrings,
            generatedAt: Date(),
            cycleMode: Preferences.playlistShuffle ? .shuffle : .loop
        )
    }

    /// Refresh in place: keep existing entries and position, remove stale videos,
    /// append newly cached ones. Falls back to buildFreshPlaylist if nothing survives.
    /// Must be called inside the barrier queue.
    private func refreshPlaylist(_ existing: PersistedPlaylist, mode: NewShouldPlay, filterStrings: [String]) -> PersistedPlaylist {
        // Build the set of video IDs that currently match and are cached
        let allMatching = VideoList.instance.videosMatchingFilter(
            mode: mode,
            filterStrings: filterStrings
        )
        let cachedIds = Set(allMatching.filter { $0.isAvailableOffline }.map { $0.id })

        // Remember which video is current
        let currentVideoId: String? = existing.entries.indices.contains(existing.currentIndex)
            ? existing.entries[existing.currentIndex].videoId
            : nil

        // Walk entries: keep those still cached, track removals before currentIndex
        var keptEntries: [PlaylistEntry] = []
        var removedBeforeCurrent = 0
        for (i, entry) in existing.entries.enumerated() {
            if cachedIds.contains(entry.videoId) {
                keptEntries.append(entry)
            } else if i < existing.currentIndex {
                removedBeforeCurrent += 1
            }
        }

        // If nothing survived, full rebuild
        if keptEntries.isEmpty {
            return buildFreshPlaylist(mode: mode, filterStrings: filterStrings)
        }

        // Adjust currentIndex after removals
        var newIndex = existing.currentIndex - removedBeforeCurrent
        newIndex = max(0, min(newIndex, keptEntries.count - 1))

        // Preserve playbackTimestamp only if the current video survived at the adjusted position
        let timestampSurvived = keptEntries.indices.contains(newIndex)
            && keptEntries[newIndex].videoId == currentVideoId
        let playbackTimestamp = timestampSurvived ? existing.playbackTimestamp : nil

        // Append newly cached videos (not already in the playlist) in shuffled order
        let existingIds = Set(keptEntries.map { $0.videoId })
        let newVideos = allMatching.filter { $0.isAvailableOffline && !existingIds.contains($0.id) }.shuffled()
        let newEntries = newVideos.map { video in
            PlaylistEntry(
                videoId: video.id,
                videoName: video.name,
                secondaryName: video.secondaryName,
                duration: video.duration > 0 ? video.duration : nil
            )
        }
        keptEntries.append(contentsOf: newEntries)

        return PersistedPlaylist(
            entries: keptEntries,
            currentIndex: newIndex,
            playbackTimestamp: playbackTimestamp,
            filterMode: mode.rawValue,
            filterStrings: filterStrings,
            generatedAt: Date(),
            cycleMode: Preferences.playlistShuffle ? .shuffle : .loop
        )
    }

    private func resolvePlaylist(_ screenUUID: String?) -> PersistedPlaylist? {
        if let uuid = screenUUID, let perScreen = state.screenPlaylists[uuid] {
            return perScreen
        }
        return state.sharedPlaylist
    }

    private func setPlaylist(_ playlist: PersistedPlaylist, for screenUUID: String?) {
        if let uuid = screenUUID {
            state.screenPlaylists[uuid] = playlist
        } else {
            state.sharedPlaylist = playlist
        }
    }

    private func persist() {
        store.write(state, to: PlaylistState.fileURL)
    }

    /// Read the extension's progress sidecar and merge into in-memory state.
    /// Returns true if anything was merged (caller decides whether to persist/delete).
    @discardableResult
    private func mergeExtensionProgress() -> Bool {
        guard let progress = store.read(PlaylistProgressState.self, from: PlaylistProgressState.fileURL) else {
            return false
        }

        var changed = false

        if let sharedProgress = progress.sharedProgress, var shared = state.sharedPlaylist {
            if sharedProgress.updatedAt > shared.generatedAt {
                shared.currentIndex = min(sharedProgress.currentIndex, max(shared.entries.count - 1, 0))
                shared.playbackTimestamp = sharedProgress.playbackTimestamp
                state.sharedPlaylist = shared
                changed = true
            }
        }

        for (uuid, screenProgress) in progress.screenProgress {
            if var playlist = state.screenPlaylists[uuid] {
                if screenProgress.updatedAt > playlist.generatedAt {
                    playlist.currentIndex = min(screenProgress.currentIndex, max(playlist.entries.count - 1, 0))
                    playlist.playbackTimestamp = screenProgress.playbackTimestamp
                    state.screenPlaylists[uuid] = playlist
                    changed = true
                }
            }
        }

        return changed
    }

    /// Read the extension's progress sidecar, merge, persist, and delete sidecar.
    /// Used at init time.
    private func incorporateExtensionProgress() {
        if mergeExtensionProgress() {
            persist()
            store.delete(at: PlaylistProgressState.fileURL)
        }
    }

}
