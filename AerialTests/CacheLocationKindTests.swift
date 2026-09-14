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
        Cache.classify(overrideCache: override, cachePath: path, externalCacheImagePath: image, mountPoint: mount)
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

    @Test("a plain /Volumes folder without an image is the 4.0 layout")
    func legacyExternalFolder() {
        #expect(kind(true, "/Volumes/X/Aerial", nil) == .legacyExternalFolder("/Volumes/X/Aerial"))
        #expect(kind(true, "/Volumes/X/Aerial", "") == .legacyExternalFolder("/Volumes/X/Aerial"))
        #expect(kind(true, "/Volumes/X/Aerial/", nil) == .legacyExternalFolder("/Volumes/X/Aerial/"))
    }

    @Test("custom folders elsewhere stay custom, including the bare mount point")
    func customFolders() {
        #expect(kind(true, "/Users/me/Movies/Aerial", nil) == .customFolder("/Users/me/Movies/Aerial"))
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

    @Test("volume membership for mount notifications")
    func volumeMembership() {
        let volume = URL(fileURLWithPath: "/Volumes/X", isDirectory: true)
        #expect(LegacyExternalCacheMigration.folder("/Volumes/X/Aerial", isOn: volume))
        #expect(LegacyExternalCacheMigration.folder("/Volumes/X", isOn: volume))
        #expect(!LegacyExternalCacheMigration.folder("/Volumes/XY/Aerial", isOn: volume))
        #expect(!LegacyExternalCacheMigration.folder("/Users/Shared/Aerial/Cache", isOn: volume))
    }
}
