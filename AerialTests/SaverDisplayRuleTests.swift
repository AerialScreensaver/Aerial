//
//  SaverDisplayRuleTests.swift
//  AerialTests
//
//  "Screensaver plays videos on" (2026-09-28): the 3.x display selection
//  re-implemented as a pure rule the extension evaluates per saver
//  window. These pin the four modes, the empty-result fallback the owner
//  chose (never a black-everywhere saver), the preview/desktop bypass,
//  and the one-time move of the stored keys onto display UUIDs.
//

import CoreGraphics
import Foundation
import Testing
@testable import Aerial

@Suite("Saver display rule")
struct SaverDisplayRuleTests {

    private let main = SaverDisplayRule.Display(uuid: "MAIN", isMain: true)
    private let second = SaverDisplayRule.Display(uuid: "SECOND", isMain: false)
    private let third = SaverDisplayRule.Display(uuid: "THIRD", isMain: false)
    /// A display under 200 pt tall: does not count as a screen (3.x quirk).
    private let tiny = SaverDisplayRule.Display(uuid: "TINY", isMain: false, countsAsScreen: false)

    private func playing(_ mode: DisplayMode, selection: [String: Bool] = [:],
                         override: SingleDisplayOverride? = nil,
                         _ displays: [SaverDisplayRule.Display]) -> Set<String> {
        SaverDisplayRule.playingDisplays(mode: mode, selection: selection, displays: displays,
                                         singleDisplayOverride: override)
    }

    @Test("all displays")
    func all() {
        #expect(playing(.allDisplays, [main, second, third]) == ["MAIN", "SECOND", "THIRD"])
        #expect(playing(.allDisplays, [main]) == ["MAIN"])
    }

    @Test("main only")
    func mainOnly() {
        #expect(playing(.mainOnly, [main, second]) == ["MAIN"])
        #expect(playing(.mainOnly, [main]) == ["MAIN"])
    }

    @Test("secondary only needs a second display that counts as a screen")
    func secondaryOnly() {
        #expect(playing(.secondaryOnly, [main, second, third]) == ["SECOND", "THIRD"])
        // Single display: the main one plays (3.x behaviour).
        #expect(playing(.secondaryOnly, [main]) == ["MAIN"])
        // The only other display is too small to count: everything plays.
        #expect(playing(.secondaryOnly, [main, tiny]) == ["MAIN", "TINY"])
    }

    @Test("selection: only entries stored true, unknown displays are off")
    func selection() {
        #expect(playing(.selection, selection: ["SECOND": true, "MAIN": false], [main, second, third]) == ["SECOND"])
        #expect(playing(.selection, selection: ["MAIN": true, "THIRD": true], [main, second, third]) == ["MAIN", "THIRD"])
    }

    @Test("an empty result falls back to every display")
    func emptyFallsBackToAll() {
        // Nothing ticked yet.
        #expect(playing(.selection, [main, second]) == ["MAIN", "SECOND"])
        // Every ticked display is off, or unknown.
        #expect(playing(.selection, selection: ["MAIN": false, "GONE": true], [main, second]) == ["MAIN", "SECOND"])
        // No main display found.
        #expect(playing(.mainOnly, [second, third]) == ["SECOND", "THIRD"])
        // Displays without a UUID are ignored, not selected.
        let ghost = SaverDisplayRule.Display(uuid: "", isMain: false)
        #expect(playing(.allDisplays, [main, ghost]) == ["MAIN"])
        #expect(playing(.allDisplays, []).isEmpty)
    }

    @Test("undocked laptop: a selection of external displays plays on the built-in")
    func undocked() {
        let builtIn = SaverDisplayRule.Display(uuid: "BUILTIN", isMain: true)
        let sel = ["EXT-A": true, "EXT-B": true]
        #expect(playing(.selection, selection: sel, [builtIn]) == ["BUILTIN"])
    }

    @Test("single-display override: Don't play is the one deliberate black-everywhere result")
    func singleDisplayOverride() {
        // Checkbox off (nil) = today's fallback: the lone display plays.
        #expect(playing(.secondaryOnly, override: nil, [main]) == ["MAIN"])
        // Play states the fallback explicitly; Don't play keeps it black.
        #expect(playing(.secondaryOnly, override: .play, [main]) == ["MAIN"])
        #expect(playing(.secondaryOnly, override: .dontPlay, [main]).isEmpty)
        #expect(playing(.mainOnly, override: .dontPlay, [main]).isEmpty)
        // Undocked laptop with a selection of externals: Don't play wins
        // over the empty-selection fallback.
        let builtIn = SaverDisplayRule.Display(uuid: "BUILTIN", isMain: true)
        #expect(playing(.selection, selection: ["EXT-A": true], override: .dontPlay, [builtIn]).isEmpty)
        #expect(playing(.selection, selection: ["BUILTIN": true], override: .dontPlay, [builtIn]).isEmpty)
        // "One display" follows the countsAsScreen quirk: a <200 pt
        // display does not make it a two-display setup.
        #expect(playing(.mainOnly, override: .dontPlay, [main, tiny]).isEmpty)
        // Two real displays: the override is inert, the mode rules.
        #expect(playing(.mainOnly, override: .dontPlay, [main, second]) == ["MAIN"])
        #expect(playing(.secondaryOnly, override: .dontPlay, [main, second]) == ["SECOND"])
        // Inert under All displays (the UI hides the checkbox there, but
        // the stored keys survive a mode switch).
        #expect(playing(.allDisplays, override: .dontPlay, [main]) == ["MAIN"])
        // An empty playing set excludes a real saver window but never a
        // preview or desktop window.
        #expect(!SaverDisplayRule.plays(uuid: "MAIN", isSaverRole: true, isPreview: false, playing: []))
        #expect(SaverDisplayRule.plays(uuid: "MAIN", isSaverRole: true, isPreview: true, playing: []))
        #expect(SaverDisplayRule.plays(uuid: "MAIN", isSaverRole: false, isPreview: false, playing: []))
    }

