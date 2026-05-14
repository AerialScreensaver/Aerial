//
//  ExtensionVideoLoader.swift
//  AerialScreenSaverExtension
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

    /// Loaded playlist state from disk (lazy, loaded once per activation)
    private var playlistState: PlaylistState?
    private var playlistLoaded = false

    /// True on first video request after activation; plays currentIndex (resume).
    /// After the first video, set to false so subsequent calls advance.
    private var isFirstVideoThisActivation = true

    /// Resume timestamp set by PlaylistManager's override closure (Companion only).
    /// Used as a side-channel since the override returns (AerialVideo?, Bool) without timestamp.
    var pendingResumeTimestamp: Double?

    private init() {
        // Explicitly trigger video list loading after VideoList.instance is initialized.
        // Cannot happen during VideoList.init() due to dispatch_once re-entrancy
        // from SourceInfo.findDuplicate accessing VideoList.instance.
        videoList.reloadSources()
        let cachedCount = videoList.videos.filter { $0.isAvailableOffline }.count
        debugLog("ExtensionVideoLoader: Initialized with \(videoList.videos.count) videos (\(cachedCount) cached)")
    }

    // MARK: - Video Selection

    /// Get the next video to play, respecting persisted playlist if available.
    /// Returns (video, shouldLoop, resumeTimestamp) — resumeTimestamp is non-nil only on first video resume.
    func getNextVideo(isVertical: Bool, screenUUID: String? = nil) -> (AerialVideo?, Bool, Double?) {
        // In Companion mode (override installed), PlaylistManager is the single source of truth.
        // Skip tryPersistedPlaylist() so we go through videoList.randomVideo() → the override.
        if videoList.nextVideoOverride != nil {
            pendingResumeTimestamp = nil
            let (video, loop) = videoList.randomVideo(excluding: [], isVertical: isVertical, screenUUID: screenUUID)
            let timestamp = pendingResumeTimestamp
            pendingResumeTimestamp = nil
            return (video, loop, timestamp)
        }

        // Extension mode: use persisted playlist directly from disk
        if let (video, shouldLoop, resumeTimestamp) = tryPersistedPlaylist(screenUUID: screenUUID) {
            debugLog("ExtensionVideoLoader: Using persisted playlist → \(video.secondaryName), shouldLoop=\(shouldLoop), resumeAt=\(resumeTimestamp.map { String(format: "%.1fs", $0) } ?? "nil")")
            return (video, shouldLoop, resumeTimestamp)
        }

        debugLog("ExtensionVideoLoader: No persisted playlist, falling back to VideoList")
        let (video, loop) = videoList.randomVideo(excluding: [], isVertical: isVertical)
        return (video, loop, nil)
    }

    /// Get the local file path for a video
    func localPathFor(video: AerialVideo) -> String {
        return videoList.localPathFor(video: video)
    }

    // MARK: - Persisted Playlist

    private func tryPersistedPlaylist(screenUUID: String?) -> (AerialVideo, Bool, Double?)? {
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
            let isSharedPlaylist = (screenUUID == nil) || (playlistState?.screenPlaylists[screenUUID!] == nil)
            if isSharedPlaylist {
                let currentMode = PrefsVideos.newShouldPlay.rawValue
                let currentStrings = Set(PrefsVideos.newShouldPlayString)
                if playlist.filterMode != currentMode || Set(playlist.filterStrings) != currentStrings {
                    debugLog("ExtensionVideoLoader: Shared playlist filter mismatch (stored mode=\(playlist.filterMode) vs current=\(currentMode)), skipping")
                    return nil
                }
            }
        }

        // Capture resume timestamp before popNextVideo() clears it
        let resumeTimestamp: Double? = isFirstVideoThisActivation ? playlist.playbackTimestamp : nil

        debugLog("ExtensionVideoLoader: Playlist has \(playlist.entries.count) entries, currentIndex=\(playlist.currentIndex), resume=\(isFirstVideoThisActivation)")

        guard let pop = playlist.popNextVideo(
            isResume: isFirstVideoThisActivation,
            resolveVideo: { [self] id in
                videoList.videos.first(where: { $0.id == id && $0.isAvailableOffline })
            },
            shouldPlay: { video in
                TimeManagement.videoMatchesCurrentTime(video)
            },
            shouldPlayFallback: { video in
                TimeManagement.videoMatchesCurrentTimeWithFallback(video)
            }
        ) else {
            debugLog("ExtensionVideoLoader: No valid offline entries found in playlist, reshuffled")
            setPlaylist(playlist, for: screenUUID)
            return nil
        }

        isFirstVideoThisActivation = false
        debugLog("ExtensionVideoLoader: Selected \(pop.video.secondaryName) at index \(playlist.currentIndex)")
        setPlaylist(playlist, for: screenUUID)
        writeProgressSidecar(index: playlist.currentIndex, timestamp: resumeTimestamp, screenUUID: screenUUID)
        return (pop.video, pop.shouldLoop, resumeTimestamp)
    }

    private func resolvePlaylist(_ screenUUID: String?) -> PersistedPlaylist? {
        guard let state = playlistState else { return nil }
        if let uuid = screenUUID, let perScreen = state.screenPlaylists[uuid] {
            return perScreen
        }
        return state.sharedPlaylist
    }

    private func setPlaylist(_ playlist: PersistedPlaylist, for screenUUID: String?) {
        if let uuid = screenUUID {
            playlistState?.screenPlaylists[uuid] = playlist
        } else {
            playlistState?.sharedPlaylist = playlist
        }
    }

    private func loadPlaylistIfNeeded() {
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

    /// Update the progress sidecar with the current playback position.
    /// Called periodically by AerialSaverView's progress timer.
    func updateProgress(timestamp: Double?, screenUUID: String?) {
        guard let playlist = resolvePlaylist(screenUUID) else { return }
        writeProgressSidecar(index: playlist.currentIndex, timestamp: timestamp, screenUUID: screenUUID)
    }

    /// Write the extension's current position to a sidecar file.
    /// The Companion reads this on next startup to sync position.
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
        isFirstVideoThisActivation = true
    }

    /// Pop the previous video from the persisted playlist, scanning backward.
    /// Returns (video, shouldLoop), or nil if no playlist or no valid entry found.
    func popPreviousFromPlaylist(screenUUID: String?) -> (AerialVideo, Bool)? {
        // Companion mode: PlaylistManager owns the in-memory currentIndex
        // and persists it. Defer to its override so backward navigation
        // stays in sync with `nextVideoOverride`. Without this, the two
        // managers' currentIndex diverge whenever the user mixes
        // next / previous and we get "skipped two ahead" / "refuses to
        // skip" symptoms.
        if let override = videoList.previousVideoOverride {
            let (video, shouldLoop) = override(screenUUID)
            if let video = video {
                return (video, shouldLoop)
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

        debugLog("ExtensionVideoLoader: Previous → \(pop.video.secondaryName) at index \(playlist.currentIndex)")
        setPlaylist(playlist, for: screenUUID)
        writeProgressSidecar(index: playlist.currentIndex, timestamp: nil, screenUUID: screenUUID)
        return (pop.video, pop.shouldLoop)
    }

    /// Reset loaded state (call on each screensaver activation to pick up fresh playlist)
    func resetPlaylistCache() {
        playlistLoaded = false
        playlistState = nil
        isFirstVideoThisActivation = true
    }

    // MARK: - Status

    /// Whether any videos are cached locally for offline playback
    var hasCachedVideos: Bool {
        return videoList.videos.contains(where: { $0.isAvailableOffline })
    }

}
