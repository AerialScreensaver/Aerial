// The presenting-sample ring, extracted from VideoTransitionCoordinator
// so the prune/pick/replay rules are unit-testable (the coordinator
// injects `now` from its CMTimebase and uses CMSampleBuffer payloads).
//
// Semantics (behavior-preserving port — tests pin these):
// - `note` keeps every entry with a future PTS plus the single newest
//   already-past entry (the frame on screen right now), capped by
//   dropping from the front. Decode-order arrival (B-frame reordering)
//   is why entries are PTS-keyed rather than "last appended".
// - `presenting(at:)` picks the newest PTS at or below now, falling
//   back to the earliest future entry (right after a flush the past
//   side is empty).
// - `inflight(after:)` returns the not-yet-presented payloads oldest
//   first, for replay into a freshly-joined/flushed layer.
//
// Not thread-safe by design — the owner confines it to one queue (the
// renderer queue in production).

import CoreMedia

struct PresentingRing<Payload> {
    static var cap: Int { 64 }

    private(set) var entries: [(pts: CMTime, payload: Payload)] = []

    /// Track an enqueued payload. `pts` must be on the same timeline as
    /// the `now` values passed to the query methods (loop-adjusted, in
    /// production). Invalid PTS entries are rejected.
    mutating func note(_ payload: Payload, pts: CMTime, now: CMTime) {
        guard pts.isValid else { return }
        entries.append((pts, payload))

        // Prune: keep everything not yet presented, plus the single
        // most-recent already-presented entry (that's the frame on
        // screen right now).
        if entries.count > 1 {
            var keep: [(pts: CMTime, payload: Payload)] = []
            keep.reserveCapacity(entries.count)
            var newestPast: (pts: CMTime, payload: Payload)?
            for entry in entries {
                if entry.pts > now {
                    keep.append(entry)
                } else if newestPast.map({ entry.pts > $0.pts }) ?? true {
                    newestPast = entry
                }
            }
            if let newestPast {
                keep.insert(newestPast, at: 0)
            }
            if keep.count > Self.cap {
                // Cap by dropping the FURTHEST-future entries — never the
                // nearest. On a frozen timebase (long pause) every entry
                // stays "future": front-dropping left the ring holding
                // the 64 frames FARTHEST from `now`, and replaying that
                // island into a joining layer wedged it (2026-08-29
                // saver-join jam). PTS-sort first: entries arrive in
                // decode order, so the array's back isn't necessarily
                // the far future.
                keep.sort { $0.pts < $1.pts }
                keep.removeLast(keep.count - Self.cap)
            }
            entries = keep
        }
    }

    /// The payload whose frame is on screen at `now`: newest PTS at or
    /// below it, falling back to the earliest queued future entry.
    func presenting(at now: CMTime) -> Payload? {
        // Newest PTS at or below `now`; on a tie the earliest-noted entry
        // wins (max(by:) keeps the first of equal maxima).
        if let onScreen = entries.filter({ $0.pts <= now }).max(by: { $0.pts < $1.pts }) {
            return onScreen.payload
        }
        // Nothing presented yet — the earliest queued future entry.
        return entries.min(by: { $0.pts < $1.pts })?.payload
    }

    /// All not-yet-presented payloads, oldest first.
    func inflight(after now: CMTime) -> [Payload] {
        entries.filter { $0.pts > now }
            .sorted { $0.pts < $1.pts }
            .map { $0.payload }
    }

    /// Drop everything. Call before any timeline reset — PTS from the
    /// old timeline are garbage on the new one.
    mutating func clear() {
        entries.removeAll()
    }
}
