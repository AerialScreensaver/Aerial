//
//  SaverDisplayRule.swift
//  Aerial
//
//  "Screensaver plays videos on": which displays the SCREENSAVER plays
//  on. Inherited from Aerial 3.x (`DisplayDetection.isScreenActive`),
//  where an excluded screen showed black; the ExtensionKit extension
//  lost the guard when the legacy saver appex was deleted (2026-06-25)
//  and the setting drove Companion UI only until 2026-09-28.
//
//  Scope: screensaver windows only. The desktop wallpaper always uses
//  every display, so the rule is evaluated per saver acquire and never
//  touches a desktop window (see `SaverAcquireRule` for the role).
//  Pure so it is unit-tested with synthetic display sets.
//

import CoreGraphics
import Foundation

enum SaverDisplayRule {

    struct Display: Equatable, Sendable {
        /// `CGDisplayCreateUUIDFromDisplayID` string — the same key the
        /// renderer keys, playlists and the stored selection use.
        let uuid: String
        let isMain: Bool
        /// 3.x `getScreenCount` quirk kept on purpose: a display shorter
        /// than 200 pt does not count when deciding whether "secondary
        /// displays only" has a secondary at all.
        let countsAsScreen: Bool

        init(uuid: String, isMain: Bool, countsAsScreen: Bool = true) {
            self.uuid = uuid
            self.isMain = isMain
            self.countsAsScreen = countsAsScreen
        }
    }

    /// UUIDs of the connected displays the saver plays on. Never empty
    /// for a non-empty input: a selection that matches nothing (laptop
    /// undocked from its selected externals, "main only" with no main
    /// found, nothing ticked yet) falls back to every display — a
    /// screensaver that is black everywhere reads as broken.
    ///
    /// 3.x semantics otherwise: allDisplays → all; mainOnly → the main
    /// display; secondaryOnly → every non-main display when more than
    /// one display counts as a screen, else all; selection → the
    /// entries stored `true` (unknown displays are off).
    static func playingDisplays(mode: DisplayMode, selection: [String: Bool], displays: [Display]) -> Set<String> {
        let known = displays.filter { !$0.uuid.isEmpty }
        let all = Set(known.map(\.uuid))
        let chosen: Set<String>
        switch mode {
        case .allDisplays:
            chosen = all
        case .mainOnly:
            chosen = Set(known.filter(\.isMain).map(\.uuid))
        case .secondaryOnly:
            let counted = known.filter(\.countsAsScreen).count
            chosen = counted > 1 ? Set(known.filter { !$0.isMain }.map(\.uuid)) : all
        case .selection:
            chosen = Set(known.filter { selection[$0.uuid] == true }.map(\.uuid))
        }
        return chosen.isEmpty ? all : chosen
    }

    /// One window: only a real screensaver window can be excluded.
    /// Previews (System Settings) and desktop windows always play, and
    /// a display whose UUID cannot be derived stays enabled (3.x: "if
    /// it's an unknown screen, we leave it enabled").
    static func plays(uuid: String?, isSaverRole: Bool, isPreview: Bool, playing: Set<String>) -> Bool {
        guard isSaverRole, !isPreview else { return true }
        guard let uuid, !uuid.isEmpty else { return true }
        return playing.contains(uuid)
    }
}

/// One-time move of the "Selected displays" dictionary from numeric
/// `CGDirectDisplayID` keys (3.x / 4.0, re-assigned by macOS across
/// sleep, wake and replug — a DisplayLink screen cycled 3 → 11 → 8 in a
/// day) onto display UUIDs. Numeric keys that match a connected display
/// are rewritten with their value; numeric keys for displays that are
/// not connected are dropped (the number says nothing about the screen
/// any more); UUID keys are kept and win over a migrated duplicate.
/// Idempotent: a dictionary with no numeric key comes back unchanged.
enum SelectionKeyMigration {
    static func migrate(dict: [String: Bool], connected: [(id: CGDirectDisplayID, uuid: String)]) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for (key, value) in dict where UInt32(key) == nil {
            result[key] = value
        }
        for (key, value) in dict {
            guard let id = UInt32(key),
                  let match = connected.first(where: { $0.id == id }),
                  !match.uuid.isEmpty,
                  result[match.uuid] == nil else { continue }
            result[match.uuid] = value
        }
        return result
    }
}
