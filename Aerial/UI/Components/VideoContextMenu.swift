//
//  VideoContextMenu.swift
//  Aerial Companion
//
//  The right-click menu for videos (Add to Playlist, Download, Favorite,
//  Hide, Rotate, Delete). Single source for every surface that shows it:
//  Video Library cards and rows, and the playlist strip/list (Home cards
//  and menubar popover). Pair it with `.videoCacheDeleteAlert` on the host
//  view, which owns the `PendingCacheDelete` state.
//

import SwiftUI

/// Alert payload for the context menu's "Delete Video" confirmation.
struct PendingCacheDelete: Identifiable {
    let id = UUID()
    let videos: [AerialVideo]
}

struct VideoContextMenu: View {
    /// Videos the actions apply to (the host resolves multi-selection).
    let videos: [AerialVideo]
    /// Passed in rather than read from the singleton: the .contextMenu
    /// builder is a snapshot from the host's last body evaluation, so the
    /// host must hold this list in observed state or the menu can serve a
    /// stale (even empty) list.
    let userPlaylists: [UserPlaylistSummary]
    @Binding var pendingCacheDelete: PendingCacheDelete?
    /// Called after a favorite, hide or rotate change so the host can
    /// redraw.
    var onChange: () -> Void = {}

    var body: some View {
        if !userPlaylists.isEmpty {
            Menu(videos.count > 1 ? "Add \(videos.count) Videos to Playlist" : "Add to Playlist") {
                ForEach(userPlaylists) { summary in
                    Button(summary.name) {
                        addVideos(to: summary.id)
                    }
                }
                Divider()
                Button("New Playlist...") {
                    addVideosToNewPlaylist()
                }
            }
        } else {
            Button("Add to New Playlist...") {
                addVideosToNewPlaylist()
            }
        }

        Divider()

        // Download
        let uncached = videos.filter { !$0.isAvailableOffline }
        if !uncached.isEmpty {
            Button {
                for v in uncached {
                    if case .none = DownloadTracker.shared.state(for: v.id) {
                        DownloadTracker.shared.queueDownload(videoId: v.id)
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
            // Every screen's playlist, not just the one clicked from:
            // "Favorites" playlists gain/lose the video, and a screen
            // playing an unfavorited video moves on.
            PlaylistManager.shared.regenerateAll()
            onChange()
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
            // Drops (or restores) the videos on every screen's filter
            // playlist; the extension cuts only screens playing one.
            PlaylistManager.shared.regenerateAll()
            onChange()
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
                        onChange()
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
        // local "My Videos" files are managed from the My Videos panel,
        // and live feeds are streams with nothing cached)
        let deletable = videos.filter { $0.isAvailableOffline && !$0.isLive && !$0.url.absoluteString.starts(with: "file") }
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

    private func addVideosToNewPlaylist() {
        let name = videos.count == 1 ? videos[0].secondaryName : "\(videos.count) Videos"
        let summary = UserPlaylistManager.shared.createPlaylist(name: name)
        addVideos(to: summary.id)
    }

    private func addVideos(to playlistId: UUID) {
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
}

// MARK: - Delete confirmation

enum VideoCacheActions {
    /// Delete downloaded videos from the cache, optionally hiding them so
    /// the DownloadCoordinator doesn't re-download them later.
    @MainActor
    static func delete(_ videos: [AerialVideo], alsoHide: Bool) {
        let ids = Set(videos.map(\.id))
        if alsoHide {
            var hidden = PrefsVideos.hidden
            for video in videos where !hidden.contains(video.id) {
                hidden.append(video.id)
            }
            PrefsVideos.hidden = hidden
        }
        // Move every screen off the videos BEFORE their files go: filter
        // playlists drop them (the extension cuts any screen whose current
        // video was removed), and user playlists — never regenerated —
        // get an explicit advance on the screens playing one.
        PlaylistManager.shared.regenerateAll(excluding: ids)
        for screenUUID in PlaylistManager.shared.userPlaylistScopes(playing: ids) {
            PlaybackManager.shared.nextVideo(screenUUID: screenUUID)
        }

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
        // Same content as above, so the extension isn't signaled again;
        // this re-posts the change so every playlist view re-reads which
        // videos are cached (a deleted one now shows as not downloaded).
        PlaylistManager.shared.regenerateAll()
    }
}

extension View {
    /// The "Delete Video" confirmation raised by `VideoContextMenu`.
    /// `onDeleted` runs after the deletion so the host can redraw.
    func videoCacheDeleteAlert(_ pending: Binding<PendingCacheDelete?>,
                               onDeleted: @escaping () -> Void = {}) -> some View {
        let title: String = {
            guard let p = pending.wrappedValue, p.videos.count > 1 else {
                return "Do you want to delete this video from your cache?"
            }
            return "Do you want to delete these \(p.videos.count) videos from your cache?"
        }()
        return alert(
            title,
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }
            ),
            presenting: pending.wrappedValue
        ) { p in
            Button("Delete and hide", role: .destructive) {
                VideoCacheActions.delete(p.videos, alsoHide: true)
                onDeleted()
            }
            Button("Delete", role: .destructive) {
                VideoCacheActions.delete(p.videos, alsoHide: false)
                onDeleted()
            }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text(p.videos.count == 1
                ? "You can also hide the video so it doesn't get redownloaded in the future."
                : "You can also hide the videos so they don't get redownloaded in the future.")
        }
    }
}
