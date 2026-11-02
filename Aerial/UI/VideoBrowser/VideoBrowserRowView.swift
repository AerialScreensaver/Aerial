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
            // Read playlists from the observed state, not the singleton: the
            // .contextMenu builder is a snapshot from the last body evaluation,
            // so a non-observable read can serve a stale (even empty) list until
            // some unrelated @Published happens to invalidate the row.
            VideoContextMenu(
                videos: state.videosForContextAction(rightClicked: video),
                userPlaylists: state.userPlaylists,
                pendingCacheDelete: $pendingCacheDelete,
                onChange: { state.refreshTrigger += 1 }
            )
        }
        .videoCacheDeleteAlert($pendingCacheDelete) { state.refreshTrigger += 1 }
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
