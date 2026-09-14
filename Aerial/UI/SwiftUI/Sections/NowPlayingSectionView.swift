//
//  NowPlayingSectionView.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 14/02/2026.
//

import SwiftUI

// Local wrapper so we can add a .playlists case without modifying the shared NewShouldPlay enum
private enum PopoverCategory: Hashable {
    case filter(NewShouldPlay)
    case playlists
}

/// Now Playing source picker section with collapsible thumbnail grid
struct NowPlayingSectionView: View {
    @ObservedObject var playbackManager: PlaybackManager

    @State private var popoverCategory: PopoverCategory = .filter(PrefsVideos.newShouldPlay)
    @State private var selectedItems: Set<String> = Set(PrefsVideos.newShouldPlayString)
    @State private var isExpanded: Bool = false
    @State private var thumbnails: [String: NSImage] = [:]
    /// Set by `reloadState()` before it programmatically reseats
    /// `popoverCategory` from authoritative state. The next firing of
    /// `.onChange(of: popoverCategory)` consumes the flag and skips the
    /// commit branch — only real user picker changes should regenerate.
    @State private var suppressCategoryOnChange: Bool = false

    /// Bumped by `reloadState()` to force a SwiftUI body re-evaluation when
    /// `PlaylistManager` state changes (e.g. user activates a playlist).
    /// `PlaylistManager` and `UserPlaylistManager` aren't observed here —
    /// they're plain singletons whose state changes via NotificationCenter —
    /// so without this tick the `userPlaylistList`'s read of
    /// `activeUserPlaylistId(...)` wouldn't trigger a re-render and the
    /// row's selection indicator would stay stale.
    @State private var playlistActivationTick: Int = 0

    /// The current filter category (extracted from popoverCategory)
    private var selectedCategory: NewShouldPlay {
        if case .filter(let mode) = popoverCategory { return mode }
        // When showing playlists, fall back to last-known filter mode
        return PrefsVideos.newShouldPlay
    }

    // MARK: - Per-Screen Helpers

    private var isPerScreen: Bool {
        playbackManager.effectiveScreenUUID != nil
    }

    /// Select all sources for the current category without writing to global prefs.
    private func selectAllLocal() {
        for source in sources {
            selectedItems.insert(modePrefix + source)
        }
    }

    /// Regenerate only the current screen's playlist and restart its playback.
    private func commitPerScreenFilter() {
        guard let screenUUID = playbackManager.effectiveScreenUUID else {
            debugLog("NowPlaying: commitPerScreenFilter — no effectiveScreenUUID, bailing")
            return
        }
        let filters = Array(selectedItems)
        debugLog("NowPlaying: commitPerScreenFilter — screen=\(screenUUID) category=\(selectedCategory) filterStrings(\(filters.count))=\(filters)")
        PlaylistManager.shared.regenerate(for: screenUUID, mode: selectedCategory, filterStrings: filters)
        playbackManager.refreshPlayback(for: screenUUID)
        // Per-screen selection changes must also wake the download coordinator,
        // otherwise picking a location with no cached matches on one screen
        // never triggers a critical download.
        DownloadCoordinator.shared.selectionDidChange()
    }

    /// Mirror of `commitPerScreenFilter` for the shared (spanned/cloned/
    /// mirrored) path. Writes the new filter to global prefs *and*
    /// regenerates the shared playlist with it — without that regenerate
    /// call, the persisted shared playlist keeps its stale filter and the
    /// desktop keeps playing the old selection until something else
    /// triggers a rebuild. (Extension-side already self-corrects via its
    /// filter-mismatch check; this fixes the desktop side at the source.)
    private func commitGlobalFilter() {
        let filters = Array(selectedItems)
        debugLog("NowPlaying: commitGlobalFilter — category=\(selectedCategory) filterStrings(\(filters.count))=\(filters)")
        PrefsVideos.newShouldPlayString = filters
        PlaylistManager.shared.regenerate(for: nil, mode: selectedCategory, filterStrings: filters)
        playbackManager.refreshPlayback()
        DownloadCoordinator.shared.selectionDidChange()
    }

