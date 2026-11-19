//
//  LivePlaybackPolicyTests.swift
//  AerialTests
//
//  Decision rules behind the 2026-11-15/16 live-feed fixes: the live pull
//  loop never queues into a layer that is not taking frames, a stashed
//  live entry only takes the slot at a real loop boundary, dead feeds are
//  benched instead of retried on every rotation, and a resolved YouTube
//  URL survives a failed refresh until it actually expires.
//

import Foundation
import Testing
@testable import Aerial

@Suite("Live enqueue gate")
struct LiveEnqueueGateTests {
    @Test("a ready layer is always fed")
    func readyEnqueues() {
        var gate = LiveEnqueueGate()
        for _ in 0..<1_000 {
            #expect(gate.decide(ready: true) == .enqueue)
        }
    }

    @Test("a layer that is not ready is skipped, never queued into")
    func notReadySkips() {
        var gate = LiveEnqueueGate()
        for _ in 0..<(LiveEnqueueGate.flushAfter - 1) {
            #expect(gate.decide(ready: false) == .skip)
        }
    }

    @Test("sustained not-ready flushes once, then backs off")
    func flushThenBackoff() {
        var gate = LiveEnqueueGate()
        var actions: [LiveEnqueueGate.Action] = []
        for _ in 0..<(LiveEnqueueGate.flushAfter + LiveEnqueueGate.backoff) {
            actions.append(gate.decide(ready: false))
        }
        let flushes = actions.indices.filter { actions[$0] == .flushThenEnqueue }
        #expect(flushes == [LiveEnqueueGate.flushAfter - 1,
                            LiveEnqueueGate.flushAfter + LiveEnqueueGate.backoff - 1])
        #expect(!actions.contains(.enqueue))
    }

    @Test("an hour of a stuck layer costs a bounded number of enqueues")
    func boundedWhenStuck() {
        var gate = LiveEnqueueGate()
        let frames = 30 * 3_600
        let enqueued = (0..<frames).filter { _ in gate.decide(ready: false) != .skip }.count
        // The field leak was one enqueue per frame (~52,000 in 30 min).
        #expect(enqueued <= frames / LiveEnqueueGate.backoff + 1)
    }

    @Test("a layer that recovers starts over with the short threshold")
    func recoveryResets() {
        var gate = LiveEnqueueGate()
        for _ in 0..<LiveEnqueueGate.flushAfter { _ = gate.decide(ready: false) }
        #expect(gate.decide(ready: true) == .enqueue)
        for _ in 0..<(LiveEnqueueGate.flushAfter - 1) {
            #expect(gate.decide(ready: false) == .skip)
        }
        #expect(gate.decide(ready: false) == .flushThenEnqueue)
    }
}

@Suite("Next-video request")
struct NextVideoRequestTests {
    @Test("only a pass boundary or an explicit advance may switch engines")
    func pendingSwitch() {
        #expect(NextVideoRequest.passStart.allowsPendingEngineSwitch)
        #expect(NextVideoRequest.explicit.allowsPendingEngineSwitch)
        // Deep-pause wake / watchdog recovery / rule re-pick, and a
        // replacement renderer starting up: the clip is still playing.
        #expect(!NextVideoRequest.reprime.allowsPendingEngineSwitch)
        #expect(!NextVideoRequest.initial.allowsPendingEngineSwitch)
    }
}

@Suite("Play-duration cut successor")
struct BudgetCutSuccessorTests {
    private let clip = URL(fileURLWithPath: "/cache/a.mov")
    private let other = URL(fileURLWithPath: "/cache/b.mov")

    @Test("a different file is cut to gaplessly")
    func nextClip() {
        #expect(PlaybackMath.budgetCutSuccessor(pick: other, current: clip, engineSwitchPending: false) == .nextClip)
        // A buffered file wins over a stale stash.
        #expect(PlaybackMath.budgetCutSuccessor(pick: other, current: clip, engineSwitchPending: true) == .nextClip)
    }

    @Test("a stashed live entry ends the clip at its play duration — it used to run to its end")
    func engineSwitch() {
        #expect(PlaybackMath.budgetCutSuccessor(pick: nil, current: clip, engineSwitchPending: true) == .engineSwitch)
    }

    @Test("nothing different follows: no cut, the loop stays seamless")
    func none() {
        #expect(PlaybackMath.budgetCutSuccessor(pick: nil, current: clip, engineSwitchPending: false) == .none)
        #expect(PlaybackMath.budgetCutSuccessor(pick: clip, current: clip, engineSwitchPending: false) == .none)
    }
}

