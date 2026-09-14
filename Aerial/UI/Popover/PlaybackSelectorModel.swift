//
//  PlaybackSelectorModel.swift
//  Aerial Companion
//
//  The selection state machine behind both the menubar "Now Playing"
//  section and the Dashboard's per-screen playback picker. Extracted from
//  the old `NowPlayingSectionView` so the exact same commit / reload logic
//  (per-screen vs global, user-playlist handling, the programmatic-reseat
//  suppression guard) is shared rather than duplicated.
//
//  The only behavioral fork is `effectiveScreenUUID`, derived from `scope`.
//

import SwiftUI
import Combine

/// Selection category. Wraps `NewShouldPlay` and adds a `.playlists` case
/// (user playlists) without modifying the shared enum.
enum PopoverCategory: Hashable {
    case filter(NewShouldPlay)
    case playlists
}

/// What the selector targets.
///  - `.popover`: the menubar popover — scope follows
///    `PlaybackManager.effectiveScreenUUID` (per-screen only in independent).
///  - `.screen(uuid)`: an explicit Dashboard scope. `nil` = the shared
///    playlist (cloned / spanned / mirrored); non-nil = one display.
enum PlaybackScope: Equatable {
    case popover
    case screen(String?)
}

@MainActor
final class PlaybackSelectorModel: ObservableObject {
    let scope: PlaybackScope
    let playbackManager: PlaybackManager

    @Published var popoverCategory: PopoverCategory
    @Published var selectedItems: Set<String>
    @Published var isExpanded: Bool = false
    @Published var thumbnails: [String: NSImage] = [:]

    /// Bumped to force the user-playlist list to re-render when the active
    /// playlist changes (PlaylistManager isn't observable).
    @Published var playlistActivationTick: Int = 0

    /// Set before a programmatic `popoverCategory` write so the next
    /// `handleCategoryChange` skips the commit/regenerate branch — only real
    /// user picker changes should regenerate.
    var suppressCategoryOnChange: Bool = false

    init(scope: PlaybackScope, playbackManager: PlaybackManager? = nil) {
        self.scope = scope
        self.playbackManager = playbackManager ?? .shared
        self.popoverCategory = .filter(PrefsVideos.newShouldPlay)
        self.selectedItems = Set(PrefsVideos.newShouldPlayString)
    }

    // MARK: - Scope

    var effectiveScreenUUID: String? {
        switch scope {
        case .popover: return playbackManager.effectiveScreenUUID
        case .screen(let uuid): return uuid
        }
    }

    var isPerScreen: Bool { effectiveScreenUUID != nil }

    var selectedCategory: NewShouldPlay {
        if case .filter(let mode) = popoverCategory { return mode }
        return PrefsVideos.newShouldPlay
    }

    var showingPlaylists: Bool {
        if case .playlists = popoverCategory { return true }
        return false
    }

    // MARK: - Sources / filter helpers

    /// Whether the current category has a suboption grid. Everything,
    /// Favorites and Live Feeds are grid-less — no chevron, no expansion.
    var hasSourceGrid: Bool {
        !showingPlaylists && ![.everything, .favorites, .liveFeeds].contains(selectedCategory)
    }

    var sources: [String] {
        if selectedCategory == .everything { return [] }
        let all = VideoList.instance.getSources(mode: filterMode)
        switch selectedCategory {
        case .source:
            return all.filter { $0.hasPrefix("tvOS") || $0.hasPrefix("macOS") || $0 == "My Videos" }
        case .expansions:
            return all.filter {
                !$0.hasPrefix("tvOS") && !$0.hasPrefix("macOS") && $0 != "My Videos" && $0 != "Live Feeds"
            }
        default:
            return all
        }
    }

    var filterMode: VideoList.FilterMode {
        switch selectedCategory {
        case .location: return .location
        case .favorites: return .favorite
        case .time: return .time
        case .scene: return .scene
        case .source, .expansions: return .source
        case .liveFeeds: return .source
        case .everything: return .cache   // unused — Everything has no sources
        }
    }

