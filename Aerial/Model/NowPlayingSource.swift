//
//  NowPlayingSource.swift
//  Aerial
//
//  Protocol for player sources (Apple Music, Spotify, VLC, etc.)
//

import Foundation
import Combine

protocol NowPlayingSource: AnyObject {
    /// Reverse-DNS identifier for the player, e.g. "com.apple.Music"
    var identifier: String { get }

    /// Human-readable name, e.g. "Apple Music"
    var displayName: String { get }

    /// Publishes new SongInfo on track change, nil on pause/stop
    var songChanged: AnyPublisher<SongInfo?, Never> { get }

    /// Start observing the player
    func start()

    /// Stop observing the player
    func stop()

    /// One-shot poll of the currently playing track
    func fetchCurrentSong(completion: @escaping (SongInfo?) -> Void)
}
