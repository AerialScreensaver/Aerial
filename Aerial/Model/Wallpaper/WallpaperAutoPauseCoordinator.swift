//
//  WallpaperAutoPauseCoordinator.swift
//  Auto-pause (window coverage) for the wallpaper EXTENSION.
//
//  The wallpaper extension is the playback vehicle, so Companion owns
//  the coverage watching itself (same detection code, same user
//  settings) and forwards coverage through the control channel's
//  per-screen `autoPaused` flag.
//
//  ONE 1 Hz poll covers every screen from a single window-server
//  snapshot (per-screen timers each took their own snapshot and
//  dominated idle CPU, 2026-07-24 sample). While the wallpaper is
//  paused by a non-coverage reason (user/battery/thermal/camera) the
//  poll samples only every `pausedPollStride` ticks — coverage can't
//  move a wallpaper that's paused anyway — and any control mutation
//  pokes an immediate sample so a resume never acts on stale coverage.
//
//  Active only while the status channel says the extension is running.
//  Stands down while the screensaver runs — the saver's own shield
//  window reads as ~100% coverage and must not auto-pause anything
//  (the extension additionally defers pauses on saver-driving
//  renderers; the post-saver reassert path restores coverage pauses).
//

import AppKit
import Combine
import os

@MainActor
final class WallpaperAutoPauseCoordinator {
    static let shared = WallpaperAutoPauseCoordinator()

    /// While paused by a non-coverage reason, sample coverage every
    /// N ticks instead of every tick (worst-case staleness ≈ N s,
    /// healed instantly by the control-mutation poke).
    private static let pausedPollStride = 15

    /// Per-screen occlusion state. Main-only.
    private struct Watch {
        let displayID: CGDirectDisplayID
        var isOccluded: Bool
    }

    private var watches: [String: Watch] = [:]
    private var coveredScreens: Set<String> = []
    private var cancellable: AnyCancellable?

    private var pollTimer: DispatchSourceTimer?
    /// uuid → displayID mirror of `watches`, readable from the poll
    /// tick off-main. Rebuilt whenever the watch set changes.
    private let pollTargets = OSAllocatedUnfairLock(initialState: [String: CGDirectDisplayID]())
    /// Tick counter + force flag for the pause-aware cadence.
    private let pollCadence = OSAllocatedUnfairLock(initialState: (tick: 0, force: false))

    private init() {}

