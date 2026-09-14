//
//  PresentingRingTests.swift
//  AerialTests
//
//  Pins the presenting-sample ring semantics extracted from
//  VideoTransitionCoordinator: the prune rule (all future + one newest
//  past, front-capped), the freeze-frame pick (newest past, else
//  earliest future), and the in-flight replay order. These rules feed
//  the ghost freeze-fade transitions and the wake-recovery replay.
//

import Testing
import CoreMedia
@testable import Aerial

@Suite("Presenting Ring")
struct PresentingRingTests {

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// Ring of Int payloads; payload value == its pts in seconds × 10
    /// so assertions read naturally.
    private func makeRing(ptsSeconds: [Double], now: Double) -> PresentingRing<Int> {
        var ring = PresentingRing<Int>()
        for pts in ptsSeconds {
            ring.note(Int(pts * 10), pts: time(pts), now: time(now))
        }
        return ring
    }

    @Test("prune keeps all future entries plus exactly one newest past")
    func pruneRule() {
        // now = 5.0; past entries 1,2,3,4; future 6,7.
        let ring = makeRing(ptsSeconds: [1, 2, 3, 4, 6, 7], now: 5)
        let pts = ring.entries.map { $0.pts.seconds }
        // Newest past (4) survives at the front; 1-3 pruned; future kept.
        #expect(pts == [4, 6, 7])
    }

    @Test("cap drops the furthest-future entries, keeping the near-now side")
    func capRule() {
        var ring = PresentingRing<Int>()
        // 80 future entries against now=0 — all kept until the cap bites.
        for i in 1...80 {
            ring.note(i, pts: time(Double(i)), now: time(0))
        }
        #expect(ring.entries.count == PresentingRing<Int>.cap)
        // The FAR future is dropped: survivors are the nearest 64
        // (1...64), so a replay into a fresh layer stays contiguous
        // with `now` instead of handing it a far-future island
        // (2026-08-29 saver-join jam).
        #expect(ring.entries.first?.payload == 1)
        #expect(ring.entries.last?.payload == PresentingRing<Int>.cap)
    }

    @Test("cap keeps the newest-past entry even when futures overflow")
    func capKeepsPast() {
        var ring = PresentingRing<Int>()
        ring.note(0, pts: time(0), now: time(1))          // past (on screen)
        for i in 2...70 {
            ring.note(i, pts: time(Double(i)), now: time(1))
        }
        #expect(ring.entries.count == PresentingRing<Int>.cap)
        #expect(ring.entries.first?.payload == 0)
        #expect(ring.presenting(at: time(1)) == 0)
    }

    @Test("presenting picks the newest past entry")
    func presentingNewestPast() {
        let ring = makeRing(ptsSeconds: [4, 6, 7], now: 5)
        #expect(ring.presenting(at: time(5)) == 40)
        // Time advances past 6 — the pick follows.
        #expect(ring.presenting(at: time(6.5)) == 60)
    }

    @Test("presenting falls back to the earliest future entry after a flush")
    func presentingColdStart() {
        // Only future entries (the just-flushed case).
        let ring = makeRing(ptsSeconds: [6, 7, 8], now: 0)
        #expect(ring.presenting(at: time(0)) == 60)
    }

    @Test("presenting on an empty ring is nil")
    func presentingEmpty() {
        let ring = PresentingRing<Int>()
        #expect(ring.presenting(at: time(1)) == nil)
    }

    @Test("decode-order (B-frame) arrival still picks display order")
    func bFrameReordering() {
        // Frames arrive in decode order 4, 2, 3 (pts seconds) while
        // now=2.5 — display order says 2 is on screen, not 4.
        var ring = PresentingRing<Int>()
        for pts in [4.0, 2.0, 3.0] {
            ring.note(Int(pts * 10), pts: time(pts), now: time(2.5))
        }
        #expect(ring.presenting(at: time(2.5)) == 20)
        #expect(ring.inflight(after: time(2.5)).map { $0 } == [30, 40])
    }

    @Test("inflight returns only future entries, pts-ascending")
    func inflightOrder() {
        let ring = makeRing(ptsSeconds: [4, 8, 6, 7], now: 5)
        #expect(ring.inflight(after: time(5)) == [60, 70, 80])
        // Everything past → empty.
        #expect(ring.inflight(after: time(9)).isEmpty)
    }

    @Test("invalid pts is rejected")
    func invalidPTS() {
        var ring = PresentingRing<Int>()
        ring.note(1, pts: .invalid, now: time(0))
        #expect(ring.entries.isEmpty)
    }

    @Test("clear empties the ring")
    func clear() {
        var ring = makeRing(ptsSeconds: [1, 2, 3], now: 0)
        ring.clear()
        #expect(ring.entries.isEmpty)
        #expect(ring.presenting(at: time(2)) == nil)
    }
}

// MARK: - No-video fallback layer (Aerial4WallpaperExtension)

@Suite("No-video fallback layer")
struct NoVideoFallbackLayerTests {

    @Test("keyframe schedule: 1 s hold + 2 s fade per hue, seamless wrap, 18 s cycle")
    func keyframeSchedule() {
        let colors = NoVideoFallbackLayer.palette
        #expect(colors.count == 6)
        let schedule = NoVideoFallbackLayer.keyframes(colors: colors, hold: 1, fade: 2)
        #expect(schedule.duration == 18)
        #expect(schedule.values.count == 13)
        #expect(schedule.keyTimes.count == 13)
        let times = schedule.keyTimes.map { $0.doubleValue }
        #expect(times.first == 0)
        #expect(times.last == 1)
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 <= $1 })
        // Second hue starts at 3/18 and holds until 4/18.
        #expect(abs(times[2] - 3.0 / 18.0) < 1e-9)
        #expect(abs(times[3] - 4.0 / 18.0) < 1e-9)
        // Wraps back to the first colour so the loop has no seam.
        #expect(schedule.values.last == colors[0])
        #expect(schedule.values[0] == colors[0] && schedule.values[1] == colors[0])
    }

    @Test("empty palette yields an empty schedule")
    func emptyPalette() {
        let schedule = NoVideoFallbackLayer.keyframes(colors: [], hold: 1, fade: 2)
        #expect(schedule.values.isEmpty && schedule.keyTimes.isEmpty && schedule.duration == 0)
    }
}
