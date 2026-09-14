//
//  PlaylistStateMachineTests.swift
//  AerialTests
//
//  Tests for PersistedPlaylist.popNextVideo() — the core playlist iteration logic.
//

import Testing
import Foundation
@testable import Aerial

// Simple video stand-in for testing
private struct FakeVideo: Equatable {
    let id: String
}

@Suite("Playlist State Machine")
struct PlaylistStateMachineTests {

    private func makePlaylist(
        ids: [String],
        currentIndex: Int = 0,
        cycleMode: PlaylistCycleMode = .loop
    ) -> PersistedPlaylist {
        let entries = ids.map { PlaylistEntry(videoId: $0, videoName: $0, secondaryName: "", duration: nil) }
        return PersistedPlaylist(
            entries: entries,
            currentIndex: currentIndex,
            playbackTimestamp: nil,
            filterMode: 0,
            filterStrings: [],
            generatedAt: Date(),
            cycleMode: cycleMode
        )
    }

    private func resolve(_ id: String) -> FakeVideo? {
        FakeVideo(id: id)
    }

    // MARK: - Empty Playlist

    @Test("Empty playlist returns nil")
    func emptyPlaylist() {
        var playlist = makePlaylist(ids: [])
        let result = playlist.popNextVideo(isResume: false, resolveVideo: resolve)
        #expect(result == nil)
    }

    // MARK: - Single Entry

    @Test("Single entry resume returns the entry")
    func singleEntryResume() {
        var playlist = makePlaylist(ids: ["A"])
        let result = playlist.popNextVideo(isResume: true, resolveVideo: resolve)
        #expect(result?.video.id == "A")
        #expect(result?.shouldLoop == true)
    }

    @Test("Single entry advance wraps to same entry")
    func singleEntryAdvance() {
        var playlist = makePlaylist(ids: ["A"], currentIndex: 0)
        let result = playlist.popNextVideo(isResume: false, resolveVideo: resolve)
        #expect(result?.video.id == "A")
        #expect(result?.shouldLoop == true)
    }

    // MARK: - Sequential Mode

    @Test("Sequential mode advances index")
    func sequentialAdvance() {
        var playlist = makePlaylist(ids: ["A", "B", "C"], currentIndex: 0)
        let result = playlist.popNextVideo(isResume: false, resolveVideo: resolve)
        #expect(result?.video.id == "B")
        #expect(playlist.currentIndex == 1)
    }

    @Test("Sequential mode wraps at end")
    func sequentialWrap() {
        var playlist = makePlaylist(ids: ["A", "B", "C"], currentIndex: 2)
        let result = playlist.popNextVideo(isResume: false, resolveVideo: resolve)
        #expect(result?.video.id == "A")
        #expect(playlist.currentIndex == 0)
    }

    @Test("Sequential mode full cycle")
    func sequentialFullCycle() {
        var playlist = makePlaylist(ids: ["A", "B", "C"], currentIndex: 0)
        // Resume at 0
        var r = playlist.popNextVideo(isResume: true, resolveVideo: resolve)
        #expect(r?.video.id == "A")
        // Advance through B, C, wrap to A
        r = playlist.popNextVideo(isResume: false, resolveVideo: resolve)
        #expect(r?.video.id == "B")
        r = playlist.popNextVideo(isResume: false, resolveVideo: resolve)
        #expect(r?.video.id == "C")
        r = playlist.popNextVideo(isResume: false, resolveVideo: resolve)
        #expect(r?.video.id == "A")
    }

    // MARK: - Resume Behavior

    @Test("Resume returns current index without advancing")
    func resumeDoesNotAdvance() {
        var playlist = makePlaylist(ids: ["A", "B", "C"], currentIndex: 1)
        let result = playlist.popNextVideo(isResume: true, resolveVideo: resolve)
        #expect(result?.video.id == "B")
        #expect(playlist.currentIndex == 1)
    }

    @Test("Resume clears playback timestamp")
    func resumeClearsTimestamp() {
        var playlist = makePlaylist(ids: ["A", "B"], currentIndex: 0)
        playlist.playbackTimestamp = 42.0
        _ = playlist.popNextVideo(isResume: true, resolveVideo: resolve)
        #expect(playlist.playbackTimestamp == nil)
    }

    // MARK: - Shuffle Mode

    @Test("Shuffle mode reshuffles at wrap")
    func shuffleReshufflesAtWrap() {
        var playlist = makePlaylist(ids: ["A", "B", "C", "D", "E"], currentIndex: 4, cycleMode: .shuffle)
        let result = playlist.popNextVideo(isResume: false, resolveVideo: resolve)
        #expect(result != nil)
        #expect(result?.didReshuffle == true)
    }

    @Test("Shuffle mode does not reshuffle mid-playlist")
    func shuffleNoReshuffleMid() {
        var playlist = makePlaylist(ids: ["A", "B", "C"], currentIndex: 0, cycleMode: .shuffle)
        let result = playlist.popNextVideo(isResume: false, resolveVideo: resolve)
        #expect(result?.didReshuffle == false)
    }

    // MARK: - shouldPlay Filter

