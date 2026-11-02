//
//  NowPlayingCoordinator.swift
//  Aerial
//
//  Singleton that merges NowPlayingSource publishers and writes
//  now-playing.json for the extension to read.
//
//  Two modes (`Preferences.nowPlayingMode`): "automatic" runs the single
//  MediaRemote-backed source (any player); "players" runs the per-player
//  providers the user ticked. Never both — their content would be the
//  same song and every write would be doubled.
//

import Foundation
import Combine

class NowPlayingCoordinator: ObservableObject {
    static let shared = NowPlayingCoordinator()

    let songUpdated = PassthroughSubject<SongInfo?, Never>()

    /// State of the Automatic source for the music settings caption.
    enum AutomaticStatus: Equatable {
        case off                // "players" mode
        case probing
        case active
        case unavailable(String)
    }
    @Published private(set) var automaticStatus: AutomaticStatus = .off

    private var sources: [NowPlayingSource] = []
    private var subscriptions = Set<AnyCancellable>()
    private var started = false

    /// Last song written to disk, so an artwork re-announce or a restarted
    /// source re-sending the same track does not rewrite now-playing.json
    /// (the extension re-bakes its overlay on every file change it polls).
    private var lastWritten: (name: String, artist: String, album: String, artwork: ObjectIdentifier?)?

    private static let filePath = AerialPaths.baseDirectory + "/now-playing.json"

    private init() {
        sources = Self.buildEnabledSources()
    }

    /// Idempotent — starts all sources and subscribes to their publishers
    func startIfNeeded() {
        guard !started else { return }
        started = true

        for source in sources {
            subscribe(to: source)
            source.start()
        }

        debugLog("🎧 NowPlayingCoordinator started with \(sources.count) source(s)")
    }

    /// Apply a new mode / enabled-set to the coordinator: stop everything,
    /// rebuild the source list from `Preferences.nowPlayingMode` and
    /// `Preferences.enabledNowPlayingSources`, re-subscribe, and clear the
    /// on-disk JSON so the extension drops any lingering song that came
    /// from a source the user just switched away from.
    func reconfigure() {
        for source in sources {
            source.stop()
        }
        sources.removeAll()
        subscriptions.removeAll()
        automaticStatus = .off

        sources = Self.buildEnabledSources()

        // Always clear before restarting — the new source set may not
        // include the player whose track is currently in the JSON.
        try? FileManager.default.removeItem(atPath: Self.filePath)
        lastWritten = nil
        songUpdated.send(nil)

        if started {
            for source in sources {
                subscribe(to: source)
                source.start()
            }
            debugLog("🎧 NowPlayingCoordinator reconfigured with \(sources.count) source(s)")
        }
    }

    /// One-shot fetch from the first available source (for preview use).
    /// Also persists to now-playing.json so the extension sees initial state.
    func fetchCurrentSong(completion: @escaping (SongInfo?) -> Void) {
        guard let source = sources.first else {
            completion(nil)
            return
        }
        source.fetchCurrentSong { [weak self] song in
            if let song = song, !song.name.isEmpty {
                self?.handleSongUpdate(song)
            }
            completion(song)
        }
    }

    /// Stop every source (quit path: the Automatic source owns a perl
    /// child that must not outlive the Companion).
    func stopAll() {
        for source in sources {
            source.stop()
        }
    }

    // MARK: - Private

    private func subscribe(to source: NowPlayingSource) {
        source.songChanged
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] song in
                self?.handleSongUpdate(song)
            }
            .store(in: &subscriptions)
        if let automatic = source as? MediaRemoteNowPlayingSource {
            automatic.availability
                .receive(on: DispatchQueue.main)
                .sink { [weak self] availability in
                    switch availability {
                    case .unknown, .probing: self?.automaticStatus = .probing
                    case .available: self?.automaticStatus = .active
                    case .unavailable(let reason): self?.automaticStatus = .unavailable(reason)
                    }
                }
                .store(in: &subscriptions)
        }
    }

    /// "automatic" → the single MediaRemote source. "players" → one
    /// provider per descriptor matching the user's enabled set (empty set
    /// = all known sources).
    private static func buildEnabledSources() -> [NowPlayingSource] {
        if Preferences.nowPlayingMode == Preferences.nowPlayingModeAutomatic {
            return [MediaRemoteNowPlayingSource()]
        }
        let prefs = Preferences.enabledNowPlayingSources
        let descriptors: [NowPlayingSourceDescriptor]
        if prefs.isEmpty {
            descriptors = NowPlayingSourceRegistry.all
        } else {
            let allowed = Set(prefs)
            descriptors = NowPlayingSourceRegistry.all.filter { allowed.contains($0.identifier) }
        }
        return descriptors.map { $0.factory() }
    }

    private func handleSongUpdate(_ song: SongInfo?) {
        guard let song, !song.name.isEmpty else {
            lastWritten = nil
            songUpdated.send(song)
            writeToDisk(song)
            return
        }
        let signature: (name: String, artist: String, album: String, artwork: ObjectIdentifier?) =
            (song.name, song.artist, song.album, song.artwork.map { ObjectIdentifier($0) })
        if let last = lastWritten, last == signature {
            return
        }
        lastWritten = signature
        songUpdated.send(song)
        writeToDisk(song)
    }

    private func writeToDisk(_ song: SongInfo?) {
        let path = Self.filePath

        guard let song = song, !song.name.isEmpty else {
            try? FileManager.default.removeItem(atPath: path)
            return
        }

        do {
            let data = try JSONEncoder().encode(song)
            let url = URL(fileURLWithPath: path)
            try data.write(to: url, options: .atomic)
        } catch {
            errorLog("Failed to write now-playing.json: \(error)")
        }
    }
}
