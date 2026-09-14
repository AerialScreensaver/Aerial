//
//  VideoBrowserState.swift
//  Aerial Companion
//
//  ObservableObject driving the Video Browser window.
//

import SwiftUI
import Combine

// MARK: - Browse Category

enum BrowseCategory: Hashable {
    case dashboard
    case nowPlaying(screenUUID: String?)
    case allVideos
    case location(String)
    case scene(SourceScene)
    case timeOfDay(String)
    case source(String)
    case downloaded
    case notDownloaded
    case favorites
    case hidden
    case activity
    case userPlaylist(id: UUID)
    case expansions

    func hash(into hasher: inout Hasher) {
        switch self {
        case .dashboard: hasher.combine("dashboard")
        case .nowPlaying(let uuid): hasher.combine("now"); hasher.combine(uuid)
        case .allVideos: hasher.combine("all")
        case .location(let l): hasher.combine("loc"); hasher.combine(l)
        case .scene(let s): hasher.combine("scene"); hasher.combine(s)
        case .timeOfDay(let t): hasher.combine("tod"); hasher.combine(t)
        case .source(let s): hasher.combine("src"); hasher.combine(s)
        case .downloaded: hasher.combine("dl")
        case .notDownloaded: hasher.combine("notdl")
        case .favorites: hasher.combine("fav")
        case .hidden: hasher.combine("hid")
        case .activity: hasher.combine("act")
        case .userPlaylist(let id): hasher.combine("upl"); hasher.combine(id)
        case .expansions: hasher.combine("exp")
        }
    }
}

// MARK: - Sort / View Mode

enum VideoSortOrder: String, CaseIterable {
    case name = "Name"
    case duration = "Duration"
}

enum VideoViewMode: String {
    case grid, list
}

/// Alert payload for the context menu's "Delete Video" confirmation
/// (used by both the card and row cell views).
struct PendingCacheDelete: Identifiable {
    let id = UUID()
    let videos: [AerialVideo]
}

// MARK: - State

class VideoBrowserState: ObservableObject {
    @Published var selectedSidebarItem: BrowseCategory = .dashboard
    @Published var selectedVideoIds: Set<String> = []
    @Published var lastClickedVideoId: String?
    /// Keyboard-navigation cursor: the moving end for shift-extend and the
    /// pivot for arrow movement. Distinct from `lastClickedVideoId`, which is
    /// the fixed range anchor that shift-extends pivot around.
    @Published var focusedVideoId: String?
    @Published var searchText: String = ""
    @Published var sortOrder: VideoSortOrder = .name
    @Published var viewMode: VideoViewMode = .grid
    @Published var thumbnails: [String: NSImage] = [:]
    @Published var refreshTrigger: Int = 0
    @Published var userPlaylists: [UserPlaylistSummary] = []

    /// Set by `routeToExpansion(id:)` to ask the Expansions content
    /// view to scroll to a specific pack card once it appears. The
    /// view clears the value after consuming it.
    @Published var pendingExpansionScroll: String? = nil

    /// While non-nil, the matching `ExpansionCard` renders an outer
    /// accent-colored stroke as a "you've arrived here" reticle. Set
    /// by `routeToExpansion(id:)`, auto-cleared by the Expansions
    /// content view a couple of seconds after scroll completes.
    @Published var highlightedExpansionId: String? = nil

    /// Deferred initial category — set by callers (e.g. the About
    /// box's "Browse Expansions" button) BEFORE invoking
    /// `openWindow(id: "videoBrowser")`. Consumed and cleared in
    /// `init()` so a freshly-opened Video Library window lands on
    /// that category. The matching `openCategoryRequest` notification
    /// (posted in the same call site) handles the already-open case.
    static var pendingInitialCategory: BrowseCategory? = nil

    /// Posted with `object: BrowseCategory` to ask an already-open
    /// Video Library window to switch its sidebar selection. The
    /// `VideoBrowserView` observes this via `.onReceive` and clears
    /// `searchText` before applying the new category so the content
    /// view actually routes to the category's content (not the
    /// global search results).
    static let openCategoryRequest = Notification.Name("com.glouel.aerial.videoBrowser.openCategoryRequest")

    private var cancellables = Set<AnyCancellable>()

