//
//  UserPlaylistModels.swift
//  Aerial
//
//  Data models for user-created playlists.
//  Shared with extension target (read-only there).
//

import Foundation

// MARK: - Index

struct UserPlaylistIndex: Codable {
    var version: Int = 1
    var playlists: [UserPlaylistSummary]
}

struct UserPlaylistSummary: Codable, Identifiable {
    var id: UUID
    var name: String
    var entryCount: Int
    var order: Int
}

// MARK: - Manifest (individual playlist file)

struct UserPlaylistManifest: Codable, Identifiable {
    var id: UUID
    var name: String
    var createdAt: Date
    var cycleMode: PlaylistCycleMode
    var entries: [PlaylistEntry]
}

// MARK: - File paths

extension UserPlaylistIndex {
    static var directoryURL: URL {
        URL(fileURLWithPath: AerialPaths.baseDirectory).appendingPathComponent("Playlists")
    }

    static var indexURL: URL {
        directoryURL.appendingPathComponent("_index.json")
    }

    static func playlistURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }

    /// Video ids referenced by ANY user playlist, read straight from the
    /// manifests on disk (no `UserPlaylistManager`, so the cache evictors
    /// can call it off the main thread). Every evictor exempts these the
    /// way it exempts favourites: a weekly rotation used to delete a
    /// playlist's own videos, the playlist then resolved to nothing and
    /// the wallpaper fell back to random cached videos (4.1.0beta15 field
    /// bundle, 2026-11-17). Unreadable manifests contribute nothing.
    static func allVideoIds(in directory: URL = directoryURL) -> Set<String> {
        // Only the ids — independent of the manifest's other fields and of
        // how their dates are encoded.
        struct Entries: Decodable {
            struct Entry: Decodable { let videoId: String }
            let entries: [Entry]
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        var ids = Set<String>()
        for file in files where file.pathExtension == "json" && file.lastPathComponent != indexURL.lastPathComponent {
            guard let data = try? Data(contentsOf: file),
                  let manifest = try? JSONDecoder().decode(Entries.self, from: data) else { continue }
            ids.formUnion(manifest.entries.map(\.videoId))
        }
        return ids
    }
}
