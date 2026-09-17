//
//  WallpaperControl.swift
//  Companion-side owner of the wallpaper extension's live control channel.
//
//  The wallpaper extension (Aerial4WallpaperExtension) is ephemeral —
//  ExtensionKit kills the process every 30–45s. So instead of an XPC
//  connection (which would have to be rebuilt on every respawn), we
//  use a file + Darwin notification pattern:
//
//    1. Companion mutates the in-memory `WallpaperControlState`.
//    2. Bumps `.version`, writes atomically to wallpaper-control.json.
//    3. Posts `com.glouel.aerial.wallpaper-control` Darwin notification.
//    4. Extension's WallpaperControlListener wakes, re-reads, reconciles.
//
//  Action counters (advance/regress) give "do this now" semantics
//  without a command queue/ACK protocol — the extension acts on the
//  delta from its last-applied state.
//

import AppKit
import Foundation
import SwiftUI
import PaperSaverKit

final class WallpaperControl: @unchecked Sendable {
    static let shared = WallpaperControl()

    /// Every mutation runs END-TO-END (state change → version bump →
    /// file write → Darwin post) on this serial queue, so version order
    /// == file order == notification order. The old NSLock covered only
    /// the in-memory mutation — the write + post ran after unlock, so a
    /// background mutate (download-driven playlistDidChange,
    /// displaysConfigDidChange) overlapping a main-thread setSpeed could
    /// land files out of order, regressing the on-disk version and
    /// silencing the extension's version gate until the next write.
    /// Read-backs sync on the same queue. We can't be `@MainActor`
    /// because `PlaylistManager.persist()` (which fires
    /// `playlistDidChange` after every playlists.json write) runs on a
    /// nonisolated synchronous context.
    private let controlQueue = DispatchQueue(label: "com.glouel.aerial.wallpaper-control-writer", qos: .userInitiated)
    private var state: WallpaperControlState
    private let store = JSONPreferencesStore.shared

    /// Pending coalesced `settingsGeneration` bump (margin sliders fire
    /// onChange continuously — one bump per quiet window is enough).
    private var pendingDisplaysBump: DispatchWorkItem?

    /// Retained so the overlay-config observation lives as long as the
    /// singleton (i.e. the process).
    private var overlayConfigObserver: NSObjectProtocol?

    /// Retained observer for screen-parameter changes (dock moves,
    /// menu bar changes, display topology) — drives the dock-insets
    /// relay to the extension.
    private var screenParamsObserver: NSObjectProtocol?

    /// Pending debounced dock-insets publish (a dock drag fires several
    /// screen-parameter changes in a burst).
    private var pendingDockPublish: DispatchWorkItem?

    /// NSScreen layout (ids + frames + scale) as of the last publish —
    /// a change bumps `screenLayoutGeneration` even when every inset
    /// is unchanged (main-thread only, like `publishDockInsets`).
    private var lastPublishedScreenLayout: String?

