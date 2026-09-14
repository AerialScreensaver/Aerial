//
//  PoiStringTableTests.swift
//  AerialTests
//
//  TVIdleScreenStrings.bundle comes in two layouts (flat `<lang>.lproj`
//  up to macOS 26, `Contents/Resources/*.loctable` from macOS 27). The
//  table loader must read both and pick the language the same way.
//

import Foundation
import Testing
@testable import Aerial

@Suite("POI string table")
struct PoiStringTableTests {

    private func tempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "PoiStringTableTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writePlist(_ object: Any, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// macOS 27 layout: one loctable, empty lproj dirs, a housekeeping key.
    private func makeLoctableBundle() throws -> String {
        let bundle = try tempDir() + "/TVIdleScreenStrings.bundle"
        let table: [String: Any] = [
            "en": ["GG_A_DAY_NAME": "Golden Gate Day", "AerialCategoryDynamic": "Dynamic Wallpapers", "Nested": ["not": "a string"]],
            "fr": ["GG_A_DAY_NAME": "Golden Gate le jour"],
            "en_GB": ["GG_A_DAY_NAME": "Golden Gate Day (GB)"],
            "LocProvenance": ["some": "metadata"],
        ]
        try writePlist(table, to: bundle + "/" + PoiStringTable.loctableRelativePath)
        for lang in ["en", "fr", "en_GB"] {
            try FileManager.default.createDirectory(atPath: bundle + "/Contents/Resources/\(lang).lproj",
                                                    withIntermediateDirectories: true)
        }
        return bundle
    }

    /// macOS 26 layout: `<lang>.lproj/Localizable.nocache.strings` binary plists.
    private func makeLegacyBundle() throws -> String {
        let bundle = try tempDir() + "/TVIdleScreenStrings.bundle"
        try writePlist(["TA_L_002_NAME": "Tahoe Day"], to: bundle + "/en.lproj/Localizable.nocache.strings")
        try writePlist(["TA_L_002_NAME": "Tahoe le jour"], to: bundle + "/fr.lproj/Localizable.nocache.strings")
        try FileManager.default.createDirectory(atPath: bundle + "/_CodeSignature", withIntermediateDirectories: true)
        return bundle
    }

    @Test("loctable layout: locales exclude housekeeping keys")
    func loctableLocales() throws {
        let bundle = try makeLoctableBundle()
        #expect(PoiStringTable.availableLocales(bundleDir: bundle) == ["en", "en_GB", "fr"])
    }

    @Test("loctable layout: loads the picked locale, drops non-string values")
    func loctableLoad() throws {
        let bundle = try makeLoctableBundle()
        let loaded = try #require(PoiStringTable.load(bundleDir: bundle, preferredLanguages: ["fr"]))
        #expect(loaded.locale == "fr")
        #expect(loaded.table["GG_A_DAY_NAME"] == "Golden Gate le jour")

        let english = try #require(PoiStringTable.load(bundleDir: bundle, locale: "en"))
        #expect(english["AerialCategoryDynamic"] == "Dynamic Wallpapers")
        #expect(english["Nested"] == nil)
    }

    @Test("legacy layout: locales come from lproj dirs that hold the table")
    func legacyLocales() throws {
        let bundle = try makeLegacyBundle()
        #expect(PoiStringTable.availableLocales(bundleDir: bundle) == ["en", "fr"])
        let loaded = try #require(PoiStringTable.load(bundleDir: bundle, preferredLanguages: ["fr-FR"]))
        #expect(loaded.locale == "fr")
        #expect(loaded.table["TA_L_002_NAME"] == "Tahoe le jour")
    }

    @Test("locale pick: override first, then en, then anything")
    func localePick() {
        let available = ["en", "en_GB", "fr", "zh_CN"]
        #expect(PoiStringTable.pickLocale(available: available, preferredLanguages: ["fr"]) == "fr")
        #expect(PoiStringTable.pickLocale(available: available, preferredLanguages: ["en-GB"]) == "en_GB")
        #expect(PoiStringTable.pickLocale(available: available, preferredLanguages: ["xx"]) == "en")
        #expect(PoiStringTable.pickLocale(available: ["de"], preferredLanguages: ["xx"]) == "de")
        #expect(PoiStringTable.pickLocale(available: [], preferredLanguages: ["en"]) == nil)
    }

    @Test("missing bundle yields nil, not an empty table")
    func missingBundle() throws {
        let dir = try tempDir()
        #expect(PoiStringTable.availableLocales(bundleDir: dir + "/nope.bundle").isEmpty)
        #expect(PoiStringTable.load(bundleDir: dir + "/nope.bundle", preferredLanguages: ["en"]) == nil)
    }
}
