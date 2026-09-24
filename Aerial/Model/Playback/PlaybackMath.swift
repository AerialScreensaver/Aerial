//
//  PlaybackMath.swift
//  Pure playback-loop math, extracted so it's unit-testable independent
//  of any player.
//

import Foundation

enum PlaybackMath {
    /// Playtime (video-content seconds) elapsed over a wall-clock interval at a
    /// given player rate. Speed-factored by `rate`; clamped so a single large
    /// gap (resume from suspension/occlusion) can't overshoot the target.
    static func boundedLoopAdvanceDelta(wallDelta: Double, rate: Float, maxWallDelta: Double = 1.0) -> Double {
        guard rate > 0, wallDelta > 0 else { return 0 }
        return min(wallDelta, maxWallDelta) * Double(rate)
    }

    /// Bounded-loop plan for the clip pass that just started, in the file
    /// engine's timebase seconds (rate-driven, so playtime is speed-factored
    /// and pause-safe by construction — no accumulator needed).
    ///
    /// - `passStart`: timebase time this pass began at (its PTS base).
    /// - `clipDuration`: the clip's length; the pass ends at `passStart + clipDuration`.
    /// - `budgetStart`: timebase time the entry's play-duration window opened at.
    /// - `budget`: the entry's play duration (seconds of playtime).
    /// - `minTail`: shortest slice of a pass worth playing — decides whether a
    ///   nearly-spent budget queues one more pass, and snaps a cut that would
    ///   land within `minTail` of a pass edge onto that edge (no sub-second
    ///   stubs, no cut a few frames before the natural end).
    ///
    /// Returns `loopAgain` (queue another pass of the same clip after this
    /// one) and `cutAt` (absolute timebase time at which THIS pass ends early
    /// because the budget runs out mid-clip; nil = play to the clip's end).
    /// Both false/nil without a usable budget or clip length.
    static func boundedLoopPlan(passStart: Double, clipDuration: Double, budgetStart: Double, budget: Double,
                                minTail: Double = 1.0) -> (loopAgain: Bool, cutAt: Double?) {
        guard budget > 0, clipDuration > 0,
              budget.isFinite, clipDuration.isFinite, passStart.isFinite, budgetStart.isFinite else {
            return (false, nil)
        }
        let passEnd = passStart + clipDuration
        let budgetEnd = budgetStart + budget
        // At least minTail of another pass still fits: keep looping.
        if budgetEnd - passEnd >= minTail { return (true, nil) }
        // The budget ends inside this pass: cut there, unless the cut would
        // sit within minTail of either edge.
        if budgetEnd >= passStart + minTail, budgetEnd <= passEnd - minTail {
            return (false, budgetEnd)
        }
        return (false, nil)
    }

    /// Cold-start resume position for a clip: 0 when the request is nil,
    /// non-finite, ≤ 0, or within `minTail` of the clip's end. A stale
    /// sidecar past EOF (2026-09-21: the idle timebase used to keep
    /// running with no subscriber, so the persisted position drifted
    /// beyond short clips) made `start()` seek past the last sample —
    /// instant EOF, then the next clip presented seconds late and
    /// fast-forwarded to catch up. Unknown/invalid clip duration → trust
    /// the request (the reader will clamp itself).
    static func resumeStart(requested: Double?, clipDuration: Double, minTail: Double = 1.0) -> Double {
        guard let requested, requested.isFinite, requested > 0 else { return 0 }
        guard clipDuration.isFinite, clipDuration > 0 else { return requested }
        return requested <= clipDuration - minTail ? requested : 0
    }

    /// PTS base for a gapless (natural EOF) swap: the next clip continues
    /// at `enqueuedEnd` when the decoder is ahead of the timebase (the
    /// normal case), but never in the past — after any decode gap the
    /// next clip starts at `now` instead of presenting seconds of late
    /// frames in a burst. `rebased` reports when the clamp changed the
    /// base.
    static func gaplessSwapBase(enqueuedEnd: Double, now: Double) -> (base: Double, rebased: Bool) {
        guard now.isFinite, enqueuedEnd.isFinite else { return (enqueuedEnd, false) }
        return now > enqueuedEnd ? (now, true) : (enqueuedEnd, false)
    }

    /// Overlay text follows the picture, not the decoder: after a gapless
    /// swap the new clip's content position (timebase − ptsOffset) is
    /// negative until the cut presents. nil = apply now; otherwise the
    /// seconds to wait before re-checking — the remaining time at the
    /// current rate, floored at 0.1 s, capped at 1 s so a rate change is
    /// picked up (rate 0 = paused: 1 s polls, the old text stays with the
    /// old picture).
    static func overlayCutDelay(position: Double, rate: Double) -> Double? {
        guard position.isFinite, position < 0 else { return nil }
        guard rate.isFinite, rate > 0 else { return 1.0 }
        return min(max(-position / rate, 0.1), 1.0)
    }
}
