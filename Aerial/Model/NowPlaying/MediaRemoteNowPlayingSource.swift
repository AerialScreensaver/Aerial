//
//  MediaRemoteNowPlayingSource.swift
//  Aerial
//
//  "Automatic (any player)": the system now-playing session through the
//  vendored mediaremote-adapter (see MediaRemoteAdapterProcess.swift).
//  Covers every player MediaRemote knows — Apple Music, Spotify, browsers,
//  Podcasts, VLC… — where the per-player providers cover two. Selected by
//  `Preferences.nowPlayingMode == "automatic"`; the per-player providers
//  stay available as "Specific players". No fallback: when the adapter
//  cannot run, `availability` says why and the overlay shows nothing.
//

import AppKit
import Combine
import Foundation

final class MediaRemoteNowPlayingSource: NowPlayingSource {
    enum Availability: Equatable {
        case unknown
        case probing
        case available
        case unavailable(String)
    }

    let identifier = "mediaremote"
    let displayName = "Automatic (any player)"

    var songChanged: AnyPublisher<SongInfo?, Never> {
        songSubject.eraseToAnyPublisher()
    }

    /// Health of the adapter, for the music settings caption. Delivered on
    /// main; starts `.unknown`, `.probing` while the `get` probe runs.
    var availability: AnyPublisher<Availability, Never> {
        availabilitySubject.eraseToAnyPublisher()
    }

    private let songSubject = PassthroughSubject<SongInfo?, Never>()
    private let availabilitySubject = CurrentValueSubject<Availability, Never>(.unknown)

    /// Owns every field below; the pipe reader and the restart timer hop here.
    private let queue = DispatchQueue(label: "com.glouel.aerial.mediaremote", qos: .utility)
    private var running = false
    private var process: MediaRemoteAdapterProcess?
    private var merger = MediaRemoteStateMerger()
    private var lastEmittedKey: MediaRemoteSongKey?
    /// Decoded artwork by `artworkHash`, newest last, at most 4 — a track
    /// that re-sends the same bytes (pause/resume, artwork re-announce)
    /// reuses the NSImage instance, which the coordinator's dedup relies on.
    private var artworkCache: [(hash: Int, image: NSImage)] = []
    private var consecutiveFailures = 0
    private var lastSpawn = Date.distantPast
    private var restartWorkItem: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?

    private static let backoffSeconds: [TimeInterval] = [1, 2, 5, 10, 30, 60]
    private static let maxConsecutiveFailures = 5
    private static let artworkMaxDimension: CGFloat = 512

