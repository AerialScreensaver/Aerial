//
//  PumpWatchdogPolicyTests.swift
//  AerialTests
//
//  Pins the off-queue pump watchdog's decision rules and the degraded
//  diagnostics line (WallpaperExtension/Rendering/PumpWatchdogPolicy.swift).
//  The 2026-09-20 wake wedge: a copyNextSampleBuffer that never returned
//  took the whole extension down because nothing ran off the stuck queue.
//

import Foundation
import Testing
@testable import Aerial

@Suite("Pump watchdog policy")
struct PumpWatchdogPolicyTests {
    private let t0: TimeInterval = 1_000

    @Test("no blocking call in flight → nothing to do")
    func idle() {
        #expect(PumpWatchdogPolicy.decide(enteredAt: nil, cancelIssuedAt: nil, escalated: false, now: t0 + 60) == .none)
    }

    @Test("a call blocked under the threshold is left alone; at the threshold the reader is cancelled")
    func cancelAtThreshold() {
        let threshold = PumpWatchdogPolicy.stallThreshold
        #expect(PumpWatchdogPolicy.decide(enteredAt: t0, cancelIssuedAt: nil, escalated: false, now: t0 + threshold - 0.1) == .none)
        #expect(PumpWatchdogPolicy.decide(enteredAt: t0, cancelIssuedAt: nil, escalated: false, now: t0 + threshold) == .cancel)
        #expect(PumpWatchdogPolicy.decide(enteredAt: t0, cancelIssuedAt: nil, escalated: false, now: t0 + 60) == .cancel)
    }

    @Test("after the cancel: quiet until escalateAfterCancel, then escalate exactly once")
    func escalation() {
        let cancelAt = t0 + PumpWatchdogPolicy.stallThreshold
        let grace = PumpWatchdogPolicy.escalateAfterCancel
        #expect(PumpWatchdogPolicy.decide(enteredAt: t0, cancelIssuedAt: cancelAt, escalated: false, now: cancelAt + grace - 1) == .none)
        #expect(PumpWatchdogPolicy.decide(enteredAt: t0, cancelIssuedAt: cancelAt, escalated: false, now: cancelAt + grace) == .escalate)
        #expect(PumpWatchdogPolicy.decide(enteredAt: t0, cancelIssuedAt: cancelAt, escalated: true, now: cancelAt + grace + 100) == .none)
        // A cancel already issued never re-issues, however long it takes.
        #expect(PumpWatchdogPolicy.decide(enteredAt: t0, cancelIssuedAt: cancelAt, escalated: false, now: cancelAt + 1) != .cancel)
    }

    @Test("rebuild backoff ladder is 2 → 5 → 15 and clamps at both ends")
    func backoff() {
        #expect(PumpWatchdogPolicy.backoffDelay(attempt: 1) == 2)
        #expect(PumpWatchdogPolicy.backoffDelay(attempt: 2) == 5)
        #expect(PumpWatchdogPolicy.backoffDelay(attempt: 3) == 15)
        #expect(PumpWatchdogPolicy.backoffDelay(attempt: 4) == 15)
        #expect(PumpWatchdogPolicy.backoffDelay(attempt: 40) == 15)
        #expect(PumpWatchdogPolicy.backoffDelay(attempt: 0) == 2)
        #expect(PumpWatchdogPolicy.backoffDelay(attempt: -3) == 2)
    }

    @Test("degraded line names the wedge and the watchdog counters")
    func degradedLine() {
        let wedged = RendererDegradedLine.format(
            subs: 4, paused: true, reasons: "coverage", fed: 997, sinceFeed: 31.2,
            tbTime: 162.1, tbRate: 0, asset: "BA4ECA11.mov",
            blockedFor: 6.3, phase: "copyNext", wdCancels: 1, wdRecreates: 0, wdAttempt: 1
        )
        #expect(wedged.contains("subs=4"))
        #expect(wedged.contains("paused=true reasons=coverage"))
        #expect(wedged.contains("asset=BA4ECA11.mov"))
        #expect(wedged.contains("QUEUE-WEDGED phase=copyNext blocked=6.3s"))
        #expect(wedged.contains("wd=cancels:1/recreates:0/attempt:1"))
        #expect(wedged.hasSuffix("(degraded: mirror)"))

        let unresponsive = RendererDegradedLine.format(
            subs: 1, paused: false, reasons: "none", fed: 10, sinceFeed: 0.5,
            tbTime: 1, tbRate: 1, asset: "x.mov",
            blockedFor: nil, phase: nil, wdCancels: 0, wdRecreates: 0, wdAttempt: 0
        )
        #expect(unresponsive.contains("QUEUE-UNRESPONSIVE"))
        #expect(!unresponsive.contains("QUEUE-WEDGED"))
    }
}
