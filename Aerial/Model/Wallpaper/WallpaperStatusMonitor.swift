//
//  WallpaperStatusMonitor.swift
//  Companion-side reader of the wallpaper extension's status channel.
//
//  The extension writes `/Users/Shared/Aerial/wallpaper-status.json`
//  every 30 s (plus on acquire/invalidate/reconcile) and posts the
//  `com.glouel.aerial.wallpaper-status` Darwin notification. This
//  monitor mirrors that into observable state: the Dashboard's
//  wallpaper card and the auto-pause coordinator key off `isRunning`
//  (status fresh within 90 s) instead of writing commands blind.
//

import CoreGraphics
import Foundation

@MainActor
final class WallpaperStatusMonitor: ObservableObject {
    static let shared = WallpaperStatusMonitor()

    @Published private(set) var status: WallpaperStatusState?
    @Published private(set) var isRunning = false

    /// Status older than this is treated as "extension not running"
    /// (writes land every 30 s; 90 s tolerates a missed cycle).
    private static let freshnessWindow: TimeInterval = 90

    private var stalenessTimer: Timer?

    /// Ids of the videos on screen right now (one per display), readable
    /// from ANY thread — the cache evictors run on the download
    /// coordinator's queue and must never delete what is playing. Empty
    /// when the extension isn't running. Refreshed by every `reload()`.
    nonisolated private static let nowPlayingLock = NSLock()
    nonisolated(unsafe) private static var nowPlayingSnapshot: Set<String> = []

    nonisolated static func nowPlayingVideoIds() -> Set<String> {
        nowPlayingLock.lock()
        defer { nowPlayingLock.unlock() }
        return nowPlayingSnapshot
    }

    nonisolated private static func updateNowPlayingSnapshot(_ ids: Set<String>) {
        nowPlayingLock.lock()
        nowPlayingSnapshot = ids
        nowPlayingLock.unlock()
    }

    /// Last control version we re-posted for (deaf-extension self-heal)
    /// — once per version, so a genuinely wedged extension doesn't get
    /// notification-spammed every 30 s.
    private var lastRenotifiedVersion = 0

    private init() {
        reload()
        registerDarwinObserver()

        // Freshness decays without any event when the extension dies —
        // re-evaluate periodically so the UI flips to "not running".
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                WallpaperStatusMonitor.shared.reload()
            }
        }
        timer.tolerance = 5
        stalenessTimer = timer
    }

    func reload() {
        let loaded = JSONPreferencesStore.shared.read(
            WallpaperStatusState.self,
            from: WallpaperStatusState.fileURL
        )
        status = loaded
        isRunning = loaded.map {
            Date().timeIntervalSince($0.lastSeen) < Self.freshnessWindow
        } ?? false
        Self.updateNowPlayingSnapshot(isRunning ? Set((loaded?.nowPlayingId ?? [:]).values) : [])

        // Desktop-wallpaper activation for the extension (screensaver-only
        // vs wallpaper): one store read per heartbeat, written on change.
        WallpaperControl.shared.refreshDesktopWallpaperActivation(reason: "status heartbeat")

        // Stale-build check (one evaluation per launch, restart once per
        // installed build) + post-restart "resolved" log.
        if let loaded {
            WallpaperExtensionHealth.evaluate(status: loaded, isRunning: isRunning)
        }

        // Mirror the extension's actual per-display playback into the
        // playlist position so the dashboard/popover "now playing",
        // highlight and preview reflect reality (not Companion's guess).
        if isRunning, let ids = loaded?.nowPlayingId, !ids.isEmpty {
            PlaylistManager.shared.applyExtensionNowPlaying(ids)

            // Keep on-screen live feeds fresh: their yt-dlp URLs expire
            // and nothing else re-resolves while the EXTENSION is the
            // player (launch-time resolveAll + Companion-pop prewarm
            // never fire then). Live ids are feed UUIDs; the resolver
            // is TTL-gated (2 h) so this is nearly always a no-op.
            for id in ids.values {
                if let uuid = UUID(uuidString: id),
                   let feed = LiveFeedManager.shared.feed(id: uuid) {
                    LiveFeedResolver.shared.resolveIfNeeded(feed)
                }
            }
        }

        // Deaf-extension self-heal: the status echoes the control
        // version the extension last APPLIED. Running but behind our
        // writer means a missed/coalesced Darwin notification (throttled
        // appex) — re-post, once per version. A false positive (status
        // write racing a fresh mutate) costs one duplicate notification,
        // which the version gate ignores.
        if isRunning, let applied = loaded?.appliedControlVersion, applied > 0 {
            let current = WallpaperControl.shared.currentVersion
            if applied < current, lastRenotifiedVersion != current {
                lastRenotifiedVersion = current
                debugLog("[WallpaperStatus] extension applied v\(applied) < our v\(current) — re-posting control notification")
                WallpaperControl.shared.repostControlNotification()
            }
        }
    }

    private func registerDarwinObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let monitor = Unmanaged<WallpaperStatusMonitor>.fromOpaque(observer).takeUnretainedValue()
                // Darwin callbacks deliver on the registering thread's
                // run loop (main here); the hop keeps it formal.
                Task { @MainActor in monitor.reload() }
            },
            WallpaperStatusState.darwinNotificationName as CFString,
            nil, .deliverImmediately
        )
    }
}

