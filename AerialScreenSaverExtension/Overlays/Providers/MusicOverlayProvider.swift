//
//  MusicOverlayProvider.swift
//  AerialScreenSaverExtension
//
//  Provider for music overlay type. Wraps the existing MusicOverlayView.
//

import SwiftUI

struct MusicOverlayProvider: OverlayTypeProvider {
    static let kind: OverlayKind = .music

    static func makeView(instance: OverlayInstance, state: OverlayState) -> AnyView {
        let song = state.songInfo ?? (state.isPreview ? Self.previewSong : nil)
        return AnyView(
            MusicOverlayView(
                songInfo: song,
                fontSize: instance.fontSize,
                fontName: instance.fontName
            )
        )
    }

    private static let previewSong = SongInfo(
        name: "Song Name",
        artist: "Artist",
        album: "Album",
        artwork: nil
    )

    static func makeSettingsView(instance: Binding<OverlayInstance>) -> AnyView {
        AnyView(MusicSettingsContent())
    }
}

// MARK: - Settings Content

private struct MusicSettingsContent: View {
    #if COMPANION_APP
    @State private var testResult: String?
    @State private var isTesting = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shows the currently playing song from Apple Music.")
                .foregroundStyle(.secondary)
                .font(.caption)

            #if COMPANION_APP
            Divider()

            Button(action: testNowPlaying) {
                HStack(spacing: 4) {
                    Image(systemName: "play.circle")
                    Text("Test Now Playing")
                }
            }
            .disabled(isTesting)

            if let result = testResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            #endif
        }
    }

    #if COMPANION_APP
    private func testNowPlaying() {
        isTesting = true
        testResult = nil

        // Safety timeout — if ScriptingBridge silently fails, don't leave the button stuck
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            if isTesting {
                isTesting = false
                testResult = "Timed out — check Apple Events permissions in System Settings → Privacy"
            }
        }

        NowPlayingCoordinator.shared.fetchCurrentSong { song in
            guard isTesting else { return } // timeout already fired
            isTesting = false
            if let song = song, !song.name.isEmpty {
                testResult = "\(song.name) — \(song.artist)"
            } else {
                testResult = "Nothing playing"
            }
        }
    }
    #endif
}