    @Test("overlay screen override: only while the override is why the lone display plays")
    func overlayScreenOverride() {
        let ext = "EXT-UUID"
        func borrowed(_ mode: DisplayMode, _ displays: [SaverDisplayRule.Display], _ single: SingleDisplayOverride?,
                      perScreen: Bool = true, selected: String = ext) -> String? {
            SaverDisplayRule.overlayScreenOverride(mode: mode, displays: displays, singleDisplayOverride: single,
                                                   perScreenOverlays: perScreen, selected: selected)
        }
        // All conditions met: borrow the selected screen's layout.
        #expect(borrowed(.secondaryOnly, [main], .play) == ext)
        #expect(borrowed(.mainOnly, [main, tiny], .play) == ext)
        // Override off, Don't play, All displays, two real displays.
        #expect(borrowed(.secondaryOnly, [main], nil) == nil)
        #expect(borrowed(.secondaryOnly, [main], .dontPlay) == nil)
        #expect(borrowed(.allDisplays, [main], .play) == nil)
        #expect(borrowed(.secondaryOnly, [main, second], .play) == nil)
        // Per-screen layouts off, or "This display" selected.
        #expect(borrowed(.secondaryOnly, [main], .play, perScreen: false) == nil)
        #expect(borrowed(.secondaryOnly, [main], .play, selected: "") == nil)
        // The predicates behind it.
        #expect(SaverDisplayRule.isSingleDisplaySetup([main]))
        #expect(SaverDisplayRule.isSingleDisplaySetup([main, tiny]))
        #expect(SaverDisplayRule.isSingleDisplaySetup([]))
        #expect(!SaverDisplayRule.isSingleDisplaySetup([main, second]))
        #expect(SaverDisplayRule.singleDisplayOverrideApplies(mode: .mainOnly, displays: [main], singleDisplayOverride: .play))
        #expect(!SaverDisplayRule.singleDisplayOverrideApplies(mode: .mainOnly, displays: [main], singleDisplayOverride: .dontPlay))
        #expect(!SaverDisplayRule.singleDisplayOverrideApplies(mode: .allDisplays, displays: [main], singleDisplayOverride: .play))
    }

    @Test("plays: only a real saver window on an excluded display goes black")
    func plays() {
        let playing: Set<String> = ["MAIN"]
        #expect(SaverDisplayRule.plays(uuid: "MAIN", isSaverRole: true, isPreview: false, playing: playing))
        #expect(!SaverDisplayRule.plays(uuid: "SECOND", isSaverRole: true, isPreview: false, playing: playing))
        // Previews and desktop windows always play.
        #expect(SaverDisplayRule.plays(uuid: "SECOND", isSaverRole: true, isPreview: true, playing: playing))
        #expect(SaverDisplayRule.plays(uuid: "SECOND", isSaverRole: false, isPreview: false, playing: playing))
        // A display without a derivable UUID stays enabled (3.x).
        #expect(SaverDisplayRule.plays(uuid: nil, isSaverRole: true, isPreview: false, playing: playing))
        #expect(SaverDisplayRule.plays(uuid: "", isSaverRole: true, isPreview: false, playing: playing))
    }
}

@Suite("Selection key migration")
struct SelectionKeyMigrationTests {

    private let connected: [(id: CGDirectDisplayID, uuid: String)] = [(3, "UUID-3"), (11, "UUID-11"), (7, "")]

    @Test("numeric keys of connected displays move to their UUID, value kept")
    func rewrite() {
        let migrated = SelectionKeyMigration.migrate(dict: ["3": true, "11": false], connected: connected)
        #expect(migrated == ["UUID-3": true, "UUID-11": false])
    }

    @Test("numeric keys of unknown displays are dropped, UUID keys are kept and win")
    func dropAndKeep() {
        let migrated = SelectionKeyMigration.migrate(
            dict: ["99": true, "3": false, "UUID-3": true, "UUID-OLD": false], connected: connected)
        #expect(migrated == ["UUID-3": true, "UUID-OLD": false])
    }

    @Test("a display whose UUID is unavailable is not migrated")
    func noUUID() {
        #expect(SelectionKeyMigration.migrate(dict: ["7": true], connected: connected).isEmpty)
    }

    @Test("idempotent on an already-migrated dictionary")
    func idempotent() {
        let done: [String: Bool] = ["UUID-3": true, "UUID-11": false]
        #expect(SelectionKeyMigration.migrate(dict: done, connected: connected) == done)
        #expect(SelectionKeyMigration.migrate(dict: [:], connected: connected).isEmpty)
    }
}
