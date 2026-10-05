//
//  LegacyContainerAccessTests.swift
//  AerialTests
//
//  Plan B of the 3.x migration — the staging folder the user drags the old
//  files into: what counts as content, where the 3.x layout starts, where
//  a dropped prefs plist is found, the layout move itself, and the cleanup
//  rule. Everything runs on temporary folders.
//

import Foundation
import Testing
@testable import Aerial

@Suite("Legacy container access — staging folder")
struct LegacyContainerAccessTests {

    private func tempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "LegacyContainerAccessTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeDir(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private func makeFile(_ path: String, _ contents: String = "x") throws {
        try makeDir((path as NSString).deletingLastPathComponent)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test("Finder droppings and 3.x leftovers are not content")
    func contentRule() {
        #expect(!LegacyContainerAccess.stagingHasContent(entries: []))
        #expect(!LegacyContainerAccess.stagingHasContent(entries: [".DS_Store", ".localized", "AerialLog.txt", "Weather.json"]))
        #expect(LegacyContainerAccess.stagingHasContent(entries: [".DS_Store", "Cache"]))
        #expect(LegacyContainerAccess.stagingHasContent(entries: ["Aerial"]))
        #expect(LegacyContainerAccess.stagingLeftovers(entries: ["Weather.json", "Thumbnails", ".DS_Store", "Cache"]) == ["Cache", "Thumbnails"])
    }

    @Test("the layout starts at the staging root, or inside a dragged Aerial folder")
    func sourceRoot() throws {
        let flat = try tempDir()
        try makeDir(flat + "/Cache")
        #expect(LegacyContainerAccess.stagedSourceRoot(in: flat) == flat)

        let nested = try tempDir()
        try makeDir(nested + "/Aerial/Cache")
        #expect(LegacyContainerAccess.stagedSourceRoot(in: nested) == nested + "/Aerial")

        let both = try tempDir()
        try makeDir(both + "/Thumbnails")
        try makeDir(both + "/Aerial/Cache")
        #expect(LegacyContainerAccess.stagedSourceRoot(in: both) == both)

        let empty = try tempDir()
        #expect(LegacyContainerAccess.stagedSourceRoot(in: empty) == empty)
    }

    @Test("a dropped prefs plist is found at the root or inside Preferences/")
    func stagedPrefs() throws {
        let plist: [String: Any] = ["overrideCache": true, "supportPath": "/Users/Shared/Aerial3"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        let atRoot = try tempDir()
        try data.write(to: URL(fileURLWithPath: atRoot + "/com.glouel.Aerial.plist"))
        guard case .found(let rootLoaded) = LegacySaverPrefs.load(candidates: LegacyContainerAccess.stagedPrefsCandidates(for: atRoot)) else {
            Issue.record("plist at the staging root not found"); return
        }
        #expect(rootLoaded.path == atRoot + "/com.glouel.Aerial.plist")
        #expect(rootLoaded.prefs.customRoot == "/Users/Shared/Aerial3/Aerial")

        let inFolder = try tempDir()
        try makeDir(inFolder + "/Preferences")
        try data.write(to: URL(fileURLWithPath: inFolder + "/Preferences/com.glouel.Aerial.plist"))
        guard case .found(let folderLoaded) = LegacySaverPrefs.load(candidates: LegacyContainerAccess.stagedPrefsCandidates(for: inFolder)) else {
            Issue.record("plist inside Preferences/ not found"); return
        }
        #expect(folderLoaded.path == inFolder + "/Preferences/com.glouel.Aerial.plist")

        let none = try tempDir()
        #expect(LegacySaverPrefs.load(candidates: LegacyContainerAccess.stagedPrefsCandidates(for: none)) == .none)
    }

    @Test("the layout move sorts Cache, Thumbnails and sources; skipped folders and files stay")
    func layoutMove() throws {
        let src = try tempDir()
        let dst = try tempDir()
        try makeFile(src + "/Cache/a.mov")
        try makeFile(src + "/Thumbnails/t.jpg")
        try makeFile(src + "/macOS 26/x.json")
        try makeFile(src + "/Preferences/com.glouel.Aerial.plist")
        try makeFile(src + "/AerialLog.txt")
        try makeDir(dst + "/Sources")

        var log: [String] = []
        try PathMigration.moveContainerContents(from: src, to: dst, skipping: ["Preferences"],
                                                log: &log, progress: { _ in })

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dst + "/Cache/a.mov"))
        #expect(fm.fileExists(atPath: dst + "/Thumbnails/t.jpg"))
        #expect(fm.fileExists(atPath: dst + "/Sources/macOS 26/x.json"))
        #expect(fm.fileExists(atPath: src + "/Preferences/com.glouel.Aerial.plist"))
        #expect(fm.fileExists(atPath: src + "/AerialLog.txt"))
        #expect(!fm.fileExists(atPath: dst + "/Sources/Preferences"))
        #expect(log.filter { $0.hasPrefix("✓ Moved") }.count == 3)

        let left = LegacyContainerAccess.stagingLeftovers(entries: try fm.contentsOfDirectory(atPath: src))
        #expect(left == ["Preferences"])
    }

    @Test("the staging folder goes away only when nothing meaningful is left")
    func cleanupRule() throws {
        let fm = FileManager.default

        let spent = try tempDir()
        try makeFile(spent + "/.DS_Store")
        try makeFile(spent + "/AerialLog.txt")
        #expect(LegacyContainerAccess.removeStagingIfEmpty(path: spent))
        #expect(!fm.fileExists(atPath: spent))

        let busy = try tempDir()
        try makeFile(busy + "/Cache/a.mov")
        #expect(!LegacyContainerAccess.removeStagingIfEmpty(path: busy))
        #expect(fm.fileExists(atPath: busy + "/Cache/a.mov"))
    }
}