    private init() {
        // Load existing state if present so we don't reset on app launch.
        if let loaded = store.read(WallpaperControlState.self, from: WallpaperControlState.fileURL) {
            self.state = loaded
        } else {
            self.state = WallpaperControlState()
        }

        // Forward overlay-config rewrites to the extension. Every
        // overlay writer (the separate-desktop toggle, all overlay-
        // editor saves) funnels through OverlayConfigManager.setConfig/
        // setLayout, which posts this notification — one hook covers
        // them all.
        overlayConfigObserver = NotificationCenter.default.addObserver(
            forName: OverlayConfigManager.configDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.overlayConfigDidChange()
        }

        // Relay dock/menubar geometry to the extension. The appex can't
        // see dock moves itself — without an NSApplication run loop its
        // NSScreen geometry is frozen at first access — while we get
        // didChangeScreenParameters reliably.
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleDockInsetsPublish()
        }
        DispatchQueue.main.async { [weak self] in
            self?.publishDockInsets()
        }
    }

    // MARK: - Dock insets relay

    private func scheduleDockInsetsPublish() {
        pendingDockPublish?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.publishDockInsets() }
        pendingDockPublish = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Measure per-screen dock/menubar insets and publish them to the
    /// extension (no-op when unchanged). The extension falls back to its
    /// own launch-time measurement only when nothing was ever published.
    private func publishDockInsets() {
        var insets: [String: [Double]] = [:]
        var layout: [String] = []
        for screen in NSScreen.screens {
            guard let did = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let cfUUID = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue() else { continue }
            let uuid = CFUUIDCreateString(nil, cfUUID) as String
            let e = DockInfo.detect(for: screen).swiftUIInsets
            insets[uuid] = [Double(e.top), Double(e.leading), Double(e.bottom), Double(e.trailing)]
            let f = screen.frame
            layout.append("\(did):\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))@\(screen.backingScaleFactor)")
        }
        // Display set / arrangement relay: the appex can't observe
        // hot-plugs or System Settings drags itself (frozen NSScreen)
        // and a rearrangement can leave every inset identical, so it
        // rides its own counter. The first publish only seeds.
        let layoutSignature = layout.sorted().joined(separator: "|")
        let layoutChanged = lastPublishedScreenLayout != nil && lastPublishedScreenLayout != layoutSignature
        lastPublishedScreenLayout = layoutSignature
        mutate(layoutChanged ? "screenLayoutDidChange" : "dockInsets") { state in
            var changed = false
            if state.dockInsets != insets {
                state.dockInsets = insets
                changed = true
            }
            if layoutChanged {
                state.screenLayoutGeneration &+= 1
                changed = true
            }
            return changed
        }
    }

    // MARK: - Public API

    /// Current global playback rate. Settings UI reads this to seed
    /// its slider on appear.
    var currentSpeed: Double {
        controlQueue.sync { state.speed }
    }

    /// Current global pause flag. Settings UI reads this to seed its
    /// pause button on appear.
    var currentPaused: Bool {
        controlQueue.sync { state.paused }
    }

    /// Whether Aerial is the system desktop wallpaper, as last published
    /// to the extension (see `refreshDesktopWallpaperActivation`).
    var desktopWallpaperActive: Bool {
        controlQueue.sync { state.desktopWallpaperActive }
    }

    /// Current video-change transition style. Settings UI reads this
    /// to seed its picker on appear.
    var currentTransitionStyle: WallpaperTransitionStyle {
        controlQueue.sync { state.transitionStyleValue }
    }

    /// Current natural-boundary transition duration in seconds.
    var currentTransitionDuration: Double {
        controlQueue.sync { state.transitionDuration }
    }

    /// Current "play audio from videos" flag. Settings UI reads this
    /// to seed its toggle on appear.
    var currentAudioEnabled: Bool {
        controlQueue.sync { state.audioEnabled }
    }

    /// Current audio volume (0...1). Settings UI reads this to seed
    /// its slider on appear.
    var currentAudioVolume: Double {
        controlQueue.sync { state.audioVolume }
    }

    /// Current writer version — the status monitor compares this against
    /// the extension's `appliedControlVersion` echo to detect a missed
    /// notification.
    var currentVersion: Int {
        controlQueue.sync { state.version }
    }

    /// True while playback is held by any NON-coverage reason
    /// (user/battery/thermal/camera). The auto-pause coordinator
    /// downshifts its window polling while this holds — coverage
    /// changes can't move a wallpaper that's paused anyway.
    var currentNonCoveragePaused: Bool {
        controlQueue.sync {
            state.paused || state.batteryPaused || state.thermalPaused || state.cameraPaused
        }
    }

    /// Re-post the control Darwin notification without mutating — the
    /// deaf-extension self-heal. The extension re-reads the file; its
    /// version gate makes a spurious re-post a logged no-op.
    func repostControlNotification() {
        controlQueue.async {
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(WallpaperControlState.darwinNotificationName as CFString),
                nil, nil, true
            )
        }
    }

    /// Set the global playback rate. Visible on the wallpaper within
    /// ~50ms (notification wake + reconcile + CMTimebaseSetRate).
    func setSpeed(_ rate: Double) {
        mutate("setSpeed(\(rate))") { state in
            guard rate != state.speed else { return false }
            state.speed = rate
            return true
        }
    }

    /// Set the video-change transition (style + natural-boundary
    /// duration). Applies from the next video boundary on every
    /// renderer.
    func setTransition(style: WallpaperTransitionStyle, duration: Double) {
        mutate("setTransition(\(style.rawValue), \(duration)s)") { state in
            guard style.rawValue != state.transitionStyle
                || duration != state.transitionDuration else { return false }
            state.transitionStyle = style.rawValue
            state.transitionDuration = duration
            return true
        }
    }

    /// Enable/disable playing the video's own audio track. Applied live
    /// by the extension; audio only actually sounds at 100% playback
    /// speed (screensaver, or wallpaper at full speed), from one
    /// renderer (main display in independent mode), never on the lock
    /// screen.
    func setAudioEnabled(_ enabled: Bool) {
        mutate("setAudioEnabled(\(enabled))") { state in
            guard enabled != state.audioEnabled else { return false }
            state.audioEnabled = enabled
            return true
        }
    }

    /// Set the audio volume (0...1). Applied live to the owning
    /// renderer.
    func setAudioVolume(_ volume: Double) {
        mutate("setAudioVolume(\(volume))") { state in
            guard volume != state.audioVolume else { return false }
            state.audioVolume = volume
            return true
        }
    }

    /// Publish whether Aerial is the system desktop wallpaper. The store
    /// read (PaperSaverKit, one plist) runs off-main; the control file is
    /// only rewritten on a change. Screensaver-only installs get `false`,
    /// which makes the extension treat every idle acquire as the saver
    /// and ignore the desktop-side pause flags, and makes the auto-pause
    /// coordinator stand down. Called from the status heartbeat and
    /// after every wallpaper-store write of ours.
    func refreshDesktopWallpaperActivation(reason: String) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let active = Self.isAerialSystemWallpaper() == true
            mutate("desktopWallpaperActive(\(active), \(reason))") { state in
                guard active != state.desktopWallpaperActive else { return false }
                debugLog("🖼 desktop wallpaper active: \(state.desktopWallpaperActive) → \(active) (\(reason))")
                state.desktopWallpaperActive = active
                return true
            }
            if !active {
                // Coverage flags are desktop-only; clear any left behind
                // so a saver session can never inherit them. No-op when
                // there is nothing to clear.
                clearAllAutoPaused()
            }
        }
    }

    /// Set the global pause flag. Visible on the wallpaper within
    /// ~50ms (notification wake + reconcile + renderer pause/resume).
    func setPaused(_ paused: Bool) {
        mutate("setPaused(\(paused))") { state in
            guard paused != state.paused else { return false }
            state.paused = paused
            return true
        }
    }

    /// Set the battery-pause flag. Separate from `setPaused` (the user's
    /// static/animated intent): the extension pauses when EITHER is set,
    /// but clearing battery-pause never resumes a user-paused (still)
    /// wallpaper. Driven by `PlaybackManager`'s battery monitor.
    func setBatteryPaused(_ paused: Bool) {
        mutate("setBatteryPaused(\(paused))") { state in
            guard paused != state.batteryPaused else { return false }
            state.batteryPaused = paused
            return true
        }
    }

    /// Clear the coverage flag on EVERY screen entry — used when the
    /// auto-pause feature is turned off. Flags can outlive their
    /// screens (set by a previous app session, or on a display UUID
    /// that re-enumeration retired), and a stale one pauses shared/
    /// spanned playback forever: the broadcast rule is
    /// any-screen-covered, and no watcher exists to ever clear it
    /// (2026-07-08 field incident).
    func clearAllAutoPaused() {
        mutate("clearAllAutoPaused") { state in
            var changed = false
            for key in state.screens.keys where state.screens[key]?.autoPaused == true {
                state.screens[key]?.autoPaused = false
                changed = true
            }
            return changed
        }
    }

    /// Clear coverage flags on screens NOT in `validUUIDs` — a display
    /// that disappears takes its flag with it instead of haunting the
    /// broadcast any-screen-covered fold.
    func pruneAutoPaused(keeping validUUIDs: Set<String>) {
        mutate("pruneAutoPaused") { state in
            var changed = false
            for key in state.screens.keys
            where !validUUIDs.contains(key) && state.screens[key]?.autoPaused == true {
                state.screens[key]?.autoPaused = false
                changed = true
            }
            return changed
        }
    }

    /// Set the thermal/Low Power Mode pause flag. Same separation
    /// rationale as `setBatteryPaused` — clearing it never resumes a
    /// user-paused wallpaper. Driven by `PlaybackManager`'s thermal
    /// monitor.
    func setThermalPaused(_ paused: Bool) {
        mutate("setThermalPaused(\(paused))") { state in
            guard paused != state.thermalPaused else { return false }
            state.thermalPaused = paused
            return true
        }
    }

    /// Set the camera-in-use pause flag. Driven by `PlaybackManager`'s
    /// camera monitor (CoreMediaIO device-running state).
    func setCameraPaused(_ paused: Bool) {
        mutate("setCameraPaused(\(paused))") { state in
            guard paused != state.cameraPaused else { return false }
            state.cameraPaused = paused
            return true
        }
    }

    /// Bump the advance counter for one screen (or all screens if nil).
    func advanceVideo(screenUUID: String?) {
        noteVideoNavigation()
        mutate("advance(\(screenUUID?.prefix(8).description ?? "all"))") { state in
            if let uuid = screenUUID {
                var screen = state.screens[uuid, default: WallpaperScreenControl()]
                screen.advanceCounter &+= 1
                state.screens[uuid] = screen
            } else {
                for key in state.screens.keys {
                    state.screens[key]?.advanceCounter &+= 1
                }
            }
            return true
        }
    }

    /// Mirror of `advanceVideo`, bumping `regressCounter` instead.
    func regressVideo(screenUUID: String?) {
        noteVideoNavigation()
        mutate("regress(\(screenUUID?.prefix(8).description ?? "all"))") { state in
            if let uuid = screenUUID {
                var screen = state.screens[uuid, default: WallpaperScreenControl()]
                screen.regressCounter &+= 1
                state.screens[uuid] = screen
            } else {
                for key in state.screens.keys {
                    state.screens[key]?.regressCounter &+= 1
                }
            }
            return true
        }
    }

    /// Request an immediate jump to `index` in the screen's playlist (or
    /// all screens if nil). Bumps a monotonic token so repeat jumps to the
    /// same index still fire. The extension seeks its persisted playlist
    /// and swaps to that video.
    func jumpToVideo(index: Int, screenUUID: String?) {
        noteVideoNavigation()
        mutate("jump(\(index), \(screenUUID?.prefix(8).description ?? "all"))") { state in
            if let uuid = screenUUID {
                var screen = state.screens[uuid, default: WallpaperScreenControl()]
                screen.jumpIndex = index
                screen.jumpToken &+= 1
                state.screens[uuid] = screen
            } else {
                // Union in the connected screens like playlistDidChange:
                // entries are created lazily, so an empty or incomplete
                // map would silently drop a broadcast jump (a version
                // bump with zero token deltas).
                var keys = Set(state.screens.keys)
                keys.formUnion(Self.connectedScreenUUIDs())
                for key in keys {
                    var screen = state.screens[key, default: WallpaperScreenControl()]
                    screen.jumpIndex = index
                    screen.jumpToken &+= 1
                    state.screens[key] = screen
                }
            }
            return true
        }
    }

    /// Every video navigation (auto or manual, from any UI) restarts the
    /// auto-advance countdown — "change every X" means X since the video
    /// last changed, however it changed.
    private func noteVideoNavigation() {
        Task { @MainActor in
            PlaybackManager.shared.noteVideoChanged()
        }
    }

    /// Called by PlaylistManager after writing a new playlists.json.
    /// Bumps `playlistGeneration` so the extension drops its cached
    /// PlaylistState and picks up the new one.
    func playlistDidChange(screenUUID: String?) {
        mutate("playlistDidChange(\(screenUUID?.prefix(8).description ?? "all"))") { state in
            if let uuid = screenUUID {
                var screen = state.screens[uuid, default: WallpaperScreenControl()]
                screen.playlistGeneration &+= 1
                state.screens[uuid] = screen
            } else {
                // Bump every recorded screen AND every currently-connected
                // one. Entries are otherwise created lazily (per-screen
                // advance/jump, auto-pause coverage), so an empty or
                // incomplete map used to drop the shared-playlist signal:
                // a version bump with zero generation deltas, which the
                // extension's per-screen diff never sees.
                var keys = Set(state.screens.keys)
                keys.formUnion(Self.connectedScreenUUIDs())
                for key in keys {
                    var screen = state.screens[key, default: WallpaperScreenControl()]
                    screen.playlistGeneration &+= 1
                    state.screens[key] = screen
                }
            }
            return true
        }
    }

    /// UUIDs of the currently-connected screens — the keys the
    /// extension's control listener watches. Same derivation as
    /// WallpaperAutoPauseCoordinator.
    private static func connectedScreenUUIDs() -> [String] {
        NSScreen.screens.compactMap { screen in
            guard let did = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let cfUUID = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue() else { return nil }
            return CFUUIDCreateString(nil, cfUUID) as String
        }
    }

    /// Auto-pause (window coverage) signal from the occlusion
    /// coordinator. Per-screen; nil applies to every known screen.
    /// Distinct from `setPaused` — the extension defers it while the
    /// saver runs, and clearing it never overrides an explicit user
    /// pause.
    func setAutoPaused(_ paused: Bool, screenUUID: String?) {
        mutate("setAutoPaused(\(paused), \(screenUUID?.prefix(8).description ?? "all"))") { state in
            if let uuid = screenUUID {
                var screen = state.screens[uuid, default: WallpaperScreenControl()]
                guard screen.autoPaused != paused else { return false }
                screen.autoPaused = paused
                state.screens[uuid] = screen
                return true
            } else {
                var changed = false
                for key in state.screens.keys where state.screens[key]?.autoPaused != paused {
                    state.screens[key]?.autoPaused = paused
                    changed = true
                }
                return changed
            }
        }
    }

    /// Displays-related settings changed (viewing mode, display mode,
    /// aspect, margins). Coalesced ~0.3 s so slider drags produce one
    /// reconfigure on the extension side, not a storm.
    func displaysConfigDidChange() {
        controlQueue.async { [self] in
            pendingDisplaysBump?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.mutate("displaysConfigDidChange") { state in
                    state.settingsGeneration &+= 1
                    return true
                }
            }
            pendingDisplaysBump = work
            controlQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    /// overlay-config.json was rewritten — tell the extension to
    /// re-read it and rebuild its overlay drivers.
    func overlayConfigDidChange() {
        mutate("overlayConfigDidChange") { state in
            state.overlayGeneration &+= 1
            return true
        }
    }

    // MARK: - System wallpaper enablement (via PaperSaverKit)
    //
    // On macOS Sonoma+ Aerial4 is set as the active system wallpaper/screensaver
    // by writing the wallpaper store's Index.plist + restarting WallpaperAgent
    // (`PaperSaver.setWallpaperExtension`). This is distinct from
    // `WallpaperStatusMonitor`, which only reports whether the extension *process*
    // is running — not whether Aerial4 is the *selected* wallpaper.

    /// Bundle identifier of the Aerial4 wallpaper extension — the choice "provider"
    /// the wallpaper store records when Aerial4 is the active wallpaper/screensaver.
    static let aerial4BundleID = "com.glouel.Aerial-App.Aerial4WallpaperExtension"

    /// Whether Aerial4 is currently the active *system* wallpaper (desktop slot).
    /// Returns `false` when another wallpaper is set or the store is unreadable.
    static func isAerialSystemWallpaper() -> Bool? {
        return PaperSaverKit.PaperSaver().getCurrentWallpaperExtension() == aerial4BundleID
    }

    /// Whether Aerial4 is currently the active *system* screensaver (idle slot).
    static func isAerialSystemScreensaver() -> Bool? {
        return PaperSaverKit.PaperSaver().getCurrentScreensaverExtension() == aerial4BundleID
    }

    /// Set Aerial4 as BOTH the desktop wallpaper and the screensaver (the `.animated`
    /// and `.paused` first-launch modes). Fire-and-forget (wizard semantics).
    static func enableAerialWallpaperAndScreensaver() {
        Task { _ = await setAerial(slot: .both) }
    }

    /// Set Aerial4 as the screensaver only (the `.off` "screensaver only" mode), leaving
    /// the user's current desktop wallpaper in place. Fire-and-forget (wizard semantics).
    ///
    /// - Note: switching here from a state where Aerial4 was already the wallpaper
    ///   (e.g. `.animated` → `.off`) leaves Aerial4 as the wallpaper — reverting to the
    ///   user's prior wallpaper needs a capture/restore step (a follow-up; PaperSaver's
    ///   image-wallpaper path is currently broken). On a fresh install `.off` correctly
    ///   sets the screensaver only and keeps the existing wallpaper.
    static func enableAerialScreensaverOnly() {
        Task { _ = await setAerial(slot: .screensaver) }
    }

    /// Set Aerial4 as the desktop wallpaper (preserving the current screensaver).
    /// Awaitable — returns whether it applied, so callers can refresh `isAerialSystemWallpaper()`.
    @discardableResult
    static func setAerialAsWallpaper() async -> Bool {
        return await setAerial(slot: .desktop)
    }

    /// Set Aerial4 as the screensaver (preserving the current desktop wallpaper).
    /// Awaitable — returns whether it applied, so callers can refresh `isAerialSystemScreensaver()`.
    @discardableResult
    static func setAerialAsScreensaver() async -> Bool {
        return await setAerial(slot: .screensaver)
    }

    /// Core setter: writes the choice, restarts WallpaperAgent, and verifies it applied
    /// (across all spaces/displays). Returns `false` on failure.
    @discardableResult
    private static func setAerial(slot: WallpaperExtensionSlot) async -> Bool {
        do {
            try await PaperSaverKit.PaperSaver().setWallpaperExtension(
                bundleID: aerial4BundleID,
                configuration: Data("aerial".utf8),
                slot: slot
            )
            shared.refreshDesktopWallpaperActivation(reason: "setAerial(\(slot))")
            return true
        } catch {
            NSLog("Aerial: failed to set Aerial4 (slot: \(slot)): \(error)")
            return false
        }
    }

    // MARK: - Internal

    /// Apply `body` on the writer queue; if it returns true, bump the
    /// version, write the file, log, and post the Darwin notification —
    /// all as one serialized unit. Returning false short-circuits
    /// (no-op mutations don't burn a version). Fire-and-forget: every
    /// caller already treats mutation as async.
    private func mutate(_ label: String, _ body: @escaping (inout WallpaperControlState) -> Bool) {
        controlQueue.async { [self] in
            guard body(&state) else { return }
            state.version &+= 1
            if store.write(state, to: WallpaperControlState.fileURL) {
                debugLog("[WallpaperControl] \(label) → v\(state.version)")
            } else {
                // In-memory state stays ahead of disk; the next
                // successful write carries the full cumulative state.
                errorLog("[WallpaperControl] \(label) → v\(state.version) WRITE FAILED (disk stale until next write)")
            }
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterPostNotification(
                center,
                CFNotificationName(WallpaperControlState.darwinNotificationName as CFString),
                nil, nil, true
            )
            // Any applied mutation may resume playback — let the
            // auto-pause coordinator sample coverage on its next tick
            // instead of waiting out the paused-cadence stride.
            WallpaperAutoPauseCoordinator.shared.pokePoll()
        }
    }
}
