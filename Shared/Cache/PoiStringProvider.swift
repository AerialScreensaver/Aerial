//
//  PoiStringProvider.swift
//  Aerial
//
//  Created by Guillaume Louel on 13/10/2018.
//  Copyright © 2018 John Coates. All rights reserved.
//

import Foundation

/// Reads Apple's `TVIdleScreenStrings.bundle` in both layouts Apple has
/// shipped, as plain plists (no `Bundle(path:)`):
///
/// * up to macOS 26: `<bundle>/<lang>.lproj/Localizable.nocache.strings`,
///   one binary-plist `.strings` per language;
/// * macOS 27+: `<bundle>/Contents/Resources/Localizable.nocache.loctable`,
///   one binary plist holding every locale keyed by locale id (plus a
///   `LocProvenance` housekeeping entry) — the `.lproj` dirs are EMPTY,
///   which is why the old `Bundle(path: "<bundle>/<lang>.lproj/")` probe
///   returns nil on it.
///
/// Language selection lives here too, so the "override language"
/// setting works the same on both layouts (`Bundle.localizedString`
/// would follow the process locale on the loctable one).
enum PoiStringTable {
    static let tableName = "Localizable.nocache"
    static let loctableRelativePath = "Contents/Resources/\(tableName).loctable"
    static let loctableHousekeepingKeys: Set<String> = ["LocProvenance"]

    private static func readLoctable(bundleDir: String) -> [String: Any]? {
        NSDictionary(contentsOfFile: bundleDir + "/" + loctableRelativePath) as? [String: Any]
    }

    /// Locale ids the bundle can serve (sorted, no preference applied).
    static func availableLocales(bundleDir: String) -> [String] {
        if let loctable = readLoctable(bundleDir: bundleDir) {
            return loctable.compactMap { key, value in
                (value is [String: Any] && !loctableHousekeepingKeys.contains(key)) ? key : nil
            }.sorted()
        }
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(atPath: bundleDir)) ?? []
        return items.compactMap { item -> String? in
            guard item.hasSuffix(".lproj") else { return nil }
            let lang = String(item.dropLast(".lproj".count))
            return fm.fileExists(atPath: bundleDir + "/" + item + "/\(tableName).strings") ? lang : nil
        }.sorted()
    }

    /// Picks a locale for `preferredLanguages` (an explicit override goes
    /// first in that list), falling back to `en`, then to whatever exists.
    static func pickLocale(available: [String], preferredLanguages: [String]) -> String? {
        guard !available.isEmpty else { return nil }
        if let best = Bundle.preferredLocalizations(from: available, forPreferences: preferredLanguages).first,
           available.contains(best) {
            return best
        }
        if available.contains("en") { return "en" }
        return available.first
    }

    /// The key → string table for one locale, or nil when the bundle (or
    /// that locale) isn't there. Non-string values are dropped.
    static func load(bundleDir: String, locale: String) -> [String: String]? {
        let raw: [String: Any]?
        if let loctable = readLoctable(bundleDir: bundleDir) {
            raw = loctable[locale] as? [String: Any]
        } else {
            raw = NSDictionary(contentsOfFile: bundleDir + "/\(locale).lproj/\(tableName).strings") as? [String: Any]
        }
        guard let raw = raw else { return nil }
        return raw.compactMapValues { $0 as? String }
    }

    /// Pick + load in one go; the locale is returned for logging.
    static func load(bundleDir: String, preferredLanguages: [String]) -> (locale: String, table: [String: String])? {
        let available = availableLocales(bundleDir: bundleDir)
        guard let locale = pickLocale(available: available, preferredLanguages: preferredLanguages),
              let table = load(bundleDir: bundleDir, locale: locale) else { return nil }
        return (locale, table)
    }
}

final class PoiStringProvider {
    static let sharedInstance = PoiStringProvider()

    private let lock = NSLock()
    private var loadAttempted = false
    private var table: [String: String] = [:]

