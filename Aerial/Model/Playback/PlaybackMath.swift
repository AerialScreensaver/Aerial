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
}
