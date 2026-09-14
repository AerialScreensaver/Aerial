//
//  PoiStringProvider.swift
//  Aerial
//
//  Created by Guillaume Louel on 13/10/2018.
//  Copyright © 2018 John Coates. All rights reserved.
//

import Foundation

final class PoiStringProvider {
    static let sharedInstance = PoiStringProvider()

    private let lock = NSLock()
    private var loadAttempted = false
    private var stringBundle: Bundle?

    /// Probed in priority order. macOS 26 wins; tvOS 26 is a fallback when
    /// the user has disabled the macOS 26 source but kept tvOS 26 enabled
    /// (the two ship identical-content TVIdleScreenStrings.bundles).
    private static let bundleSearchPaths = ["macOS 26", "tvOS 26"]

    /// Languages shipped inside TVIdleScreenStrings.bundle. Used to map the
    /// user's preferred languages onto an available `.lproj` directory.
    private static let supportedLanguages: [String] = [
        "de", "he", "en_AU", "ar", "el", "ja", "en", "uk", "es_419", "zh_CN",
        "es", "pt_BR", "da", "it", "sk", "pt_PT", "ms", "sv", "cs", "ko",
        "no", "hu", "zh_HK", "tr", "pl", "zh_TW", "en_GB", "vi", "ru",
        "fr_CA", "fr", "fi", "id", "nl", "th", "pt", "ro", "hr", "hi", "ca",
    ]

    /// Lazy + thread-safe bundle access. First call attempts the load; later
    /// calls return the cached bundle (or nil if every probed path failed).
    private func bundle() -> Bundle? {
        lock.lock()
        defer { lock.unlock() }
        if loadAttempted { return stringBundle }
        loadAttempted = true
        stringBundle = loadBundle()
        return stringBundle
    }

    private func loadBundle() -> Bundle? {
        let override = PrefsAdvanced.ciOverrideLanguage
        let preferences = override.isEmpty ? Locale.preferredLanguages : [override]
        let lang = Bundle.preferredLocalizations(from: Self.supportedLanguages, forPreferences: preferences).first

        for source in Self.bundleSearchPaths {
            let base = Cache.supportPath.appending("/Sources/\(source)/TVIdleScreenStrings.bundle")
            let path = lang.map { "\(base)/\($0).lproj/" } ?? base
            if let b = Bundle(path: path) {
                debugLog("📚 Loaded TVIdleScreenStrings from \(source) (lang: \(lang ?? "default"))")
                return b
            }
        }
        errorLog("📚 TVIdleScreenStrings.bundle not found in any of \(Self.bundleSearchPaths)")
        return nil
    }

    /// Localized POI text for an Apple key. Bundle miss / missing-bundle
    /// returns the key verbatim — that's the path source-bundled English
    /// POI text (e.g. community packs) follows.
    func getString(_ key: String) -> String {
        guard let b = bundle() else { return key }
        return b.localizedString(forKey: key, value: "", table: "Localizable.nocache")
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
