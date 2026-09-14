//
//  DashboardModel.swift
//  Aerial Companion
//
//  Drives the Video Library Dashboard. The Dashboard summarises what each
//  display is doing and (in later phases) lets the user change it inline.
//
//  This is a dedicated ObservableObject rather than a reuse of
//  `VideoBrowserState` because the Dashboard reacts to events
//  `VideoBrowserState` ignores (overlay-config changes, display hotplug).
//  `PlaylistManager` / `OverlayConfigManager` are plain singletons mutated
//  via NotificationCenter — not observable — so we coalesce their changes
//  into a `refreshTrigger` tick that subviews depend on to re-query. Same
//  pattern as `VideoBrowserState.refreshTrigger` and
//  `NowPlayingSectionView.playlistActivationTick`.
//

import SwiftUI
import Combine

@MainActor
final class DashboardModel: ObservableObject {
    /// Bumped by any observed singleton change to force subviews that read
    /// `PlaylistManager` / display state to re-evaluate.
    @Published var refreshTrigger: Int = 0

    /// Cached current-video thumbnails, keyed by screen UUID (independent)
    /// or `sharedKey` (shared modes). Drives the card miniatures.
    @Published var projectedImages: [String: NSImage] = [:]
    /// Bumped when `projectedImages` changes so the AppKit-backed
    /// `DashboardMiniature` redraws (mirrors `DisplayPreviewView`).
    @Published var projectionRefreshID = UUID()

    /// Reactive, crash-safe mirror of `PlaybackManager.availableScreens`
    /// (uuid + name + geometry). Drives the per-display cards without ever
    /// reading a live `NSScreen`/`screenUuid` during render — that traps when
    /// a display disconnects mid-hotplug.
    @Published private(set) var screenInfos: [PlaybackManager.ScreenInfo] = []

    let playbackManager = PlaybackManager.shared

    private let sharedKey = "__shared__"
    /// Last videoId loaded per key — skips redundant async thumbnail fetches.
    private var loadedVideoIdByKey: [String: String] = [:]
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Mirror the reactive, crash-safe screen list. It's rebuilt only when
        // the screen set actually changes (not at the 1 Hz playbackProgress
        // cadence), so observing `model` is enough to keep the cards live.
        screenInfos = playbackManager.availableScreens
        playbackManager.$availableScreens
            .receive(on: DispatchQueue.main)
            .sink { [weak self] screens in
                self?.screenInfos = screens
                self?.refreshProjections()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: PlaylistManager.playlistDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshTrigger += 1
                self?.refreshProjections()
            }
            .store(in: &cancellables)

