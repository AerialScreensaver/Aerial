//
//  PlaylistPropertyTests.swift
//  AerialTests
//
//  Property tests for the persisted-playlist state machine. The inputs
//  are what the sidecar JSON can actually carry: duplicate and empty
//  video ids, a currentIndex that is negative, huge, or past the end
//  (a playlist that shrank since it was written), entries that no
//  longer resolve, and predicates that reject everything.
//

import Foundation
import Testing
@testable import Aerial

private struct V: Equatable { let id: String }

@Suite("Playlist state machine properties")
struct PlaylistPropertyTests {
    private func make(_ ids: [String], current: Int, mode: PlaylistCycleMode) -> PersistedPlaylist {
        PersistedPlaylist(
            entries: ids.map { PlaylistEntry(videoId: $0, videoName: $0, secondaryName: "", duration: nil) },
            currentIndex: current, playbackTimestamp: 1.5, filterMode: 0, filterStrings: [],
            generatedAt: Date(), cycleMode: mode
        )
    }

    private func randomIndex(_ rng: inout SeededGenerator) -> Int {
        switch rng.int(0...9) {
        case 0: return Int.min
        case 1: return Int.max
        case 2: return -1
        default: return rng.int(-40...40)
        }
    }

    private func randomMode(_ rng: inout SeededGenerator) -> PlaylistCycleMode {
        [.loop, .shuffle, .repeatOne].randomElement(using: &rng)!
    }

    @Test("popNext/popPrevious never trap and always land on a valid index, whatever the persisted currentIndex")
    func popsLandOnValidIndex() {
        forAll(iterations: 600) { rng, _ in
            let ids = (0..<rng.int(0...12)).map { _ in rng.identifier() }
            var playlist = make(ids, current: randomIndex(&rng), mode: randomMode(&rng))
            let resolvable = Set(ids.filter { _ in rng.bool(probability: 0.8) })
            let resolve: (String) -> V? = { resolvable.contains($0) ? V(id: $0) : nil }
            let predicate: ((V) -> Bool)? = rng.bool(probability: 0.4) ? { $0.id.hashValue % 2 == 0 } : nil
            let fallback: ((V) -> Bool)? = rng.bool(probability: 0.5) ? { $0.id.count > 1 } : nil
            let count = ids.count

            let next = playlist.popNextVideo(isResume: rng.bool(), resolveVideo: resolve,
                                             shouldPlay: predicate, shouldPlayFallback: fallback)
            if let next {
                #expect((0..<count).contains(playlist.currentIndex), "\(rng.trail) index=\(playlist.currentIndex) count=\(count)")
                #expect(playlist.entries[playlist.currentIndex].videoId == next.video.id, "\(rng.trail)")
                #expect(next.shouldLoop == (count <= 1), "\(rng.trail)")
                #expect(playlist.playbackTimestamp == nil, "\(rng.trail)")
                #expect(resolvable.contains(next.video.id), "\(rng.trail)")
            } else {
                #expect(count == 0 || resolvable.isEmpty || playlist.currentIndex == 0, "\(rng.trail) nil result but index=\(playlist.currentIndex)")
            }

            let previous = playlist.popPreviousVideo(resolveVideo: resolve, shouldPlay: predicate, shouldPlayFallback: fallback)
            if let previous {
                #expect((0..<count).contains(playlist.currentIndex), "\(rng.trail) index=\(playlist.currentIndex) count=\(count)")
                #expect(playlist.entries[playlist.currentIndex].videoId == previous.video.id, "\(rng.trail)")
            } else {
                #expect(count == 0 || resolvable.isEmpty || !ids.contains(where: resolvable.contains), "\(rng.trail)")
            }
        }
    }