@Suite("Live feed availability")
struct LiveFeedAvailabilityTests {
    private let t0: TimeInterval = 1_000

    @Test("an unknown feed is playable")
    func unknown() {
        #expect(!LiveFeedAvailability().isBenched(id: "a", now: t0))
    }

    @Test("a failed feed sits out its cooldown, then comes back")
    func cooldown() {
        var state = LiveFeedAvailability()
        state.noteFailure(id: "a", reason: "playback failed", now: t0)
        #expect(state.isBenched(id: "a", now: t0))
        #expect(state.isBenched(id: "a", now: t0 + LiveFeedAvailability.cooldown - 1))
        #expect(!state.isBenched(id: "a", now: t0 + LiveFeedAvailability.cooldown))
        #expect(!state.isBenched(id: "b", now: t0))
    }

    @Test("a feed that plays again is cleared at once")
    func success() {
        var state = LiveFeedAvailability()
        state.noteFailure(id: "a", reason: "no video received", now: t0)
        state.noteSuccess(id: "a")
        #expect(!state.isBenched(id: "a", now: t0 + 1))
        #expect(state.benched(now: t0 + 1).isEmpty)
    }

    @Test("the retry delay counts down to the end of the cooldown, then disappears")
    func retryDelays() {
        var state = LiveFeedAvailability()
        state.noteFailure(id: "a", reason: "playback failed", now: t0)
        #expect(state.retryDelays(now: t0) == ["a": LiveFeedAvailability.cooldown])
        #expect(state.retryDelays(now: t0 + 90) == ["a": LiveFeedAvailability.cooldown - 90])
        #expect(state.retryDelays(now: t0 + LiveFeedAvailability.cooldown).isEmpty)
        state.noteFailure(id: "b", reason: "no video received", now: t0 + 100)
        state.noteSuccess(id: "b")
        #expect(state.retryDelays(now: t0 + 101).keys.sorted() == ["a"])
    }

    @Test("the status map lists benched feeds with their reason, and prune drops expired ones")
    func statusAndPrune() {
        var state = LiveFeedAvailability()
        state.noteFailure(id: "old", reason: "playback failed", now: t0)
        state.noteFailure(id: "new", reason: "no video received", now: t0 + 500)
        let later = t0 + LiveFeedAvailability.cooldown + 1
        #expect(state.benched(now: later) == ["new": "no video received"])
        state.prune(now: later)
        #expect(state.failures.keys.sorted() == ["new"])
    }
}

