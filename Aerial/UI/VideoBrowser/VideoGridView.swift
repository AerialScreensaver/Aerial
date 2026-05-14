//
//  VideoGridView.swift
//  Aerial Companion
//
//  Grid/list content view for Browse mode.
//

import SwiftUI
import UniformTypeIdentifiers

/// Per-frame card-position reporter used by the marquee selection.
/// Each card publishes its frame in the grid coordinate space; the marquee
/// rectangle hit-tests against this map to compute the live selection.
private struct CardFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct VideoGridView: View {
    @ObservedObject var state: VideoBrowserState
    @StateObject private var myVideosVM = MyVideosViewModel()
    @StateObject private var downloadTracker = DownloadTracker.shared
    @State private var isDropTargeted = false

    // MARK: - Marquee selection state

    /// Map of video id → frame in the grid coordinate space, populated by
    /// `CardFramePreferenceKey` reports from each card's GeometryReader.
    @State private var cardFrames: [String: CGRect] = [:]
    /// Drag start point in grid coords; nil when no drag is in progress.
    @State private var marqueeStart: CGPoint?
    /// Current drag location; tracked alongside `marqueeStart`.
    @State private var marqueeCurrent: CGPoint?
    /// Selection captured at drag start. Plain drag → empty (replace mode);
    /// shift/cmd drag → existing selection (additive / toggle baseline).
    @State private var marqueeInitialSelection: Set<String> = []
    /// Modifier flags captured at drag start. Constant for the lifetime of
    /// the drag — re-reading `NSApp.currentEvent?.modifierFlags` mid-drag
    /// would let modifier toggles change selection semantics in flight.
    @State private var marqueeModifiers: NSEvent.ModifierFlags = []

    var body: some View {
        VStack(spacing: 0) {
            // Content (search + view-mode toggle now live in the
            // window toolbar; Download All moved into the section
            // headers so it appears in context with the other actions.)
            let videos = state.filteredVideos

            if videos.isEmpty && !state.isMyVideos {
                VStack(spacing: 8) {
                    Image(systemName: "film")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No videos found")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.viewMode == .grid {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if state.isMyVideos {
                            myVideosHeader
                            myVideosDropZone
                        } else if state.currentSourceName != nil {
                            sourceHeader
                        } else if let header = categoryHeader() {
                            header
                        }

                        if videos.isEmpty {
                            myVideosEmptyState
                        } else {
                            videoGrid(videos: videos)
                        }

                        // Global cross-source results below the grid,
                        // excluding the current source so we don't
                        // render a duplicate card for it.
                        if !state.searchText.isEmpty {
                            GlobalSearchResultsView(
                                state: state,
                                excludedSource: state.currentSourceName,
                                showOtherSourcesHeader: true
                            )
                        }
                    }
                    .padding(16)
                }
            } else {
                if state.isMyVideos {
                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                myVideosHeader
                                myVideosDropZone
                            }
                            .padding(16)
                        }
                        .frame(height: 220)

                        Divider()

