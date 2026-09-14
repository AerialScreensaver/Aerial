//
//  AppleSourceMigration.swift
//  Aerial
//
//  One-shot rename of the Apple macOS source in persisted user state:
//  "macOS 26" (and any older "macOS NN") → "macOS". Up to 4.1.0beta17 the
//  source was named after the OS release, and that name is the key in
//  `sourcesEnabled`, the `source:` rotation filter and every persisted
//  playlist's `filterStrings` — so a rename without this pass silently
//  disabled nothing and matched nothing.
//
//  The rewrites are pure functions (unit-tested); `applyIfNeeded()` is the
//  Companion-only I/O wrapper (the wallpaper extension never writes prefs).
//  The on-disk folder is handled separately by
//  `SourceList.seedAppleMacSourceIfNeeded()`.
//

import Foundation

enum AppleSourceMigration {
    static let newName = SourceList.appleMacSourceName
    static let userDefaultsKey = "appleMacSourceMigrationApplied"
    private static let legacyPrefix = "macOS "
    private static let sourceFilterPrefix = "source:"

    /// "macOS 26", "macOS 15"… — the prefix followed by digits only.
    /// "macOS" itself and "macOS Beta" are not legacy names.
    static func isLegacyAppleMacName(_ name: String) -> Bool {
        guard name.hasPrefix(legacyPrefix) else { return false }
        let suffix = name.dropFirst(legacyPrefix.count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    /// `sourcesEnabled`: carry the user's choice for the NEWEST legacy
    /// entry over to "macOS" (an explicit "macOS" value already present
    /// wins), then drop every legacy key.
    static func migrateEnabledSources(_ sources: [String: Bool]) -> [String: Bool] {
        let legacyKeys = sources.keys.filter(isLegacyAppleMacName)
            .sorted { lhs, rhs in
                // Numeric compare on the suffix: "macOS 26" > "macOS 15" > "macOS 9"
                (Int(lhs.dropFirst(legacyPrefix.count)) ?? 0) > (Int(rhs.dropFirst(legacyPrefix.count)) ?? 0)
            }
        guard !legacyKeys.isEmpty else { return sources }
        var out = sources
        if out[newName] == nil, let newest = legacyKeys.first, let value = sources[newest] {
            out[newName] = value
        }
        for key in legacyKeys { out.removeValue(forKey: key) }
        return out
    }

    /// Rotation / playlist filter strings: `source:macOS 26` → `source:macOS`.
    /// Other prefixes (location:, time:, scene:…) pass through; the result
    /// is deduplicated with the original order kept.
    static func migrateFilterStrings(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for string in strings {
            var value = string
            if string.hasPrefix(sourceFilterPrefix),
               isLegacyAppleMacName(String(string.dropFirst(sourceFilterPrefix.count))) {
                value = sourceFilterPrefix + newName
            }
            if seen.insert(value).inserted { out.append(value) }
        }
        return out
    }

    /// Rewrites every playlist's filter strings; returns how many changed.
    static func migratePlaylists(_ state: inout PlaylistState) -> Int {
        var touched = 0
        if let shared = state.sharedPlaylist {
            let migrated = migrateFilterStrings(shared.filterStrings)
            if migrated != shared.filterStrings {
                state.sharedPlaylist?.filterStrings = migrated
                touched += 1
            }
        }
        for (uuid, playlist) in state.screenPlaylists {
            let migrated = migrateFilterStrings(playlist.filterStrings)
            if migrated != playlist.filterStrings {
                state.screenPlaylists[uuid]?.filterStrings = migrated
                touched += 1
            }
        }
        return touched
    }

    /// Runs once per install (flag in UserDefaults). Safe to call before
    /// VideoList / PlaylistManager exist — it only touches the JSON files
    /// through the same stores they use.
    static func applyIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: userDefaultsKey) else { return }

        let enabledBefore = PrefsVideos.enabledSources
        let enabledAfter = migrateEnabledSources(enabledBefore)
        if enabledAfter != enabledBefore { PrefsVideos.enabledSources = enabledAfter }

        let rotationBefore = PrefsVideos.newShouldPlayString
        let rotationAfter = migrateFilterStrings(rotationBefore)
        if rotationAfter != rotationBefore { PrefsVideos.newShouldPlayString = rotationAfter }

        var playlistsTouched = 0
        if var state = JSONPreferencesStore.shared.read(PlaylistState.self, from: PlaylistState.fileURL) {
            playlistsTouched = migratePlaylists(&state)
            if playlistsTouched > 0 {
                JSONPreferencesStore.shared.write(state, to: PlaylistState.fileURL)
            }
        }

        if enabledAfter != enabledBefore || rotationAfter != rotationBefore || playlistsTouched > 0 {
            let enabled = enabledAfter[newName].map { "\($0)" } ?? "default"
            debugLog("🍎 [AppleFeed] migrated source name → \(newName) (enabled=\(enabled), rotation filters=\(rotationAfter.count), playlists rewritten=\(playlistsTouched))")
        } else {
            debugLog("🍎 [AppleFeed] no legacy macOS source name in prefs — nothing to migrate")
        }
        defaults.set(true, forKey: userDefaultsKey)
    }
}