        // Display hotplug / rearrangement. Re-detect before bumping so the
        // geometry the cards read is current.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DisplayDetection.sharedInstance.detectDisplays()
                self?.refreshTrigger += 1
                self?.refreshProjections()
            }
            .store(in: &cancellables)

        // Newly-downloaded videos may now have real thumbnails.
        NotificationCenter.default.publisher(for: DownloadCoordinator.downloadDidCompleteNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshProjections() }
            .store(in: &cancellables)

        // Overlay common/per-screen toggle changed → re-render overlay rows.
        NotificationCenter.default.publisher(for: OverlayConfigManager.configDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshTrigger += 1 }
            .store(in: &cancellables)

        refreshProjections()
    }

    // MARK: - Topology

    var viewingMode: ViewingMode { PrefsDisplays.viewingMode }

    var isIndependent: Bool { viewingMode == .independent }

    /// Whether overlays are configured per-screen (vs. common to all).
    var overlayPerScreen: Bool { OverlayConfigManager.shared.config.perScreen }

    func timeModeName() -> String {
        switch PrefsTime.timeMode {
        case .disabled:        return "Disabled"
        case .nightShift:      return "Night Shift"
        case .manual:          return "Manual"
        case .lightDarkMode:   return "Light/Dark Mode"
        case .coordinates:     return "Coordinates"
        case .locationService: return "Location Service"
        }
    }

    /// Human-readable explanation of a viewing mode, for the header.
    func modeDescription(_ mode: ViewingMode) -> String {
        switch mode {
        case .independent: return "Each display plays its own video — set per display below."
        case .cloned:      return "All displays show the same video."
        case .spanned:     return "One video spans across all displays."
        case .mirrored:    return "All displays mirror the same video (alternates flipped)."
        }
    }

    /// Apply a viewing-mode change live. Beyond writing the pref this must
    /// rebuild playlists for the new topology and restart playback —
    /// otherwise the running wallpaper keeps the old layout. Route ALL mode
    /// changes through here (never set `PrefsDisplays.viewingMode` from a
    /// view) so the side effects stay consistent.
    func applyViewingModeChange(_ newMode: ViewingMode) {
        guard newMode != PrefsDisplays.viewingMode else { return }
        PrefsDisplays.viewingMode = newMode
        WallpaperControl.shared.displaysConfigDidChange()

        // Rebuild the shared playlist for the new topology.
        // `regenerate(for: nil)` also clears stale per-screen playlists when
        // leaving independent.
        PlaylistManager.shared.regenerate(for: nil,
                                          mode: PrefsVideos.newShouldPlay,
                                          filterStrings: PrefsVideos.newShouldPlayString)

        // Restart live playback under the new mode and rescan downloads.
        playbackManager.refreshPlayback()
        DownloadCoordinator.shared.selectionDidChange()

        // Re-render (card layout switches independent ↔ single shared card)
        // and recompute projections for the new scope set.
        refreshTrigger += 1
        loadedVideoIdByKey.removeAll()   // force re-resolve under the new scopes
        projectedImages.removeAll()
        refreshProjections()
    }

    // MARK: - Recap setters (live)

    /// Turn day/night adaptation on (via Location Services) or off, live.
    /// `reevaluate()` is required so `.locationService` actually starts
    /// location / requests permission — same as TimeSettingsPanel.
    func setTimeAdaptation(_ mode: TimeMode) {
        guard mode != PrefsTime.timeMode else { return }
        PrefsTime.timeMode = mode
        LocationProvider.shared.reevaluate()
        refreshTrigger += 1
    }

    /// Change which displays play, live. Re-detect displays and refresh
    /// playback so the running wallpaper starts/stops on the affected screens.
    func setDisplayMode(_ mode: DisplayMode) {
        guard mode != PrefsDisplays.displayMode else { return }
        PrefsDisplays.displayMode = mode
        WallpaperControl.shared.displaysConfigDidChange()
        DisplayDetection.sharedInstance.detectDisplays()
        playbackManager.refreshPlayback()
        refreshTrigger += 1
    }

    /// Current playlist playback mode (loop / shuffle / repeat one).
    /// Global (`Preferences.playlistMode`), so it applies to every display.
    var playbackMode: PlaylistCycleMode { Preferences.playlistMode }

    /// Cycle loop → shuffle → repeat one for all playlists, live — mirrors
    /// the popover's cycle-mode selector (`PlaylistStripView`).
    /// `setPlaybackMode` already posts `playlistDidChangeNotification`; the
    /// extra tick flips the card without waiting for that async hop.
    func cyclePlaybackMode() {
        let next: PlaylistCycleMode
        switch Preferences.playlistMode {
        case .loop: next = .shuffle
        case .shuffle: next = .repeatOne
        case .repeatOne: next = .loop
        }
        PlaylistManager.shared.setPlaybackMode(next)
        refreshTrigger += 1
    }

    // MARK: - Playlist queries
    //
    // `screenUUID == nil` queries the shared playlist (cloned / spanned /
    // mirrored); a non-nil UUID queries that independent display's playlist.

    func currentEntry(for screenUUID: String?) -> PlaylistEntry? {
        let entries = PlaylistManager.shared.allEntries(for: screenUUID)
        guard !entries.isEmpty else { return nil }
        let idx = PlaylistManager.shared.currentIndex(for: screenUUID)
        guard idx >= 0, idx < entries.count else { return entries.first }
        return entries[idx]
    }

    func entryCount(for screenUUID: String?) -> Int {
        PlaylistManager.shared.allEntries(for: screenUUID).count
    }

    /// Human-readable "now playing" label for a scope, or nil if the
    /// playlist is empty.
    func nowPlayingText(for screenUUID: String?) -> String? {
        guard let entry = currentEntry(for: screenUUID) else { return nil }
        let primary = entry.videoName
        let secondary = entry.secondaryName
        if !secondary.isEmpty && secondary != primary {
            return "\(primary) — \(secondary)"
        }
        return primary
    }

    // MARK: - Projection thumbnails

    func thumbnail(for screenUUID: String?) -> NSImage? {
        projectedImages[screenUUID ?? sharedKey]
    }

    /// Load (async, cached) the current-video thumbnail(s) for the active
    /// topology. Independent mode loads one per screen; shared modes load a
    /// single image used across the whole arrangement.
    func refreshProjections() {
        if isIndependent {
            let uuids = playbackManager.availableScreens.map { $0.uuid }
            let valid = Set(uuids)
            for uuid in uuids {
                loadThumbnail(scope: uuid, key: uuid)
            }
            // Drop stale per-screen entries (disconnected displays).
            for key in projectedImages.keys where key != sharedKey && !valid.contains(key) {
                projectedImages[key] = nil
                loadedVideoIdByKey[key] = nil
            }
        } else {
            loadThumbnail(scope: nil, key: sharedKey)
        }
    }

    private func loadThumbnail(scope screenUUID: String?, key: String) {
        guard let entry = currentEntry(for: screenUUID) else {
            if projectedImages[key] != nil { projectedImages[key] = nil }
            loadedVideoIdByKey[key] = nil
            return
        }
        // Skip if we already resolved this exact video for this key.
        if loadedVideoIdByKey[key] == entry.videoId, projectedImages[key] != nil { return }
        guard let video = VideoList.instance.videos.first(where: { $0.id == entry.videoId }) else { return }
        loadedVideoIdByKey[key] = entry.videoId
        Thumbnails.get(forVideo: video) { [weak self] image in
            guard let image = image else { return }
            DispatchQueue.main.async {
                self?.projectedImages[key] = image
                self?.projectionRefreshID = UUID()
            }
        }
    }
}
