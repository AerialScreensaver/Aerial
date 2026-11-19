// Pure decision rules for the renderer's off-queue pump watchdog, kept
// free of AVFoundation so they are unit-testable (PumpWatchdogPolicyTests).
//
// Background (2026-09-20 field bundle): after a docked wake on macOS 27,
// `AVAssetReaderTrackOutput.copyNextSampleBuffer` never returned on the
// recreated reader. The renderer queue stayed inside it, every
// `queue.sync` reader blocked behind it, and WallpaperAgent killed the
// extension 30 s later. Nothing in-process could notice: every existing
// watchdog was `queue.async` onto the very queue that was stuck.
//
// The watchdog runs OFF the renderer queue (the 2 s feed-health timer):
// it reads the pump's blocking-call marker and, past the stall threshold,
// reports the stall to the handler, which replaces the whole renderer
// (new queue, new reader, same video and position) and abandons the
// stuck one.
//
// It used to call `cancelReading()` on the stuck reader instead. That
// call, made from another thread while `copyNextSampleBuffer` waits,
// tears the reader's semaphore down under the waiting thread: in the
// 2026-11-12 field bundle 22 of 47 watchdog cancels were the process's
// last log line (EXC_BAD_ACCESS in FigSemaphoreWaitRelative), 12 of them
// on the first read after login, which was only slow. Rule since then:
// no thread other than the renderer queue ever cancels a reader.

import Foundation

enum PumpWatchdogPolicy {
    /// Seconds a blocking AVFoundation call may take on a WARM reader
    /// (one that already delivered a sample) before the pump counts as
    /// stalled. A 4K HEVC decode step is tens of ms.
    static let stallThreshold: TimeInterval = 10
    /// Same, for a COLD call: `startReading`, or the first
    /// `copyNextSampleBuffer` of a reader. That one opens the decoder
    /// session and seeks; right after login it took more than 5 s on a
    /// healthy Mac (the 2026-11-12 bundle), so it gets a long allowance.
    static let coldStallThreshold: TimeInterval = 30
    /// While the same call stays blocked, the stall is reported again at
    /// this interval — and the handler replaces a given renderer key at
    /// most once per interval, so a decoder that is slow for everyone
    /// cannot spawn renderers in a loop.
    static let replacementInterval: TimeInterval = 60
    /// Rebuild delays after a failed reader create, by attempt
    /// (1-based); the last value repeats.
    static let backoff: [TimeInterval] = [2, 5, 15]
    /// Re-check cadence while a rebuild is deferred (renderer paused or
    /// without subscribers).
    static let recheckDelay: TimeInterval = 15
    /// `diagnosticsSnapshot` skips the queue hop outright when the pump
    /// has been inside one call this long — no point queueing another
    /// block behind a known wedge.
    static let skipHopAfter: TimeInterval = 1
    /// The snapshot reply must not open a poster-frame decode (a fresh
    /// VideoToolbox session) while the pump's own decode has been stuck
    /// this long — same decoder, same wedge.
    static let posterSkipAfter: TimeInterval = 1

    enum Decision: Equatable {
        case none
        case stalled
    }

    /// All times are on one monotonic clock that does not advance while
    /// the Mac sleeps (`ProcessInfo.systemUptime`) — a read in flight
    /// across a sleep is not a stall. `enteredAt`: when the pump entered
    /// its current blocking call (nil = not in one). `cold`: see
    /// `coldStallThreshold`. `lastReportedAt`: when this call's stall was
    /// last reported.
    static func decide(enteredAt: TimeInterval?, cold: Bool,
                       lastReportedAt: TimeInterval?, now: TimeInterval) -> Decision {
        guard let enteredAt else { return .none }
        if let lastReportedAt {
            return now - lastReportedAt >= replacementInterval ? .stalled : .none
        }
        let threshold = cold ? coldStallThreshold : stallThreshold
        return now - enteredAt >= threshold ? .stalled : .none
    }

    /// Handler-side gate: may the renderer behind a key be replaced now,
    /// given when it was last replaced for a stall?
    static func mayReplace(lastReplacedAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let lastReplacedAt else { return true }
        return now - lastReplacedAt >= replacementInterval
    }

    /// Delay before rebuild attempt `attempt` (1-based; ≤ 0 reads as 1).
    static func backoffDelay(attempt: Int) -> TimeInterval {
        let index = max(1, min(attempt, backoff.count)) - 1
        return backoff[index]
    }
}

/// The `🗺 periodic` / `dumpTopology` renderer line served from the
/// off-queue mirror when the renderer queue can't answer. Pure so the
/// shape is pinned by a test; the live line (`diagnosticsLineOnQueue`)
/// carries more counters.
enum RendererDegradedLine {
    static func format(subs: Int, paused: Bool, reasons: String, fed: Int, sinceFeed: TimeInterval,
                       tbTime: Double, tbRate: Double, asset: String,
                       blockedFor: TimeInterval?, phase: String?,
                       wdCancels: Int, wdRecreates: Int, wdAttempt: Int) -> String {
        let wedge: String
        if let blockedFor {
            wedge = " QUEUE-WEDGED phase=\(phase ?? "?") blocked=\(String(format: "%.1f", blockedFor))s"
        } else {
            wedge = " QUEUE-UNRESPONSIVE"
        }
        return "subs=\(subs) tbRate=\(tbRate) tbTime=\(String(format: "%.1f", tbTime))s paused=\(paused) reasons=\(reasons) fed=\(fed) lastFeed=\(String(format: "%.1f", sinceFeed))s asset=\(asset)\(wedge) wd=cancels:\(wdCancels)/recreates:\(wdRecreates)/attempt:\(wdAttempt) (degraded: mirror)"
    }
}