    // MARK: - Computed Properties

    private var sources: [String] {
        let all = VideoList.instance.getSources(mode: filterMode)
        switch selectedCategory {
        case .source:
            // Built-in Apple manifests + the "My Videos" local folder.
            // Community / paid expansion packs live in the Expansions
            // grouping below.
            return all.filter {
                $0.hasPrefix("tvOS") || $0.hasPrefix("macOS") || $0 == "My Videos"
            }
        case .expansions:
            // Anything else that isn't an Apple manifest, "My Videos"
            // or "Live Feeds" — community packs, installed paid packs,
            // anything added via "Got an install link?".
            return all.filter {
                !$0.hasPrefix("tvOS") && !$0.hasPrefix("macOS")
                    && $0 != "My Videos" && $0 != "Live Feeds"
            }
        default:
            return all
        }
    }

    private var filterMode: VideoList.FilterMode {
        switch selectedCategory {
        case .location: return .location
        case .favorites: return .favorite
        case .time: return .time
        case .scene: return .scene
        case .source, .expansions: return .source  // both partitions of the source list
        case .liveFeeds: return .source  // arbitrary — we bypass sources[] for this mode
        }
    }

    private var modePrefix: String {
        return String(describing: filterMode) + ":"
    }

    private var selectedSourceCount: Int {
        sources.filter { selectedItems.contains(modePrefix + $0) }.count
    }

    private var summaryText: String {
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
        if selected.isEmpty || selected.count == sources.count {
            return "All"
        }
        return selected.joined(separator: ", ")
    }

    private var allSelected: Bool {
        guard !sources.isEmpty else { return true }
        return selectedSourceCount == sources.count
    }

    private var sourceRows: [[Int]] {
        let cols = 4
        return stride(from: 0, to: sources.count, by: cols).map { start in
            Array(start..<min(start + cols, sources.count))
        }
    }

    private var gridHeight: CGFloat {
        let rowHeight: CGFloat = 63   // thumbnail (45) + VStack spacing (4) + caption (~14)
        let rowSpacing: CGFloat = 8
        let rows = CGFloat(sourceRows.count)
        let contentHeight = rows * rowHeight + max(0, rows - 1) * rowSpacing + 4
        return min(contentHeight, 220)
    }

