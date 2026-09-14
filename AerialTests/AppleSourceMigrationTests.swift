//
//  AppleSourceMigrationTests.swift
//  AerialTests
//
//  "macOS 26" → "macOS" rewrites of the persisted source name.
//

import Foundation
import Testing
@testable import Aerial

@Suite("Apple source name migration")
struct AppleSourceMigrationTests {

    @Test("legacy name detection")
    func legacyNames() {
        #expect(AppleSourceMigration.isLegacyAppleMacName("macOS 26"))
        #expect(AppleSourceMigration.isLegacyAppleMacName("macOS 15"))
        #expect(!AppleSourceMigration.isLegacyAppleMacName("macOS"))
        #expect(!AppleSourceMigration.isLegacyAppleMacName("macOS "))
        #expect(!AppleSourceMigration.isLegacyAppleMacName("macOS Beta"))
        #expect(!AppleSourceMigration.isLegacyAppleMacName("tvOS 26"))
        #expect(!AppleSourceMigration.isLegacyAppleMacName("Future macOS Versions"))
    }

    @Test("sourcesEnabled: newest legacy value carries over, legacy keys dropped")
    func enabledSources() {
        let migrated = AppleSourceMigration.migrateEnabledSources(
            ["macOS 26": false, "macOS 15": true, "tvOS 26": true, "Live Feeds": true])
        #expect(migrated == ["macOS": false, "tvOS 26": true, "Live Feeds": true])
    }

    @Test("sourcesEnabled: an explicit macOS entry wins over legacy ones")
    func enabledSourcesExplicitWins() {
        let migrated = AppleSourceMigration.migrateEnabledSources(["macOS": true, "macOS 26": false])
        #expect(migrated == ["macOS": true])
    }

    @Test("sourcesEnabled: nothing to do is a no-op")
    func enabledSourcesNoop() {
        let input: [String: Bool] = ["macOS": true, "tvOS 26": true]
        #expect(AppleSourceMigration.migrateEnabledSources(input) == input)
        #expect(AppleSourceMigration.migrateEnabledSources([:]) == [:])
    }

    @Test("filter strings: only source:macOS NN is rewritten, order kept, deduped")
    func filterStrings() {
        let input = ["location:Tahoe", "source:macOS 26", "source:tvOS 26", "source:Future macOS Versions",
                     "source:macOS 15", "time:night", "source:macOS"]
        let migrated = AppleSourceMigration.migrateFilterStrings(input)
        #expect(migrated == ["location:Tahoe", "source:macOS", "source:tvOS 26", "source:Future macOS Versions", "time:night"])
        #expect(AppleSourceMigration.migrateFilterStrings(migrated) == migrated)
    }

    @Test("playlists: every persisted playlist's filters are rewritten, counted once each")
    func playlists() {
        func playlist(_ filters: [String]) -> PersistedPlaylist {
            PersistedPlaylist(entries: [], currentIndex: 0, playbackTimestamp: nil,
                              filterMode: 4, filterStrings: filters, generatedAt: Date())
        }
        var state = PlaylistState(version: 1,
                                  sharedPlaylist: playlist(["source:macOS 26"]),
                                  screenPlaylists: ["A": playlist(["source:macOS 26", "location:Sonoma"]),
                                                    "B": playlist(["location:Sonoma"])])
        let touched = AppleSourceMigration.migratePlaylists(&state)
        #expect(touched == 2)
        #expect(state.sharedPlaylist?.filterStrings == ["source:macOS"])
        #expect(state.screenPlaylists["A"]?.filterStrings == ["source:macOS", "location:Sonoma"])
        #expect(state.screenPlaylists["B"]?.filterStrings == ["location:Sonoma"])
        #expect(AppleSourceMigration.migratePlaylists(&state) == 0)
    }
}
