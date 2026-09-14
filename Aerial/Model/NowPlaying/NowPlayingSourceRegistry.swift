//
//  NowPlayingSourceRegistry.swift
//  Aerial
//
//  Static list of NowPlayingSource implementations the app knows about.
//  Both the coordinator (to decide which providers to instantiate) and
//  the overlay inspector (to render checkboxes) read from this list.
//
//  Adding a new player = adding one descriptor entry here plus the
//  provider file. No other code changes required.
//

import Foundation

struct NowPlayingSourceDescriptor {
    /// Reverse-DNS identifier, e.g. "com.apple.Music". Stable — used
    /// as the persistence key in `enabledNowPlayingSources`.
    let identifier: String

    /// User-facing label shown in the inspector checkbox.
    let displayName: String

    /// Deferred constructor. Only called when the source is enabled,
    /// so disabled providers pay zero runtime cost.
    let factory: () -> NowPlayingSource
}

enum NowPlayingSourceRegistry {
    static let all: [NowPlayingSourceDescriptor] = [
        NowPlayingSourceDescriptor(
            identifier: "com.apple.Music",
            displayName: "Apple Music",
            factory: { AppleMusicProvider() }
        ),
        NowPlayingSourceDescriptor(
            identifier: "com.spotify.client",
            displayName: "Spotify",
            factory: { SpotifyProvider() }
        ),
    ]
}