    // MARK: - NowPlayingSource

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            consecutiveFailures = 0
            probeAndStream()
        }
    }

    func stop() {
        queue.sync { [self] in
            running = false
            restartWorkItem?.cancel()
            restartWorkItem = nil
            removeWakeObserver()
            process?.stop()
            process = nil
            if availabilitySubject.value == .available || availabilitySubject.value == .probing {
                publish(.unknown)
            }
            debugLog("🎧 MediaRemoteNowPlayingSource stopped")
        }
    }

    /// Paused tracks count here (the Test button and the preview want
    /// "what is loaded", like the legacy providers' one-shot poll).
    func fetchCurrentSong(completion: @escaping (SongInfo?) -> Void) {
        queue.async { [self] in
            if merger.hasSnapshot {
                let song = song(from: merger.state, allowPaused: true)
                DispatchQueue.main.async { completion(song) }
                return
            }
            let song: SongInfo?
            switch MediaRemoteAdapterProcess.get() {
            case .success(let payload):
                song = payload.flatMap { self.song(from: $0, allowPaused: true) }
            case .failure(let error):
                debugLog("🎧 [MediaRemote] get failed: \(error)")
                song = nil
            }
            DispatchQueue.main.async { completion(song) }
        }
    }

    // MARK: - Probe + stream (queue)

    private func probeAndStream() {
        publish(.probing)
        switch MediaRemoteAdapterProcess.get() {
        case .failure(let error):
            errorLog("🎧 [MediaRemote] adapter unavailable: \(error) — the Automatic source is off; choose Specific players in the music overlay settings")
            publish(.unavailable(error.description))
            running = false
        case .success(let payload):
            publish(.available)
            debugLog("🎧 MediaRemoteNowPlayingSource started (probe: \(payload == nil ? "nothing playing" : "playing"))")
            // Seed from the probe so the first emission does not wait for
            // the stream's initial snapshot.
            if let payload {
                _ = merger.apply(.data(diff: false, payload: payload))
                emitIfChanged()
            }
            spawnStream()
        }
    }

    private func spawnStream() {
        guard running else { return }
        let proc = MediaRemoteAdapterProcess()
        merger = MediaRemoteStateMerger()
        lastSpawn = Date()
        do {
            try proc.start(
                onLine: { [weak self] line in
                    self?.queue.async { self?.handle(line: line) }
                },
                onExit: { [weak self] status in
                    self?.queue.async { self?.handleExit(status: status) }
                }
            )
            process = proc
        } catch {
            process = nil
            handleExit(status: -1, launchError: "\(error)")
        }
    }

    private func handle(line: String) {
        guard let parsed = MediaRemoteAdapterLine.parse(line) else {
            debugLog("🎧 [MediaRemote] unparseable line: \(line.prefix(120))")
            return
        }
        if case .other(let type) = parsed {
            debugLog("🎧 [MediaRemote] ignoring line of type \(type)")
            return
        }
        guard merger.apply(parsed) else { return }
        emitIfChanged()
    }

    /// Emits only when the song key moved: timing ticks never emit, an
    /// artwork arrival emits the full song, a pause emits nil.
    private func emitIfChanged() {
        let key = MediaRemoteSongKey.key(from: merger.state)
        guard key != lastEmittedKey else { return }
        lastEmittedKey = key
        guard let key else {
            DispatchQueue.main.async { [songSubject] in songSubject.send(nil) }
            return
        }
        let artwork = artworkImage(for: key, state: merger.state)
        let song = SongInfo(name: key.title, artist: key.artist, album: key.album, artwork: artwork)
        debugLog("🎧 [MediaRemote] now playing: \(key.title) — \(key.artist) [\(key.bundleID)]\(artwork == nil ? " (no artwork yet)" : "")")
        DispatchQueue.main.async { [songSubject] in songSubject.send(song) }
    }

    private func song(from state: [String: Any], allowPaused: Bool) -> SongInfo? {
        guard let key = MediaRemoteSongKey.key(from: state, allowPaused: allowPaused) else { return nil }
        return SongInfo(name: key.title, artist: key.artist, album: key.album,
                        artwork: artworkImage(for: key, state: state))
    }

    private func artworkImage(for key: MediaRemoteSongKey, state: [String: Any]) -> NSImage? {
        guard let hash = key.artworkHash else { return nil }
        if let cached = artworkCache.first(where: { $0.hash == hash }) { return cached.image }
        guard let data = MediaRemoteSongKey.artworkData(from: state),
              let image = NSImage(data: data) else {
            debugLog("🎧 [MediaRemote] artwork present but undecodable (\(state["artworkMimeType"] as? String ?? "?"))")
            return nil
        }
        let sized = Self.downscaled(image, maxDimension: Self.artworkMaxDimension)
        artworkCache.append((hash, sized))
        if artworkCache.count > 4 { artworkCache.removeFirst(artworkCache.count - 4) }
        return sized
    }

    /// The overlay draws artwork at a few hundred points; a 3000×3000
    /// cover would otherwise travel as a multi-MB PNG through
    /// now-playing.json every 3 s on the extension side.
    private static func downscaled(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let target = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let result = NSImage(size: target)
        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy, fraction: 1.0)
        result.unlockFocus()
        return result
    }

    // MARK: - Restart policy (queue)

    private func handleExit(status: Int32, launchError: String? = nil) {
        process = nil
        guard running else { return }
        // A long healthy run resets the ladder.
        if Date().timeIntervalSince(lastSpawn) > 60 { consecutiveFailures = 0 }
        consecutiveFailures += 1
        if consecutiveFailures > Self.maxConsecutiveFailures {
            let reason = launchError ?? "stream exited \(consecutiveFailures) times in a row (last status \(status))"
            errorLog("🎧 [MediaRemote] giving up: \(reason)")
            publish(.unavailable(reason))
            running = false
            return
        }
        if SystemSleepState.shared.isAsleep {
            debugLog("🎧 [MediaRemote] stream exited (status \(status)) while asleep — restarting on wake")
            installWakeObserver()
            return
        }
        let delay = Self.backoffSeconds[min(consecutiveFailures - 1, Self.backoffSeconds.count - 1)]
        debugLog("🎧 [MediaRemote] stream exited (status \(status)\(launchError.map { ", \($0)" } ?? "")) — restarting in \(Int(delay)) s")
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.restartWorkItem = nil
            self.spawnStream()
        }
        restartWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func installWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async {
                guard let self else { return }
                self.removeWakeObserver()
                guard self.running, self.process == nil else { return }
                self.spawnStream()
            }
        }
    }

    private func removeWakeObserver() {
        if let token = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            wakeObserver = nil
        }
    }

    private func publish(_ value: Availability) {
        DispatchQueue.main.async { [availabilitySubject] in availabilitySubject.send(value) }
    }
}
