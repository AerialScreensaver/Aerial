//
//  PlaylistModels.swift
//  Aerial
//
//  Shared data models for persistent playlists.
//  Used by both Companion app (read/write) and extension (read-only).
//

import Foundation

// MARK: - Cycle Mode

enum PlaylistCycleMode: Int, Codable {
    case loop = 0      // Replay same order each cycle
    case shuffle = 1   // Reshuffle entries when playlist wraps around
    case repeatOne = 2 // Keep replaying the current video (enforced by the
                       // renderer — the playlist itself is never popped)
}

// MARK: - Top-level state persisted to /Users/Shared/Aerial/playlists.json

struct PlaylistState: Codable {
    var version: Int = 1
    var sharedPlaylist: PersistedPlaylist?
    var screenPlaylists: [String: PersistedPlaylist] // Keyed by screen UUID
}

struct PersistedPlaylist: Codable {
    var entries: [PlaylistEntry]
    var currentIndex: Int
    var playbackTimestamp: Double?    // Seconds into the current video (for resume)
    var filterMode: Int              // NewShouldPlay.rawValue at generation time
    var filterStrings: [String]      // The selection that generated this playlist
    var generatedAt: Date
    var cycleMode: PlaylistCycleMode

    init(entries: [PlaylistEntry], currentIndex: Int, playbackTimestamp: Double?,
         filterMode: Int, filterStrings: [String], generatedAt: Date,
         cycleMode: PlaylistCycleMode = .loop) {
        self.entries = entries
        self.currentIndex = currentIndex
        self.playbackTimestamp = playbackTimestamp
        self.filterMode = filterMode
        self.filterStrings = filterStrings
        self.generatedAt = generatedAt
        self.cycleMode = cycleMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode([PlaylistEntry].self, forKey: .entries)
        currentIndex = try container.decode(Int.self, forKey: .currentIndex)
        playbackTimestamp = try container.decodeIfPresent(Double.self, forKey: .playbackTimestamp)
        filterMode = try container.decode(Int.self, forKey: .filterMode)
        filterStrings = try container.decode([String].self, forKey: .filterStrings)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        // Decode as raw Int so an unknown future mode degrades to .loop
        // instead of throwing and failing the whole playlist decode.
        let rawCycleMode = try container.decodeIfPresent(Int.self, forKey: .cycleMode)
        cycleMode = rawCycleMode.flatMap { PlaylistCycleMode(rawValue: $0) } ?? .loop
    }
}

struct PlaylistEntry: Codable {
    var videoId: String
    var videoName: String            // For display without needing full AerialVideo
    var secondaryName: String
    var duration: Double?            // Native video length, cached for UI (progress bar calculation)
    var playDuration: Double? = nil  // Optional per-video play-duration override, in seconds of PLAYTIME.
                                     // When set on a multi-entry playlist, the player loops this video
                                     // until playDuration of (speed-factored) playtime elapses, then
                                     // advances. nil = current behavior (play once / rotation).
}

// MARK: - Shared Playlist Iteration

extension PersistedPlaylist {

