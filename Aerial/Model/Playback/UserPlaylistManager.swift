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

    // MARK: - Import / Export

    /// Pretty-printed manifest JSON for sharing — the per-playlist file
    /// format IS the interchange format.
    func exportData(id: UUID) -> Data? {
        guard let manifest = playlist(id: id) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(manifest)
    }

    struct ImportResult {
        let summary: UserPlaylistSummary
        /// Entries whose videoId matches nothing in the library — Apple
        /// ids are universal, but My Videos ids are machine-random
        /// UUIDs and can't be matched across Macs.
        let unresolvedCount: Int
        let totalCount: Int
    }

    /// Import a shared playlist manifest. The file's id is never
    /// trusted (fresh UUID, next order); the name is de-duplicated.
    func importPlaylist(from data: Data) throws -> ImportResult {
        var manifest = try JSONDecoder().decode(UserPlaylistManifest.self, from: data)

        ensureDirectory()
        manifest.id = UUID()
        manifest.createdAt = Date()
        manifest.name = availableName(startingFrom: manifest.name)
        store.write(manifest, to: UserPlaylistIndex.playlistURL(for: manifest.id))

        let nextOrder = (index.playlists.map { $0.order }.max() ?? -1) + 1
        let summary = UserPlaylistSummary(
            id: manifest.id,
            name: manifest.name,
            entryCount: manifest.entries.count,
            order: nextOrder
        )
        index.playlists.append(summary)
        persistIndex()
        notify()

        let unresolved = manifest.entries.filter { entry in
            !VideoList.instance.videos.contains { $0.id == entry.videoId }
        }.count
        return ImportResult(summary: summary, unresolvedCount: unresolved, totalCount: manifest.entries.count)
    }

    private func availableName(startingFrom base: String) -> String {
        let existing = Set(index.playlists.map { $0.name })
        guard existing.contains(base) else { return base }
        var counter = 2
        while existing.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
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
