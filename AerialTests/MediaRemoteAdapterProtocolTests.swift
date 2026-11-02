//
//  MediaRemoteAdapterProtocolTests.swift
//  AerialTests
//
//  The mediaremote-adapter wire format as the Automatic now-playing
//  source consumes it: envelope parsing, diff merging and the song key
//  that decides when the overlay is told something changed.
//

import Foundation
import Testing
@testable import Aerial

@Suite("MediaRemote adapter protocol")
struct MediaRemoteAdapterProtocolTests {

    private let snapshot = #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.Music","playing":true,"title":"Tahoe","artist":"Aerial","album":"Journée","durationMicros":214000000,"elapsedTimeMicros":8100000,"timestampEpochMicros":1760000000000000,"playbackRate":1}}"#
    private let artworkDiff = #"{"type":"data","diff":true,"payload":{"artworkData":"iVBORw0KGgo=","artworkMimeType":"image/png"}}"#
    private let elapsedDiff = #"{"type":"data","diff":true,"payload":{"elapsedTimeMicros":12000000,"timestampEpochMicros":1760000004000000}}"#
    private let pauseDiff = #"{"type":"data","diff":true,"payload":{"playing":false,"playbackRate":0}}"#
    private let removeAlbum = #"{"type":"data","diff":true,"payload":{"album":null}}"#

    @Test("envelope, bare get object, null and garbage lines")
    func parsing() throws {
        guard case .data(let diff, let payload) = try #require(MediaRemoteAdapterLine.parse(snapshot)) else {
            Issue.record("snapshot did not parse as data"); return
        }
        #expect(diff == false)
        #expect(payload["title"] as? String == "Tahoe")

        let bare = try #require(MediaRemoteAdapterLine.parse(#"{"bundleIdentifier":"com.spotify.client","playing":true,"title":"Bare"}"#))
        #expect(bare == .data(diff: false, payload: ["bundleIdentifier": "com.spotify.client", "playing": true, "title": "Bare"]))

        #expect(MediaRemoteAdapterLine.parse("null") == .null)
        #expect(MediaRemoteAdapterLine.parse(#"{"type":"data","diff":false,"payload":null}"#) == .null)
        #expect(MediaRemoteAdapterLine.parse(#"{"type":"hello","payload":{}}"#) == .other(type: "hello"))
        #expect(MediaRemoteAdapterLine.parse("") == nil)
        #expect(MediaRemoteAdapterLine.parse("not json at all") == nil)
        #expect(MediaRemoteAdapterLine.parse("[1,2,3]") == nil)
    }

    @Test("snapshot then diffs: merge, null removal, change reporting")
    func merging() throws {
        // `#expect` captures its operands immutably, so each mutating
        // `apply` lands in a local first.
        var merger = MediaRemoteStateMerger()
        #expect(merger.hasSnapshot == false)
        let appliedSnapshot = merger.apply(try #require(MediaRemoteAdapterLine.parse(snapshot)))
        #expect(appliedSnapshot)
        #expect(merger.hasSnapshot)
        #expect(merger.state["album"] as? String == "Journée")

        let appliedArtwork = merger.apply(try #require(MediaRemoteAdapterLine.parse(artworkDiff)))
        #expect(appliedArtwork)
        #expect(merger.state["artworkData"] as? String == "iVBORw0KGgo=")
        #expect(merger.state["title"] as? String == "Tahoe", "a diff keeps the untouched keys")

        let removedAlbum = merger.apply(try #require(MediaRemoteAdapterLine.parse(removeAlbum)))
        #expect(removedAlbum)
        #expect(merger.state["album"] == nil, "null removes the key")
        let removedAgain = merger.apply(try #require(MediaRemoteAdapterLine.parse(removeAlbum)))
        #expect(removedAgain == false, "removing an absent key changes nothing")

        let cleared = merger.apply(.null)
        #expect(cleared)
        #expect(merger.state.isEmpty)
        let clearedAgain = merger.apply(.null)
        #expect(clearedAgain == false)
        let ignored = merger.apply(.other(type: "x"))
        #expect(ignored == false)
    }

    @Test("song key: timing ticks never change it, artwork and pause do")
    func songKey() throws {
        var merger = MediaRemoteStateMerger()
        _ = merger.apply(try #require(MediaRemoteAdapterLine.parse(snapshot)))
        let first = try #require(MediaRemoteSongKey.key(from: merger.state))
        #expect(first.title == "Tahoe" && first.artist == "Aerial" && first.album == "Journée")
        #expect(first.bundleID == "com.apple.Music")
        #expect(first.artworkHash == nil)

        _ = merger.apply(try #require(MediaRemoteAdapterLine.parse(elapsedDiff)))
        #expect(MediaRemoteSongKey.key(from: merger.state) == first, "elapsed/timestamp only — same key")

        _ = merger.apply(try #require(MediaRemoteAdapterLine.parse(artworkDiff)))
        let withArt = try #require(MediaRemoteSongKey.key(from: merger.state))
        #expect(withArt != first)
        #expect(withArt.artworkHash != nil)
        #expect(MediaRemoteSongKey.artworkData(from: merger.state) == Data(base64Encoded: "iVBORw0KGgo="))

        _ = merger.apply(try #require(MediaRemoteAdapterLine.parse(pauseDiff)))
        #expect(MediaRemoteSongKey.key(from: merger.state) == nil, "paused → nothing to show")
        #expect(MediaRemoteSongKey.key(from: merger.state, allowPaused: true) == withArt, "…unless the caller wants what is loaded")

        #expect(MediaRemoteSongKey.key(from: ["playing": true, "title": ""]) == nil)
        #expect(MediaRemoteSongKey.key(from: ["playing": true]) == nil)
        #expect(MediaRemoteSongKey.key(from: [:]) == nil)
    }
}
