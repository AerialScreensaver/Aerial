//
//  JSONPreferencesStoreTests.swift
//  AerialTests
//
//  The store must tell "no file" apart from "a file we can't parse": the
//  settings managers fall back to defaults in both cases but may only
//  WRITE those defaults in the first. An undecodable file is quarantined
//  next to itself so the user's bytes survive. Everything runs on
//  temporary folders.
//

import Foundation
import Testing
@testable import Aerial

@Suite("JSONPreferencesStore — absent vs undecodable")
struct JSONPreferencesStoreTests {

    struct Doc: Codable, Equatable {
        var a: Int
    }

    private func tempFile() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("JSONPreferencesStoreTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    @Test("a missing file is absent, not an error")
    func absent() throws {
        let url = try tempFile()
        guard case .absent = JSONPreferencesStore.shared.readChecked(Doc.self, from: url) else {
            Issue.record("expected .absent")
            return
        }
        #expect(JSONPreferencesStore.shared.read(Doc.self, from: url) == nil)
    }

    @Test("a valid file decodes through both entry points")
    func value() throws {
        let url = try tempFile()
        #expect(JSONPreferencesStore.shared.write(Doc(a: 7), to: url))
        guard case .value(let doc) = JSONPreferencesStore.shared.readChecked(Doc.self, from: url) else {
            Issue.record("expected .value")
            return
        }
        #expect(doc == Doc(a: 7))
        #expect(JSONPreferencesStore.shared.read(Doc.self, from: url) == Doc(a: 7))
    }

    @Test("garbage is undecodable, read() still returns nil, and the bytes are untouched")
    func undecodable() throws {
        let url = try tempFile()
        try "{ not json".write(to: url, atomically: true, encoding: .utf8)
        guard case .undecodable = JSONPreferencesStore.shared.readChecked(Doc.self, from: url) else {
            Issue.record("expected .undecodable")
            return
        }
        #expect(JSONPreferencesStore.shared.read(Doc.self, from: url) == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
    }

    @Test("quarantine moves the file aside with a timestamped name and keeps the bytes")
    func quarantine() throws {
        let url = try tempFile()
        try "{ not json".write(to: url, atomically: true, encoding: .utf8)
        let when = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC

        let moved = try #require(JSONPreferencesStore.shared.quarantine(url, now: when))
        #expect(moved.lastPathComponent == "settings.corrupt-20231114-221320.json")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try String(contentsOf: moved, encoding: .utf8) == "{ not json")

        // The path is absent again, so defaults may now be written.
        guard case .absent = JSONPreferencesStore.shared.readChecked(Doc.self, from: url) else {
            Issue.record("expected .absent after quarantine")
            return
        }

        // A second quarantine within the same second must not collide.
        try "{ again".write(to: url, atomically: true, encoding: .utf8)
        let second = try #require(JSONPreferencesStore.shared.quarantine(url, now: when))
        #expect(second != moved)
        #expect(second.lastPathComponent.hasPrefix("settings.corrupt-20231114-221320-"))
        #expect(second.pathExtension == "json")
        #expect(try String(contentsOf: moved, encoding: .utf8) == "{ not json")
        #expect(try String(contentsOf: second, encoding: .utf8) == "{ again")
    }

    @Test("quarantine of a missing file fails cleanly")
    func quarantineMissing() throws {
        #expect(JSONPreferencesStore.shared.quarantine(try tempFile()) == nil)
    }
}