@Suite("Live feed resolve policy")
struct LiveFeedResolvePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_794_770_000)

    private func manifest(expiring epoch: Int) -> String {
        "https://manifest.googlevideo.com/api/manifest/hls_variant/expire/\(epoch)/ei/abc/ip/1.2.3.4/id/x.1/playlist/index.m3u8"
    }

    @Test("the expiry is read from a googlevideo manifest URL")
    func expiryParsing() {
        #expect(LiveFeedResolvePolicy.expiry(ofResolvedURL: manifest(expiring: 1_794_780_815))
                == Date(timeIntervalSince1970: 1_794_780_815))
        #expect(LiveFeedResolvePolicy.expiry(ofResolvedURL: "https://example.com/v?expire=1794780815&x=1")
                == Date(timeIntervalSince1970: 1_794_780_815))
        #expect(LiveFeedResolvePolicy.expiry(ofResolvedURL: "https://example.com/live/index.m3u8") == nil)
        #expect(LiveFeedResolvePolicy.expiry(ofResolvedURL: "https://example.com/expire/soon/index.m3u8") == nil)
    }

    @Test("a URL is usable until its own expiry, not a moment longer")
    func usability() {
        let soon = Int(now.timeIntervalSince1970) + 3_600
        #expect(LiveFeedResolvePolicy.isUsable(resolvedURL: manifest(expiring: soon), resolvedAt: now, now: now))
        let past = Int(now.timeIntervalSince1970) - 10
        #expect(!LiveFeedResolvePolicy.isUsable(resolvedURL: manifest(expiring: past), resolvedAt: now, now: now))
        // Inside the safety margin counts as expired.
        let marginal = Int(now.timeIntervalSince1970) + 30
        #expect(!LiveFeedResolvePolicy.isUsable(resolvedURL: manifest(expiring: marginal), resolvedAt: now, now: now))
        #expect(!LiveFeedResolvePolicy.isUsable(resolvedURL: nil, resolvedAt: now, now: now))
        #expect(!LiveFeedResolvePolicy.isUsable(resolvedURL: "", resolvedAt: now, now: now))
    }

    @Test("without a readable expiry the resolve time decides")
    func assumedLifetime() {
        let url = "https://example.com/live/index.m3u8"
        let fresh = now.addingTimeInterval(-LiveFeedResolvePolicy.assumedLifetime + 600)
        let stale = now.addingTimeInterval(-LiveFeedResolvePolicy.assumedLifetime - 1)
        #expect(LiveFeedResolvePolicy.isUsable(resolvedURL: url, resolvedAt: fresh, now: now))
        #expect(!LiveFeedResolvePolicy.isUsable(resolvedURL: url, resolvedAt: stale, now: now))
        #expect(!LiveFeedResolvePolicy.isUsable(resolvedURL: url, resolvedAt: nil, now: now))
    }

    @Test("a fresh URL is left alone; an old or expired one is refreshed")
    func refresh() {
        let valid = manifest(expiring: Int(now.timeIntervalSince1970) + 10_000)
        #expect(!LiveFeedResolvePolicy.shouldResolve(resolvedURL: valid, resolvedAt: now.addingTimeInterval(-60),
                                                     lastFailedAt: nil, now: now))
        let old = now.addingTimeInterval(-LiveFeedResolvePolicy.refreshAfter)
        #expect(LiveFeedResolvePolicy.shouldResolve(resolvedURL: valid, resolvedAt: old, lastFailedAt: nil, now: now))
        let expired = manifest(expiring: Int(now.timeIntervalSince1970) - 1)
        #expect(LiveFeedResolvePolicy.shouldResolve(resolvedURL: expired, resolvedAt: now.addingTimeInterval(-60),
                                                    lastFailedAt: nil, now: now))
        #expect(LiveFeedResolvePolicy.shouldResolve(resolvedURL: nil, resolvedAt: nil, lastFailedAt: nil, now: now))
    }

    @Test("a failure holds automatic retries off for the backoff — the 4.1.11 logs show 4 yt-dlp runs in 7 s")
    func failureBackoff() {
        let justFailed = now.addingTimeInterval(-7)
        #expect(!LiveFeedResolvePolicy.shouldResolve(resolvedURL: nil, resolvedAt: nil, lastFailedAt: justFailed, now: now))
        let longAgo = now.addingTimeInterval(-5 * 60)
        #expect(LiveFeedResolvePolicy.shouldResolve(resolvedURL: nil, resolvedAt: nil, lastFailedAt: longAgo, now: now))
    }

    @Test("the retry gap grows with consecutive failures: 5, 15, 30 minutes, then hourly")
    func escalatingBackoff() {
        #expect(LiveFeedResolvePolicy.retryDelay(afterFailures: nil) == 5 * 60)
        #expect(LiveFeedResolvePolicy.retryDelay(afterFailures: 0) == 5 * 60)
        #expect(LiveFeedResolvePolicy.retryDelay(afterFailures: 1) == 5 * 60)
        #expect(LiveFeedResolvePolicy.retryDelay(afterFailures: 2) == 15 * 60)
        #expect(LiveFeedResolvePolicy.retryDelay(afterFailures: 3) == 30 * 60)
        #expect(LiveFeedResolvePolicy.retryDelay(afterFailures: 4) == 60 * 60)
        #expect(LiveFeedResolvePolicy.retryDelay(afterFailures: 40) == 60 * 60)
    }

    @Test("an automatic resolve waits out the step for the stored failure count")
    func backoffHonoursCount() {
        let tenMinutesAgo = now.addingTimeInterval(-10 * 60)
        // One failure: 5 min have passed → try. Two failures: 15 min step → wait.
        #expect(LiveFeedResolvePolicy.shouldResolve(resolvedURL: nil, resolvedAt: nil,
                                                    lastFailedAt: tenMinutesAgo, failureCount: 1, now: now))
        #expect(!LiveFeedResolvePolicy.shouldResolve(resolvedURL: nil, resolvedAt: nil,
                                                     lastFailedAt: tenMinutesAgo, failureCount: 2, now: now))
        #expect(LiveFeedResolvePolicy.nextAutomaticRetry(lastFailedAt: tenMinutesAgo, failureCount: 4)
                == tenMinutesAgo.addingTimeInterval(60 * 60))
    }

    @Test("yt-dlp failures map to something the user can act on")
    func hints() {
        #expect(LiveFeedResolveHint.classify("[youtube] UZ20XjGsCCs: Sign in to confirm you’re not a bot.") == .botCheck)
        #expect(LiveFeedResolveHint.classify("[youtube] Gd9d4q6WvUY: This video is not available") == .streamGone)
        #expect(LiveFeedResolveHint.classify("[youtube] abc: Private video. Sign in if you've been granted access") == .streamGone)
        #expect(LiveFeedResolveHint.classify(LiveFeedResolver.ytDlpMissingError) == .toolMissing)
        #expect(LiveFeedResolveHint.classify("yt-dlp could not be launched: no such file") == .toolMissing)
        #expect(LiveFeedResolveHint.classify("yt-dlp exited with status 2") == .other)
        let text = LiveFeedResolveHint.toolMissing.text(installCommand: "brew install yt-dlp", upgradeCommand: "brew upgrade yt-dlp")
        #expect(text == "yt-dlp is missing. Install it with brew install yt-dlp.")
        #expect(LiveFeedResolveHint.other.text(installCommand: "x", upgradeCommand: "brew upgrade yt-dlp").contains("brew upgrade yt-dlp"))
    }

    @Test("a failed RTSP transmuxer is not respawned for 30 s")
    func rtspBackoff() {
        #expect(LiveFeedResolvePolicy.shouldStartTransmuxer(lastFailedAt: nil, now: now))
        #expect(!LiveFeedResolvePolicy.shouldStartTransmuxer(lastFailedAt: now.addingTimeInterval(-4), now: now))
        #expect(!LiveFeedResolvePolicy.shouldStartTransmuxer(lastFailedAt: now.addingTimeInterval(-29.9), now: now))
        #expect(LiveFeedResolvePolicy.shouldStartTransmuxer(lastFailedAt: now.addingTimeInterval(-30), now: now))
    }

    @Test("yt-dlp's error is trimmed to its message")
    func errorSummary() {
        let botCheck = """
        WARNING: something unrelated
        ERROR: [youtube] UZ20XjGsCCs: Sign in to confirm you’re not a bot. Use --cookies-from-browser or --cookies for the authentication. See  https://github.com/yt-dlp/yt-dlp/wiki/FAQ#how-do-i-pass-cookies-to-yt-dlp  for how to manually pass cookies.
        """
        #expect(LiveFeedResolver.summarize(ytDlpError: botCheck, status: 1)
                == "[youtube] UZ20XjGsCCs: Sign in to confirm you’re not a bot.")
        #expect(LiveFeedResolver.summarize(ytDlpError: "ERROR: [youtube] Gd9d4q6WvUY: This video is not available", status: 1)
                == "[youtube] Gd9d4q6WvUY: This video is not available")
        #expect(LiveFeedResolver.summarize(ytDlpError: "", status: 2) == "yt-dlp exited with status 2")
    }
}

