//
//  PlayViewButton.swift
//  Aerial Companion
//
//  Header action that sets the wallpaper playback selection to the
//  category currently browsed in the Video Library ("play what I'm
//  looking at"). Scope rules:
//    - cloned/spanned/mirrored viewing modes → the shared playlist
//    - independent mode, one display → that display
//    - independent mode, several displays → the display hosting this
//      window; Shift-click opens a picker (each display + All Displays)
//  When the target scope already plays this view, the button becomes a
//  non-actionable "Playing" chip (Shift-click picker stays available).
//

import SwiftUI

struct PlayViewButton: View {
    @ObservedObject var state: VideoBrowserState
    @StateObject private var playbackManager = PlaybackManager.shared
    @State private var hostScreenUUID: String?
    @State private var showingScreenPicker = false

    var body: some View {
        if Self.playTarget(for: state.selectedSidebarItem) != nil {
            playControl
                .background(HostScreenReader(screenUUID: $hostScreenUUID))
                .popover(isPresented: $showingScreenPicker, arrowEdge: .bottom) {
                    screenPicker
                }
        }
    }

    // MARK: - Control

    @ViewBuilder
    private var playControl: some View {
        if isCurrentSelection(for: clickScopeUUID) {
            // Status chip, not an action — except Shift-click, which can
            // still target the OTHER displays in independent mode.
            Button(action: { handleClick(playing: true) }) {
                Label("Playing", systemImage: "waveform")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .foregroundColor(.aerial)
            .help(isIndependentMultiMonitor
                  ? "Already playing on \(targetScreenName ?? "this display") — Shift-click to play it on another display"
                  : "This is what's currently playing")
        } else {
            let empty = isViewEmpty
            Button(action: { handleClick(playing: false) }) {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.aerial)
            .disabled(empty)
            .help(empty
                  ? "No videos to play in this view"
                  : (isIndependentMultiMonitor
                     ? "Play this on \(targetScreenName ?? "this display") — Shift-click to choose a display"
                     : "Set the wallpaper to play this"))
        }
    }

    /// True when the mapped selection would play nothing — an empty user
    /// playlist, or a category with zero matching videos. Cached-ness is
    /// deliberately ignored: playing an all-uncached view is valid (it
    /// queues the downloads via selectionDidChange).
    private var isViewEmpty: Bool {
        guard let target = Self.playTarget(for: state.selectedSidebarItem) else { return true }
        switch target {
        case .userPlaylist(let id):
            return UserPlaylistManager.shared.playlist(id: id)?.entries.isEmpty ?? true
        case .filter(let mode, let filters):
            return VideoList.instance.videosMatchingFilter(mode: mode, filterStrings: filters).isEmpty
        }
    }

    private func handleClick(playing: Bool) {
        let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        if shiftHeld && isIndependentMultiMonitor {
            showingScreenPicker = true
        } else if !playing {
            apply(to: clickScopeUUID)
        }
    }

    private var screenPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Play on")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.bottom, 4)
            ForEach(playbackManager.availableScreens) { screen in
                let alreadyPlaying = isCurrentSelection(for: screen.uuid)
                Button(action: {
                    showingScreenPicker = false
                    apply(to: screen.uuid)
                }) {
                    HStack {
                        Image(systemName: "display")
                        Text(screen.name)
                        Spacer()
                        if alreadyPlaying {
                            Image(systemName: "checkmark")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(alreadyPlaying)
            }
            Divider()
            Button(action: {
                showingScreenPicker = false
                applyToAllDisplays()
            }) {
                HStack {
                    Image(systemName: "rectangle.on.rectangle")
                    Text("All Displays")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(minWidth: 220)
    }

    // MARK: - Scope

    private var isIndependentMultiMonitor: Bool {
        PrefsDisplays.viewingMode == .independent && playbackManager.availableScreens.count > 1
    }

    /// nil = shared playlist scope. Non-nil = one display (independent mode).
    /// Multi-monitor independent mode targets the display hosting this window.
    private var clickScopeUUID: String? {
        guard PrefsDisplays.viewingMode == .independent else { return nil }
        let screens = playbackManager.availableScreens
        if screens.count == 1 { return screens[0].uuid }
        if let uuid = hostScreenUUID, !uuid.isEmpty { return uuid }
        // Window not resolved yet (first render) — key-window fallback.
        return (NSApp.keyWindow?.screen ?? NSScreen.main)?.screenUuid
    }

    private var targetScreenName: String? {
        guard let uuid = clickScopeUUID else { return nil }
        return playbackManager.availableScreens.first { $0.uuid == uuid }?.name
    }

    // MARK: - Category → selection mapping

    private enum PlayTarget {
        case filter(NewShouldPlay, [String])
        case userPlaylist(UUID)
    }

    private static func playTarget(for category: BrowseCategory) -> PlayTarget? {
        switch category {
        case .allVideos:
            return .filter(.everything, [])
        case .location(let name):
            return .filter(.location, ["location:\(name)"])
        case .scene(let scene):
            return .filter(.scene, ["scene:\(scene.rawValue)"])
        case .timeOfDay(let slug):
            return .filter(.time, ["time:\(slug.capitalizeFirstLetter())"])
        case .favorites:
            return .filter(.favorites, [])
        case .source(let name):
            if name == "Live Feeds" { return .filter(.liveFeeds, []) }
            // Same built-in test as VideoList.partitionSourceFilterStrings:
            // built-ins play under .source, packs under .expansions.
            let isBuiltIn = name.hasPrefix("tvOS") || name.hasPrefix("macOS") || name == "My Videos"
            return .filter(isBuiltIn ? .source : .expansions, ["source:\(name)"])
        case .userPlaylist(let id):
            return .userPlaylist(id)
        default:
            // Home, Now Playing, Activity, the Expansions gallery and the
            // Downloaded / Not Downloaded / Hidden lenses have no playback
            // selection equivalent.
            return nil
        }
    }

    // MARK: - Current-selection check

    private func isCurrentSelection(for scopeUUID: String?) -> Bool {
        guard let target = Self.playTarget(for: state.selectedSidebarItem) else { return false }
        switch target {
        case .userPlaylist(let id):
            return PlaylistManager.shared.activeUserPlaylistId(for: scopeUUID) == id
        case .filter(let mode, let filters):
            guard let info = PlaylistManager.shared.filterInfo(for: scopeUUID),
                  info.mode == mode else { return false }
            switch mode {
            case .everything, .favorites, .liveFeeds:
                return true   // these modes ignore filter strings
            default:
                // Compare only this mode's prefixed strings, case-insensitive
                // (persisted arrays can carry stale entries from other modes).
                guard let prefix = filters.first?.prefix(while: { $0 != ":" }).lowercased() else { return false }
                func relevant(_ strings: [String]) -> Set<String> {
                    Set(strings.map { $0.lowercased() }.filter { $0.hasPrefix(prefix + ":") })
                }
                return relevant(info.filterStrings) == relevant(filters)
            }
        }
    }

    // MARK: - Apply

    private func apply(to scopeUUID: String?) {
        guard let target = Self.playTarget(for: state.selectedSidebarItem) else { return }
        switch target {
        case .userPlaylist(let id):
            PlaylistManager.shared.activateUserPlaylist(id: id, for: scopeUUID)
            refreshPlayback(for: scopeUUID)
        case .filter(let mode, let filters):
            if let scopeUUID {
                PlaylistManager.shared.regenerate(for: scopeUUID, mode: mode, filterStrings: filters)
            } else {
                // Shared scope must write BOTH prefs before regenerating —
                // the extension re-validates shared playlists against them.
                PrefsVideos.newShouldPlay = mode
                PrefsVideos.newShouldPlayString = filters
                PlaylistManager.shared.regenerate(for: nil, mode: mode, filterStrings: filters)
            }
            refreshPlayback(for: scopeUUID)
            DownloadCoordinator.shared.selectionDidChange()
        }
        showNewSelectionNow(scopeUUID: scopeUUID)
    }

    /// Global prefs + shared playlist first (keeps the shared default
    /// coherent), then every screen in independent mode — mirrors
    /// ExpansionsContentView.applySetToPlay.
    private func applyToAllDisplays() {
        guard let target = Self.playTarget(for: state.selectedSidebarItem) else { return }
        let perScreenUUIDs: [String] = PrefsDisplays.viewingMode == .independent
            ? NSScreen.screens.map(\.screenUuid).filter { !$0.isEmpty }
            : []

        switch target {
        case .userPlaylist(let id):
            PlaylistManager.shared.activateUserPlaylist(id: id, for: nil)
            refreshPlayback(for: nil)
            for uuid in perScreenUUIDs {
                PlaylistManager.shared.activateUserPlaylist(id: id, for: uuid)
                refreshPlayback(for: uuid)
            }
        case .filter(let mode, let filters):
            PrefsVideos.newShouldPlay = mode
            PrefsVideos.newShouldPlayString = filters
            PlaylistManager.shared.regenerate(for: nil, mode: mode, filterStrings: filters)
            refreshPlayback(for: nil)
            for uuid in perScreenUUIDs {
                PlaylistManager.shared.regenerate(for: uuid, mode: mode, filterStrings: filters)
                refreshPlayback(for: uuid)
            }
            DownloadCoordinator.shared.selectionDidChange()
        }
        showNewSelectionNow(scopeUUID: nil)
    }

    private func refreshPlayback(for scopeUUID: String?) {
        if let scopeUUID {
            PlaybackManager.shared.refreshPlayback(for: scopeUUID)
        } else {
            PlaybackManager.shared.refreshPlayback()
        }
    }

    /// Make the new selection visible right away. The playlist-change
    /// signal alone isn't enough: a paused wallpaper defers the cut until
    /// resume, and a surviving current video isn't cut at all. An explicit
    /// jump cuts even while paused — the new first frame is presented with
    /// the rate untouched — so an auto-paused wallpaper updates and STAYS
    /// paused. A broadcast jump (nil) reaches per-screen renderers too.
    /// Manual user pause is the exception: "Play" resumes it.
    private func showNewSelectionNow(scopeUUID: String?) {
        PlaybackManager.shared.skipTo(playlistIndex: 0, screenUUID: scopeUUID)
        if PlaybackManager.shared.isPaused {
            PlaybackManager.shared.togglePause()
        }
    }
}

// MARK: - Host Screen Reader

/// Reports the UUID of the screen hosting this view's window, tracking
/// window drags across displays. Reads happen on window events (never
/// mid-hotplug renders, where NSScreen.screenUuid can return "").
private struct HostScreenReader: NSViewRepresentable {
    @Binding var screenUUID: String?

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.onChange = { uuid in
            DispatchQueue.main.async {
                if screenUUID != uuid { screenUUID = uuid }
            }
        }
        return view
    }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.onChange = { uuid in
            DispatchQueue.main.async {
                if screenUUID != uuid { screenUUID = uuid }
            }
        }
    }

    final class TrackerView: NSView {
        var onChange: ((String?) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else {
                onChange?(nil)
                return
            }
            onChange?(window.screen?.screenUuid)
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.onChange?(self?.window?.screen?.screenUuid)
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
