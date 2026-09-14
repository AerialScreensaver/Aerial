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
    /// In-memory mirror of `Preferences.enabledNowPlayingSources`.
    /// Empty set carries the "all enabled" implicit-default semantics
    /// (so an unconfigured install opts into every known player and
    /// later-added players too). Materialized to an explicit subset
    /// the first time the user unchecks something.
    @State private var enabledSources: Set<String> = Set(Preferences.enabledNowPlayingSources)
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shows the currently playing song from the players you select.")
                .foregroundStyle(.secondary)
                .font(.caption)

            #if COMPANION_APP
            Divider()

            Text("Players to monitor")
                .font(.system(size: 12, weight: .semibold))
            Text("These apply to all Music overlays in Aerial.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            ForEach(NowPlayingSourceRegistry.all, id: \.identifier) { src in
                Toggle(src.displayName, isOn: bindingForSource(src.identifier))
            }

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
    private func isSourceEnabled(_ identifier: String) -> Bool {
        // Empty set = implicit "all enabled".
        enabledSources.isEmpty || enabledSources.contains(identifier)
    }

    private func bindingForSource(_ identifier: String) -> Binding<Bool> {
        Binding(
            get: { isSourceEnabled(identifier) },
            set: { newValue in
                // Materialize the implicit "all enabled" set before
                // mutating, so unchecking the first source writes a
                // real subset to disk rather than persisting `[]`
                // (which would be re-interpreted as "all enabled").
                var current: Set<String> = enabledSources.isEmpty
                    ? Set(NowPlayingSourceRegistry.all.map { $0.identifier })
                    : enabledSources
                if newValue {
                    current.insert(identifier)
                } else {
                    current.remove(identifier)
                }
                enabledSources = current
                Preferences.enabledNowPlayingSources = Array(current).sorted()
                NowPlayingCoordinator.shared.reconfigure()
            }
        )
    }

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