    /// Pop the next video from the playlist using the unified iteration algorithm.
    /// - Parameters:
    ///   - isResume: If true, resume at currentIndex; otherwise advance.
    ///   - resolveVideo: Closure to resolve a video ID to a concrete video (nil if unavailable).
    ///   - shouldPlay: Optional filter (e.g. time-of-day). If all entries are rejected, falls through to shouldPlayFallback, then unfiltered.
    ///   - shouldPlayFallback: Optional relaxed filter (e.g. current + adjacent time slice). Tried before fully unfiltered pass.
    /// - Returns: Tuple of (video, shouldLoop, didReshuffle), or nil if no video found.
    mutating func popNextVideo<V>(
        isResume: Bool,
        resolveVideo: (String) -> V?,
        shouldPlay: ((V) -> Bool)? = nil,
        shouldPlayFallback: ((V) -> Bool)? = nil
    ) -> (video: V, shouldLoop: Bool, didReshuffle: Bool)? {
        guard !entries.isEmpty else { return nil }

        let count = entries.count

        // `currentIndex` comes from a sidecar JSON or a playlist that has

        // since shrunk — never trust it as a subscript. A negative value

        // would otherwise trap (`-1 % count == -1`).

        let normalizedCurrent = ((currentIndex % count) + count) % count

        // First call: resume at currentIndex. Subsequent: advance.
        let startIndex: Int
        if isResume {
            startIndex = normalizedCurrent
        } else {
            startIndex = (normalizedCurrent + 1) % count
        }

        // Detect playlist wrap-around: reshuffle in shuffle mode
        var didReshuffle = false
        if !isResume && startIndex == 0 && cycleMode == .shuffle {
            reshuffleEntries()
            didReshuffle = true
        }

        // Pass 1: iterate with shouldPlay filter
        for offset in 0..<count {
            let index = (startIndex + offset) % count
            let entry = entries[index]

            if let video = resolveVideo(entry.videoId) {
                if shouldPlay?(video) ?? true {
                    currentIndex = index
                    playbackTimestamp = nil
                    let shouldLoop = count <= 1
                    return (video: video, shouldLoop: shouldLoop, didReshuffle: didReshuffle)
                }
            }
        }

        // Pass 2: try adjacent time-slice fallback (e.g. sunset→night)
        if shouldPlay != nil, let fallback = shouldPlayFallback {
            for offset in 0..<count {
                let index = (startIndex + offset) % count
                let entry = entries[index]

                if let video = resolveVideo(entry.videoId) {
                    if fallback(video) {
                        currentIndex = index
                        playbackTimestamp = nil
                        let shouldLoop = count <= 1
                        return (video: video, shouldLoop: shouldLoop, didReshuffle: didReshuffle)
                    }
                }
            }
        }

        // Pass 3: if all filters rejected everything, retry without any filter (graceful degradation)
        if shouldPlay != nil {
            for offset in 0..<count {
                let index = (startIndex + offset) % count
                let entry = entries[index]

                if let video = resolveVideo(entry.videoId) {
                    currentIndex = index
                    playbackTimestamp = nil
                    let shouldLoop = count <= 1
                    return (video: video, shouldLoop: shouldLoop, didReshuffle: didReshuffle)
                }
            }
        }

        // All entries exhausted — reshuffle and reset for next attempt
        if cycleMode == .shuffle {
            reshuffleEntries()
            didReshuffle = true
        }
        currentIndex = 0
        return nil
    }

    /// Pop the previous video from the playlist, scanning backward.
    /// Used for user-initiated "skip to previous" navigation.
    /// - Parameters:
    ///   - resolveVideo: Closure to resolve a video ID to a concrete video (nil if unavailable).
    ///   - shouldPlay: Optional time-of-day filter. Falls through to shouldPlayFallback, then unfiltered.
    ///   - shouldPlayFallback: Optional relaxed filter (e.g. current + adjacent time slice).
    /// - Returns: Tuple of (video, shouldLoop), or nil if no video found.
    mutating func popPreviousVideo<V>(
        resolveVideo: (String) -> V?,
        shouldPlay: ((V) -> Bool)? = nil,
        shouldPlayFallback: ((V) -> Bool)? = nil
    ) -> (video: V, shouldLoop: Bool)? {
        guard !entries.isEmpty else { return nil }

        let count = entries.count
        let normalizedCurrent = ((currentIndex % count) + count) % count
        let startIndex = (normalizedCurrent - 1 + count) % count

        // Pass 1: scan backward with strict filter
        for offset in 0..<count {
            let index = (startIndex - offset + count) % count
            let entry = entries[index]
            if let video = resolveVideo(entry.videoId) {
                if shouldPlay?(video) ?? true {
                    currentIndex = index
                    playbackTimestamp = nil
                    return (video: video, shouldLoop: count <= 1)
                }
            }
        }

        // Pass 2: scan backward with relaxed filter
        if shouldPlay != nil, let fallback = shouldPlayFallback {
            for offset in 0..<count {
                let index = (startIndex - offset + count) % count
                let entry = entries[index]
                if let video = resolveVideo(entry.videoId) {
                    if fallback(video) {
                        currentIndex = index
                        playbackTimestamp = nil
                        return (video: video, shouldLoop: count <= 1)
                    }
                }
            }
        }

        // Pass 3: scan backward without any filter (graceful degradation)
        if shouldPlay != nil {
            for offset in 0..<count {
                let index = (startIndex - offset + count) % count
                let entry = entries[index]
                if let video = resolveVideo(entry.videoId) {
                    currentIndex = index
                    playbackTimestamp = nil
                    return (video: video, shouldLoop: count <= 1)
                }
            }
        }

        return nil
    }