    var modePrefix: String { String(describing: filterMode) + ":" }

    var selectedSourceCount: Int {
        sources.filter { selectedItems.contains(modePrefix + $0) }.count
    }

    var summaryText: String {
        if selectedCategory == .favorites {
            let count = PrefsVideos.favorites.count
            return count == 1 ? "1 video" : "\(count) videos"
        }
        if selectedCategory == .liveFeeds {
            let count = VideoList.instance.videos.filter { $0.isLive }.count
            return count == 1 ? "1 feed" : "\(count) feeds"
        }
        if sources.isEmpty { return "" }
        let selected = sources.filter { selectedItems.contains(modePrefix + $0) }
        if selected.isEmpty || selected.count == sources.count { return "All" }
        return selected.joined(separator: ", ")
    }

    var allSelected: Bool {
        guard !sources.isEmpty else { return true }
        return selectedSourceCount == sources.count
    }

    var sourceRows: [[Int]] {
        let cols = 4
        return stride(from: 0, to: sources.count, by: cols).map { start in
            Array(start..<min(start + cols, sources.count))
        }
    }

    var gridHeight: CGFloat {
        let rowHeight: CGFloat = 63
        let rowSpacing: CGFloat = 8
        let rows = CGFloat(sourceRows.count)
        let contentHeight = rows * rowHeight + max(0, rows - 1) * rowSpacing + 4
        return min(contentHeight, 220)
    }

    // MARK: - Commit

    private func selectAllLocal() {
        for source in sources { selectedItems.insert(modePrefix + source) }
    }

    private func selectAll() {
        for source in sources { selectedItems.insert(modePrefix + source) }
        PrefsVideos.newShouldPlayString = Array(selectedItems)
    }

    /// Regenerate only the current screen's playlist and restart its playback.
    private func commitPerScreenFilter() {
        guard let screenUUID = effectiveScreenUUID else { return }
        let filters = Array(selectedItems)
        PlaylistManager.shared.regenerate(for: screenUUID, mode: selectedCategory, filterStrings: filters)
        playbackManager.refreshPlayback(for: screenUUID)
        DownloadCoordinator.shared.selectionDidChange()
    }

    /// Write the new filter to global prefs and regenerate the shared playlist.
    private func commitGlobalFilter() {
        let filters = Array(selectedItems)
        PrefsVideos.newShouldPlayString = filters
        PlaylistManager.shared.regenerate(for: nil, mode: selectedCategory, filterStrings: filters)
        playbackManager.refreshPlayback()
        DownloadCoordinator.shared.selectionDidChange()
    }

    private func commit() {
        if isPerScreen { commitPerScreenFilter() } else { commitGlobalFilter() }
    }

    // MARK: - Category change

    /// Programmatic write that suppresses the next `.onChange` firing — used
    /// by `reloadState()` to mirror authoritative state without committing.
    func setCategorySilently(_ newValue: PopoverCategory) {
        guard popoverCategory != newValue else { return }
        suppressCategoryOnChange = true
        popoverCategory = newValue
    }

    func handleCategoryChange(_ newValue: PopoverCategory) {
        if suppressCategoryOnChange {
            suppressCategoryOnChange = false
            return
        }
        switch newValue {
        case .filter(let mode):
            isExpanded = false
            thumbnails = [:]
            loadThumbnails()
            if isPerScreen {
                if mode == .everything {
                    // No suboptions — persist an empty filter (ignored by
                    // .everything; also means switching back to Locations
                    // lands on the auto-select-all path).
                    selectedItems = []
                } else if selectedSourceCount == 0 && mode != .favorites && mode != .liveFeeds {
                    selectAllLocal()
                }
                commitPerScreenFilter()
            } else {
                PrefsVideos.newShouldPlay = mode
                if mode == .everything {
                    selectedItems = []
                } else {
                    selectedItems = Set(PrefsVideos.newShouldPlayString)
                    if selectedSourceCount == 0 && mode != .favorites && mode != .liveFeeds {
                        selectAll()
                    }
                }
                commitGlobalFilter()
            }
        case .playlists:
            isExpanded = false
        }
    }

