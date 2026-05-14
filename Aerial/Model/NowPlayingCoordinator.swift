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
        sources = [AppleMusicProvider()]
    }

    /// Idempotent — starts all sources and subscribes to their publishers
    func startIfNeeded() {
        guard !started else { return }
        started = true

        for source in sources {
            source.songChanged
                .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
                .sink { [weak self] song in
                    self?.handleSongUpdate(song)
                }
                .store(in: &subscriptions)

            source.start()
        }

        debugLog("🎧 NowPlayingCoordinator started with \(sources.count) source(s)")
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

    private func handleSongUpdate(_ song: SongInfo?) {
        songUpdated.send(song)
        writeToDisk(song)
    }

    private func writeToDisk(_ song: SongInfo?) {
        let path = Self.filePath

        guard let song = song, !song.name.isEmpty else {
            // Remove file when nothing is playing
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