/// Diagnostic window-list dumper for the "second screensaver window in
/// a corner" reports. The extension can't see WallpaperAgent's window
/// geometry — only the Companion (a regular app) can enumerate it via
/// CGWindowList. Saver windows linger 5-20 s after didstop, so dumping
/// shortly after each saver start/stop catches the spurious window's
/// exact frame and owner while it's still on screen. Window NAMES need
/// screen-recording permission; frames/owners/layers don't, and that's
/// all we log.
enum WallpaperWindowDump {
    static func register() {
        let dnc = DistributedNotificationCenter.default()
        let events: [(name: String, delays: [Double])] = [
            ("com.apple.screensaver.didstart", [2.0]),
            ("com.apple.screensaver.didstop", [2.0, 8.0]),
        ]
        for event in events {
            dnc.addObserver(forName: Notification.Name(event.name), object: nil, queue: .main) { _ in
                for delay in event.delays {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        dump(reason: "\(event.name.split(separator: ".").last ?? "") +\(Int(delay))s")
                    }
                }
            }
        }
        debugLog("🪟 WallpaperWindowDump registered (saver start/stop)")
    }

    /// Log every window that could plausibly be a wallpaper/saver
    /// surface: anything owned by a wallpaper-ish process, plus any
    /// window at or below the desktop level band (layer < 0).
    static func dump(reason: String) {
        let lines = capture()
        debugLog("🪟 window dump [\(reason)]: \(lines.count) wallpaper/desktop-band window(s)")
        for line in lines { debugLog("  \(line)") }
    }

    /// Build the dump lines without logging — shared by `dump` and the
    /// diagnostics-bundle exporter.
    static func capture() -> [String] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return ["🪟 CGWindowListCopyWindowInfo returned nil"]
        }
        let interestingOwners = ["wallpaper", "loginwindow", "screensaver", "dock"]
        var lines: [String] = []
        for w in list {
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? "?"
            let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
            let ownerMatch = interestingOwners.contains { owner.lowercased().contains($0) }
            guard ownerMatch || layer < 0 else { continue }
            let pid = (w[kCGWindowOwnerPID as String] as? Int) ?? 0
            let num = (w[kCGWindowNumber as String] as? Int) ?? 0
            let onscreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
            let alpha = (w[kCGWindowAlpha as String] as? Double) ?? 1
            var boundsDesc = "?"
            if let b = w[kCGWindowBounds as String] as? [String: Double] {
                boundsDesc = describeBounds(b)
            }
            lines.append("🪟 \(owner)(\(pid)) #\(num) layer=\(layer) bounds=\(boundsDesc) onscreen=\(onscreen)\(alpha < 1 ? String(format: " a=%.2f", alpha) : "")")
        }
        return lines.sorted()
    }

    /// `kCGWindowBounds` as "(x,y wxh)" in CG global coordinates (origin
    /// top-left of the main display, y down). Never converts blindly:
    /// the window server hands out NaN / ±inf / 1.8e308 bounds for
    /// lock-screen transition windows, and `Int(_:)` traps on those —
    /// the 2026-09-15 Companion SIGTRAP on the second saver start of a
    /// row (dump fired as the screen locked). Such values are printed
    /// raw so the offending window stays identifiable in the log.
    static func describeBounds(_ bounds: [String: Double]) -> String {
        func component(_ key: String) -> String {
            let value = bounds[key] ?? 0
            guard value.isFinite, abs(value) < 1_000_000_000 else { return "\(value)" }
            return String(Int(value))
        }
        return "(\(component("X")),\(component("Y")) \(component("Width"))x\(component("Height")))"
    }
}
