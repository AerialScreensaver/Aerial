//
//  VideoBrowserCardView.swift
//  Aerial Companion
//
//  Individual video card for the browse grid.
//

import SwiftUI
import UniformTypeIdentifiers

struct VideoBrowserCardView: View {
    let video: AerialVideo
    @ObservedObject var state: VideoBrowserState
    var isCurrent: Bool = false
    var showTimeMatch: Bool = false
    var isMyVideos: Bool = false
    var onTitleChanged: ((String) -> Void)? = nil

    @StateObject private var downloadTracker = DownloadTracker.shared
    @State private var showingOverridePicker = false
    @State private var editingTitle: String = ""

    private var isSelected: Bool {
        state.selectedVideoIds.contains(video.id)
    }

    private var matchesTime: Bool {
        TimeManagement.videoMatchesCurrentTime(video)
    }

    private var hasOverride: Bool {
        PrefsVideos.timeOfDayOverride[video.id] != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Thumbnail
            ZStack(alignment: .topTrailing) {
                thumbnailView
                    .frame(height: 108)
                    .clipped()
                    .cornerRadius(6)

                // Download status
                if video.isAvailableOffline {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.aerial).shadow(color: .black.opacity(0.5), radius: 4, x: 2, y: 2)
                        .padding(4)
                } else {
                    // Dark scrim + download badge
                    ZStack {
                        Rectangle()
                            .fill(Color.black.opacity(0.4))
                            .cornerRadius(6)

                        downloadBadge(for: video)
                    }
                }

                // Time-match dot
                if showTimeMatch {
                    Circle()
                        .fill(matchesTime ? Color.green : Color.gray.opacity(0.5))
                        .frame(width: 8, height: 8)
                        .position(x: 10, y: 10)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isCurrent ? Color.aerial : (isSelected ? Color.aerial.opacity(0.5) : Color.clear), lineWidth: 2)
            )
            .opacity(showTimeMatch && !matchesTime ? 0.6 : 1.0)

