//
//  SpotifyProvider.swift
//  Aerial
//
//  NowPlayingSource for Spotify using DistributedNotifications + ScriptingBridge.
//  Mirrors AppleMusicProvider — different notification name, userInfo keys,
//  bundle ID, and artwork-via-URL fetch since Spotify's notification carries
//  an HTTPS URL instead of an inline image.
//

import Foundation
import Combine
import AppKit
import ScriptingBridge

class SpotifyProvider: NowPlayingSource {
    let identifier = "com.spotify.client"
    let displayName = "Spotify"

    var songChanged: AnyPublisher<SongInfo?, Never> {
        songSubject.eraseToAnyPublisher()
    }

    private let songSubject = PassthroughSubject<SongInfo?, Never>()
    private var observerToken: NSObjectProtocol?
    private var isObserving = false

    /// Token that increments on every new track notification — used to
    /// drop late artwork downloads if the track has already changed
    /// again before the previous fetch finished.
    private var artworkFetchSeq: Int = 0

    func start() {
        guard !isObserving else { return }
        isObserving = true

        observerToken = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleNotification(notification)
        }

        debugLog("🎧 SpotifyProvider started (distributed notifications)")
    }

    func stop() {
        guard isObserving else { return }
        isObserving = false

        if let token = observerToken {
            DistributedNotificationCenter.default().removeObserver(token)
            observerToken = nil
        }

        debugLog("🎧 SpotifyProvider stopped")
    }

    func fetchCurrentSong(completion: @escaping (SongInfo?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
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
            debugLog("🎧 Spotify \(state.lowercased())")
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

        debugLog("🎧 Spotify: \(artist) – \(name) (\(album))")

        // Emit text immediately so the overlay updates without waiting
        // on the artwork download.
        let basicSong = SongInfo(name: name, artist: artist, album: album, artwork: nil)
        songSubject.send(basicSong)

        artworkFetchSeq += 1
        let mySeq = artworkFetchSeq

        // Prefer the URL Spotify hands us in userInfo; if absent (rare
        // — happens for some DJ / Radio sessions on older builds),
        // fall back to ScriptingBridge's `currentTrack.artworkUrl`.
        var urlString = info["Artwork URL"] as? String
        if urlString == nil || urlString?.isEmpty == true {
            urlString = artworkURLFromScriptingBridge()
            if let fallback = urlString, !fallback.isEmpty {
                debugLog("🎧 Spotify artwork: userInfo had no URL, using SB fallback")
            }
        }

        guard let urlString = urlString, let url = URL(string: urlString) else {
            debugLog("🎧 Spotify artwork inspect [\(name)]: no Artwork URL in userInfo, SB fallback also empty")
            return
        }

        fetchArtworkWithRetry(url: url, name: name, artist: artist, album: album,
                              seq: mySeq, attempt: 0)
    }

    /// Two-shot HTTPS fetch with a single retry at ~500 ms for
    /// transient network failures. Logs one diagnostic line on
    /// final give-up so missing artwork shows up actionably in
    /// the debug log.
    private func fetchArtworkWithRetry(url: URL, name: String, artist: String, album: String,
                                       seq: Int, attempt: Int) {
        let maxAttempts = 2

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            // Stale — user has moved on.
            guard seq == self.artworkFetchSeq else { return }

            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? -1
            let bytes = data?.count ?? 0

            if let data = data, status >= 200, status < 300,
               let image = NSImage(data: data), image.isValid, image.size != .zero {
                let fullSong = SongInfo(name: name, artist: artist, album: album, artwork: image)
                DispatchQueue.main.async {
                    guard seq == self.artworkFetchSeq else { return }
                    self.songSubject.send(fullSong)
                }
                return
            }

            let nextAttempt = attempt + 1
            if nextAttempt < maxAttempts {
                DispatchQueue.global(qos: .userInitiated)
                    .asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                        self?.fetchArtworkWithRetry(url: url, name: name, artist: artist, album: album,
                                                    seq: seq, attempt: nextAttempt)
                    }
                return
            }

            // Final failure — log what we saw so the next bug report
            // distinguishes "404" from "network error" from "bytes
            // present but NSImage rejected them".
            let errorDesc = error.map { String(describing: $0) } ?? "nil"
            let imageDecodable = data.flatMap { NSImage(data: $0) } != nil
            debugLog("🎧 Spotify artwork inspect [\(name)]: url=\(url.absoluteString) status=\(status) bytes=\(bytes) decodable=\(imageDecodable) error=\(errorDesc)")
            debugLog("🎧 Spotify artwork: gave up for \(name) after \(maxAttempts) attempts")
        }.resume()
    }

    /// Pull `currentTrack.artworkUrl` from SB. Used as a fallback
    /// only when the notification's `Artwork URL` key is missing.
    private func artworkURLFromScriptingBridge() -> String? {
        guard let spotify = SBApplication(bundleIdentifier: "com.spotify.client"),
              spotify.isRunning,
              let currentTrack = spotify.value(forKey: "currentTrack") as? SBObject,
              let url = currentTrack.value(forKey: "artworkUrl") as? String,
              !url.isEmpty else {
            return nil
        }
        return url
    }

    // MARK: - ScriptingBridge

    private func pollScriptingBridge(allowPaused: Bool = false) -> SongInfo? {
        guard let spotify = SBApplication(bundleIdentifier: "com.spotify.client") else {
            debugLog("🎧 SB: Could not create SBApplication for Spotify")
            return nil
        }

        guard spotify.isRunning else {
            debugLog("🎧 SB: Spotify.app is not running")
            return nil
        }

        // Spotify's playerState is exposed as a FourCC OSType. The
        // SBApplication bridge returns it as an NSNumber whose value
        // equals the four-byte big-endian code:
        //   'kPSP' = 0x6B505350 = 1800426320 (playing)
        //   'kPSp' = 0x6B505370 = 1800426352 (paused)
        //   'kPSS' = 0x6B505353 = 1800426323 (stopped)
        let playingState = 1800426320
        let pausedState  = 1800426352

        guard let stateRaw = (spotify.value(forKey: "playerState") as? NSNumber)?.intValue else {
            debugLog("🎧 SB: Could not read Spotify playerState")
            return nil
        }

        debugLog("🎧 SB: Spotify playerState = \(stateRaw)")

        if !allowPaused && stateRaw != playingState {
            debugLog("🎧 SB: Spotify not playing (allowPaused=false)")
            return nil
        }

        if allowPaused && stateRaw != playingState && stateRaw != pausedState {
            debugLog("🎧 SB: Spotify not playing or paused (state \(stateRaw))")
            return nil
        }

        guard let currentTrack = spotify.value(forKey: "currentTrack") as? SBObject else {
            debugLog("🎧 SB: Could not get Spotify currentTrack")
            return nil
        }

        let name = currentTrack.value(forKey: "name") as? String ?? ""
        let artist = currentTrack.value(forKey: "artist") as? String ?? ""
        let album = currentTrack.value(forKey: "album") as? String ?? ""

        guard !name.isEmpty else {
            debugLog("🎧 SB: Spotify track name is empty")
            return nil
        }

        debugLog("🎧 SB: Spotify track: \(artist) – \(name)")

        // Spotify's track exposes `artworkUrl` as a string rather than
        // an inline image collection like Apple Music. Fetch it
        // synchronously here since we're already on a background queue
        // courtesy of `fetchCurrentSong`.
        var artwork: NSImage?
        if let urlString = currentTrack.value(forKey: "artworkUrl") as? String,
           let url = URL(string: urlString),
           let data = try? Data(contentsOf: url) {
            artwork = NSImage(data: data)
        }

        return SongInfo(name: name, artist: artist, album: album, artwork: artwork)
    }
}
