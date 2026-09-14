//
//  SidecarJSONFuzzTests.swift
//  AerialTests
//
//  Mutation fuzzing of the sidecar JSON files the app and the wallpaper
//  extension exchange through /Users/Shared/Aerial. Each model's seed is
//  a valid document; the fuzzer drops keys, swaps types, injects nulls,
//  extremes, empties, duplicates and junk, then decodes with the same
//  decoder production uses. The contract: a decode either throws or
//  yields a value that the consumers can use without trapping — and a
//  successful decode must re-encode.
//

import Foundation
import Testing
@testable import Aerial

@Suite("Sidecar JSON fuzz")
struct SidecarJSONFuzzTests {
    // MARK: - Mutation engine

    private func junk(_ rng: inout SeededGenerator) -> Any {
        let pool: [Any] = [
            NSNull(), "", "🌊", "null", "NaN", "1e999", "-1", String(repeating: "x", count: 5000),
            0, -1, 1, Int.max, Int.min, 1e308, -1e308, 1e-308, 0.5, -0.0, true, false,
            [Any](), [String: Any](), [NSNull()], ["deep": ["deeper": [1, 2, NSNull()]]],
        ]
        return pool.randomElement(using: &rng)!
    }

    private func nodeCount(_ value: Any) -> Int {
        switch value {
        case let dict as [String: Any]: return 1 + dict.values.reduce(0) { $0 + nodeCount($1) }
        case let array as [Any]: return 1 + array.reduce(0) { $0 + nodeCount($1) }
        default: return 1
        }
    }

    /// Mutate with per-node probability `p`, chosen by the caller so a
    /// document of any size gets an expected 1–3 edits — enough to be
    /// rejected sometimes and accepted sometimes. (A fixed per-node rate
    /// rejects every large document and tests nothing.)
    private func mutate(_ value: Any, _ rng: inout SeededGenerator, p: Double, depth: Int = 0) -> Any {
        if depth > 0 && rng.bool(probability: p) { return junk(&rng) }
        switch value {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (key, child) in dict where !rng.bool(probability: p) {
                out[key] = mutate(child, &rng, p: p, depth: depth + 1)
            }
            if rng.bool(probability: p) { out["zz_extra_\(rng.int(0...9))"] = junk(&rng) }
            return out
        case let array as [Any]:
            var out = array.map { mutate($0, &rng, p: p, depth: depth + 1) }
            if rng.bool(probability: p) {
                switch rng.int(0...2) {
                case 0: out = []
                case 1: out.append(junk(&rng))
                default: out += out
                }
            }
            return out
        case let number as NSNumber:
            guard rng.bool(probability: p) else { return number }
            return [0, -1, Int.max, Int.min, 1e308, -number.doubleValue, number.doubleValue * 1e6, 0.001, 2_147_483_648.0].randomElement(using: &rng)!
        case let string as String:
            guard rng.bool(probability: p) else { return string }
            return ["", "🌊", string + string, "not-a-date", "2026-13-45T99:99:99Z", String(repeating: string, count: 50)].randomElement(using: &rng)!
        default:
            return value
        }
    }

    private func mutate(_ tree: Any, _ rng: inout SeededGenerator) -> Any {
        let nodes = max(1, nodeCount(tree))
        let p = rng.bool(probability: 0.15) ? 0.15 : Double(rng.int(1...3)) / Double(nodes)
        return mutate(tree, &rng, p: min(1, p))
    }

