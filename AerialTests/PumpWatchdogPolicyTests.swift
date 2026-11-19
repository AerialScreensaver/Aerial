//
//  PumpWatchdogPolicyTests.swift
//  AerialTests
//
//  Pins the off-queue pump watchdog's decision rules and the degraded
//  diagnostics line (WallpaperExtension/Rendering/PumpWatchdogPolicy.swift).
//  The 2026-09-20 wake wedge: a copyNextSampleBuffer that never returned
//  took the whole extension down because nothing ran off the stuck queue.
//  The 2026-11-12 bundle: the watchdog's own cancelReading() crashed the
//  process on reads that were only slow — hence cold/warm thresholds and
//  "report, never cancel".
//

import Foundation
import Testing
@testable import Aerial

@Suite("Pump watchdog policy")
struct PumpWatchdogPolicyTests {
    private let t0: TimeInterval = 1_000

    @Test("no blocking call in flight → nothing to do")
    func idle() {
        #expect(PumpWatchdogPolicy.decide(enteredAt: nil, cold: false, lastReportedAt: nil, now: t0 + 600) == .none)
        #expect(PumpWatchdogPolicy.decide(enteredAt: nil, cold: true, lastReportedAt: nil, now: t0 + 600) == .none)
    }

    @Test("a warm read is left alone under the threshold and reported stalled at it")
    func warmThreshold() {
        let threshold = PumpWatchdogPolicy.stallThreshold
        #expect(PumpWatchdogPolicy.decide(enteredAt: t0, cold: false, lastReportedAt: nil, now: t0 + threshold - 0.1) == .none)
        #expect(PumpWatchdogPolicy.decide(enteredAt: t0, cold: false, lastReportedAt: nil, now: t0 + threshold) == .stalled)
    }

    @Test("a cold read (startReading / first sample) gets the long allowance — the login case")
    func coldThreshold() {
        let cold = PumpWatchdogPolicy.coldStallThreshold
        #expect(cold > PumpWatchdogPolicy.stallThreshold)
        // The field stalls were cut at 5–8 s; none of those may trip now.
        #expect(PumpWatchdogPolicy.decide(enteredAt: t0, cold: true, lastReportedAt: nil, now: t0 + 8.5) == .none)
        #expect(PumpWatchdogPolicy.decide(enteredAt: t0, cold: true, lastReportedAt: nil, now: t0 + cold - 0.1) == .none)
        #expect(PumpWatchdogPolicy.decide(enteredAt: t0, cold: true, lastReportedAt: nil, now: t0 + cold) == .stalled)
    }

    @Test("a reported stall stays quiet, then repeats once per replacement interval")
    func repeatedReport() {
        let reportedAt = t0 + PumpWatchdogPolicy.stallThreshold
        let interval = PumpWatchdogPolicy.replacementInterval
        #expect(PumpWatchdogPolicy.decide(enteredAt: t0, cold: false, lastReportedAt: reportedAt, now: reportedAt + 2) == .none)
        #expect(PumpWatchdogPolicy.decide(enteredAt: t0, cold: false, lastReportedAt: reportedAt, now: reportedAt + interval - 0.1) == .none)
        #expect(PumpWatchdogPolicy.decide(enteredAt: t0, cold: false, lastReportedAt: reportedAt, now: reportedAt + interval) == .stalled)
    }

    @Test("a key is replaced at most once per replacement interval")
    func replacementGate() {
        let interval = PumpWatchdogPolicy.replacementInterval
        #expect(PumpWatchdogPolicy.mayReplace(lastReplacedAt: nil, now: t0))
        #expect(!PumpWatchdogPolicy.mayReplace(lastReplacedAt: t0, now: t0 + interval - 0.1))
        #expect(PumpWatchdogPolicy.mayReplace(lastReplacedAt: t0, now: t0 + interval))
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
