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
// it reads the pump's blocking-call marker and, past `stallThreshold`,
// calls `cancelReading()` on the stuck reader — the one AVFoundation
// call that makes a pending `copyNextSampleBuffer` return. If the queue
// is still blocked `escalateAfterCancel` later the cancel was ignored
// and the handler's escalation hook fires. The pump then rebuilds the
// reader on a backoff ladder, never immediately (an immediate rebuild
// wedged again in the same window).

import Foundation

enum PumpWatchdogPolicy {
    /// Seconds a single blocking AVFoundation call may take before the
    /// watchdog cancels the reader. A 4K HEVC decode step is tens of ms;
    /// a cold decoder session is under a second; a slow external cache
    /// volume produces its first frame in 1–2 s. Well inside the agent's
    /// ~30 s snapshot budget even with the backoff + rebuild that follow.
    static let stallThreshold: TimeInterval = 5
    /// Seconds after the cancel before the queue counts as wedged for good.
    static let escalateAfterCancel: TimeInterval = 10
    /// Rebuild delays after a watchdog cancel, by attempt (1-based);
    /// the last value repeats.
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
        case cancel
        case escalate
    }

    /// `enteredAt`: when the pump entered its current blocking call (nil
    /// = not in one). `cancelIssuedAt`: when the watchdog already
    /// cancelled that call's reader. `escalated`: the escalation for this
    /// call already fired.
    static func decide(enteredAt: TimeInterval?, cancelIssuedAt: TimeInterval?,
                       escalated: Bool, now: TimeInterval) -> Decision {
        guard let enteredAt else { return .none }
        if let cancelIssuedAt {
            if !escalated, now - cancelIssuedAt >= escalateAfterCancel { return .escalate }
            return .none
        }
        return now - enteredAt >= stallThreshold ? .cancel : .none
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