                        List(videos, id: \.id, selection: $state.selectedVideoIds) { video in
                            VideoBrowserRowView(video: video, state: state)
                        }
                    }
                } else if state.currentSourceName != nil {
                    VStack(spacing: 0) {
                        ScrollView {
                            sourceHeader
                                .padding(16)
                        }
                        .frame(height: 120)

                        Divider()

                        List(videos, id: \.id, selection: $state.selectedVideoIds) { video in
                            VideoBrowserRowView(video: video, state: state)
                        }
                    }
                } else {
                    List(videos, id: \.id, selection: $state.selectedVideoIds) { video in
                        VideoBrowserRowView(video: video, state: state)
                    }
                }
            }

            // Error banner
            if state.isMyVideos, let error = myVideosVM.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.system(size: 12))
                    Spacer()
                    Button(action: { myVideosVM.errorMessage = nil }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss error")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.15))
                .cornerRadius(6)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Import progress
            if state.isMyVideos && myVideosVM.isImporting {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(myVideosVM.importProgress)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if state.isMyVideos {
                myVideosVM.scanFolder()
            }
        }
        .onChange(of: state.isMyVideos) { isMyVideos in
            if isMyVideos {
                myVideosVM.scanFolder()
            }
        }
    }

    // MARK: - Download All Button

    /// Wraps `downloadAllButton` with the gating logic that previously
    /// lived in the top toolbar — only render anything when the current
    /// view contains uncached videos. This is the entry point used by
    /// the section headers; render an EmptyView otherwise so it sits
    /// invisibly in the header's `actions` slot.
    @ViewBuilder
    private var downloadAllButtonIfNeeded: some View {
        if state.filteredVideos.contains(where: { !$0.isAvailableOffline }) {
            downloadAllButton
        }
    }

    @ViewBuilder
    private var downloadAllButton: some View {
        let uncached = state.filteredVideos.filter { !$0.isAvailableOffline }
        let allQueued = uncached.allSatisfy {
            if case .none = downloadTracker.state(for: $0.id) { return false }
            return true
        }

        if allQueued {
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Downloading \(uncached.count)...")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        } else {
            Button(action: {
                for video in uncached {
                    if case .none = downloadTracker.state(for: video.id) {
                        downloadTracker.queueDownload(videoId: video.id)
                    }
                }
            }) {
                Label("Download All (\(uncached.count))", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.aerial)
            .help("Download all \(uncached.count) uncached videos in this view")
        }
    }

    // MARK: - My Videos Header Card

    private var myVideosHeader: some View {
        ContentHeader(
            icon: "film.stack",
            title: "My Videos",
            description: "You can add your own videos here, or copy them manually in `/Users/Shared/Aerial/My Videos/`. Files cannot be played from other locations because of security restrictions in macOS."
        ) {
            downloadAllButtonIfNeeded
            Button(action: { myVideosVM.openInFinder() }) {
                Label("Open Folder", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button(action: {
                SourceList.ensureDefaultLocalSource()
                state.refreshTrigger += 1
            }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    // MARK: - Source Header Card

    private var sourceHeader: some View {
        let sourceName = state.currentSourceName ?? ""
        let source = SourceList.list.first { $0.name == sourceName }

        return ContentHeader(
            icon: "tray",
            title: sourceName,
            description: source?.description
        ) {
            downloadAllButtonIfNeeded
            Button(action: {
                VideoList.instance.reloadSource(named: sourceName)
            }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    // MARK: - Category Header (Locations / Scenes / Time of Day / etc.)

    /// Builds a header card for the catch-all categories (locations,
    /// scenes, time-of-day, favorites, downloaded, hidden, all videos).
    /// Returns nil for categories rendered by other paths (My Videos,
    /// named sources, Now Playing, Live Feeds, user playlists, etc.).
    /// The Download All button surfaces in the actions slot when the
    /// current view contains uncached videos.
    private func categoryHeader() -> AnyView? {
        let (icon, title): (String, String)
        switch state.selectedSidebarItem {
        case .allVideos: (icon, title) = ("film.stack", "All Videos")
        case .location(let name): (icon, title) = ("mappin", name)
        case .scene(let scene): (icon, title) = (sceneIcon(scene), scene.rawValue)
        case .timeOfDay(let slug): (icon, title) = (timeOfDayIcon(slug), slug.capitalized)
        case .downloaded: (icon, title) = ("arrow.down.circle", "Downloaded")
        case .notDownloaded: (icon, title) = ("cloud", "Not Downloaded")
        case .favorites: (icon, title) = ("star", "Favorites")
        case .hidden: (icon, title) = ("eye.slash", "Hidden")
        default: return nil
        }

        return AnyView(
            ContentHeader(icon: icon, title: title) {
                downloadAllButtonIfNeeded
            }
        )
    }

    private func timeOfDayIcon(_ slug: String) -> String {
        switch slug.lowercased() {
        case "sunrise": return "sunrise"
        case "sunset": return "sunset"
        case "night": return "moon.stars"
        default: return "sun.max"
        }
    }

    // MARK: - My Videos Drop Zone

    private var myVideosDropZone: some View {
        DropZoneView(isTargeted: $isDropTargeted)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
                return true
            }
    }

    // MARK: - My Videos Empty State

    private var myVideosEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No videos yet")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Text("Drag video files onto the drop zone above, or use Open Folder to add files manually.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Video Grid

    private func videoGrid(videos: [AerialVideo]) -> some View {
        ZStack(alignment: .topLeading) {
            // Background drag-target. Catches marquee drags from the empty
            // space between cards. Cards are layered above this and consume
            // their own taps + drag-to-playlist gestures, so neither is
            // disrupted by this layer.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                    if !modifiers.contains(.shift) && !modifiers.contains(.command) {
                        state.clearSelection()
                    }
                }
                .gesture(marqueeGesture)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200, maximum: 200), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(videos, id: \.id) { video in
                    VideoBrowserCardView(
                        video: video,
                        state: state,
                        isCurrent: false,
                        showTimeMatch: state.currentTimeRestriction.active,
                        isMyVideos: state.isMyVideos,
                        onTitleChanged: state.isMyVideos ? { newTitle in
                            updateMyVideoTitle(video: video, newTitle: newTitle)
                        } : nil
                    )
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: CardFramePreferenceKey.self,
                                value: [video.id: geo.frame(in: .named("videoGrid"))]
                            )
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Marquee rectangle, drawn while a drag is in progress. Hit
            // testing is disabled so the rectangle never intercepts the
            // gesture that's drawing it.
            if let rect = marqueeRect {
                Rectangle()
                    .strokeBorder(Color.aerial, lineWidth: 1)
                    .background(Color.aerial.opacity(0.15))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "videoGrid")
        .onPreferenceChange(CardFramePreferenceKey.self) { cardFrames = $0 }
    }

    // MARK: - Marquee Selection

    /// Rectangle spanning the live drag, or nil when no drag is active.
    /// Computed from `marqueeStart` / `marqueeCurrent` so the order of mouse
    /// movement (down-right vs up-left) doesn't produce a negative-size rect.
    private var marqueeRect: CGRect? {
        guard let start = marqueeStart, let current = marqueeCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    /// Drag gesture that drives marquee selection. `minimumDistance: 4` lets
    /// straight clicks pass through to `onTapGesture` for selection-clear.
    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("videoGrid"))
            .onChanged { value in
                if marqueeStart == nil {
                    marqueeStart = value.startLocation
                    marqueeModifiers = NSApp.currentEvent?.modifierFlags ?? []
                    if marqueeModifiers.contains(.shift) || marqueeModifiers.contains(.command) {
                        marqueeInitialSelection = state.selectedVideoIds
                    } else {
                        marqueeInitialSelection = []
                    }
                }
                marqueeCurrent = value.location
                updateMarqueeSelection()
            }
            .onEnded { _ in
                marqueeStart = nil
                marqueeCurrent = nil
                marqueeInitialSelection = []
                marqueeModifiers = []
            }
    }

    /// Recompute the live selection from `marqueeRect` × `cardFrames`.
    /// Plain drag = replace; shift drag = additive; cmd drag = toggle —
    /// matching `selectVideo(_:modifiers:)`'s semantics for clicks.
    private func updateMarqueeSelection() {
        guard let rect = marqueeRect else { return }
        let hits = Set(cardFrames.compactMap { $0.value.intersects(rect) ? $0.key : nil })

        if marqueeModifiers.contains(.command) {
            state.selectedVideoIds = marqueeInitialSelection.symmetricDifference(hits)
        } else {
            // Plain drag (initial empty) → replace; shift drag (initial set) → union.
            state.selectedVideoIds = marqueeInitialSelection.union(hits)
        }
    }

    // MARK: - Title Update

    private func updateMyVideoTitle(video: AerialVideo, newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Find the video's local file path from its urls
        let filePath = video.urls[.v4KHEVC] ?? video.urls.values.first ?? ""
        guard !filePath.isEmpty else { return }

        // Read entries.json
        let entriesPath = Cache.supportPath.appending("/Sources/My Videos/entries.json")
        guard let jsonData = try? Data(contentsOf: URL(fileURLWithPath: entriesPath)),
              let manifest = try? newJSONDecoder().decode(VideoManifest.self, from: jsonData) else {
            return
        }

        // Update matching asset title
        let updatedAssets = manifest.assets.map { asset -> VideoAsset in
            if asset.url4KSDR == filePath {
                return VideoAsset(
                    accessibilityLabel: asset.accessibilityLabel,
                    id: asset.id,
                    title: trimmed,
                    timeOfDay: asset.timeOfDay,
                    scene: asset.scene,
                    pointsOfInterest: asset.pointsOfInterest,
                    url4KHDR: asset.url4KHDR,
                    url4KSDR: asset.url4KSDR,
                    url1080H264: asset.url1080H264,
                    url1080HDR: asset.url1080HDR,
                    url4KSDR120FPS: asset.url4KSDR120FPS,
                    url4KSDR240FPS: asset.url4KSDR240FPS,
                    url1080SDR: asset.url1080SDR,
                    url: asset.url,
                    type: asset.type
                )
            }
            return asset
        }

        let updatedManifest = VideoManifest(
            assets: updatedAssets,
            initialAssetCount: manifest.initialAssetCount,
            version: manifest.version
        )

        // Save and refresh
        if let source = SourceList.list.first(where: { $0.name == "My Videos" && $0.type == .local }) {
            SourceList.saveEntries(source: source, manifest: updatedManifest)
        }

        // Reload VideoList to pick up the new title
        SourceList.ensureDefaultLocalSource()
        state.refreshTrigger += 1
    }

    // MARK: - Drop Handling

    private func handleDrop(providers: [NSItemProvider]) {
        var urls: [URL] = []
        var rejectedExtensions: Set<String> = []
        let supportedExtensions = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]

        let group = DispatchGroup()

        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url {
                        let ext = url.pathExtension.lowercased()
                        if supportedExtensions.contains(ext) {
                            urls.append(url)
                        } else {
                            rejectedExtensions.insert(ext.isEmpty ? "unknown" : ext)
                        }
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            if !urls.isEmpty {
                myVideosVM.importVideos(urls: urls)
                // Refresh the grid after import completes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    SourceList.ensureDefaultLocalSource()
                    state.refreshTrigger += 1
                }
            }
            if !rejectedExtensions.isEmpty {
                let formats = rejectedExtensions.sorted().map { ".\($0)" }.joined(separator: ", ")
                let count = rejectedExtensions.count
                myVideosVM.showError("File type\(count == 1 ? "" : "s") not supported: \(formats)")
            }
        }
    }
}

struct VideoGridView_Previews: PreviewProvider {
    static var previews: some View {
        VideoGridView(state: PreviewData.makeState())
            .frame(width: 600, height: 500)
    }
}
