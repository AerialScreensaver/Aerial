// Pure decision rules for the live-feed engine and the live↔file
// handover, kept free of AVFoundation so they are unit-testable
// (LivePlaybackPolicyTests).
//
// Background (2026-11-15/16 field bundles, 4.1.11): a display layer handed
// from the file engine to the live engine kept the file renderer's stopped
// timebase and its unpresented frames. The live pull loop enqueued every
// frame regardless, nothing was ever released, and ~52,000 decoded frames
// (154 GiB) piled up until the Mac ran out of swap. The same logs showed
// dead feeds costing a full cached clip each rotation, and a stashed live
// entry taking over mid-clip whenever the file reader was rebuilt.

import Foundation

/// Per-subscriber gate for the live pull loop: a layer that is not
/// accepting data is skipped, never queued into.
///
/// Live frames are DisplayImmediately, so a healthy layer is always ready.
/// A layer that stays not-ready is holding something it cannot present;
/// after `flushAfter` consecutive frames it is flushed once and fed again.
/// If that does not cure it the gate backs off to one flush per `backoff`
/// frames, so a permanently sick layer costs a flush every few seconds
/// instead of one per frame — and still never accumulates frames.
struct LiveEnqueueGate: Equatable {
    enum Action: Equatable {
        case enqueue
        case skip
        case flushThenEnqueue
    }

    /// Consecutive not-ready frames before the first flush (~1 s at 30 fps).
    static let flushAfter = 30
    /// Same, once a flush has already failed to make the layer ready
    /// (~10 s at 30 fps).
    static let backoff = 300

    private(set) var notReadyStreak = 0
    private(set) var threshold = LiveEnqueueGate.flushAfter

    mutating func decide(ready: Bool) -> Action {
        if ready {
            notReadyStreak = 0
            threshold = Self.flushAfter
            return .enqueue
        }
        notReadyStreak += 1
        guard notReadyStreak >= threshold else { return .skip }
        notReadyStreak = 0
        threshold = Self.backoff
        return .flushThenEnqueue
    }
}

/// Why the file engine is asking its playlist hook for the next video.
/// Only some of these are a point where a stashed live entry may take the
/// slot over: the hook used to treat EVERY call as the loop boundary, so a
/// reader rebuilt mid-clip (deep-pause wake, watchdog recovery, a
/// replacement renderer starting up) cut the file short and jumped to the
/// live feed.
enum NextVideoRequest: Equatable {
    /// First pick of a freshly started renderer — the current clip has
    /// only just begun.
    case initial
    /// A pass ended and its successor is on screen: the loop boundary.
    case passStart
    /// Re-pick of the buffered next video mid-clip (reader recreated,
    /// repeat-one flipped, time-slice rule changed).
    case reprime
    /// The user asked to move on (advance / jump).
    case explicit

    /// Whether a live entry stashed for "the loop boundary" may switch
    /// engines on this request.
    var allowsPendingEngineSwitch: Bool {
        switch self {
        case .passStart, .explicit: return true
        case .initial, .reprime: return false
        }
    }
}

/// Which live feeds are currently worth trying.
///
/// A feed that exhausted its recovery attempts is benched for `cooldown`:
/// the playlist skips it instead of paying the retry ladder (and, before
/// this, a whole cached clip) on every rotation. Benching is also the
/// loop guard — within one cooldown each dead feed is tried once, so a
/// playlist of nothing but dead feeds runs out of candidates and the
/// caller falls back to a cached video.
struct LiveFeedAvailability: Equatable {
    /// How long a failed feed sits out before it is tried again.
    static let cooldown: TimeInterval = 10 * 60

    struct Failure: Equatable {
        var at: TimeInterval
        var reason: String
    }

    private(set) var failures: [String: Failure] = [:]

    /// A feed ran out of recovery attempts.
    mutating func noteFailure(id: String, reason: String, now: TimeInterval) {
        failures[id] = Failure(at: now, reason: reason)
    }

    /// A feed delivered a frame: it works again.
    mutating func noteSuccess(id: String) {
        failures.removeValue(forKey: id)
    }

    func isBenched(id: String, now: TimeInterval) -> Bool {
        guard let failure = failures[id] else { return false }
        return now - failure.at < Self.cooldown
    }

    /// Feeds still inside their cooldown (id → reason), for the status
    /// file.
    func benched(now: TimeInterval) -> [String: String] {
        failures.filter { now - $0.value.at < Self.cooldown }.mapValues(\.reason)
    }

    /// Seconds until each benched feed is tried again (id → seconds, > 0).
    /// The status file turns these into wall-clock times for the
    /// Companion's "Feed down, will retry at …" message.
    func retryDelays(now: TimeInterval) -> [String: TimeInterval] {
        failures.compactMapValues { failure in
            let left = Self.cooldown - (now - failure.at)
            return left > 0 ? left : nil
        }
    }

    /// Drop expired entries so the table cannot grow without bound.
    mutating func prune(now: TimeInterval) {
        failures = failures.filter { now - $0.value.at < Self.cooldown }
    }
}
