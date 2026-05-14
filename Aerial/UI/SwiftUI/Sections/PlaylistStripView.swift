//
//  PlaylistStripView.swift
//  Aerial Companion
//
//  Playlist section with toggle between horizontal strip and vertical list modes.
//  Persists the user's view mode preference across launches.
//

import SwiftUI

struct PlaylistSectionView: View {
    @ObservedObject var playbackManager: PlaybackManager
    @StateObject private var downloadTracker = DownloadTracker.shared
    @State private var entries: [PlaylistEntry] = []
    @State private var uncachedEntries: [PlaylistEntry] = []
    @State private var currentIdx: Int = 0
    @State private var thumbnails: [String: NSImage] = [:]
    @State private var listMode: Bool = Preferences.playlistListMode
    @State private var shuffleMode: Bool = Preferences.playlistShuffle
    @State private var displayToPlaylistIndex: [Int: Int] = [:]

    var body: some View {
        VStack(spacing: 4) {
            if entries.isEmpty && uncachedEntries.isEmpty {
                emptyState
            } else {
                HStack {
                    cycleModeIndicator
                    timeFilterIndicator
                    if !listMode {
                        directionIndicator
                    }
                    Spacer()
                    viewModeToggle
                }.padding(4)
            

                if listMode {
                    PlaylistListView(
                        entries: entries,
                        uncachedEntries: uncachedEntries,
                        currentIdx: currentIdx,
                        thumbnails: thumbnails,
                        playbackManager: playbackManager,
                        downloadTracker: downloadTracker,
                        onTapEntry: { tapEntry(index: $0) },
                        onDownload: { downloadEntry(videoId: $0) }
                    )
                } else {
                    thumbnailStrip
                }
            }

            if playbackManager.playbackMode != .none {
                SpeedSliderView(speed: Binding(
                    get: { playbackManager.globalSpeed },
                    set: { playbackManager.globalSpeed = $0 }
                ))
                .padding(.top, 4)
            }
        }
        .onAppear { reload() }
        .onChange(of: playbackManager.popoverScreenUUID) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: PlaylistManager.playlistDidChangeNotification)) { _ in
            reload()
        }
        .onReceive(downloadTracker.$downloadingVideoIds) { _ in
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: DownloadCoordinator.downloadDidCompleteNotification)) { _ in
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserPlaylistManager.didChangeNotification)) { _ in
            // Reload active user playlist from disk if it changed
            PlaylistManager.shared.reloadActiveUserPlaylistIfNeeded(for: playbackManager.effectiveScreenUUID)
            reload()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
            Text("Building playlist...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(height: 68)
    }

    // MARK: - Cycle Mode Indicator

    private var cycleModeIndicator: some View {
        Group {
            if entries.count <= 1 {
                // Single video: static repeat.1 icon
                Image(systemName: "repeat.1")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary.opacity(0.5))
            } else {
                // 2+ videos: tappable loop/shuffle toggle
                Button(action: {
                    shuffleMode.toggle()
                    Preferences.playlistShuffle = shuffleMode
                    PlaylistManager.shared.regenerateAll()
                }) {
                    Image(systemName: shuffleMode ? "shuffle" : "repeat")
                        .font(.system(size: 14))
                        .foregroundColor(shuffleMode ? .aerial : .secondary.opacity(0.5))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(shuffleMode ? "Replay in order" : "Shuffle on each loop")
                .accessibilityLabel(shuffleMode ? "Replay in order" : "Shuffle on each loop")
            }
        }
    }

    // MARK: - Time Filter Indicator

    private var timeFilterIndicator: some View {
        Group {
            let (isRestricted, restrictTo) = TimeManagement.sharedInstance.shouldRestrictPlaybackToDayNightVideo()
            if isRestricted {
                let next = nextTimeSlice(restrictTo)
                HStack(spacing: 3) {
                    Image(systemName: timeOfDayIcon(restrictTo))
                        .font(.system(size: 14))
                        .foregroundColor(.aerial)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.5))
                    Image(systemName: timeOfDayIcon(next))
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    if let transitionDate = TimeManagement.sharedInstance.nextTransitionDate() {
                        Text("in \(timeRemainingString(until: transitionDate))")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                .help("\(restrictTo.capitalized) → \(next) in \(TimeManagement.sharedInstance.nextTransitionDate().map { timeRemainingString(until: $0) } ?? "...")")
            }
        }
    }

    private func timeOfDayIcon(_ timeSlice: String) -> String {
        switch timeSlice {
        case "night":
            return "moon.fill"
        case "sunrise":
            return "sunrise.fill"
        case "sunset":
            return "sunset.fill"
        default:
            return "sun.max.fill"
        }
    }

    // MARK: - Direction Indicator

    private var directionIndicator: some View {
        HStack(spacing: 3) {
            Image(systemName: "chevron.backward")
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
            Image(systemName: "chevron.forward")
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundColor(.secondary.opacity(0.45))
    }

    // MARK: - View Mode Toggle

    private var viewModeToggle: some View {
        HStack(spacing: 4) {
            Button(action: {
                listMode = false
                Preferences.playlistListMode = false
            }) {
                Image(systemName: "rectangle.split.1x2.fill")
                    .font(.system(size: 14))
                    .foregroundColor(listMode ? .secondary.opacity(0.5) : .aerial)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Show the playlist as a thumbnail strip")
            .accessibilityLabel("Show the playlist as a thumbnail strip")

            Button(action: {
                listMode = true
                Preferences.playlistListMode = true
            }) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 14))
                    .foregroundColor(listMode ? .aerial : .secondary.opacity(0.5))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Show the playlist as a list")
            .accessibilityLabel("Show the playlist as a list")
        }
    }

    // MARK: - Thumbnail Strip

    private var thumbnailStrip: some View {
        GeometryReader { geo in
            let sidePadding = max(0, (geo.size.width - 96) / 2)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            playlistThumbnail(entry: entry, index: index)
                                .id(index)
                        }
                        ForEach(Array(uncachedEntries.enumerated()), id: \.offset) { _, entry in
                            uncachedThumbnail(entry: entry)
                                .id("dl-\(entry.videoId)")
                        }
                    }
                    .padding(.horizontal, sidePadding)
                    .padding(.vertical, 2)
                }
                .onChange(of: currentIdx) { newIndex in
                    guard newIndex >= 0 && newIndex < entries.count else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
                .onAppear {
                    // Scroll to current on appear
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [entries, currentIdx] in
                        guard currentIdx >= 0 && currentIdx < entries.count else { return }
                        proxy.scrollTo(currentIdx, anchor: .center)
                    }
                }
            }
        }
        .frame(height: 68)
        // Group the strip as a single VO container with a summary
        // label, so VoiceOver users can step into it intentionally
        // instead of having every thumbnail announced as the user
        // walks the popover.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(playlistAccessibilityLabel)
    }

    private var playlistAccessibilityLabel: String {
        let total = entries.count + uncachedEntries.count
        if total == 0 { return "Playlist, empty" }
        if total == 1 { return "Playlist, 1 video" }
        return "Playlist, \(total) videos"
    }

    // MARK: - Individual Thumbnail

    private func playlistThumbnail(entry: PlaylistEntry, index: Int) -> some View {
        let isCurrent = index == currentIdx

        return VStack(spacing: 2) {
            ZStack(alignment: .leading) {
                // Thumbnail image
                if let thumb = thumbnails[entry.videoId] {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 96, height: 54)
                        .clipped()
                        .cornerRadius(4)
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 96, height: 54)
                        .cornerRadius(4)
                        .overlay(
                            Image(systemName: "film")
                                .foregroundColor(.secondary.opacity(0.4))
                                .font(.system(size: 14))
                        )
                }

                // Progress bar overlay on current video (left edge, fills top-to-bottom)
                if isCurrent {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.aerial.opacity(0.8))
                            .frame(
                                width: 3,
                                height: geo.size.height * playbackManager.playbackProgress
                            )
                    }
                    .frame(width: 96, height: 54)
                }

                // Pause/play toggle overlay on current thumbnail
                if isCurrent && playbackManager.playbackMode != .none {
                    Button(action: { playbackManager.togglePause() }) {
                        Image(systemName: playbackManager.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 96, height: 54)
                    .help(playbackManager.isPaused ? "Resume" : "Pause")
                    .accessibilityLabel(playbackManager.isPaused ? "Resume" : "Pause")
                    .keyboardShortcut(.space, modifiers: [])
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isCurrent ? Color.aerial : Color.clear, lineWidth: 2)
            )
            .shadow(color: isCurrent ? Color.aerial.opacity(0.3) : .clear, radius: 4)

            // Label
            Text(entry.secondaryName.isEmpty ? entry.videoName : entry.secondaryName)
                .font(.system(size: 9))
                .foregroundColor(isCurrent ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: 96)
        }
        .onTapGesture {
            guard !isCurrent else { return }
            tapEntry(index: index)
        }
        // Each thumbnail is announced as a single VO element with
        // position context; the play/pause overlay button keeps its
        // own label so it remains separately reachable.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(thumbnailAccessibilityLabel(entry: entry, index: index))
        .accessibilityAddTraits(isCurrent ? [.isSelected, .isButton] : .isButton)
    }

    private func thumbnailAccessibilityLabel(entry: PlaylistEntry, index: Int) -> String {
        let title = entry.secondaryName.isEmpty ? entry.videoName : entry.secondaryName
        let total = entries.count
        if total <= 1 { return title }
        return "\(title), \(index + 1) of \(total)"
    }

    // MARK: - Uncached Thumbnail

    private func uncachedThumbnail(entry: PlaylistEntry) -> some View {
        let dlState = downloadTracker.state(for: entry.videoId)

        return VStack(spacing: 2) {
            ZStack {
                // Thumbnail image (dimmed)
                if let thumb = thumbnails[entry.videoId] {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 96, height: 54)
                        .clipped()
                        .cornerRadius(4)
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 96, height: 54)
                        .cornerRadius(4)
                }

                // Dark scrim
                Rectangle()
                    .fill(Color.black.opacity(0.4))
                    .frame(width: 96, height: 54)
                    .cornerRadius(4)

                // Badge overlay
                switch dlState {
                case .downloading(let progress):
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 2)
                            .frame(width: 28, height: 28)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.aerial, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: 28, height: 28)
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                case .queued:
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.8))
                case .none:
                    Button(action: { downloadEntry(videoId: entry.videoId) }) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 22))
                            .foregroundColor(.white.opacity(0.8))
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Download this video")
                    .accessibilityLabel("Download this video")
                }
            }
            .opacity(0.6)

            // Label
            Text(entry.secondaryName.isEmpty ? entry.videoName : entry.secondaryName)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: 96)
        }
        // Combine the dimmed thumbnail + label as one VO node and
        // surface "not downloaded yet" so users understand why these
        // entries can't be activated.
        .accessibilityElement(children: .combine)
        .accessibilityLabel({
            let title = entry.secondaryName.isEmpty ? entry.videoName : entry.secondaryName
            return "\(title), not downloaded"
        }())
    }

    // MARK: - Actions

    private func tapEntry(index: Int) {
        let playlistIndex = displayToPlaylistIndex[index] ?? index
        PlaylistManager.shared.setCurrentIndex(playlistIndex, for: playbackManager.effectiveScreenUUID)
        if playbackManager.isPlaying {
            playbackManager.skipTo(playlistIndex: playlistIndex, screenUUID: playbackManager.effectiveScreenUUID)
        }
    }

    private func downloadEntry(videoId: String) {
        downloadTracker.queueDownload(videoId: videoId)
    }

    // MARK: - Data Loading

    private func reload() {
        let screenUUID = playbackManager.effectiveScreenUUID
        let allEntries = PlaylistManager.shared.allEntries(for: screenUUID)
        let playlistCurrentIdx = PlaylistManager.shared.currentIndex(for: screenUUID)

        // Compute time restriction once — reused by both cached and uncached sections
        let (isRestricted, restrictTo) = TimeManagement.sharedInstance.shouldRestrictPlaybackToDayNightVideo()

        if isRestricted {
            // Build a videoId→timeOfDay lookup to avoid repeated linear scans
            let videoTimeMap = Dictionary(
                VideoList.instance.videos.map { ($0.id, $0.timeOfDay) },
                uniquingKeysWith: { first, _ in first }
            )

            var filtered: [PlaylistEntry] = []
            var indexMap: [Int: Int] = [:]

            for (originalIdx, entry) in allEntries.enumerated() {
                let matches = videoTimeMap[entry.videoId] == restrictTo
                let isCurrent = originalIdx == playlistCurrentIdx

                if matches || isCurrent {
                    indexMap[filtered.count] = originalIdx
                    filtered.append(entry)
                }
            }

            entries = filtered
            displayToPlaylistIndex = indexMap
            currentIdx = indexMap.first(where: { $0.value == playlistCurrentIdx })?.key ?? 0
        } else {
            entries = allEntries
            displayToPlaylistIndex = Dictionary(uniqueKeysWithValues: allEntries.indices.map { ($0, $0) })
            currentIdx = playlistCurrentIdx
        }

        reloadUncachedEntries(isRestricted: isRestricted, restrictTo: restrictTo)
        loadMissingThumbnails()
    }

    private func reloadUncachedEntries(isRestricted: Bool, restrictTo: String) {
        let screenUUID = playbackManager.effectiveScreenUUID

        // User playlists are explicit — no uncached section
        if PlaylistManager.shared.isUserPlaylistActive(for: screenUUID) {
            uncachedEntries = []
            return
        }

        let existingIds = Set(entries.map { $0.videoId })

        // Determine the effective filter
        let mode: NewShouldPlay
        let filterStrings: [String]
        if let info = PlaylistManager.shared.filterInfo(for: screenUUID) {
            mode = info.mode
            filterStrings = info.filterStrings
        } else {
            mode = PrefsVideos.newShouldPlay
            filterStrings = PrefsVideos.newShouldPlayString
        }

        // Get all matching videos, keep only uncached ones not already in playlist
        let allMatching = VideoList.instance.videosMatchingFilter(mode: mode, filterStrings: filterStrings)
        uncachedEntries = allMatching
            .filter { !$0.isAvailableOffline && !existingIds.contains($0.id) }
            .filter { !isRestricted || $0.timeOfDay == restrictTo }
            .map { PlaylistEntry(videoId: $0.id, videoName: $0.name, secondaryName: $0.secondaryName, duration: $0.duration) }
    }

    private func loadMissingThumbnails() {
        let allVideoEntries = entries + uncachedEntries
        // Build lookup once instead of linear scan per entry
        let videoById = Dictionary(
            VideoList.instance.videos.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for entry in allVideoEntries {
            guard thumbnails[entry.videoId] == nil else { continue }
            if let video = videoById[entry.videoId] {
                Thumbnails.get(forVideo: video) { image in
                    if let image = image {
                        DispatchQueue.main.async {
                            thumbnails[entry.videoId] = image
                        }
                    }
                }
            }
        }
    }
}

struct PlaylistSectionView_Previews: PreviewProvider {
    static var previews: some View {
        PlaylistSectionView(playbackManager: PlaybackManager.shared)
            .padding()
            .frame(width: 380)
    }
}
