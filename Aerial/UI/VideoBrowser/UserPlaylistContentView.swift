//
//  UserPlaylistContentView.swift
//  Aerial
//
//  Content view for a user-created playlist.
//

import SwiftUI
import UniformTypeIdentifiers

struct UserPlaylistContentView: View {
    @ObservedObject var state: VideoBrowserState
    @State private var isDropTargeted = false

    private var playlistId: UUID? {
        state.userPlaylistId
    }

    private var manifest: UserPlaylistManifest? {
        guard let id = playlistId else { return nil }
        return UserPlaylistManager.shared.playlist(id: id)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            if let manifest = manifest {
                headerView(manifest: manifest)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
            }

            // Content
            if let manifest = manifest, !manifest.entries.isEmpty {
                entryList(manifest: manifest)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.plainText], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .overlay(
            Group {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.aerial, lineWidth: 2)
                        .background(Color.aerial.opacity(0.05))
                        .cornerRadius(8)
                        .padding(4)
                }
            }
        )
    }

    // MARK: - Header

    private func headerView(manifest: UserPlaylistManifest) -> some View {
        ContentHeader(
            icon: "music.note.list",
            title: manifest.name,
            description: "\(manifest.entries.count) video\(manifest.entries.count == 1 ? "" : "s")"
        ) {
            if !manifest.entries.isEmpty {
                Button(action: { shufflePlaylist() }) {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Entry List

    private func entryList(manifest: UserPlaylistManifest) -> some View {
        List {
            ForEach(Array(manifest.entries.enumerated()), id: \.element.videoId) { index, entry in
                entryRow(entry: entry, index: index)
            }
            .onMove { source, destination in
                guard let id = playlistId else { return }
                UserPlaylistManager.shared.moveEntry(from: source, to: destination, in: id)
            }
            .onDelete { offsets in
                guard let id = playlistId else { return }
                UserPlaylistManager.shared.removeEntry(at: offsets, from: id)
            }
        }
    }

    private func entryRow(entry: PlaylistEntry, index: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 24, alignment: .trailing)

            // Thumbnail
            thumbnailView(for: entry.videoId)
                .frame(width: 80, height: 45)
                .clipped()
                .cornerRadius(4)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.secondaryName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(entry.videoName)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let dur = entry.duration {
                Text(formatDuration(dur))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Button(action: {
                guard let id = playlistId else { return }
                UserPlaylistManager.shared.removeEntry(at: IndexSet(integer: index), from: id)
            }) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No videos yet")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Text("Drag videos here or right-click videos in the browser to add them.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private func thumbnailView(for videoId: String) -> some View {
        if let thumb = state.thumbnails[videoId] {
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
                .onAppear {
                    if let video = VideoList.instance.videos.first(where: { $0.id == videoId }) {
                        state.loadThumbnail(for: video)
                    }
                }
        }
    }

    // MARK: - Actions

    private func shufflePlaylist() {
        guard let id = playlistId, var manifest = manifest else { return }
        manifest.entries.shuffle()
        // Write the shuffled manifest directly
        JSONPreferencesStore.shared.write(manifest, to: UserPlaylistIndex.playlistURL(for: id))
        state.refreshTrigger += 1
        NotificationCenter.default.post(name: UserPlaylistManager.didChangeNotification, object: nil)
    }

    // MARK: - Drop

    private func handleDrop(providers: [NSItemProvider]) {
        guard let id = playlistId else { return }
        for provider in providers {
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                guard let payload = string as? String else { return }
                let videoIds = payload.components(separatedBy: "\n").filter { !$0.isEmpty }
                DispatchQueue.main.async {
                    for videoId in videoIds {
                        guard let video = VideoList.instance.videos.first(where: { $0.id == videoId }) else { continue }
                        let entry = PlaylistEntry(
                            videoId: video.id,
                            videoName: video.name,
                            secondaryName: video.secondaryName,
                            duration: video.duration > 0 ? video.duration : nil
                        )
                        UserPlaylistManager.shared.addVideo(entry, to: id)
                    }
                }
            }
        }
    }
}
