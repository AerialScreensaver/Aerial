//
//  CacheLocationKindTests.swift
//  AerialTests
//
//  The cache-location classifier behind `Cache.isAvailable` /
//  `resolveCachePath` / the 4.0 → 4.1 external-cache offer, plus the
//  pure helpers of the migration.
//

import Foundation
import Testing
@testable import Aerial

@Suite("Cache location kind")
struct CacheLocationKindTests {

    private let mount = "/Users/Shared/Aerial/ExternalCache"

    private func kind(_ override: Bool, _ path: String?, _ image: String?) -> Cache.LocationKind {
        Cache.classify(overrideCache: override, cachePath: path, externalCacheImagePath: image)
    }

    @Test("override off is internal, whatever else is set")
    func internalWhenOverrideOff() {
        #expect(kind(false, nil, nil) == .internalFolder)
        #expect(kind(false, "/Volumes/X/Aerial", "/Volumes/X/Aerial/Aerial Cache.sparsebundle") == .internalFolder)
    }

    @Test("an image path wins over the cache path")
    func imageMode() {
        let image = "/Volumes/X/Aerial/Aerial Cache.sparsebundle"
        #expect(kind(true, mount, image) == .externalImage(image))
        #expect(kind(true, nil, image) == .externalImage(image))
    }

    @Test("a plain location outside /Users/Shared without an image needs conversion")
    func legacyExternalFolder() {
        #expect(kind(true, "/Volumes/X/Aerial", nil) == .legacyExternalFolder("/Volumes/X/Aerial"))
        #expect(kind(true, "/Volumes/X/Aerial", "") == .legacyExternalFolder("/Volumes/X/Aerial"))
        #expect(kind(true, "/Volumes/X/Aerial/", nil) == .legacyExternalFolder("/Volumes/X/Aerial/"))
        #expect(kind(true, "/Users/me/Aerial/Cache", nil) == .legacyExternalFolder("/Users/me/Aerial/Cache"))
    }

    @Test("only shared folders stay directly readable by the extension")
    func customFolders() {
        #expect(kind(true, "/Users/Shared/Aerial/Other", nil) == .customFolder("/Users/Shared/Aerial/Other"))
        #expect(kind(true, mount, nil) == .customFolder(mount))
        #expect(kind(true, mount + "/Cache", nil) == .customFolder(mount + "/Cache"))
        #expect(kind(true, "", nil) == .internalFolder)
        #expect(kind(true, nil, nil) == .internalFolder)
    }

    @Test("sibling videos and inventory ignore hidden files and non-videos")
    func inventory() throws {
        let dir = NSTemporaryDirectory() + "CacheLocationKindTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1000).write(to: URL(fileURLWithPath: dir + "/b.mov"))
        try Data(repeating: 0, count: 500).write(to: URL(fileURLWithPath: dir + "/a.mov"))
        try Data(repeating: 0, count: 700).write(to: URL(fileURLWithPath: dir + "/.hidden.mov"))
        try Data("x".utf8).write(to: URL(fileURLWithPath: dir + "/notes.txt"))
        try FileManager.default.createDirectory(atPath: dir + "/Aerial Cache.sparsebundle", withIntermediateDirectories: true)

        #expect(ExternalCacheImage.siblingVideos(inFolder: dir) == ["a.mov", "b.mov"])
        let inventory = LegacyExternalCacheMigration.inventory(folder: dir)
        #expect(inventory.count == 2)
        #expect(inventory.bytes == 1500)
        #expect(ExternalCacheImage.siblingVideos(inFolder: dir + "/nope").isEmpty)
        #expect(LegacyExternalCacheMigration.inventory(folder: dir + "/nope") == .init(count: 0, bytes: 0))
    }

    @Test("sibling packs are the visible folders under Expansions/")
    func siblingPacks() throws {
        let dir = NSTemporaryDirectory() + "CacheLocationKindTests-" + UUID().uuidString
        let packs = dir + "/Expansions"
        for name in ["B Pack", "A Pack", ".hidden"] {
            try FileManager.default.createDirectory(atPath: packs + "/" + name, withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: URL(fileURLWithPath: packs + "/notes.txt"))

        #expect(ExternalCacheImage.siblingPacks(inFolder: dir) == ["A Pack", "B Pack"])
        #expect(ExternalCacheImage.siblingPacks(inFolder: dir + "/nope").isEmpty)
    }

    @Test("volume membership for mount notifications")
    func volumeMembership() {
        let volume = URL(fileURLWithPath: "/Volumes/X", isDirectory: true)
        #expect(LegacyExternalCacheMigration.folder("/Volumes/X/Aerial", isOn: volume))
        #expect(LegacyExternalCacheMigration.folder("/Volumes/X", isOn: volume))
        #expect(!LegacyExternalCacheMigration.folder("/Volumes/XY/Aerial", isOn: volume))
        #expect(!LegacyExternalCacheMigration.folder("/Users/Shared/Aerial/Cache", isOn: volume))
    }

    @Test("cards per folder: move first on the boot volume, image first on a drive")
    func legacyCacheChoices() {
        let drive = "/Volumes/X/Aerial"
        let home = "/Users/me/Aerial/Cache"
        #expect(LegacyCacheChoice.cases(for: drive) == [.convert, .useInternal, .later])
        #expect(LegacyCacheChoice.cases(for: home) == [.moveToDefault, .convert, .later])
        for folder in [drive, home] {
            let cases = LegacyCacheChoice.cases(for: folder)
            #expect(LegacyCacheChoice.recommended(for: folder) == cases[0])
            #expect(cases.filter { $0.tagline(folder: folder).hasPrefix("Recommended") } == [cases[0]])
        }
        #expect(LegacyCacheChoice.moveToDefault.actionButtonTitle == "Move Now")
        #expect(LegacyCacheChoice.convert.actionButtonTitle == "Convert Now")
        #expect(LegacyCacheChoice.useInternal.actionButtonTitle == nil)
        #expect(LegacyCacheChoice.later.actionButtonTitle == nil)
    }

    @Test("move plan: videos to the cache, packs to the sources root, hidden items ignored")
    func moveToDefaultPlan() throws {
        let dir = NSTemporaryDirectory() + "CacheLocationKindTests-" + UUID().uuidString
        let packs = dir + "/Expansions"
        for name in ["Pack B", "Pack A", ".hidden"] {
            try FileManager.default.createDirectory(atPath: packs + "/" + name, withIntermediateDirectories: true)
        }
        for name in ["b.mov", "a.mov", ".hidden.mov", "notes.txt"] {
            try Data("x".utf8).write(to: URL(fileURLWithPath: dir + "/" + name))
        }
        try Data("x".utf8).write(to: URL(fileURLWithPath: packs + "/readme.txt"))

        let jobs = LegacyExternalCacheMigration.plan(folder: dir, cacheDir: "/c", sourcesDir: "/s")
        #expect(jobs == [
            .init(src: dir + "/a.mov", dst: "/c/a.mov"),
            .init(src: dir + "/b.mov", dst: "/c/b.mov"),
            .init(src: packs + "/Pack A", dst: "/s/Pack A"),
            .init(src: packs + "/Pack B", dst: "/s/Pack B")
        ])
        #expect(LegacyExternalCacheMigration.plan(folder: dir + "/nope", cacheDir: "/c", sourcesDir: "/s").isEmpty)
    }
}
