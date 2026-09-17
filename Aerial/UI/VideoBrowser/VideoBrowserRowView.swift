//
//  VideoBrowserRowView.swift
//  Aerial Companion
//
//  Compact list row alternative to the card view.
//

import SwiftUI
import UniformTypeIdentifiers

struct VideoBrowserRowView: View {
    let video: AerialVideo
    @ObservedObject var state: VideoBrowserState

    @State private var pendingCacheDelete: PendingCacheDelete?

    var body: some View {
        HStack(spacing: 10) {
            // Thumbnail
            thumbnailView
                .rotatedByOverride(RotationOverride.degrees(for: video))
                .frame(width: 80, height: 45)
                .clipped()
                .cornerRadius(4)
                .onAppear { state.loadThumbnail(for: video) }

            // Name
            VStack(alignment: .leading, spacing: 2) {
                if !video.secondaryName.isEmpty {
                    Text(video.secondaryName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                Text(video.name)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Metadata
            HStack(spacing: 8) {
                Image(systemName: timeOfDayIcon(video.timeOfDay))
                    .font(.system(size: 14))
                    .foregroundColor(PrefsVideos.timeOfDayOverride[video.id] != nil ? .aerial : .secondary)

                Image(systemName: sceneIcon(video.scene))
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)

                if video.duration > 0 {
                    Text(formatDuration(video.duration))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }

                // Download status
                Image(systemName: video.isAvailableOffline ? "checkmark.circle.fill" : "cloud")
                    .font(.system(size: 12))
                    .foregroundColor(video.isAvailableOffline ? .green : .secondary)

                // Favorite
                Image(systemName: PrefsVideos.favorites.contains(video.id) ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundColor(PrefsVideos.favorites.contains(video.id) ? .yellow : .secondary.opacity(0.3))
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(object: state.dragPayload(for: video) as NSString)
        }
        .contextMenu {
            contextMenuContent
        }
        .alert(
            cacheDeleteTitle,
            isPresented: Binding(
                get: { pendingCacheDelete != nil },
                set: { if !$0 { pendingCacheDelete = nil } }
            ),
            presenting: pendingCacheDelete
        ) { pending in
            Button("Delete and hide", role: .destructive) {
                state.deleteVideosFromCache(pending.videos, alsoHide: true)
            }
            Button("Delete", role: .destructive) {
                state.deleteVideosFromCache(pending.videos, alsoHide: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.videos.count == 1
                ? "You can also hide the video so it doesn't get redownloaded in the future."
                : "You can also hide the videos so they don't get redownloaded in the future.")
        }
    }

    private var cacheDeleteTitle: String {
        guard let pending = pendingCacheDelete, pending.videos.count > 1 else {
            return "Do you want to delete this video from your cache?"
        }
        return "Do you want to delete these \(pending.videos.count) videos from your cache?"
    }

    // MARK: - Context Menu (multi-selection aware)

    @ViewBuilder
    private var contextMenuContent: some View {
        let videos = state.videosForContextAction(rightClicked: video)
        // Read playlists from the observed state, not the singleton: the
        // .contextMenu builder is a snapshot from the last body evaluation,
        // so a non-observable read can serve a stale (even empty) list until
        // some unrelated @Published happens to invalidate the row.
        let summaries = state.userPlaylists
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
                    DownloadTracker.shared.queueDownload(videoId: v.id)
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

        // Rotate (local files only): extra rotation on top of the clip's
        // own metadata, for clips that play upside down or sideways.
        let rotatable = videos.filter { $0.url.isFileURL }
        if !rotatable.isEmpty {
            Divider()
            Menu(rotatable.count > 1 ? "Rotate \(rotatable.count) Videos" : "Rotate") {
                ForEach(RotationOverride.options, id: \.degrees) { option in
                    let isCurrent = rotatable.allSatisfy { RotationOverride.degrees(for: $0) == option.degrees }
                    Button {
                        RotationOverride.apply(option.degrees, to: rotatable)
                        state.refreshTrigger += 1
                    } label: {
                        if isCurrent {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            }
        }
        // Delete from cache (downloaded, remote-source videos only —
        // local "My Videos" files are managed from the My Videos panel)
        let deletable = videos.filter { $0.isAvailableOffline && !$0.url.absoluteString.starts(with: "file") }
        if !deletable.isEmpty {
            Divider()
            Button {
                pendingCacheDelete = PendingCacheDelete(videos: deletable)
            } label: {
                Label(deletable.count == 1 ? "Delete Video" : "Delete \(deletable.count) Videos",
                      systemImage: "trash")
            }
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
                        .font(.system(size: 10))
                )
        }
    }
}

struct VideoBrowserRowView_Previews: PreviewProvider {
    static var previews: some View {
        let video = PreviewData.makeVideo()
        VideoBrowserRowView(video: video, state: PreviewData.makeState())
            .frame(width: 500)
            .padding()
    }
}
