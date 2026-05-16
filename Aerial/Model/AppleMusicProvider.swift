//
//  AppleMusicProvider.swift
//  Aerial
//
//  NowPlayingSource for Apple Music using DistributedNotifications + ScriptingBridge.
//

import Foundation
import Combine
import AppKit
import ScriptingBridge

class AppleMusicProvider: NowPlayingSource {
    let identifier = "com.apple.Music"
    let displayName = "Apple Music"

    var songChanged: AnyPublisher<SongInfo?, Never> {
        songSubject.eraseToAnyPublisher()
    }

    private let songSubject = PassthroughSubject<SongInfo?, Never>()
    private var observerToken: NSObjectProtocol?
    private var isObserving = false

    /// Increments on every new track notification. Late artwork
    /// retries compare against this so they drop if the user has
    /// already skipped to a different song.
    private var artworkFetchSeq: Int = 0

    /// Cumulative delays (ms) between artwork retry attempts. Apple
    /// Music's CDN-fetched artwork can take up to ~1.5s to populate
    /// for streamed (non-library) tracks; one shot is too eager.
    private static let artworkRetryDelaysMs: [Int] = [0, 200, 400, 800]

    func start() {
        guard !isObserving else { return }
        isObserving = true

        observerToken = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleNotification(notification)
        }

