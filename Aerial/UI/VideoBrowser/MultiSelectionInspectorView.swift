//
//  MultiSelectionInspectorView.swift
//  Aerial Companion
//
//  Inspector panel shown when multiple videos are selected.
//

import SwiftUI

struct MultiSelectionInspectorView: View {
    @ObservedObject var state: VideoBrowserState
    @StateObject private var downloadTracker = DownloadTracker.shared

    private var videos: [AerialVideo] { state.selectedVideos }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                // 2x2 thumbnail mosaic
                thumbnailMosaic
                    .frame(height: 120)
                    .clipped()
                    .cornerRadius(8)

                Text("\(videos.count) Videos Selected")
                    .font(.system(size: 16, weight: .semibold))

                // Total duration
                let totalDuration = videos.reduce(0.0) { $0 + $1.duration }
                if totalDuration > 0 {
                    Text("Total: \(formatDuration(totalDuration))")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .padding(16)

            Divider()

            // Bulk actions
            VStack(alignment: .leading, spacing: 8) {
                Text("ACTIONS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 2)

                // Add to Playlist
                addToPlaylistMenu

                // Download All uncached
                let uncached = videos.filter { !$0.isAvailableOffline }
                if !uncached.isEmpty {
                    Button(action: {
                        for video in uncached {
                            if case .none = downloadTracker.state(for: video.id) {
                                downloadTracker.queueDownload(videoId: video.id)
                            }
                        }
                    }) {
                        Label("Download \(uncached.count) Uncached", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderless)
                }

                // Favorite / Unfavorite
                let allFavorited = videos.allSatisfy { PrefsVideos.favorites.contains($0.id) }
                Button(action: {
                    var favs = PrefsVideos.favorites
                    if allFavorited {
                        let ids = Set(videos.map(\.id))
                        favs.removeAll { ids.contains($0) }
                    } else {
                        for video in videos where !favs.contains(video.id) {
                            favs.append(video.id)
                        }
                    }
                    PrefsVideos.favorites = favs
                    state.refreshTrigger += 1
                }) {
                    Label(allFavorited ? "Unfavorite All" : "Favorite All",
                          systemImage: allFavorited ? "star.slash" : "star.fill")
                }
                .buttonStyle(.borderless)

                // Hide / Unhide
                let allHidden = videos.allSatisfy { PrefsVideos.hidden.contains($0.id) }
                Button(action: {
                    var hidden = PrefsVideos.hidden
                    if allHidden {
                        let ids = Set(videos.map(\.id))
                        hidden.removeAll { ids.contains($0) }
                    } else {
                        for video in videos where !hidden.contains(video.id) {
                            hidden.append(video.id)
                        }
                    }
                    PrefsVideos.hidden = hidden
                    state.refreshTrigger += 1
                }) {
                    Label(allHidden ? "Unhide All" : "Hide All",
                          systemImage: allHidden ? "eye" : "eye.slash")
                }
                .buttonStyle(.borderless)
            }
            .padding(16)

            Spacer()
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Thumbnail Mosaic

    @ViewBuilder
    private var thumbnailMosaic: some View {
        let thumbVideos = Array(videos.prefix(4))
        GeometryReader { geo in
            let half = geo.size.width / 2
            let halfH = geo.size.height / 2
            ZStack {
                ForEach(Array(thumbVideos.enumerated()), id: \.offset) { index, video in
                    let x = index % 2 == 0 ? 0 : half
                    let y = index < 2 ? 0 : halfH
                    thumbnailImage(for: video)
                        .frame(width: half, height: halfH)
                        .clipped()
                        .offset(x: x, y: y)
                }
            }
        }
    }

    @ViewBuilder
    private func thumbnailImage(for video: AerialVideo) -> some View {
        if let thumb = state.thumbnails[video.id] {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .onAppear { state.loadThumbnail(for: video) }
        }
    }

    // MARK: - Add to Playlist

    @ViewBuilder
    private var addToPlaylistMenu: some View {
        let summaries = UserPlaylistManager.shared.allSummaries()
        if !summaries.isEmpty {
            Menu {
                ForEach(summaries) { summary in
                    Button(summary.name) {
                        addVideos(to: summary.id)
                    }
                }
                Divider()
                Button("New Playlist...") {
                    let summary = UserPlaylistManager.shared.createPlaylist(name: "\(videos.count) Videos")
                    addVideos(to: summary.id)
                }
            } label: {
                Label("Add \(videos.count) to Playlist", systemImage: "music.note.list")
            }
            .menuStyle(.borderlessButton)
        } else {
            Button(action: {
                let summary = UserPlaylistManager.shared.createPlaylist(name: "\(videos.count) Videos")
                addVideos(to: summary.id)
            }) {
                Label("Add to New Playlist", systemImage: "music.note.list")
            }
            .buttonStyle(.borderless)
        }
    }

    private func addVideos(to playlistId: UUID) {
        for video in videos {
            let entry = PlaylistEntry(
                videoId: video.id,
                videoName: video.name,
                secondaryName: video.secondaryName,
                duration: video.duration > 0 ? video.duration : nil
            )
            UserPlaylistManager.shared.addVideo(entry, to: playlistId)
        }
    }
}
