//
//  SystemSleepState.swift
//  Aerial Companion
//
//  Tracks whether the Mac is within a system-sleep span so background
//  maintenance (download scheduling, location refresh) can stand down
//  during sleep — including the periodic "dark wakes" macOS performs
//  under Power Nap.
//
//  `NSWorkspace.willSleepNotification` fires once before sleep and
//  `didWakeNotification` fires once on the next *full* wake; neither
//  fires during a dark wake. So a flag raised on willSleep and lowered
//  on didWake is true for the entire sleep span (every dark wake in
//  between), and false whenever the Mac is genuinely awake — even if
//  the display alone has slept. That's exactly the gate we want:
//  suppress uninvited work during sleep, but keep filling the cache on
//  an always-on Mac whose display merely powered down.
//
//  Companion-only module.
//

import AppKit

final class SystemSleepState {
    static let shared = SystemSleepState()

    /// Guards `_isAsleep`: written on the main thread (notifications post
    /// to main) and read from DownloadCoordinator's work queue.
    private let lock = NSLock()
    private var _isAsleep = false

    private var started = false

    /// True while the system is in its sleep span (including dark wakes).
    /// Defaults to false so a freshly launched app is never gated — a
    /// launch implies an awake session.
    var isAsleep: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isAsleep
    }

    private init() {}

    // MARK: - Lifecycle

    /// Call once from AppDelegate at startup.
    func start() {
        guard !started else { return }
        started = true

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self,
                       selector: #selector(handleWillSleep),
                       name: NSWorkspace.willSleepNotification,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(handleDidWake),
                       name: NSWorkspace.didWakeNotification,
                       object: nil)
    }

    // MARK: - Notifications

    @objc private func handleWillSleep() {
        lock.lock(); _isAsleep = true; lock.unlock()
        debugLog("SystemSleepState: willSleep — gating background maintenance")
    }

    @objc private func handleDidWake() {
        lock.lock(); _isAsleep = false; lock.unlock()
        debugLog("SystemSleepState: didWake — background maintenance ungated")

        // Catch up on the maintenance we deferred during sleep. Clearing the
        // flag *before* this call (above) keeps the ordering deterministic:
        // the scheduled check sees an awake state and runs. This absorbs the
        // wake handler DownloadCoordinator used to own itself.
        DownloadCoordinator.shared.performScheduledCheck()
    }
}
