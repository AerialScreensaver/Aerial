//
//  Music.swift
//  Aerial
//
//  Created by Guillaume Louel on 29/06/2021.
//  Copyright © 2021 Guillaume Louel. All rights reserved.
//

import Foundation
import AppKit
import Combine

typealias MusicCallback = (SongInfo) -> Void

struct SongInfo: Codable {
    let name: String
    let artist: String
    let album: String
    let artwork: NSImage?

    enum CodingKeys: String, CodingKey {
        case name, artist, album, artworkData
    }

    init(name: String, artist: String, album: String, artwork: NSImage?) {
        self.name = name
        self.artist = artist
        self.album = album
        self.artwork = artwork
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        artist = try container.decode(String.self, forKey: .artist)
        album = try container.decode(String.self, forKey: .album)

        if let data = try container.decodeIfPresent(Data.self, forKey: .artworkData) {
            artwork = NSImage(data: data)
        } else {
            artwork = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(artist, forKey: .artist)
        try container.encode(album, forKey: .album)

        if let artwork = artwork,
           let tiff = artwork.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try container.encode(png, forKey: .artworkData)
        }
    }
}

class Music {
    static let instance: Music = Music()
    var callbacks = [MusicCallback]()
    var wasSetup = false

    #if COMPANION_APP
    private var companionSub: AnyCancellable?
    #endif

    /// Read cached now-playing.json written by the Companion app
    static func readCachedSong() -> SongInfo? {
        let path = AerialPaths.baseDirectory + "/now-playing.json"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(SongInfo.self, from: data)
    }

    func setup() {
        guard !wasSetup else { return }
        wasSetup = true

        #if COMPANION_APP
        debugLog("🎧 Music: subscribing to NowPlayingCoordinator")
        companionSub = NowPlayingCoordinator.shared.songUpdated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] song in
                guard let self = self else { return }
                let info = song ?? SongInfo(name: "", artist: "", album: "", artwork: nil)
                for callback in self.callbacks {
                    callback(info)
                }
            }

        // Fetch initial state
        NowPlayingCoordinator.shared.fetchCurrentSong { [weak self] song in
            guard let self = self else { return }
            let info = song ?? SongInfo(name: "", artist: "", album: "", artwork: nil)
            for callback in self.callbacks {
                callback(info)
            }
        }
        #else
        debugLog("🎧 Music: starting file-poll timer (3s)")
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let song = Music.readCachedSong()
            let info = song ?? SongInfo(name: "", artist: "", album: "", artwork: nil)
            for callback in self.callbacks {
                callback(info)
            }
        }
        // Immediate first read
        let song = Music.readCachedSong()
        let info = song ?? SongInfo(name: "", artist: "", album: "", artwork: nil)
        for callback in callbacks {
            callback(info)
        }
        #endif
    }

    // MARK: - Callbacks
    func addCallback(_ callback: @escaping MusicCallback) {
        debugLog("🎧 Adding music callback")
        callbacks.append(callback)
    }
}
