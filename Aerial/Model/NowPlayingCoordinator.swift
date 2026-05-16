//
//  NowPlayingCoordinator.swift
//  Aerial
//
//  Singleton that merges NowPlayingSource publishers and writes
//  now-playing.json for the extension to read.
//

import Foundation
import Combine

class NowPlayingCoordinator {
    static let shared = NowPlayingCoordinator()

    let songUpdated = PassthroughSubject<SongInfo?, Never>()

    private var sources: [NowPlayingSource] = []
    private var subscriptions = Set<AnyCancellable>()
    private var started = false

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

    /// Apply a new enabled-set to the coordinator: stop everything,
    /// rebuild the source list from `Preferences.enabledNowPlayingSources`,
    /// re-subscribe, and clear the on-disk JSON so the extension drops
    /// any lingering song that came from a source the user just unchecked.
    func reconfigure() {
        for source in sources {
            source.stop()
        }
        sources.removeAll()
        subscriptions.removeAll()

        sources = Self.buildEnabledSources()

        // Always clear before restarting — the new source set may not
        // include the player whose track is currently in the JSON.
        try? FileManager.default.removeItem(atPath: Self.filePath)
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

    // MARK: - Private

    private func subscribe(to source: NowPlayingSource) {
        source.songChanged
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] song in
                self?.handleSongUpdate(song)
            }
            .store(in: &subscriptions)
    }

    /// Instantiate one provider per descriptor matching the user's
    /// enabled set. Empty set = all known sources.
    private static func buildEnabledSources() -> [NowPlayingSource] {
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