    // MARK: - Reload / thumbnails

    func reloadState() {
        playlistActivationTick &+= 1

        let effectiveUUID = effectiveScreenUUID
        let userPlaylistActive = PlaylistManager.shared.isUserPlaylistActive(for: effectiveUUID)

        if userPlaylistActive { setCategorySilently(.playlists) }

        // User playlist active → persisted filterMode is -1, which
        // filterInfo() can't parse; bail before the regenerate branch below
        // would wipe the just-activated playlist.
        guard !userPlaylistActive else {
            loadThumbnails()
            return
        }

        if let screenUUID = effectiveUUID {
            if let info = PlaylistManager.shared.filterInfo(for: screenUUID) {
                if !showingPlaylists { setCategorySilently(.filter(info.mode)) }
                selectedItems = Set(info.filterStrings)
            } else {
                if !showingPlaylists { setCategorySilently(.filter(PrefsVideos.newShouldPlay)) }
                selectedItems = Set(PrefsVideos.newShouldPlayString)
                PlaylistManager.shared.regenerate(for: screenUUID, mode: selectedCategory, filterStrings: Array(selectedItems))
            }
        } else {
            if !showingPlaylists { setCategorySilently(.filter(PrefsVideos.newShouldPlay)) }
            selectedItems = Set(PrefsVideos.newShouldPlayString)
        }
        loadThumbnails()
    }

    func loadThumbnails() {
        let mode = selectedCategory
        let prefix: String
        switch mode {
        case .location:            prefix = "location"
        case .time:                prefix = "time"
        case .scene:               prefix = "scene"
        case .source, .expansions: prefix = "source"
        default:                   return
        }

        for item in sources {
            guard thumbnails[item] == nil else { continue }
            let videos = VideoList.instance.videosMatchingFilter(mode: mode, filterStrings: ["\(prefix):\(item)"])
            if let video = videos.first {
                Thumbnails.get(forVideo: video) { [weak self] image in
                    if let image = image {
                        DispatchQueue.main.async { self?.thumbnails[item] = image }
                    }
                }
            }
        }
    }

    func toggleSource(_ path: String) {
        if selectedItems.contains(path) { selectedItems.remove(path) } else { selectedItems.insert(path) }
        commit()
    }

    func toggleAll() {
        if allSelected {
            for source in sources { selectedItems.remove(modePrefix + source) }
        } else {
            if isPerScreen { selectAllLocal() } else { selectAll() }
        }
        commit()
    }

    // MARK: - User playlists

    func isUserPlaylistActive() -> Bool {
        PlaylistManager.shared.isUserPlaylistActive(for: effectiveScreenUUID)
    }

    func activeUserPlaylistId() -> UUID? {
        PlaylistManager.shared.activeUserPlaylistId(for: effectiveScreenUUID)
    }

    func activateUserPlaylist(_ id: UUID) {
        PlaylistManager.shared.activateUserPlaylist(id: id, for: effectiveScreenUUID)
        if let screenUUID = effectiveScreenUUID {
            playbackManager.refreshPlayback(for: screenUUID)
        } else {
            playbackManager.refreshPlayback()
        }
        playlistActivationTick &+= 1
    }

    func backToFilters() {
        let mode = selectedCategory
        if let screenUUID = effectiveScreenUUID {
            PlaylistManager.shared.regenerate(for: screenUUID, mode: mode, filterStrings: Array(selectedItems))
            playbackManager.refreshPlayback(for: screenUUID)
        } else {
            PlaylistManager.shared.regenerate()
            playbackManager.refreshPlayback()
        }
        popoverCategory = .filter(mode)
    }
}