    private var showingPlaylists: Bool {
        if case .playlists = popoverCategory { return true }
        return false
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 8) {
            // Header row — entire row is tappable to expand/collapse
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 20))

                categoryPicker
                    .font(.title3)

                if !showingPlaylists {
                    Text(summaryText)
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if !showingPlaylists && selectedCategory != .favorites && selectedCategory != .liveFeeds {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !showingPlaylists else { return }
                guard selectedCategory != .favorites && selectedCategory != .liveFeeds else { return }
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            }

            // User playlists list
            if showingPlaylists {
                userPlaylistList
            }

            // Expanded grid
            if !showingPlaylists && isExpanded && selectedCategory != .favorites && selectedCategory != .liveFeeds {
                VStack(alignment: .leading, spacing: 8) {
                    // Select All toggle
                    Button(action: toggleAll) {
                        HStack(spacing: 4) {
                            Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 13))
                                .foregroundColor(allSelected ? .aerial : .secondary)
                            Text(allSelected ? "All selected" : "Select all")
                                //.font(.caption)
                                .foregroundColor(.primary)
                        }.padding(.leading, 4)
                    }
                    .buttonStyle(.plain)
                    .help(allSelected ? "Deselect all" : "Select all")


                    // Multi-row thumbnail grid (non-lazy to avoid sizing issues in popover)
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(sourceRows, id: \.self) { row in
                                HStack(spacing: 8) {
                                    ForEach(row, id: \.self) { index in
                                        let source = sources[index]
                                        let path = modePrefix + source
                                        // Name-based count instead of index — `sources` may be a
                                        // partitioned subset of `getSources(...)` (Source vs.
                                        // Expansions split), so positional lookups would mis-resolve.
                                        let count = VideoList.instance.videos.filter { $0.sources.contains(where: { $0.name == source }) }.count
                                        SourceThumbnailCard(
                                            name: source,
                                            videoCount: count,
                                            isSelected: selectedItems.contains(path),
                                            thumbnail: thumbnails[source],
                                            onTap: { toggleSource(path) }
                                        )
                                    }
                                    if row.count < 4 { Spacer() }
                                }
                            }
                        }
                        .padding( 4)
                    }
                    .frame(height: gridHeight)
                }
                .padding(4)
            }
        }
        .padding(.vertical, 4)
        .onAppear { reloadState() }
        .onChange(of: playbackManager.popoverScreenUUID) { _ in reloadState() }
        // Re-sync from prefs whenever any code path regenerates the playlist
        // (the picker's own commitGlobalFilter, the Expansions thank-you
        // sheet's applySetToPlay, the post-manifest VideoList callback). The
        // existing programmatic-sync guard inside .onChange(of: popoverCategory)
        // makes the reseat idempotent — no write loop.
        .onReceive(NotificationCenter.default.publisher(for: PlaylistManager.playlistDidChangeNotification)) { _ in
            debugLog("🔎 NowPlaying: playlistDidChangeNotification received")
            reloadState()
        }
        // Belt and braces: AppKit posts `NSPopover.willShowNotification` every
        // time the menubar popover is about to become visible. Subscribing
        // here guarantees a re-sync from prefs on every popover show, even if
        // SwiftUI throttles the Combine subscription above while the popover
        // is hidden in its NSHostingController.
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.willShowNotification)) { _ in
            debugLog("🔎 NowPlaying: NSPopover.willShowNotification received")
            reloadState()
        }
    }

    // MARK: - Category Picker

    private var categoryPicker: some View {
        Picker("", selection: $popoverCategory) {
            Label("Locations", systemImage: "location").tag(PopoverCategory.filter(.location))
            Label("Favorites", systemImage: "star").tag(PopoverCategory.filter(.favorites))
            Label("Times", systemImage: "clock").tag(PopoverCategory.filter(.time))
            Label("Scenes", systemImage: "leaf").tag(PopoverCategory.filter(.scene))
            Label("Expansions", systemImage: "sparkles").tag(PopoverCategory.filter(.expansions))
            Label("Live Feeds", systemImage: "dot.radiowaves.left.and.right").tag(PopoverCategory.filter(.liveFeeds))
            Label("Sources", systemImage: "video.badge.plus").tag(PopoverCategory.filter(.source))
            if !UserPlaylistManager.shared.allSummaries().isEmpty {
                Divider()
                Label("Playlists", systemImage: "music.note.list").tag(PopoverCategory.playlists)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help("Filter what's playing — by location, time, scene, source, expansion, live feed, or playlist")
        .onChange(of: popoverCategory) { newValue in
            if suppressCategoryOnChange {
                suppressCategoryOnChange = false
                debugLog("NowPlaying: onChange(popoverCategory) suppressed (programmatic sync)")
                return
            }
            switch newValue {
            case .filter(let mode):
                isExpanded = false
                debugLog("NowPlaying: onChange(popoverCategory) — filter mode=\(mode) isPerScreen=\(isPerScreen)")
                thumbnails = [:]
                loadThumbnails()
                if isPerScreen {
                    debugLog("NowPlaying: onChange — per-screen branch, selectedSourceCount=\(selectedSourceCount)")
                    if selectedSourceCount == 0 && mode != .favorites && mode != .liveFeeds {
                        selectAllLocal()
                    }
                    commitPerScreenFilter()
                } else {
                    debugLog("NowPlaying: onChange — global branch, writing newShouldPlay=\(mode)")
                    PrefsVideos.newShouldPlay = mode
                    selectedItems = Set(PrefsVideos.newShouldPlayString)
                    if selectedSourceCount == 0 && mode != .favorites && mode != .liveFeeds {
                        selectAll()
                    }
                    commitGlobalFilter()
                }
            case .playlists:
                isExpanded = false
            }
        }
    }

    // MARK: - Actions

    /// Programmatic write to `popoverCategory` that suppresses the next
    /// `.onChange` firing — used by `reloadState()` to mirror authoritative
    /// state without triggering a commit/regenerate.
    private func setCategorySilently(_ newValue: PopoverCategory) {
        guard popoverCategory != newValue else { return }
        suppressCategoryOnChange = true
        popoverCategory = newValue
    }

    private func reloadState() {
        // Force a body re-render — covers the case where the only relevant
        // change is the active user playlist (PlaylistManager isn't observed,
        // and `setCategorySilently(.playlists)` below is a no-op when already
        // on `.playlists`).
        playlistActivationTick &+= 1

        let effectiveUUID = playbackManager.effectiveScreenUUID
        let userPlaylistActive = PlaylistManager.shared.isUserPlaylistActive(for: effectiveUUID)

        // Detect active user playlist → show playlists view
        if userPlaylistActive {
            setCategorySilently(.playlists)
        }

        // When a user playlist is active for this screen, the persisted
        // playlist has filterMode = -1 — which filterInfo() can't parse
        // (NewShouldPlay only covers 0...6). Bailing out here is critical:
        // the else-branch of the screenUUID block below would call
        // regenerate(for: screenUUID, ...), wiping the just-activated user
        // playlist with a filter-derived one. That's what produced both the
        // "click does nothing" symptom and the "always resets to Sources >
        // My Videos on relaunch" symptom.
        guard !userPlaylistActive else {
            loadThumbnails()
            return
        }

        if let screenUUID = effectiveUUID {
            if let info = PlaylistManager.shared.filterInfo(for: screenUUID) {
                if !showingPlaylists {
                    setCategorySilently(.filter(info.mode))
                }
                selectedItems = Set(info.filterStrings)
            } else {
                // No per-screen playlist yet — seed from global prefs
                if !showingPlaylists {
                    setCategorySilently(.filter(PrefsVideos.newShouldPlay))
                }
                selectedItems = Set(PrefsVideos.newShouldPlayString)
                PlaylistManager.shared.regenerate(for: screenUUID, mode: selectedCategory, filterStrings: Array(selectedItems))
            }
        } else {
            if !showingPlaylists {
                setCategorySilently(.filter(PrefsVideos.newShouldPlay))
            }
            selectedItems = Set(PrefsVideos.newShouldPlayString)
        }
        loadThumbnails()
    }

    private func loadThumbnails() {
        // Translate the picker's category into the prefix `videosMatchingFilter`
        // expects on each filter string ("location:Africa", "time:Day", etc.).
        // Matches the same routine PlaylistManager uses for real playback,
        // so each card's thumbnail comes from a video that would actually
        // play if the user picked just that item.
        let mode = selectedCategory
        let prefix: String
        switch mode {
        case .location:            prefix = "location"
        case .time:                prefix = "time"
        case .scene:               prefix = "scene"
        case .source, .expansions: prefix = "source"
        default:                   return  // favorites / liveFeeds don't render the grid
        }

        for item in sources {
            guard thumbnails[item] == nil else { continue }
            let videos = VideoList.instance.videosMatchingFilter(
                mode: mode,
                filterStrings: ["\(prefix):\(item)"]
            )
            if let video = videos.first {
                Thumbnails.get(forVideo: video) { image in
                    if let image = image {
                        DispatchQueue.main.async {
                            thumbnails[item] = image
                        }
                    }
                }
            }
        }
    }

    private func toggleSource(_ path: String) {
        if selectedItems.contains(path) {
            selectedItems.remove(path)
        } else {
            selectedItems.insert(path)
        }
        debugLog("NowPlaying: toggleSource — path=\(path) selectedItems(\(selectedItems.count))=\(Array(selectedItems)) isPerScreen=\(isPerScreen)")
        if isPerScreen {
            commitPerScreenFilter()
        } else {
            commitGlobalFilter()
        }
    }

    private func toggleAll() {
        debugLog("NowPlaying: toggleAll — allSelected=\(allSelected) isPerScreen=\(isPerScreen)")
        if allSelected {
            // Deselect all for current mode
            for source in sources {
                selectedItems.remove(modePrefix + source)
            }
        } else {
            if isPerScreen {
                selectAllLocal()
            } else {
                selectAll()
            }
        }
        debugLog("NowPlaying: toggleAll — after toggle, selectedItems(\(selectedItems.count))=\(Array(selectedItems))")
        if isPerScreen {
            commitPerScreenFilter()
        } else {
            commitGlobalFilter()
        }
    }

    private func selectAll() {
        for source in sources {
            selectedItems.insert(modePrefix + source)
        }
        PrefsVideos.newShouldPlayString = Array(selectedItems)
    }

    // MARK: - User Playlist List

    private var userPlaylistList: some View {
        // Touch `playlistActivationTick` so SwiftUI registers this computed
        // view as dependent on it. Without this read, the tick bumps inside
        // `reloadState()` invalidate `NowPlayingSectionView` overall, but
        // SwiftUI's diff doesn't propagate into this sub-view's ForEach —
        // the row content is treated as stable across subsequent activations
        // and the highlight stays on the first-clicked playlist.
        _ = playlistActivationTick
        let summaries = UserPlaylistManager.shared.allSummaries()
        let activeId = PlaylistManager.shared.activeUserPlaylistId(for: playbackManager.effectiveScreenUUID)

        return VStack(alignment: .leading, spacing: 4) {
            ForEach(summaries) { summary in
                let isActive = summary.id == activeId
                HStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 14))
                        .foregroundColor(isActive ? .aerial : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(summary.name)
                            .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                            .foregroundColor(isActive ? .aerial : .primary)
                            .lineLimit(1)
                        Text("\(summary.entryCount) video\(summary.entryCount == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.aerial)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(isActive ? Color.aerial.opacity(0.25) : Color.clear)
                .cornerRadius(6)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard summary.entryCount > 0 else { return }
                    PlaylistManager.shared.activateUserPlaylist(id: summary.id, for: playbackManager.effectiveScreenUUID)
                    if let screenUUID = playbackManager.effectiveScreenUUID {
                        playbackManager.refreshPlayback(for: screenUUID)
                    } else {
                        playbackManager.refreshPlayback()
                    }
                }
                .opacity(summary.entryCount > 0 ? 1.0 : 0.5)
            }

            // "Back to filters" button
            Button(action: {
                // Deactivate user playlist — regenerate from current filter prefs
                let mode = selectedCategory
                if let screenUUID = playbackManager.effectiveScreenUUID {
                    PlaylistManager.shared.regenerate(for: screenUUID, mode: mode, filterStrings: Array(selectedItems))
                    playbackManager.refreshPlayback(for: screenUUID)
                } else {
                    PlaylistManager.shared.regenerate()
                    playbackManager.refreshPlayback()
                }
                withAnimation(.easeInOut(duration: 0.2)) {
                    popoverCategory = .filter(mode)
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12))
                    Text("Back to filter-based playback")
                        .font(.system(size: 12))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .opacity(PlaylistManager.shared.isUserPlaylistActive(for: playbackManager.effectiveScreenUUID) ? 1.0 : 0.0)
        }
        .padding(4)
    }
}

struct NowPlayingSectionView_Previews: PreviewProvider {
    static var previews: some View {
        NowPlayingSectionView(playbackManager: PlaybackManager.shared)
            .padding()
            .frame(width: 380, height: 300)
    }
}