    private static let decoder: JSONDecoder = newJSONDecoder()
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Fuzz one model: `seed` must decode as-is (else the run is vacuous);
    /// every mutation either throws or passes `check` and re-encodes.
    private func fuzz<T: Codable>(
        _ type: T.Type, seed: Data, iterations: Int = 150,
        sourceLocation: SourceLocation = #_sourceLocation,
        check: (T, inout SeededGenerator) -> Void = { _, _ in }
    ) throws {
        var rng = SeededGenerator(seed: 0xF00D)
        let baseline = try Self.decoder.decode(T.self, from: seed)
        check(baseline, &rng)
        let tree = try JSONSerialization.jsonObject(with: seed)
        var decoded = 0, rejected = 0
        try forAll(iterations: iterations, seed: 0xF00D) { rng, _ in
            let mutated = mutate(tree, &rng)
            guard JSONSerialization.isValidJSONObject(mutated) else { return }
            let data = try JSONSerialization.data(withJSONObject: mutated)
            guard let value = try? Self.decoder.decode(T.self, from: data) else { rejected += 1; return }
            decoded += 1
            check(value, &rng)
            #expect((try? Self.encoder.encode(value)) != nil, "\(rng.trail) \(T.self) decoded but will not re-encode", sourceLocation: sourceLocation)
        }
        // A fuzz that only ever rejects (or only ever accepts) is not exercising the decoder.
        #expect(decoded > 0 && rejected > 0, "\(T.self): decoded=\(decoded) rejected=\(rejected)", sourceLocation: sourceLocation)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data { try Self.encoder.encode(value) }

    // MARK: - Seeds

    private func playlist(_ ids: [String], index: Int, mode: PlaylistCycleMode) -> PersistedPlaylist {
        PersistedPlaylist(
            entries: ids.map { PlaylistEntry(videoId: $0, videoName: "Name \($0)", secondaryName: "sub", duration: 42.5, playDuration: 10) },
            currentIndex: index, playbackTimestamp: 12.5, filterMode: 1, filterStrings: ["sea", "space"],
            generatedAt: Date(timeIntervalSinceReferenceDate: 700_000_000), cycleMode: mode
        )
    }

    private func overlayLayout(_ marker: String) -> OverlayLayout {
        var layout = OverlayLayout.empty
        layout.addInstance(OverlayInstance(id: UUID(), kind: .message, position: .center, fontName: marker, fontSize: 20, typeSettings: [:]))
        layout.addInstance(OverlayInstance(id: UUID(), kind: .clock, position: .topLeft, fontName: marker, fontSize: 64, typeSettings: [:]))
        return layout
    }

    // MARK: - Tests

    @Test("playlists.json: any decodable playlist can be popped in both directions and searched")
    func playlistsJSON() throws {
        let seed = try encode(PlaylistState(
            version: 1,
            sharedPlaylist: playlist(["A", "B", "C", "A"], index: 1, mode: .shuffle),
            screenPlaylists: ["screen-1": playlist(["X"], index: 0, mode: .loop), "screen-2": playlist([], index: 0, mode: .repeatOne)]
        ))
        try fuzz(PlaylistState.self, seed: seed) { state, rng in
            for var pl in [state.sharedPlaylist].compactMap({ $0 }) + Array(state.screenPlaylists.values) {
                let resolve: (String) -> String? = { rng.bool(probability: 0.8) ? $0 : nil }
                _ = pl.popNextVideo(isResume: rng.bool(), resolveVideo: resolve)
                _ = pl.popPreviousVideo(resolveVideo: resolve)
                _ = pl.index(ofVideoId: rng.element(of: pl.entries.map(\.videoId)) ?? "?", searchingBackFrom: rng.int(-9...9))
                pl.reshuffleEntries()
                #expect(pl.entries.isEmpty || (0..<pl.entries.count).contains(pl.currentIndex), "\(rng.trail)")
            }
        }
    }

    @Test("playlist-progress.json and playback-handoff.json survive mutation")
    func progressAndHandoffJSON() throws {
        let progress = PlaylistProgress(currentIndex: 3, playbackTimestamp: 7.25, updatedAt: Date(timeIntervalSinceReferenceDate: 700_000_000))
        try fuzz(PlaylistProgressState.self, seed: try encode(PlaylistProgressState(sharedProgress: progress, screenProgress: ["screen-1": progress])))
        try fuzz(PlaybackHandoff.self, seed: try encode(PlaybackHandoff(startRate: 1.0, writtenAt: Date(timeIntervalSinceReferenceDate: 700_000_000))))
    }

    @Test("overlay-config.json: any decodable config resolves a layout for any screen")
    func overlayConfigJSON() throws {
        let seed = try encode(OverlayConfig(
            version: 1, perScreen: true, separateDesktopConfig: true,
            sharedLayout: overlayLayout("shared"), screenLayouts: ["u1": overlayLayout("u1")],
            desktopSharedLayout: overlayLayout("desktop"), desktopScreenLayouts: ["u1": overlayLayout("desktop-u1")]
        ))
        try fuzz(OverlayConfig.self, seed: seed) { config, rng in
            let uuid: String? = rng.bool() ? "u1" : (rng.bool() ? nil : "unknown")
            let layout = config.resolvedLayout(for: uuid, isDesktop: rng.bool())
            for instance in layout.allInstances {
                #expect(layout.instances(at: instance.position).contains(instance), "\(rng.trail)")
                #expect(layout.instance(withID: instance.id) != nil, "\(rng.trail)")
            }
        }
    }

    @Test("wallpaper-control.json and wallpaper-status.json survive mutation")
    func controlAndStatusJSON() throws {
        try fuzz(WallpaperControlState.self, seed: try encode(WallpaperControlState()))
        // WallpaperStatusState has a hand-written decoder and no default init — seed from a literal.
        let status: [String: Any] = [
            "pid": 4242, "lastSeen": "2026-09-01T10:00:00Z", "saverActive": false, "lockedActive": true,
            "pausedScreens": ["u1"], "autoPausedScreens": [], "nowPlaying": ["u1": "Sea"], "nowPlayingId": ["u1": "v1"],
            "nowPlayingPosition": ["u1": 12.5], "nowPlayingRate": ["u1": 1.0], "appliedControlVersion": 7,
            "extensionVersion": "4.1.0", "extensionBuild": "1234", "extensionBinaryModified": 1_756_000_000.0,
        ]
        try fuzz(WallpaperStatusState.self, seed: try JSONSerialization.data(withJSONObject: status)) { state, rng in
            _ = state.identity
            #expect(state.pausedScreens.count >= 0, "\(rng.trail)")
        }
    }

    @Test("settings, user-playlist index/manifest and weather cache survive mutation")
    func settingsAndIndexesJSON() throws {
        try fuzz(ScreensaverSettings.self, seed: try encode(ScreensaverSettings.default))
        try fuzz(UserPlaylistIndex.self, seed: try encode(UserPlaylistIndex(version: 1, playlists: [
            UserPlaylistSummary(id: UUID(), name: "Favorites", entryCount: 5, order: 0),
            UserPlaylistSummary(id: UUID(), name: "", entryCount: 0, order: -1),
        ])))
        try fuzz(UserPlaylistManifest.self, seed: try encode(UserPlaylistManifest(
            id: UUID(), name: "Night", createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000), cycleMode: .shuffle,
            entries: [PlaylistEntry(videoId: "v1", videoName: "V1", secondaryName: "", duration: 60, playDuration: nil)]
        ))) { manifest, rng in
            var pl = PersistedPlaylist(entries: manifest.entries, currentIndex: rng.int(-5...5), playbackTimestamp: nil,
                                       filterMode: 0, filterStrings: [], generatedAt: Date(), cycleMode: manifest.cycleMode)
            _ = pl.popNextVideo(isResume: false, resolveVideo: { $0 })
        }
        try fuzz(WeatherCacheIndex.self, seed: try encode(WeatherCacheIndex()))
    }
}