@Suite("Live feed model")
struct LiveFeedModelTests {
    @Test("a live-feeds.json written before the failure fields still decodes")
    func decodesOldFile() throws {
        let json = """
        {"id":"601B1DD2-C3EB-4A8F-A760-0369088B3415","displayName":"Boston","sourceURL":"https://www.youtube.com/watch?v=x",
         "kind":"youtube","playbackSeconds":1800,"addedAt":0}
        """
        let feed = try JSONDecoder().decode(LiveFeed.self, from: Data(json.utf8))
        #expect(feed.lastResolveError == nil)
        #expect(feed.lastResolveFailedAt == nil)
        #expect(feed.resolveFailureCount == nil)
    }

    @Test("a status file from an older extension has no unavailable feeds")
    func statusDefaults() throws {
        let status = try JSONDecoder().decode(WallpaperStatusState.self, from: Data(#"{"pid":1}"#.utf8))
        #expect(status.unavailableLiveFeeds.isEmpty)
        #expect(status.unavailableLiveFeedsRetryAt.isEmpty)
    }

    @Test("only retry times still ahead produce a message")
    func pendingRetries() {
        let now = Date(timeIntervalSince1970: 1_794_800_000)
        let pending = LiveFeedDownMessage.pending(["soon": 1_794_800_300, "past": 1_794_799_000], now: now)
        #expect(pending == ["soon": Date(timeIntervalSince1970: 1_794_800_300)])
        #expect(LiveFeedDownMessage.text(retryAt: Date(timeIntervalSince1970: 1_794_800_300)).hasPrefix("Feed down, will retry at "))
    }
}