        debugLog("🎧 AppleMusicProvider started (distributed notifications)")
    }

    func stop() {
        guard isObserving else { return }
        isObserving = false

        if let token = observerToken {
            DistributedNotificationCenter.default().removeObserver(token)
            observerToken = nil
        }

        debugLog("🎧 AppleMusicProvider stopped")
    }

    func fetchCurrentSong(completion: @escaping (SongInfo?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // allowPaused: true so the test button returns track info even when paused
            let song = self.pollScriptingBridge(allowPaused: true)
            DispatchQueue.main.async {
                completion(song)
            }
        }
    }

    // MARK: - Distributed Notification Handler

    private func handleNotification(_ notification: Notification) {
        guard let info = notification.userInfo else {
            songSubject.send(nil)
            return
        }

        let state = info["Player State"] as? String ?? ""

        if state == "Paused" || state == "Stopped" {
            debugLog("🎧 Music \(state.lowercased())")
            songSubject.send(nil)
            return
        }

        let name = info["Name"] as? String ?? ""
        let artist = info["Artist"] as? String ?? ""
        let album = info["Album"] as? String ?? ""

        guard !name.isEmpty else {
            songSubject.send(nil)
            return
        }

        debugLog("🎧 \(artist) – \(name) (\(album))")

        // Send text info immediately, then fetch artwork in background
        let basicSong = SongInfo(name: name, artist: artist, album: album, artwork: nil)
        songSubject.send(basicSong)

        artworkFetchSeq += 1
        fetchArtworkWithRetry(name: name, artist: artist, album: album,
                              seq: artworkFetchSeq, attempt: 0)
    }

    /// Retry artwork fetch on a backoff schedule. Music.app populates
    /// `currentTrack.artworks` asynchronously after the playerInfo
    /// notification, especially for streamed (non-library) tracks
    /// where the artwork is pulled from Apple's CDN on demand.
    /// Each attempt re-reads `currentTrack` and verifies its name
    /// still matches what we were dispatched for; if the user has
    /// skipped, we bail and let the next notification's retry chain
    /// handle artwork for the new track.
    private func fetchArtworkWithRetry(name: String, artist: String, album: String,
                                       seq: Int, attempt: Int) {
        let delays = Self.artworkRetryDelaysMs
        guard attempt < delays.count else {
            debugLog("🎧 SB artwork: gave up for \(name) after \(delays.count) attempts")
            return
        }

        let work: () -> Void = { [weak self] in
            guard let self = self else { return }
            // Track may have advanced — drop stale work.
            guard seq == self.artworkFetchSeq else { return }

            guard let music = SBApplication(bundleIdentifier: "com.apple.Music"),
                  music.isRunning,
                  let currentTrack = music.value(forKey: "currentTrack") as? SBObject else {
                return
            }

            // Defend against Music.app updating `currentTrack` before
            // sending the corresponding notification — if the live name
            // doesn't match ours, a fresher notification is on the way
            // and its own retry chain will handle artwork.
            let liveName = currentTrack.value(forKey: "name") as? String ?? ""
            guard liveName == name else { return }

            if let image = self.fetchArtworkFromTrack(currentTrack) {
                let fullSong = SongInfo(name: name, artist: artist, album: album, artwork: image)
                DispatchQueue.main.async {
                    guard seq == self.artworkFetchSeq else { return }
                    self.songSubject.send(fullSong)
                }
                return
            }

            // Last attempt about to fail — dump what we got back from
            // SB so the next bug report has something actionable
            // (empty artworks array vs. weird type vs. corrupt data).
            let isLastAttempt = (attempt + 1) >= Self.artworkRetryDelaysMs.count
            if isLastAttempt {
                self.logArtworkDiagnostics(track: currentTrack, name: name)
            }

            // Not ready yet — schedule next attempt.
            self.fetchArtworkWithRetry(name: name, artist: artist, album: album,
                                        seq: seq, attempt: attempt + 1)
        }

        let delayMs = delays[attempt]
        let queue = DispatchQueue.global(qos: .userInitiated)
        if delayMs == 0 {
            queue.async(execute: work)
        } else {
            queue.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: work)
        }
    }

    // MARK: - ScriptingBridge

    private func pollScriptingBridge(allowPaused: Bool = false) -> SongInfo? {
        guard let music = SBApplication(bundleIdentifier: "com.apple.Music") else {
            debugLog("🎧 SB: Could not create SBApplication for Music")
            return nil
        }

        guard music.isRunning else {
            debugLog("🎧 SB: Music.app is not running")
            return nil
        }

        // Check player state — 1800426320 = 'kPSP' = playing, 1800426352 = 'kPSp' = paused
        let playingState = 1800426320
        let pausedState = 1800426352

        guard let stateRaw = (music.value(forKey: "playerState") as? NSNumber)?.intValue else {
            debugLog("🎧 SB: Could not read playerState")
            return nil
        }

        debugLog("🎧 SB: playerState = \(stateRaw)")

        if !allowPaused && stateRaw != playingState {
            debugLog("🎧 SB: Not playing (allowPaused=false)")
            return nil
        }

        if allowPaused && stateRaw != playingState && stateRaw != pausedState {
            debugLog("🎧 SB: Not playing or paused (state \(stateRaw))")
            return nil
        }

        guard let currentTrack = music.value(forKey: "currentTrack") as? SBObject else {
            debugLog("🎧 SB: Could not get currentTrack")
            return nil
        }

        let name = currentTrack.value(forKey: "name") as? String ?? ""
        let artist = currentTrack.value(forKey: "artist") as? String ?? ""
        let album = currentTrack.value(forKey: "album") as? String ?? ""

        guard !name.isEmpty else {
            debugLog("🎧 SB: Track name is empty")
            return nil
        }

        debugLog("🎧 SB: Found track: \(artist) – \(name)")

        let artwork = fetchArtworkFromTrack(currentTrack)

        return SongInfo(name: name, artist: artist, album: album, artwork: artwork)
    }

    /// Emits a single line describing what SB actually returned for
    /// each artwork-extraction leg. Called once on the final retry's
    /// failure; never on intermediate retries (those are noisy and
    /// usually transient — Music.app just hadn't finished its CDN
    /// fetch yet).
    private func logArtworkDiagnostics(track: SBObject, name: String) {
        let artworks = track.value(forKey: "artworks") as? SBElementArray
        let count = artworks?.count ?? -1

        guard let firstArt = artworks?.firstObject as? SBObject else {
            debugLog("🎧 SB artwork inspect [\(name)]: artworks.count=\(count), no firstObject")
            return
        }

        func describe(_ value: Any?) -> String {
            guard let value = value else { return "nil" }
            let type = String(describing: Swift.type(of: value))
            if let img = value as? NSImage {
                return "\(type) NSImage(valid=\(img.isValid), size=\(img.size))"
            }
            if let data = value as? Data {
                return "\(type) Data(\(data.count)B)"
            }
            return type
        }

        let dataLeg = describe(firstArt.value(forKey: "data"))
        let rawDataLeg = describe(firstArt.value(forKey: "rawData"))

        debugLog("🎧 SB artwork inspect [\(name)]: artworks.count=\(count) data=\(dataLeg) rawData=\(rawDataLeg)")
    }

    private func fetchArtworkFromTrack(_ track: SBObject) -> NSImage? {
        guard let artworks = track.value(forKey: "artworks") as? SBElementArray,
              artworks.count > 0,
              let firstArt = artworks.firstObject as? SBObject else {
            return nil
        }

        // Music.app's artwork object exposes the image through two
        // properties: `data` (typed `picture`, usually bridges to
        // NSImage) and `raw data` (typed `data`, raw bytes — surfaced
        // as `rawData` in scripting bridge). Across macOS versions
        // and track types either one can come back nil or in an
        // unexpected form, so try the full cascade before giving up.

        if let image = firstArt.value(forKey: "data") as? NSImage,
           image.isValid, image.size != .zero {
            return image
        }

        if let data = firstArt.value(forKey: "data") as? Data,
           let image = NSImage(data: data), image.isValid, image.size != .zero {
            return image
        }

        if let data = firstArt.value(forKey: "rawData") as? Data,
           let image = NSImage(data: data), image.isValid, image.size != .zero {
            return image
        }

        return nil
    }
}