    /// Shuffle entries, ensuring the first entry after shuffle differs from the last entry before.
    mutating func reshuffleEntries() {
        let lastEntry = entries.last
        entries.shuffle()
        // Avoid replaying the video that just finished — but bounded: a
        // playlist whose entries all share one videoId (duplicates are
        // legal in user playlists) can never satisfy the rule, and an
        // unbounded retry would spin the extension forever.
        var attempts = 0
        while attempts < 8 && entries.count > 1 && entries.first?.videoId == lastEntry?.videoId {
            entries.shuffle()
            attempts += 1
        }
    }

    /// Index of the entry playing `id`, searching BACKWARDS (wrapping)
    /// from `start` (default: the cursor). The extension's cursor runs
    /// one entry ahead of the screen — `popNextVideo` pre-pops the next
    /// reader at the start of every video — so the on-screen occurrence
    /// of a video is the one at or just before the cursor; this picks
    /// that one even when the playlist lists the same video twice.
    func index(ofVideoId id: String, searchingBackFrom start: Int? = nil) -> Int? {
        let count = entries.count
        guard count > 0 else { return nil }
        let from = ((start ?? currentIndex) % count + count) % count
        for offset in 0..<count {
            let index = (from - offset + count) % count
            if entries[index].videoId == id { return index }
        }
        return nil
    }
}

// MARK: - Extension progress sidecar persisted to /Users/Shared/Aerial/playlist-progress.json

struct PlaylistProgressState: Codable {
    var sharedProgress: PlaylistProgress?
    var screenProgress: [String: PlaylistProgress] // Keyed by screen UUID
}

struct PlaylistProgress: Codable {
    var currentIndex: Int
    var playbackTimestamp: Double?
    var updatedAt: Date
}

// MARK: - File paths

extension PlaylistState {
    static var fileURL: URL {
        URL(fileURLWithPath: AerialPaths.baseDirectory).appendingPathComponent("playlists.json")
    }
}

extension PlaylistProgressState {
    static var fileURL: URL {
        URL(fileURLWithPath: AerialPaths.baseDirectory).appendingPathComponent("playlist-progress.json")
    }
}

// MARK: - Desktop → extension playback handoff
// Written by Companion when the screensaver is about to start, read by
// the extension on its first `playVideo`. Carries the desktop's current
// effective rate so the extension can ease into 1.0 from wherever the
// desktop was visibly at (0.0 when paused, user's desktop speed
// otherwise). Freshness-gated so a stale hint from an earlier session
// can't colour an unrelated extension activation.

struct PlaybackHandoff: Codable {
    var startRate: Float
    var writtenAt: Date

    /// Longest age we'll honour before treating a hint as stale.
    static let maxAge: TimeInterval = 10

    static var fileURL: URL {
        URL(fileURLWithPath: AerialPaths.baseDirectory).appendingPathComponent("playback-handoff.json")
    }
}
