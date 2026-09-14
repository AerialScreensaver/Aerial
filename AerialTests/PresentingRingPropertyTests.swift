//
//  PresentingRingPropertyTests.swift
//  AerialTests
//
//  Random operation sequences against PresentingRing, checked against an
//  independent oracle — the original linear-scan algorithm that the
//  crash-hardening rewrite (max/min(by:)) replaced. Inputs include every
//  CMTime the field can produce: invalid, indefinite, ±infinity, zero
//  timescale, mixed timescales, negatives.
//

import CoreMedia
import Foundation
import Testing
@testable import Aerial

@Suite("PresentingRing properties")
struct PresentingRingPropertyTests {
    private typealias Entry = (pts: CMTime, payload: Int)

    /// The pre-rewrite algorithm, kept verbatim as the oracle.
    private func oraclePresenting(_ entries: [Entry], at now: CMTime) -> Int? {
        var best: Entry?
        for entry in entries where entry.pts <= now {
            if let b = best { if entry.pts > b.pts { best = entry } } else { best = entry }
        }
        if best == nil {
            for entry in entries {
                if let b = best { if entry.pts < b.pts { best = entry } } else { best = entry }
            }
        }
        return best?.payload
    }

    @Test("random note/query sequences: never trap, capped, ≤1 presented entry, queries match the oracle")
    func randomOperationSequences() {
        forAll(iterations: 250) { rng, _ in
            var ring = PresentingRing<Int>()
            var now = rng.validCMTime(seconds: 0...100)
            var lastNoteNow = now
            for step in 0..<rng.int(1...160) {
                switch rng.int(0...9) {
                case 0...5:
                    let pts = rng.anyCMTime()
                    let before = ring.entries.count
                    ring.note(step, pts: pts, now: now)
                    #expect(ring.entries.count <= PresentingRing<Int>.cap, "\(rng.trail) step=\(step)")
                    if pts.isValid {
                        // Pruning happens on an accepted note: relative to
                        // that note's `now`, at most one entry is "past".
                        lastNoteNow = now
                        let presented = ring.entries.filter { $0.pts <= lastNoteNow }.count
                        #expect(presented <= 1, "\(rng.trail) step=\(step) presented=\(presented)")
                    } else {
                        #expect(ring.entries.count == before, "\(rng.trail) step=\(step) invalid pts accepted")
                    }
                case 6:
                    now = rng.anyCMTime()
                case 7:
                    ring.clear()
                    #expect(ring.entries.isEmpty, "\(rng.trail) step=\(step)")
                default:
                    let query = rng.anyCMTime()
                    let entries = ring.entries.map { (pts: $0.pts, payload: $0.payload) }
                    #expect(ring.presenting(at: query) == oraclePresenting(entries, at: query), "\(rng.trail) step=\(step) query=\(query)")
                    let inflight = ring.inflight(after: query)
                    let expected = entries.filter { $0.pts > query }.sorted { $0.pts < $1.pts }.map { $0.payload }
                    #expect(inflight == expected, "\(rng.trail) step=\(step) query=\(query)")
                }
            }
        }
    }

    @Test("edge CMTime values as `now` never trap", arguments: EdgeValues.cmTimes)
    func edgeNowValues(now: CMTime) {
        var ring = PresentingRing<Int>()
        for (i, pts) in EdgeValues.cmTimes.enumerated() {
            ring.note(i, pts: pts, now: now)
        }
        #expect(ring.entries.count <= PresentingRing<Int>.cap)
        _ = ring.presenting(at: now)
        _ = ring.inflight(after: now)
        for pts in EdgeValues.cmTimes {
            _ = ring.presenting(at: pts)
            _ = ring.inflight(after: pts)
        }
    }

    @Test("cap: after overflow the ring holds the nearest-future side plus one past entry")
    func capKeepsNearFuture() {
        forAll(iterations: 100) { rng, _ in
            var ring = PresentingRing<Int>()
            let now = CMTime(seconds: 50, preferredTimescale: 600)
            let count = PresentingRing<Int>.cap + rng.int(1...200)
            var futures: [Double] = []
            for i in 0..<count {
                let seconds = rng.double(-50...5000)
                if seconds > 50 { futures.append(seconds) }
                ring.note(i, pts: CMTime(seconds: seconds, preferredTimescale: 600), now: now)
            }
            #expect(ring.entries.count <= PresentingRing<Int>.cap, "\(rng.trail)")
            let keptFuture = ring.entries.filter { $0.pts > now }.map { $0.pts.seconds }
            // Everything kept is ≤ the furthest dropped: the far future went first.
            if let maxKept = keptFuture.max(), keptFuture.count < futures.count {
                let dropped = futures.sorted().suffix(futures.count - keptFuture.count)
                #expect(dropped.allSatisfy { $0 >= maxKept - 1e-9 }, "\(rng.trail) maxKept=\(maxKept) dropped=\(dropped.prefix(3))")
            }
        }
    }
}
