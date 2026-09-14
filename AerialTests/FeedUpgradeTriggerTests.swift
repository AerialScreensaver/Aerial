//
//  FeedUpgradeTriggerTests.swift
//  AerialTests
//
//  The tar left behind in a source folder is the "installed feed"
//  marker; a build pointing at a different tar name must trigger a
//  re-fetch regardless of the weekly refresh window.
//

import Foundation
import Testing
@testable import Aerial

@Suite("Feed upgrade trigger")
struct FeedUpgradeTriggerTests {

    private func tempRoot() throws -> String {
        let dir = NSTemporaryDirectory() + "FeedUpgradeTriggerTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func appleSource(root: String, tar: String = "resources-27-0-1.tar") -> Source {
        var source = Source(name: "feedtest", description: "", manifestUrl: "https://example.invalid/a/b/\(tar)",
                            type: .macOS, scenes: [.nature], isCachable: true, license: "", more: "")
        source.rootPath = root
        return source
    }

    @Test("marker path is the tar name inside the source folder; nil for non-tar sources")
    func markerPath() throws {
        let root = try tempRoot()
        #expect(appleSource(root: root).feedMarkerPath == root + "/feedtest/resources-27-0-1.tar")

        var pack = Source(name: "pack", description: "", manifestUrl: "https://example.invalid/pack/entries.json",
                          type: .tvOS12, scenes: [.nature], isCachable: false, license: "", more: "")
        pack.rootPath = root
        #expect(pack.feedMarkerPath == nil)

        var local = Source(name: "My Videos", description: "", manifestUrl: "/Users/Shared/Aerial/My Videos",
                           type: .local, scenes: [.nature], isCachable: false, license: "", more: "")
        local.rootPath = root
        #expect(local.feedMarkerPath == nil)
        #expect(!local.needsFeedUpgrade())
    }

    @Test("not cached → no upgrade (the plain download path handles it)")
    func notCached() throws {
        let root = try tempRoot()
        #expect(!appleSource(root: root).needsFeedUpgrade())
    }

    @Test("cached with the old tar → upgrade; with the wanted tar → nothing")
    func cachedStates() throws {
        let root = try tempRoot()
        let source = appleSource(root: root)
        let folder = root + "/feedtest"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: folder + "/entries.json"))
        try Data().write(to: URL(fileURLWithPath: folder + "/resources-26-0-1.tar"))
        #expect(source.needsFeedUpgrade())

        try Data().write(to: URL(fileURLWithPath: folder + "/resources-27-0-1.tar"))
        #expect(!source.needsFeedUpgrade())
    }

    @Test("staged install rejects a bad tar and keeps the current entries.json")
    func stagedInstallKeepsCurrentOnFailure() throws {
        let root = try tempRoot()
        let folder = root + "/feedtest"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let current = "{\"assets\": [{\"id\": \"keep\", \"url-4K-SDR-240FPS\": \"https://example.invalid/k.mov\"}], \"categories\": []}"
        try Data(current.utf8).write(to: URL(fileURLWithPath: folder + "/entries.json"))
        let badTar = folder + "/resources-27-0-1.tar"
        try Data("<html>not a tar</html>".utf8).write(to: URL(fileURLWithPath: badTar))

        #expect(!FileHelpers.installFeedArchive(tar: badTar, into: folder))
        #expect(String(data: try Data(contentsOf: URL(fileURLWithPath: folder + "/entries.json")), encoding: .utf8) == current)
        #expect(!FileManager.default.fileExists(atPath: badTar))
        #expect(!FileManager.default.fileExists(atPath: folder + "/.staging"))
        #expect(appleSource(root: root).needsFeedUpgrade())
    }

    @Test("staged install swaps entries + strings bundle and leaves only the new tar")
    func stagedInstallSucceeds() throws {
        let root = try tempRoot()
        let folder = root + "/feedtest"
        let fm = FileManager.default
        try fm.createDirectory(atPath: folder + "/TVIdleScreenStrings.bundle/en.lproj", withIntermediateDirectories: true)
        try Data("old".utf8).write(to: URL(fileURLWithPath: folder + "/TVIdleScreenStrings.bundle/en.lproj/Localizable.nocache.strings"))
        try Data("{\"assets\": [{\"id\": \"old\", \"url-4K-SDR-240FPS\": \"https://example.invalid/o.mov\"}], \"categories\": []}".utf8)
            .write(to: URL(fileURLWithPath: folder + "/entries.json"))
        try Data().write(to: URL(fileURLWithPath: folder + "/resources-26-0-1.tar"))

        // Build a real tar with the macOS 27 layout.
        let payload = root + "/payload"
        try fm.createDirectory(atPath: payload + "/TVIdleScreenStrings.bundle/Contents/Resources/en.lproj", withIntermediateDirectories: true)
        try Data("new".utf8).write(to: URL(fileURLWithPath: payload + "/TVIdleScreenStrings.bundle/Contents/Resources/Localizable.nocache.loctable"))
        try Data("{\"assets\": [{\"id\": \"new\", \"url-4K-SDR-240FPS\": \"https://example.invalid/n.mov\"}], \"categories\": []}".utf8)
            .write(to: URL(fileURLWithPath: payload + "/entries.json"))
        let tar = folder + "/resources-27-0-1.tar"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.currentDirectoryPath = payload
        process.arguments = ["-cf", tar, "entries.json", "TVIdleScreenStrings.bundle"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        #expect(FileHelpers.installFeedArchive(tar: tar, into: folder))
        let entries = try String(contentsOfFile: folder + "/entries.json", encoding: .utf8)
        #expect(entries.contains("\"new\""))
        #expect(fm.fileExists(atPath: folder + "/TVIdleScreenStrings.bundle/Contents/Resources/Localizable.nocache.loctable"))
        #expect(!fm.fileExists(atPath: folder + "/TVIdleScreenStrings.bundle/en.lproj"))
        #expect(!fm.fileExists(atPath: folder + "/resources-26-0-1.tar"))
        #expect(fm.fileExists(atPath: tar))
        #expect(!fm.fileExists(atPath: folder + "/.staging"))
        #expect(!appleSource(root: root).needsFeedUpgrade())
    }
}