    @Test("shouldPlay filter skips entries")
    func shouldPlayFilterSkips() {
        var playlist = makePlaylist(ids: ["A", "B", "C"], currentIndex: 0)
        let result = playlist.popNextVideo(
            isResume: false,
            resolveVideo: resolve,
            shouldPlay: { $0.id != "B" }
        )
        #expect(result?.video.id == "C")
        #expect(playlist.currentIndex == 2)
    }

    @Test("shouldPlay filter falls back when all filtered")
    func shouldPlayFallback() {
        var playlist = makePlaylist(ids: ["A", "B"], currentIndex: 0)
        // Filter rejects everything — should fall back to pass 2
        let result = playlist.popNextVideo(
            isResume: false,
            resolveVideo: resolve,
            shouldPlay: { _ in false }
        )
        #expect(result?.video.id == "B")
    }

    // MARK: - resolveVideo Returning Nil

    @Test("Unresolvable entries are skipped")
    func skipUnresolvable() {
        var playlist = makePlaylist(ids: ["A", "B", "C"], currentIndex: 0)
        let result = playlist.popNextVideo(isResume: false, resolveVideo: { id in
            id == "B" ? nil : FakeVideo(id: id)
        })
        #expect(result?.video.id == "C")
    }

    @Test("All unresolvable returns nil")
    func allUnresolvable() {
        var playlist = makePlaylist(ids: ["A", "B"], currentIndex: 0)
        let result = playlist.popNextVideo(isResume: false, resolveVideo: { _ in nil as FakeVideo? })
        #expect(result == nil)
    }

    // MARK: - reshuffleEntries Invariant

    @Test("Reshuffle ensures first differs from old last")
    func reshuffleInvariant() {
        for _ in 0..<50 {
            var playlist = makePlaylist(ids: ["A", "B", "C", "D"])
            // Set last entry to "D"
            playlist.entries = [
                PlaylistEntry(videoId: "A", videoName: "A", secondaryName: "", duration: nil),
                PlaylistEntry(videoId: "B", videoName: "B", secondaryName: "", duration: nil),
                PlaylistEntry(videoId: "C", videoName: "C", secondaryName: "", duration: nil),
                PlaylistEntry(videoId: "D", videoName: "D", secondaryName: "", duration: nil),
            ]
            let lastBefore = playlist.entries.last!.videoId
            playlist.reshuffleEntries()
            #expect(playlist.entries.first!.videoId != lastBefore)
        }
    }
}

// MARK: - Bounded Loop Accumulator

/// Tests for the pure playtime-accumulator math behind the per-video
/// play-duration override (PlayerCoordinator.boundedLoopAdvanceDelta).
@Suite("Bounded Loop Accumulator")
struct BoundedLoopAccumulatorTests {

    @Test("Playtime delta scales by player rate (speed-factored)")
    func deltaScalesByRate() {
        #expect(PlayerCoordinator.boundedLoopAdvanceDelta(wallDelta: 1.0, rate: 1.0) == 1.0)
        #expect(PlayerCoordinator.boundedLoopAdvanceDelta(wallDelta: 1.0, rate: 2.0) == 2.0)
        #expect(PlayerCoordinator.boundedLoopAdvanceDelta(wallDelta: 0.5, rate: 2.0) == 1.0)
        #expect(PlayerCoordinator.boundedLoopAdvanceDelta(wallDelta: 1.0, rate: 0.5) == 0.5)
    }

    @Test("Non-positive rate or wallDelta yields zero (pause-safe)")
    func deltaZeroGuards() {
        #expect(PlayerCoordinator.boundedLoopAdvanceDelta(wallDelta: 1.0, rate: 0.0) == 0)
        #expect(PlayerCoordinator.boundedLoopAdvanceDelta(wallDelta: 1.0, rate: -1.0) == 0)
        #expect(PlayerCoordinator.boundedLoopAdvanceDelta(wallDelta: -0.1, rate: 1.0) == 0)
        #expect(PlayerCoordinator.boundedLoopAdvanceDelta(wallDelta: 0.0, rate: 1.0) == 0)
    }

    @Test("A large wall gap is clamped (resume from suspension can't overshoot)")
    func deltaClampsLargeGap() {
        #expect(PlayerCoordinator.boundedLoopAdvanceDelta(wallDelta: 300, rate: 1.0, maxWallDelta: 1.0) == 1.0)
        // Clamp applies before the rate multiply.
        #expect(PlayerCoordinator.boundedLoopAdvanceDelta(wallDelta: 300, rate: 2.0, maxWallDelta: 1.0) == 2.0)
    }

    @Test("Accumulating 0.1s ticks crosses the target; 2x needs ~half the ticks")
    func accumulationCrossesTarget() {
        let target = 30.0

        var acc = 0.0, ticks = 0
        while acc < target {
            acc += PlayerCoordinator.boundedLoopAdvanceDelta(wallDelta: 0.1, rate: 1.0)
            ticks += 1
        }
        #expect(acc >= target)
        #expect(ticks >= 299 && ticks <= 302)   // 30s / 0.1s ≈ 300 (±float)

        var acc2 = 0.0, ticks2 = 0
        while acc2 < target {
            acc2 += PlayerCoordinator.boundedLoopAdvanceDelta(wallDelta: 0.1, rate: 2.0)
            ticks2 += 1
        }
        #expect(acc2 >= target)
        #expect(ticks2 >= 148 && ticks2 <= 152)  // twice the playtime per tick → ~half the ticks
    }
}
