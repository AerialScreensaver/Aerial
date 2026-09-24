//
//  LegacySaverPrefsTests.swift
//  AerialTests
//
//  The 3.x saver prefs reader behind the wizard's custom-cache import:
//  every encoding the old `@SimpleStorage` wrapper produced, the
//  flag-required rule, the `<supportPath>/Aerial` root, and the
//  existence rule.
//

import Foundation
import Testing
@testable import Aerial

@Suite("Legacy 3.x saver prefs")
struct LegacySaverPrefsTests {

    private let drive = "/Volumes/X/AerialData"

    private func tempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "LegacySaverPrefsTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func bookmark(of dir: String) throws -> Data {
        try URL(fileURLWithPath: dir, isDirectory: true).bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    @Test("native values (3.6): the root is the chosen folder plus Aerial")
    func nativeValues() throws {
        let dir = try tempDir()
        let prefs = LegacySaverPrefs.parse([
            "overrideCache": true,
            "supportPath": drive,
            "supportBookmarkData": try bookmark(of: dir)
        ])
        #expect(prefs.overrideCache)
        #expect(prefs.supportPath == drive)
        #expect(prefs.supportBookmarkData?.isEmpty == false)
        #expect(prefs.hasOverride)
        #expect(prefs.customRoot == drive + "/Aerial")
        #expect(prefs.customCacheFolder == drive + "/Aerial/Cache")
    }

    @Test("JSON-encoded strings decode to the same values")
    func jsonStrings() {
        let base64 = Data("book".utf8).base64EncodedString()
        let prefs = LegacySaverPrefs.parse([
            "overrideCache": "true",
            "supportPath": "\"\(drive)\"",
            "supportBookmarkData": "\"\(base64)\""
        ])
        #expect(prefs.overrideCache)
        #expect(prefs.supportPath == drive)
        #expect(prefs.supportBookmarkData == Data("book".utf8))
        #expect(prefs.customCacheFolder == drive + "/Aerial/Cache")
    }

    @Test("JSON data blobs decode to the same values")
    func jsonBlobs() {
        let base64 = Data("book".utf8).base64EncodedString()
        let prefs = LegacySaverPrefs.parse([
            "overrideCache": Data("true".utf8),
            "supportPath": Data("\"\(drive)\"".utf8),
            "supportBookmarkData": Data("\"\(base64)\"".utf8)
        ])
        #expect(prefs.overrideCache)
        #expect(prefs.supportPath == drive)
        #expect(prefs.supportBookmarkData == Data("book".utf8))
    }

    @Test("the flag is required: a folder alone is not an override")
    func flagRequired() throws {
        let dir = try tempDir()
        let noFlag = LegacySaverPrefs.parse(["supportPath": dir, "supportBookmarkData": try bookmark(of: dir)])
        #expect(!noFlag.hasOverride)
        #expect(noFlag.customCacheFolder == nil)
        #expect(noFlag.customRoot?.hasSuffix("/Aerial") == true)   // the root is still known

        let off = LegacySaverPrefs.parse(["overrideCache": "false", "supportPath": dir])
        #expect(!off.hasOverride)
        #expect(off.customCacheFolder == nil)
    }

    @Test("the path string wins; an empty string falls back to the bookmark; junk gives nothing")
    func stringBeforeBookmark() throws {
        let dir = try tempDir()
        let name = (dir as NSString).lastPathComponent
        let mark = try bookmark(of: dir)

        let both = LegacySaverPrefs.parse(["overrideCache": true, "supportPath": drive, "supportBookmarkData": mark])
        #expect(both.customRoot == drive + "/Aerial")

        let bookmarkOnly = LegacySaverPrefs.parse(["overrideCache": true, "supportPath": "", "supportBookmarkData": mark])
        #expect(bookmarkOnly.customRoot?.hasSuffix("/" + name + "/Aerial") == true)

        let junk = LegacySaverPrefs.parse(["overrideCache": true, "supportBookmarkData": Data("nope".utf8)])
        #expect(junk.customRoot == nil)
        #expect(!junk.hasOverride)

        #expect(LegacySaverPrefs.parse([:]) == LegacySaverPrefs(overrideCache: false, supportPath: nil, supportBookmarkData: nil))
    }

    @Test("trailing slashes and the /Users/Shared root")
    func normalisation() {
        let slash = LegacySaverPrefs.parse(["overrideCache": true, "supportPath": drive + "/"])
        #expect(slash.customCacheFolder == drive + "/Aerial/Cache")

        // 3.x users who shared /Users/Shared between the saver and the
        // companion land on 4.x's default cache — nothing to import.
        let shared = LegacySaverPrefs.parse(["overrideCache": true, "supportPath": "/Users/Shared"])
        #expect(shared.customCacheFolder == Cache.defaultCachePath)
        #expect(shared.importableCacheFolder() == nil)
    }

    @Test("existence rule: an existing cache, or an unplugged /Volumes root")
    func importable() {
        #expect(LegacySaverPrefs.isImportable(root: "/Users/me/AerialQA/Aerial", rootExists: true, cacheIsDirectory: true))
        #expect(LegacySaverPrefs.isImportable(root: "/Volumes/X/Aerial", rootExists: false, cacheIsDirectory: false))
        #expect(!LegacySaverPrefs.isImportable(root: "/Users/me/AerialQA/Aerial", rootExists: false, cacheIsDirectory: false))
        #expect(!LegacySaverPrefs.isImportable(root: "/Volumes/X/Aerial", rootExists: true, cacheIsDirectory: false))
    }

    @Test("importable folder on disk: needs <root>/Cache to be a directory")
    func importableOnDisk() throws {
        let dir = try tempDir()
        let prefs = LegacySaverPrefs.parse(["overrideCache": true, "supportPath": dir])
        #expect(prefs.importableCacheFolder() == nil)   // root exists, no Cache yet

        try FileManager.default.createDirectory(atPath: dir + "/Aerial/Cache", withIntermediateDirectories: true)
        #expect(prefs.importableCacheFolder() == dir + "/Aerial/Cache")
    }

    @Test("load: first candidate that parses, binary plist round trip")
    func load() throws {
        let dir = try tempDir()
        let plistPath = dir + "/com.glouel.Aerial.plist"
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["overrideCache": true, "supportPath": drive, "debugMode": true],
            format: .binary, options: 0)
        try data.write(to: URL(fileURLWithPath: plistPath))

        guard case .found(let loaded) = LegacySaverPrefs.load(candidates: [dir + "/missing.plist", plistPath]) else {
            Issue.record("expected the readable plist to be found")
            return
        }
        #expect(loaded.path == plistPath)
        #expect(loaded.prefs.customCacheFolder == drive + "/Aerial/Cache")
        #expect(LegacySaverPrefs.load(candidates: [dir + "/missing.plist"]) == .none)
    }

    @Test("load: an unreadable plist is a denial, never a fallback to the next candidate")
    func loadDenied() throws {
        let dir = try tempDir()
        let locked = dir + "/locked.plist"
        let readable = dir + "/readable.plist"
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["overrideCache": true, "supportPath": drive], format: .binary, options: 0)
        try data.write(to: URL(fileURLWithPath: locked))
        try data.write(to: URL(fileURLWithPath: readable))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked) }

        #expect(LegacySaverPrefs.load(candidates: [locked, readable]) == .denied(path: locked))
    }
}
