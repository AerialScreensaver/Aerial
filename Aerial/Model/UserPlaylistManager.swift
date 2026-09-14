//
//  UserPlaylistManager.swift
//  Aerial
//
//  CRUD singleton for user-created playlists.
//  Companion-only — the extension reads JSON files directly.
//

import Foundation

class UserPlaylistManager {

    // MARK: - Singleton

    static let shared = UserPlaylistManager()

    // MARK: - Notifications

    static let didChangeNotification = Notification.Name("com.glouel.aerial.userPlaylistDidChange")

    // MARK: - Private

    private let store = JSONPreferencesStore.shared
    private var index: UserPlaylistIndex

    private init() {
        if let loaded = store.read(UserPlaylistIndex.self, from: UserPlaylistIndex.indexURL) {
            index = loaded
        } else {
            index = UserPlaylistIndex(version: 1, playlists: [])
        }
    }

    // MARK: - Read

    func allSummaries() -> [UserPlaylistSummary] {
        index.playlists.sorted { $0.order < $1.order }
    }

    func playlist(id: UUID) -> UserPlaylistManifest? {
        store.read(UserPlaylistManifest.self, from: UserPlaylistIndex.playlistURL(for: id))
    }

    // MARK: - Create

    @discardableResult
    func createPlaylist(name: String) -> UserPlaylistSummary {
        ensureDirectory()

        let id = UUID()
        let now = Date()
        let manifest = UserPlaylistManifest(
            id: id,
            name: name,
            createdAt: now,
            cycleMode: .loop,
            entries: []
        )
        store.write(manifest, to: UserPlaylistIndex.playlistURL(for: id))

        let nextOrder = (index.playlists.map { $0.order }.max() ?? -1) + 1
        let summary = UserPlaylistSummary(id: id, name: name, entryCount: 0, order: nextOrder)
        index.playlists.append(summary)
        persistIndex()
        notify()
        return summary
    }

    // MARK: - Rename

    func renamePlaylist(id: UUID, name: String) {
        guard var manifest = playlist(id: id) else { return }
        manifest.name = name
        store.write(manifest, to: UserPlaylistIndex.playlistURL(for: id))

        if let idx = index.playlists.firstIndex(where: { $0.id == id }) {
            index.playlists[idx].name = name
        }
        persistIndex()
        notify()
    }

    // MARK: - Delete

    func deletePlaylist(id: UUID) {
        let url = UserPlaylistIndex.playlistURL(for: id)
        try? FileManager.default.removeItem(at: url)

        index.playlists.removeAll { $0.id == id }
        // Re-number order
        for i in index.playlists.indices {
            index.playlists[i].order = i
        }
        persistIndex()
        notify()
    }

    // MARK: - Add / Remove / Move Videos

    func addVideo(_ entry: PlaylistEntry, to playlistId: UUID) {
        guard var manifest = playlist(id: playlistId) else { return }
        // Dedup
        guard !manifest.entries.contains(where: { $0.videoId == entry.videoId }) else { return }
        manifest.entries.append(entry)
        saveManifest(manifest)
    }

    func removeEntry(at offsets: IndexSet, from playlistId: UUID) {
        guard var manifest = playlist(id: playlistId) else { return }
        manifest.entries.remove(atOffsets: offsets)
        saveManifest(manifest)
    }

    func moveEntry(from source: IndexSet, to destination: Int, in playlistId: UUID) {
        guard var manifest = playlist(id: playlistId) else { return }
        manifest.entries.move(fromOffsets: source, toOffset: destination)
        saveManifest(manifest)
    }

    /// Set (or clear, with nil) the per-video play-duration override for one entry.
    func setPlayDuration(_ seconds: Double?, forEntryAt index: Int, in playlistId: UUID) {
        guard var manifest = playlist(id: playlistId),
              manifest.entries.indices.contains(index) else { return }
        manifest.entries[index].playDuration = seconds
        saveManifest(manifest)
    }

    // MARK: - Helpers

    private func saveManifest(_ manifest: UserPlaylistManifest) {
        store.write(manifest, to: UserPlaylistIndex.playlistURL(for: manifest.id))
        if let idx = index.playlists.firstIndex(where: { $0.id == manifest.id }) {
            index.playlists[idx].entryCount = manifest.entries.count
            index.playlists[idx].name = manifest.name
        }
        persistIndex()
        notify()
    }

    private func ensureDirectory() {
        let dir = UserPlaylistIndex.directoryURL
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func persistIndex() {
        ensureDirectory()
        store.write(index, to: UserPlaylistIndex.indexURL)
    }

    private func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }
}
