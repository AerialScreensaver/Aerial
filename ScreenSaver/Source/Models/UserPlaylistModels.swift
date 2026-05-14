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
}