            // Name
            VStack(alignment: .leading, spacing: 1) {
                if !video.secondaryName.isEmpty {
                    if isMyVideos, onTitleChanged != nil {
                        HStack(spacing: 4) {
                            TextField("Title", text: $editingTitle, onCommit: {
                                let trimmed = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    onTitleChanged?(trimmed)
                                }
                            })
                            .font(.system(size: 12, weight: .semibold))
                            .textFieldStyle(.plain)
                            .lineLimit(1)
                            .onAppear { editingTitle = video.secondaryName }
                            Image(systemName: "pencil.line")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text(video.secondaryName)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                }
                Text(video.name)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            // Metadata row
            HStack(spacing: 6) {
                // Time-of-day icon (tappable)
                Button(action: { showingOverridePicker.toggle() }) {
                    Image(systemName: timeOfDayIcon(video.timeOfDay))
                        .font(.system(size: 13))
                        .foregroundColor(hasOverride ? .aerial : .secondary)
                }
                .buttonStyle(.borderless)
                .help(video.timeOfDay.capitalized)
                .accessibilityLabel("Time of day: \(video.timeOfDay.capitalized). Tap to override.")
                .popover(isPresented: $showingOverridePicker) {
                    TimeOfDayOverrideView(video: video, state: state)
                        .padding(12)
                }

                // Scene icon
                Image(systemName: sceneIcon(video.scene))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .help(video.scene.rawValue.capitalized)

                // Duration
                if video.duration > 0 {
                    Text(formatDuration(video.duration))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Favorite toggle
                Button(action: { toggleFavorite() }) {
                    Image(systemName: PrefsVideos.favorites.contains(video.id) ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundColor(PrefsVideos.favorites.contains(video.id) ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .help(PrefsVideos.favorites.contains(video.id) ? "Remove from favorites" : "Add to favorites")
                .accessibilityLabel(PrefsVideos.favorites.contains(video.id) ? "Remove from favorites" : "Add to favorites")

                // Hidden toggle
                Button(action: { toggleHidden() }) {
                    Image(systemName: PrefsVideos.hidden.contains(video.id) ? "eye.slash.fill" : "eye.slash")
                        .font(.system(size: 12))
                        .foregroundColor(PrefsVideos.hidden.contains(video.id) ? .red : .secondary)
                }
                .buttonStyle(.borderless)
                .help(PrefsVideos.hidden.contains(video.id) ? "Unhide this video" : "Hide this video")
                .accessibilityLabel(PrefsVideos.hidden.contains(video.id) ? "Unhide this video" : "Hide this video")
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.aerial.opacity(0.08) : Color(NSColor.controlBackgroundColor))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            state.selectVideo(video, modifiers: modifiers)
        }
        .onDrag {
            NSItemProvider(object: state.dragPayload(for: video) as NSString)
        }
        .contextMenu {
            contextMenuContent
        }
        .onAppear {
            state.loadThumbnail(for: video)
        }
    }

    // MARK: - Context Menu (multi-selection aware)

    @ViewBuilder
    private var contextMenuContent: some View {
        let videos = state.videosForContextAction(rightClicked: video)
        let summaries = UserPlaylistManager.shared.allSummaries()
        if !summaries.isEmpty {
            Menu(videos.count > 1 ? "Add \(videos.count) Videos to Playlist" : "Add to Playlist") {
                ForEach(summaries) { summary in
                    Button(summary.name) {
                        addVideos(videos, to: summary.id)
                    }
                }
                Divider()
                Button("New Playlist...") {
                    let name = videos.count == 1 ? video.secondaryName : "\(videos.count) Videos"
                    let summary = UserPlaylistManager.shared.createPlaylist(name: name)
                    addVideos(videos, to: summary.id)
                }
            }
        } else {
            Button("Add to New Playlist...") {
                let name = videos.count == 1 ? video.secondaryName : "\(videos.count) Videos"
                let summary = UserPlaylistManager.shared.createPlaylist(name: name)
                addVideos(videos, to: summary.id)
            }
        }

        Divider()

        // Download
        let uncached = videos.filter { !$0.isAvailableOffline }
        if !uncached.isEmpty {
            Button {
                for v in uncached {
                    if case .none = downloadTracker.state(for: v.id) {
                        downloadTracker.queueDownload(videoId: v.id)
                    }
                }
            } label: {
                Label(uncached.count == 1 ? "Download" : "Download \(uncached.count) Videos",
                      systemImage: "arrow.down.circle")
            }
        }

        // Favorite / Unfavorite
        let allFavorited = videos.allSatisfy { PrefsVideos.favorites.contains($0.id) }
        Button {
            var favs = PrefsVideos.favorites
            if allFavorited {
                let ids = Set(videos.map(\.id))
                favs.removeAll { ids.contains($0) }
            } else {
                for v in videos where !favs.contains(v.id) {
                    favs.append(v.id)
                }
            }
            PrefsVideos.favorites = favs
            state.refreshTrigger += 1
        } label: {
            Label(allFavorited ? (videos.count > 1 ? "Unfavorite All" : "Unfavorite") : (videos.count > 1 ? "Favorite All" : "Favorite"),
                  systemImage: allFavorited ? "star.slash" : "star.fill")
        }

        // Hide / Unhide
        let allHidden = videos.allSatisfy { PrefsVideos.hidden.contains($0.id) }
        Button {
            var hidden = PrefsVideos.hidden
            if allHidden {
                let ids = Set(videos.map(\.id))
                hidden.removeAll { ids.contains($0) }
            } else {
                for v in videos where !hidden.contains(v.id) {
                    hidden.append(v.id)
                }
            }
            PrefsVideos.hidden = hidden
            state.refreshTrigger += 1
        } label: {
            Label(allHidden ? (videos.count > 1 ? "Unhide All" : "Unhide") : (videos.count > 1 ? "Hide All" : "Hide"),
                  systemImage: allHidden ? "eye" : "eye.slash")
        }
    }

    private func addVideos(_ videos: [AerialVideo], to playlistId: UUID) {
        for v in videos {
            let entry = PlaylistEntry(
                videoId: v.id,
                videoName: v.name,
                secondaryName: v.secondaryName,
                duration: v.duration > 0 ? v.duration : nil
            )
            UserPlaylistManager.shared.addVideo(entry, to: playlistId)
        }
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumb = state.thumbnails[video.id] {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .overlay(
                    Image(systemName: "film")
                        .foregroundColor(.secondary.opacity(0.4))
                        .font(.system(size: 20))
                )
        }
    }

    // MARK: - Download Badge

    @ViewBuilder
    private func downloadBadge(for video: AerialVideo) -> some View {
        let dlState = downloadTracker.state(for: video.id)
        switch dlState {
        case .downloading(let progress):
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 3)
                    .frame(width: 42, height: 42)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.aerial, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 42, height: 42)
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.down")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
            }
        case .queued:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 33))
                .foregroundColor(.white.opacity(0.8))
        case .none:
            Button(action: { downloadTracker.queueDownload(videoId: video.id) }) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 33))
                    .foregroundColor(.white.opacity(0.8))
            }
            .buttonStyle(.borderless)
            .help("Download this video")
            .accessibilityLabel("Download this video")
        }
    }

    // MARK: - Actions

    private func toggleFavorite() {
        var favs = PrefsVideos.favorites
        if favs.contains(video.id) {
            favs.removeAll { $0 == video.id }
        } else {
            favs.append(video.id)
        }
        PrefsVideos.favorites = favs
        state.refreshTrigger += 1
    }

    private func toggleHidden() {
        var hidden = PrefsVideos.hidden
        if hidden.contains(video.id) {
            hidden.removeAll { $0 == video.id }
        } else {
            hidden.append(video.id)
        }
        PrefsVideos.hidden = hidden
        state.refreshTrigger += 1
    }
}

struct VideoBrowserCardView_Previews: PreviewProvider {
    static var previews: some View {
        let video = PreviewData.makeVideo()
        VideoBrowserCardView(video: video, state: PreviewData.makeState())
            .frame(width: 220)
            .padding()
    }
}