    /// Probed in priority order. The Apple macOS source carries the
    /// canonical bundle; tvOS 26 is a fallback when the user disabled it
    /// (that bundle is a subset — none of the macOS 27+ keys).
    static let bundleSearchPaths = [SourceList.appleMacSourceName, "tvOS 26"]

    /// Lazy + thread-safe table access. First call attempts the load; later
    /// calls return the cached table (empty if every probed path failed).
    private func loadedTable() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if !loadAttempted {
            loadAttempted = true
            table = loadTable() ?? [:]
        }
        return table
    }

    /// Forget the cached table so the next lookup re-reads the bundle.
    /// Called after a feed install and on every catalog refresh — the
    /// strings for newly published assets live in the freshly extracted
    /// bundle, and the extension process outlives Companion's download.
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        loadAttempted = false
        table = [:]
    }

    private func loadTable() -> [String: String]? {
        let override = PrefsAdvanced.ciOverrideLanguage
        let preferences = override.isEmpty ? Locale.preferredLanguages : [override]

        for source in Self.bundleSearchPaths {
            // Resolve through the source's folder (root-aware); the Apple
            // sources searched here always live in the default root today.
            let folder = SourceList.list.first(where: { $0.name == source })?.folderPath
                ?? Cache.defaultSourcesRoot + "/\(source)"
            let bundleDir = folder + "/" + FileHelpers.feedStringsBundleName
            if let loaded = PoiStringTable.load(bundleDir: bundleDir, preferredLanguages: preferences) {
                debugLog("📚 Loaded TVIdleScreenStrings from \(source) (locale: \(loaded.locale), \(loaded.table.count) strings)")
                return loaded.table
            }
        }
        errorLog("📚 TVIdleScreenStrings.bundle not found in any of \(Self.bundleSearchPaths)")
        return nil
    }

    /// Localized POI text for an Apple key. Bundle miss / missing-bundle
    /// returns the key verbatim — that's the path source-bundled English
    /// POI text (e.g. community packs) follows.
    func getString(_ key: String) -> String {
        loadedTable()[key] ?? key
    }

    /// Same lookup, kept under a separate name for category subcategory
    /// names + asset titles in `Source.swift` callers.
    func getLocalizedNameKey(key: String) -> String {
        getString(key)
    }

    // MARK: - Language UI bridge (for AdvancedSettingsPanel)

    // swiftlint:disable:next cyclomatic_complexity
    func getLanguagePosition() -> Int {
        // The list is alphabetized based on their english name in the UI
        switch PrefsAdvanced.ciOverrideLanguage {
        case "ar":      return 1   // Arabic
        case "zh_CN":   return 2   // Chinese Simplified
        case "zh_TW":   return 3   // Chinese Traditional
        case "nl":      return 4   // Dutch
        case "en":      return 5   // English
        case "fr":      return 6   // French
        case "de":      return 7   // German
        case "he":      return 8   // Hebrew
        case "hu":      return 9   // Hungarian
        case "it":      return 10  // Italian
        case "ja":      return 11  // Japanese
        case "ko":      return 12  // Korean
        case "pl":      return 13  // Polish
        case "pt":      return 14  // Portuguese
        case "pt_BR":   return 15  // Portuguese (Brazil)
        case "ru":      return 16  // Russian
        case "es":      return 17  // Spanish
        case "sv":      return 18  // Swedish
        case "tl":      return 19  // Tagalog
        default:        return 0   // Preferred language
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    func getLanguageStringFromPosition(pos: Int) -> String {
        switch pos {
        case 1:  return "ar"
        case 2:  return "zh_CN"
        case 3:  return "zh_TW"
        case 4:  return "nl"
        case 5:  return "en"
        case 6:  return "fr"
        case 7:  return "de"
        case 8:  return "he"
        case 9:  return "hu"
        case 10: return "it"
        case 11: return "ja"
        case 12: return "ko"
        case 13: return "pl"
        case 14: return "pt"
        case 15: return "pt_BR"
        case 16: return "ru"
        case 17: return "es"
        case 18: return "sv"
        case 19: return "tl"
        default: return ""
        }
    }
}