    @Test("everything resolvable, no predicate, loop mode: popNext walks forward, popPrevious walks back, resume repeats")
    func orderedWalk() {
        forAll(iterations: 400) { rng, _ in
            let ids = (0..<rng.int(1...10)).map { "v\($0)" }
            let count = ids.count
            let start = rng.int(0...(count - 1))
            var playlist = make(ids, current: start, mode: .loop)
            let resolve: (String) -> V? = { V(id: $0) }

            let next = playlist.popNextVideo(isResume: false, resolveVideo: resolve)
            #expect(next?.video.id == ids[(start + 1) % count], "\(rng.trail)")
            #expect(playlist.currentIndex == (start + 1) % count, "\(rng.trail)")

            let resumed = playlist.popNextVideo(isResume: true, resolveVideo: resolve)
            #expect(resumed?.video.id == ids[(start + 1) % count], "\(rng.trail) resume must not advance")

            let back = playlist.popPreviousVideo(resolveVideo: resolve)
            #expect(back?.video.id == ids[start], "\(rng.trail)")
            #expect(playlist.currentIndex == start, "\(rng.trail)")

            // A full lap visits every index exactly once and returns home.
            var visited: [Int] = []
            for _ in 0..<count {
                _ = playlist.popNextVideo(isResume: false, resolveVideo: resolve)
                visited.append(playlist.currentIndex)
            }
            #expect(Set(visited).count == count, "\(rng.trail) visited=\(visited)")
            #expect(playlist.currentIndex == start, "\(rng.trail)")
        }
    }

    @Test("a persisted index outside the playlist is normalized, not trapped on", arguments: [Int.min, -100, -1, 3, 4, 99, Int.max])
    func outOfRangeIndexNormalized(current: Int) {
        var playlist = make(["a", "b", "c"], current: current, mode: .loop)
        let resolve: (String) -> V? = { V(id: $0) }
        let next = playlist.popNextVideo(isResume: false, resolveVideo: resolve)
        #expect(next != nil)
        #expect((0..<3).contains(playlist.currentIndex))
        var again = make(["a", "b", "c"], current: current, mode: .loop)
        #expect(again.popPreviousVideo(resolveVideo: resolve) != nil)
        #expect((0..<3).contains(again.currentIndex))
        #expect(again.index(ofVideoId: "b", searchingBackFrom: current) == 1)
    }

    @Test("index(ofVideoId:searchingBackFrom:) returns an index holding that id, or nil when absent, for any start")
    func indexLookup() {
        forAll(iterations: 500) { rng, _ in
            let ids = (0..<rng.int(0...10)).map { _ in rng.identifier() }
            let playlist = make(ids, current: randomIndex(&rng), mode: randomMode(&rng))
            let wanted = rng.bool(probability: 0.8) ? (rng.element(of: ids) ?? "missing") : "missing"
            let start: Int? = rng.bool() ? randomIndex(&rng) : nil
            let found = playlist.index(ofVideoId: wanted, searchingBackFrom: start)
            if let found {
                #expect((0..<ids.count).contains(found) && ids[found] == wanted, "\(rng.trail)")
            } else {
                #expect(!ids.contains(wanted), "\(rng.trail) '\(wanted)' present but not found")
            }
        }
    }

    @Test("reshuffle preserves the multiset of ids and terminates on all-duplicate playlists")
    func reshufflePreservesAndTerminates() {
        forAll(iterations: 300) { rng, _ in
            let pool = ["A", "B", "C"].prefix(rng.int(1...3))
            let ids = (0..<rng.int(0...12)).map { _ in rng.element(of: pool)! }
            var playlist = make(ids, current: 0, mode: .shuffle)
            playlist.reshuffleEntries()
            #expect(playlist.entries.map(\.videoId).sorted() == ids.sorted(), "\(rng.trail)")
        }
        // This exact shape spun forever before the bounded retry.
        var duplicates = make(["same", "same", "same"], current: 2, mode: .shuffle)
        duplicates.reshuffleEntries()
        #expect(duplicates.entries.count == 3)
    }

    @Test("reshuffle avoids an immediate replay when the ids allow it")
    func reshuffleAvoidsReplay() {
        // Six distinct ids: a false failure needs nine straight unlucky
        // shuffles, (1/6)^9 ≈ 1e-7 per case.
        forAll(iterations: 200) { rng, _ in
            let ids = (0..<6).map { "v\($0)" }.shuffled(using: &rng)
            var playlist = make(ids, current: 5, mode: .shuffle)
            let last = ids.last
            playlist.reshuffleEntries()
            #expect(playlist.entries.first?.videoId != last, "\(rng.trail)")
        }
    }
}