    /// Call once from app startup. Reacts to extension status changes
    /// (running / saver-active) and display topology changes.
    func start() {
        cancellable = WallpaperStatusMonitor.shared.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reevaluate() }
            }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluate() }
        }
        reevaluate()
    }

    /// Re-derive the watch/pause state from prefs + extension status.
    /// Public so the settings toggle applies immediately instead of at
    /// the next status tick.
    func reevaluate() {
        let monitor = WallpaperStatusMonitor.shared
        // Saver and lock screen both present the wallpaper full-screen:
        // their own shield windows read as ~100% coverage and must not
        // trigger auto-pause.
        let presenting = (monitor.status?.saverActive ?? false)
            || (monitor.status?.lockedActive ?? false)
        let shouldWatch = Preferences.desktopAutoPause
            && monitor.isRunning
            && !presenting

        if shouldWatch {
            let wasWatching = pollTimer != nil
            syncWatchesToScreens()
            // Poke only when watching just started (saver exit,
            // extension appeared) — a fresh sample lands on the next
            // tick. Poking every status heartbeat would defeat the
            // paused-cadence stride.
            if !wasWatching { pokePoll() }
        } else if !Preferences.desktopAutoPause {
            // Feature off = no coverage pause, period. Clear EVERY flag
            // in the control file, not just our in-memory set — flags
            // set by a previous app session or on since-retired screen
            // UUIDs aren't in `coveredScreens` and would stick forever.
            teardownWatches()
            coveredScreens.removeAll()
            WallpaperControl.shared.clearAllAutoPaused()
        } else {
            let hadWatches = !watches.isEmpty
            teardownWatches()
            // Release coverage pauses when standing down because the
            // extension is gone — but NOT when the saver or lock screen
            // took over: those flags must survive so the exit/unlock
            // reasserts land them again.
            if hadWatches && !presenting && !coveredScreens.isEmpty {
                for uuid in coveredScreens {
                    WallpaperControl.shared.setAutoPaused(false, screenUUID: uuid)
                }
                coveredScreens.removeAll()
            }
        }
    }

    /// Any-thread. Force the next poll tick to sample coverage even if
    /// the pause-aware cadence would skip it — poked on every control
    /// mutation so a user resume acts on fresh coverage within a tick.
    nonisolated func pokePoll() {
        pollCadence.withLock { $0.force = true }
    }

    // MARK: - Watch bookkeeping (main)

    private func syncWatchesToScreens() {
        var current: [String: CGDirectDisplayID] = [:]
        for screen in NSScreen.screens {
            guard let did = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let cfUUID = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue() else { continue }
            current[CFUUIDCreateString(nil, cfUUID) as String] = did
        }

        // Control-file hygiene: coverage flags for screens that aren't
        // connected anymore (an earlier session's flag, or a UUID that
        // display re-enumeration retired) have no watcher left to clear
        // them and would pause shared/spanned playback forever.
        WallpaperControl.shared.pruneAutoPaused(keeping: Set(current.keys))

        for uuid in watches.keys where current[uuid] == nil {
            watches.removeValue(forKey: uuid)
            if coveredScreens.remove(uuid) != nil {
                WallpaperControl.shared.setAutoPaused(false, screenUUID: uuid)
            }
        }

        // Coverage only signals on CHANGES, so an already-covered
        // display (common at startup, or when the user just resumed)
        // would otherwise never fire. Seed new watches with their
        // current coverage and assert it now: an already-covered
        // display auto-pauses immediately, and a stale persisted
        // auto-pause flag for an uncovered display gets cleared.
        let added = current.filter { watches[$0.key] == nil }
        if !added.isEmpty {
            let seeds = DesktopOcclusionMonitor.coverages(
                for: added.mapValues { CGDisplayBounds($0) }
            )
            let threshold = Preferences.desktopAutoPauseThreshold
            for (uuid, did) in added {
                let coveredNow = (seeds[uuid] ?? 0) >= threshold
                watches[uuid] = Watch(displayID: did, isOccluded: coveredNow)
                debugLog("🖥️ Wallpaper auto-pause watching screen \(uuid.prefix(8)) (display \(did)) covered=\(coveredNow)")
                coverageChanged(uuid: uuid, covered: coveredNow)
            }
        }

        let mirror = watches.mapValues { $0.displayID }
        pollTargets.withLock { $0 = mirror }
        watches.isEmpty ? cancelPollTimer() : ensurePollTimer()
    }

    private func teardownWatches() {
        // Idempotent + silent: reevaluate() lands here on every status
        // heartbeat while the saver/lock screen is up — only log and
        // work on an actual transition.
        guard !watches.isEmpty || pollTimer != nil else { return }
        watches.removeAll()
        pollTargets.withLock { $0 = [:] }
        cancelPollTimer()
        debugLog("🖥️ Wallpaper auto-pause watching stopped")
    }

    // MARK: - Polling (utility queue)

    private func ensurePollTimer() {
        guard pollTimer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now() + 1.0, repeating: 1.0)
        source.setEventHandler { [weak self] in
            self?.pollTick()
        }
        source.resume()
        pollTimer = source
    }

    private func cancelPollTimer() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    nonisolated private func pollTick() {
        let targets = pollTargets.withLock { $0 }
        guard !targets.isEmpty else { return }

        let (tick, forced) = pollCadence.withLock { state -> (Int, Bool) in
            state.tick += 1
            let force = state.force
            state.force = false
            return (state.tick, force)
        }
        // Pause-aware cadence: a wallpaper paused by a non-coverage
        // reason can't move, so its coverage only needs a slow
        // heartbeat (control mutations poke past the stride).
        if !forced,
           tick % Self.pausedPollStride != 0,
           WallpaperControl.shared.currentNonCoveragePaused {
            return
        }

        // Screen bounds re-resolved every sample: display rearranges in
        // System Settings → Displays heal within the next tick, and an
        // unplugged display's `.null` bounds read as 0% coverage until
        // the disconnect reevaluate tears its watch down.
        let coverages = DesktopOcclusionMonitor.coverages(
            for: targets.mapValues { CGDisplayBounds($0) }
        )
        let threshold = Preferences.desktopAutoPauseThreshold
        DispatchQueue.main.async { [weak self] in
            self?.applyCoverages(coverages, threshold: threshold)
        }
    }

    private func applyCoverages(_ coverages: [String: Double], threshold: Double) {
        for (uuid, coverage) in coverages {
            guard var watch = watches[uuid] else { continue }
            let nowOccluded = coverage >= threshold
            guard nowOccluded != watch.isOccluded else { continue }
            watch.isOccluded = nowOccluded
            watches[uuid] = watch
            debugLog("🖥️ Occlusion changed: \(nowOccluded ? "occluded" : "visible") (coverage: \(Int(coverage * 100))%)")
            coverageChanged(uuid: uuid, covered: nowOccluded)
        }
    }

    private func coverageChanged(uuid: String, covered: Bool) {
        guard watches[uuid] != nil else { return }
        if covered {
            coveredScreens.insert(uuid)
        } else {
            coveredScreens.remove(uuid)
        }
        debugLog("🖥️ Wallpaper auto-pause: screen \(uuid.prefix(8)) covered=\(covered)")
        // Per-screen signal in every viewing mode: per-screen renderers
        // map 1:1; the broadcast renderer (cloned/spanned) pauses on any
        // covered screen and only resumes when the extension sees no
        // screen still flagged — matching the desktop path's "any
        // covered screen pauses all" semantics.
        WallpaperControl.shared.setAutoPaused(covered, screenUUID: uuid)
    }
}
