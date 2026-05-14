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

        // Fetch artwork via ScriptingBridge on background queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let artwork = self.fetchArtwork()
            if let artwork = artwork {
                let fullSong = SongInfo(name: name, artist: artist, album: album, artwork: artwork)
                DispatchQueue.main.async {
                    self.songSubject.send(fullSong)
                }
            }
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

    private func fetchArtwork() -> NSImage? {
        guard let music = SBApplication(bundleIdentifier: "com.apple.Music") else {
            debugLog("🎧 SB artwork: Could not create SBApplication")
            return nil
        }

        guard music.isRunning else {
            debugLog("🎧 SB artwork: Music.app is not running")
            return nil
        }

        guard let currentTrack = music.value(forKey: "currentTrack") as? SBObject else {
            debugLog("🎧 SB artwork: Could not get currentTrack")
            return nil
        }

        return fetchArtworkFromTrack(currentTrack)
    }

    private func fetchArtworkFromTrack(_ track: SBObject) -> NSImage? {
        guard let artworks = track.value(forKey: "artworks") as? SBElementArray,
              artworks.count > 0,
              let firstArt = artworks.firstObject as? SBObject,
              let image = firstArt.value(forKey: "data") as? NSImage else {
            return nil
        }
        return image
    }
}