    init() {
        // The Dashboard is the default landing view (the property's
        // initial value above). A caller can still override the initial
        // selection via `pendingInitialCategory` below.

        // Honor a deferred initial category set by a caller right
        // before openWindow(id: "videoBrowser") — e.g. the About box's
        // "Browse Expansions" button. Consume and clear so it only
        // applies to this fresh window.
        if let pending = Self.pendingInitialCategory {
            selectedSidebarItem = pending
            Self.pendingInitialCategory = nil
        }

        NotificationCenter.default.publisher(for: PlaylistManager.playlistDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshTrigger += 1 }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: DownloadCoordinator.downloadDidCompleteNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshTrigger += 1 }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserPlaylistManager.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshUserPlaylists()
                self?.refreshTrigger += 1
            }
            .store(in: &cancellables)

        VideoList.instance.addCallback { [weak self] in
            DispatchQueue.main.async {
                self?.refreshTrigger += 1
            }
        }

        refreshUserPlaylists()
    }

    private func refreshUserPlaylists() {
        userPlaylists = UserPlaylistManager.shared.allSummaries()
    }

    // MARK: - Selection

    /// Single-selected video (for inspector compatibility)
    var selectedVideo: AerialVideo? {
        guard selectedVideoIds.count == 1, let id = selectedVideoIds.first else { return nil }
        return VideoList.instance.videos.first { $0.id == id }
    }

    /// All selected videos resolved from VideoList. One object per selected
    /// id even if the list ever regresses to holding duplicate ids again —
    /// the count here drives user-facing labels ("N Videos Selected",
    /// "Add N Videos to Playlist") and must never exceed the id count.
    var selectedVideos: [AerialVideo] {
        var seen = Set<String>()
        return VideoList.instance.videos.filter {
            selectedVideoIds.contains($0.id) && seen.insert($0.id).inserted
        }
    }

    var hasMultiSelection: Bool {
        selectedVideoIds.count > 1
    }

    func selectVideo(_ video: AerialVideo, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            // Cmd+click: toggle
            if selectedVideoIds.contains(video.id) {
                selectedVideoIds.remove(video.id)
            } else {
                selectedVideoIds.insert(video.id)
            }
            lastClickedVideoId = video.id
            focusedVideoId = video.id
        } else if modifiers.contains(.shift), let anchorId = lastClickedVideoId {
            // Shift+click: range select from the anchor (anchor stays put)
            selectRange(from: anchorId, to: video.id)
        } else {
            // Plain click: single select
            selectedVideoIds = [video.id]
            lastClickedVideoId = video.id
            focusedVideoId = video.id
        }
    }

    /// Selects the inclusive range of displayed videos between two ids, in
    /// `filteredVideos` order. The range anchor (`lastClickedVideoId`) is left
    /// untouched so successive shift-clicks / shift-arrows pivot around it;
    /// only the moving cursor (`focusedVideoId`) advances. Falls back to a
    /// single selection if either id isn't currently displayed. Shared by
    /// shift-click and shift-arrow.
    private func selectRange(from anchorId: String, to toId: String) {
        let videos = filteredVideos
        guard let anchorIndex = videos.firstIndex(where: { $0.id == anchorId }),
              let toIndex = videos.firstIndex(where: { $0.id == toId }) else {
            selectedVideoIds = [toId]
            lastClickedVideoId = toId
            focusedVideoId = toId
            return
        }
        let range = min(anchorIndex, toIndex)...max(anchorIndex, toIndex)
        selectedVideoIds = Set(videos[range].map(\.id))
        focusedVideoId = toId
    }

    /// Selects every currently displayed video (the `filteredVideos` order
    /// shown in both grid and list). Backs ⌘A in grid mode.
    func selectAllDisplayed() {
        let videos = filteredVideos
        guard !videos.isEmpty else { return }
        selectedVideoIds = Set(videos.map(\.id))
        lastClickedVideoId = videos.first?.id
        focusedVideoId = videos.last?.id
    }

    /// Moves the keyboard cursor through the displayed grid. `columns` is the
    /// current column count (derived from width by the view). With `extend`
    /// (shift held) the selection grows from the anchor to the new cursor;
    /// otherwise the cursor becomes a fresh single selection. Uses
    /// `filteredVideos` as the ordering authority — same as click selection.
    func moveFocus(_ direction: MoveCommandDirection, columns: Int, extend: Bool) {
        let videos = filteredVideos
        guard !videos.isEmpty else { return }

        // Current cursor position, falling back to the single selection, the
        // last click, then the first card.
        let currentId = focusedVideoId ?? selectedVideoIds.first ?? lastClickedVideoId
        let currentIndex = currentId.flatMap { id in
            videos.firstIndex(where: { $0.id == id })
        } ?? 0

        let step: Int
        switch direction {
        case .left:  step = -1
        case .right: step = 1
        case .up:    step = -max(1, columns)
        case .down:  step = max(1, columns)
        @unknown default: return
        }

        let targetIndex = min(max(currentIndex + step, 0), videos.count - 1)
        let targetId = videos[targetIndex].id

        if extend, let anchorId = lastClickedVideoId {
            selectRange(from: anchorId, to: targetId)   // anchor fixed, cursor moves
        } else {
            selectedVideoIds = [targetId]
            lastClickedVideoId = targetId
            focusedVideoId = targetId
        }
    }

    func clearSelection() {
        selectedVideoIds.removeAll()
        lastClickedVideoId = nil
        focusedVideoId = nil
    }

    /// For context menu: if right-clicked video is in selection, return all selected; otherwise just that one
    func videosForContextAction(rightClicked video: AerialVideo) -> [AerialVideo] {
        if selectedVideoIds.contains(video.id) {
            return selectedVideos
        }
        return [video]
    }

    /// Drag payload: newline-separated video IDs
    func dragPayload(for video: AerialVideo) -> String {
        if selectedVideoIds.contains(video.id) && selectedVideoIds.count > 1 {
            return selectedVideoIds.joined(separator: "\n")
        }
        return video.id
    }

    /// Delete downloaded videos from the cache, optionally hiding them so
    /// the DownloadCoordinator doesn't re-download them later.
    func deleteVideosFromCache(_ videos: [AerialVideo], alsoHide: Bool) {
        for video in videos {
            let path = VideoList.instance.localPathFor(video: video)
            if !path.isEmpty {
                do {
                    try FileManager.default.removeItem(atPath: path)
                } catch {
                    errorLog("Couldn't delete cached video at \(path): \(error.localizedDescription)")
                }
            }
        }
        if alsoHide {
            var hidden = PrefsVideos.hidden
            for video in videos where !hidden.contains(video.id) {
                hidden.append(video.id)
            }
            PrefsVideos.hidden = hidden
        }
        // Drops the deleted entries from every filter playlist, persists,
        // and bumps playlistGeneration — the extension advances away if
        // one of them was playing.
        PlaylistManager.shared.regenerateAll()
        refreshTrigger += 1
    }

    // MARK: - Computed

    var isDashboard: Bool {
        if case .dashboard = selectedSidebarItem { return true }
        return false
    }

    var isNowPlaying: Bool {
        if case .nowPlaying = selectedSidebarItem { return true }
        return false
    }

    var isMyVideos: Bool {
        if case .source("My Videos") = selectedSidebarItem { return true }
        return false
    }

    var isLiveFeeds: Bool {
        if case .source("Live Feeds") = selectedSidebarItem { return true }
        return false
    }

    var isUserPlaylist: Bool {
        if case .userPlaylist = selectedSidebarItem { return true }
        return false
    }

    var isExpansions: Bool {
        if case .expansions = selectedSidebarItem { return true }
        return false
    }

    var isActivity: Bool {
        if case .activity = selectedSidebarItem { return true }
        return false
    }

    /// True for sections whose content is rendered by `VideoGridView`
    /// and therefore supports the grid/list view-mode toggle. False for
    /// Now Playing, Live Feeds, User Playlists, the Expansions showcase,
    /// and Activity — all of which have bespoke content layouts.
    var supportsViewMode: Bool {
        switch selectedSidebarItem {
        case .dashboard, .nowPlaying, .userPlaylist, .expansions, .activity:
            return false
        case .source(let name) where name == "Live Feeds":
            return false
        default:
            return true
        }
    }

    /// Views where the right inspector stays permanently open — showing a
    /// "No Selection" placeholder when nothing is selected — instead of
    /// collapsing as you select/deselect. Exactly the views that render
    /// selectable `VideoBrowserCardView`s: the grid/list browsing views plus
    /// the per-monitor Now Playing sections and the Activity feed. Home, User
    /// Playlists, Live Feeds, and Expansions don't use the shared video
    /// selection, so they're excluded.
    var keepsInspectorOpen: Bool {
        supportsViewMode || isNowPlaying || isActivity
    }

    var userPlaylistId: UUID? {
        if case .userPlaylist(let id) = selectedSidebarItem { return id }
        return nil
    }

    var currentSourceName: String? {
        if case .source(let name) = selectedSidebarItem, name != "My Videos" { return name }
        return nil
    }

    var filteredVideos: [AerialVideo] {
        let allVideos = VideoList.instance.videos
        var result: [AerialVideo]

        switch selectedSidebarItem {
        case .allVideos:
            result = allVideos.filter { !PrefsVideos.hidden.contains($0.id) }
        case .location(let loc):
            result = allVideos.filter { $0.name == loc && !PrefsVideos.hidden.contains($0.id) }
        case .scene(let scene):
            result = allVideos.filter { $0.scene == scene && !PrefsVideos.hidden.contains($0.id) }
        case .timeOfDay(let tod):
            result = allVideos.filter { $0.timeOfDay.lowercased() == tod.lowercased() && !PrefsVideos.hidden.contains($0.id) }
        case .source(let src):
            result = allVideos.filter { video in
                video.sources.contains(where: { $0.name == src })
                    && !PrefsVideos.hidden.contains(video.id)
            }
        case .downloaded:
            result = allVideos.filter { $0.isAvailableOffline && !PrefsVideos.hidden.contains($0.id) }
        case .notDownloaded:
            result = allVideos.filter { !$0.isAvailableOffline && !PrefsVideos.hidden.contains($0.id) }
        case .favorites:
            result = allVideos.filter { PrefsVideos.favorites.contains($0.id) && !PrefsVideos.hidden.contains($0.id) }
        case .hidden:
            result = allVideos.filter { PrefsVideos.hidden.contains($0.id) }
        default:
            result = allVideos.filter { !PrefsVideos.hidden.contains($0.id) }
        }

        // Search filter
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { Self.matches($0, query: query) }
        }

        // Sort
        switch sortOrder {
        case .name:
            result.sort { $0.secondaryName < $1.secondaryName }
        case .duration:
            result.sort { $0.duration > $1.duration }
        }

        // The grid's ForEach, the marquee frame map and list-mode selection
        // all key off video id — duplicate ids there are SwiftUI undefined
        // behavior (ghost cards, broken context menus), so never let them
        // through even if VideoList regresses.
        return result.unique(for: \.id)
    }

    var currentTimeRestriction: (active: Bool, restrictTo: String) {
        let (active, restrictTo) = TimeManagement.sharedInstance.shouldRestrictPlaybackToDayNightVideo()
        return (active, restrictTo)
    }

    // MARK: - Thumbnail Loading

    func loadThumbnail(for video: AerialVideo) {
        guard thumbnails[video.id] == nil else { return }
        Thumbnails.get(forVideo: video) { [weak self] image in
            if let image = image {
                DispatchQueue.main.async {
                    self?.thumbnails[video.id] = image
                }
            }
        }
    }

    func timeModeName() -> String {
        switch PrefsTime.timeMode {
        case .disabled: return "Disabled"
        case .nightShift: return "Night Shift"
        case .manual: return "Manual"
        case .lightDarkMode: return "Light/Dark Mode"
        case .coordinates: return "Coordinates"
        case .locationService: return "Location Service"
        }
    }

    // MARK: - Search matching (shared between filteredVideos + global search)

    /// Lowercase substring match across the user-readable text fields
    /// of an `AerialVideo`. `query` MUST already be lowercased — keeps
    /// the per-video work to one allocation per field.
    static func matches(_ video: AerialVideo, query: String) -> Bool {
        if video.name.lowercased().contains(query) { return true }
        if video.secondaryName.lowercased().contains(query) { return true }
        if video.poi.values.contains(where: { $0.lowercased().contains(query) }) { return true }
        return false
    }

    /// Same predicate, applied to the stripped asset metadata that
    /// ships in `expansions.json` for not-yet-installed packs.
    /// Mirrors the video predicate's scope: title + secondary label
    /// + POI values. `query` MUST already be lowercased.
    static func matches(_ asset: ExpansionAsset, query: String) -> Bool {
        if let t = asset.title?.lowercased(), t.contains(query) { return true }
        if let a = asset.accessibilityLabel?.lowercased(), a.contains(query) { return true }
        if let poi = asset.pointsOfInterest,
           poi.values.contains(where: { $0.lowercased().contains(query) }) {
            return true
        }
        return false
    }

    // MARK: - Routing

    /// Switch to the Expansions tab and ask its content view to
    /// scroll to the given expansion id. Used by global search to
    /// jump from an "Available" result group to the installable
    /// pack card. Clears `searchText` so the content view actually
    /// renders `ExpansionsContentView` (otherwise the active query
    /// keeps the content area on the global search results).
    func routeToExpansion(id: String) {
        clearSelection()
        searchText = ""
        selectedSidebarItem = .expansions
        pendingExpansionScroll = id
        highlightedExpansionId = id
    }

    // MARK: - Global search (cross-source, grouped by Source)

    /// One result group's matching items. Two backings:
    ///   - `.installed`: a live `Source` from `SourceList.list` with
    ///     its playable `[AerialVideo]` matches.
    ///   - `.available`: an `Expansion` from the bundled catalog that
    ///     the user has NOT installed yet, with stripped-metadata
    ///     `[ExpansionAsset]` matches. No playback affordances — the
    ///     card surfaces an "Open in Expansions" jump button instead.
    struct GlobalSearchSourceGroup: Identifiable {
        enum Backing {
            case installed(Source, [AerialVideo])
            case available(Expansion, [ExpansionAsset])
        }
        let backing: Backing

        var id: String {
            switch backing {
            case .installed(let s, _): return s.name
            case .available(let e, _): return "expansion:\(e.id)"
            }
        }

        var displayName: String {
            switch backing {
            case .installed(let s, _): return s.name
            case .available(let e, _): return e.name
            }
        }

        var displayDescription: String {
            switch backing {
            case .installed(let s, _): return s.description
            case .available(let e, _): return e.description
            }
        }

        var isInstalled: Bool {
            switch backing {
            case .installed: return true
            case .available: return false
            }
        }

        /// Apple-shipped "core" manifests (`tvOS …` / `macOS …`).
        /// These are always present, always installed, and always
        /// pinned to the top of the global search results.
        var isCore: Bool {
            switch backing {
            case .installed(let s, _):
                return s.name.hasPrefix("tvOS") || s.name.hasPrefix("macOS")
            case .available:
                return false
            }
        }

        /// Whether the card should render the Installed/Available
        /// badge. Core sources are intrinsically installed and don't
        /// need the chip.
        var showsInstallBadge: Bool { !isCore }

        /// Sort key: lower = appears earlier. Apple-shipped cores
        /// pin to the top, then installed sources with at least one
        /// downloaded match, then installed sources where matches
        /// still need downloading, then available-but-not-installed
        /// expansions.
        var sortPriority: Int {
            switch backing {
            case .installed(_, let videos):
                if isCore { return 0 }
                return videos.contains(where: { $0.isAvailableOffline }) ? 1 : 2
            case .available:
                return 3
            }
        }
    }

    /// Group global search matches by source, sorted by priority.
    /// `excludedSource` lets `VideoGridView` omit its own source from
    /// the global section so we don't render duplicate cards.
    func globalSearchGroups(excluding excludedSource: String? = nil) -> [GlobalSearchSourceGroup] {
        let query = searchText.lowercased()
        guard !query.isEmpty else { return [] }
        let matches = VideoList.instance.videos.filter { Self.matches($0, query: query) }
        let bySource = Dictionary(grouping: matches, by: { $0.source.name })
        var groups: [GlobalSearchSourceGroup] = []
        for (sourceName, videos) in bySource {
            guard sourceName != excludedSource else { continue }
            guard let source = SourceList.list.first(where: { $0.name == sourceName }) else { continue }
            groups.append(GlobalSearchSourceGroup(
                backing: .installed(source, videos.sorted { $0.secondaryName < $1.secondaryName })
            ))
        }

        // Available expansions: walk the catalog and surface any
        // not-yet-installed pack whose stripped metadata matches the
        // query. Installed packs are skipped — the live Source above
        // is the source of truth for them.
        for expansion in ExpansionStore.shared.expansions {
            guard !ExpansionStore.shared.isInstalled(expansion) else { continue }
            guard let assets = expansion.assets, !assets.isEmpty else { continue }
            let matched = assets.filter { Self.matches($0, query: query) }
            guard !matched.isEmpty else { continue }
            groups.append(GlobalSearchSourceGroup(
                backing: .available(
                    expansion,
                    matched.sorted { ($0.title ?? "") < ($1.title ?? "") }
                )
            ))
        }
        return groups.sorted {
            if $0.sortPriority != $1.sortPriority { return $0.sortPriority < $1.sortPriority }
            return $0.displayName < $1.displayName
        }
    }
}
