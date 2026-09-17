//
//  WallpaperControlListener.swift
//  Extension-side subscriber for the Companion → wallpaper control
//  channel.
//
//  Companion mutates `wallpaper-control.json` and posts the
//  `com.glouel.aerial.wallpaper-control` Darwin notification. We
//  wake, re-read, diff against the last state we applied, and
//  dispatch deltas:
//
//    - speed change            → setNominalRate on all SharedRenderers
//    - per-screen advanceCounter→ advanceNow on that SharedRenderer
//    - per-screen regressCounter→ regressNow on that SharedRenderer
//    - playlistGeneration      → ExtensionVideoLoader.reload + advanceNow
//
//  Reconciliation is idempotent (last-applied version check), so
//  process respawns and duplicate notifications are no-op.
//

import Foundation

final class WallpaperControlListener: @unchecked Sendable {
    static let shared = WallpaperControlListener()

    private let lock = NSLock()
    private var lastApplied: WallpaperControlState

    private init() {
        // Read whatever Companion wrote during a prior session. Counts
        // as our baseline — we don't replay actions on cold start.
        let initial = JSONPreferencesStore.shared.read(
            WallpaperControlState.self,
            from: WallpaperControlState.fileURL
        ) ?? WallpaperControlState()
        self.lastApplied = initial

        registerDarwinObserver()
        debugLog("[WallpaperControl] init — baseline version=\(initial.version), speed=\(initial.speed)")
    }

    // MARK: - Public: queried by the handler on each fresh SharedRenderer

    /// Current speed Companion wants. Cold-start acquires use this to
    /// init the renderer at the right rate (otherwise a respawn would
    /// reset to the 0.125 default until the next notification).
    var currentSpeed: Double {
        lock.lock(); defer { lock.unlock() }
        return lastApplied.speed
    }

    /// Current pause flag Companion wants. Cold-start acquires use
    /// this to spin up a fresh renderer in the right play/pause state
    /// (a respawn would otherwise start playing until the next
    /// notification arrived).
    var currentPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return lastApplied.paused
    }

    /// Whether Aerial is the system desktop wallpaper (Companion reads
    /// the wallpaper store). Screensaver-only installs report false —
    /// every idle acquire is then the saver, and the desktop-side pause
    /// flags are ignored.
    var currentDesktopWallpaperActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return lastApplied.desktopWallpaperActive
    }

    /// The user/coverage pause inputs a renderer should honour right now
    /// (`WallpaperControlState.effectivePauseInputs`), one lock take.
    func effectivePauseInputs(rendererKey: String) -> (user: Bool, coverage: Bool) {
        lock.lock(); defer { lock.unlock() }
        return lastApplied.effectivePauseInputs(rendererKey: rendererKey, isBroadcast: rendererKey == broadcastRendererKey)
    }

    /// Battery-pause flag Companion wants. Cold-start acquires seed the
    /// renderer's `.battery` reason from this.
    var currentBatteryPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return lastApplied.batteryPaused
    }

    /// Thermal/Low Power Mode pause flag Companion wants. Cold-start
    /// acquires seed the renderer's `.thermal` reason from this.
    var currentThermalPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return lastApplied.thermalPaused
    }

    /// Camera-in-use pause flag Companion wants. Cold-start acquires
    /// seed the renderer's `.camera` reason from this.
    var currentCameraPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return lastApplied.cameraPaused
    }

    /// Version of the last-applied control state — echoed into the
    /// status file so the Companion can detect a deaf extension and
    /// re-post the control notification.
    var lastAppliedVersion: Int {
        lock.lock(); defer { lock.unlock() }
        return lastApplied.version
    }

    /// Transition config Companion wants. Cold-start acquires seed
    /// fresh renderers with this (a respawn would otherwise run the
    /// defaults until the next notification).
    var currentTransitionConfig: TransitionConfig {
        lock.lock(); defer { lock.unlock() }
        return TransitionConfig(
            style: lastApplied.transitionStyleValue,
            duration: lastApplied.transitionDuration
        )
    }

    /// "Play audio from videos" flag Companion wants. Cold-start
    /// acquires seed fresh renderers from this (combined with the
    /// audio-owner policy in the handler).
    var currentAudioEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return lastApplied.audioEnabled
    }

    /// Audio volume (0...1) Companion wants.
    var currentAudioVolume: Double {
        lock.lock(); defer { lock.unlock() }
        return lastApplied.audioVolume
    }

    /// Per-screen dock/menubar insets relayed by Companion (screen UUID
    /// → [top, leading, bottom, trailing]). Preferred over local
    /// NSScreen measurement, which is frozen at first access in an
    /// appex. Read by overlay drivers at creation and on refresh.
    var currentDockInsets: [String: [Double]] {
        lock.lock(); defer { lock.unlock() }
        return lastApplied.dockInsets
    }

    /// Screen UUIDs auto-paused (window coverage) per the last-applied
    /// control state. Read by the status reporter for the dashboard echo.
    func autoPausedScreens() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lastApplied.screens.filter { $0.value.autoPaused }.map { $0.key }
    }

    /// Whether the auto-pause signal applies to a renderer scope. For a
    /// per-screen renderer the key IS the screen UUID; the broadcast
    /// renderer is auto-paused while ANY screen is covered.
    func isAutoPausedScope(_ rendererKey: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if rendererKey == broadcastRendererKey {
            return lastApplied.screens.values.contains { $0.autoPaused }
        }
        return lastApplied.screens[rendererKey]?.autoPaused ?? false
    }

    // MARK: - Darwin notification

    private func registerDarwinObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let listener = Unmanaged<WallpaperControlListener>.fromOpaque(observer).takeUnretainedValue()
                listener.reconcile()
            },
            WallpaperControlState.darwinNotificationName as CFString,
            nil, .deliverImmediately
        )
    }

    // MARK: - Reconcile

    private func reconcile() {
        let fresh: WallpaperControlState
        if let loaded = JSONPreferencesStore.shared.read(
            WallpaperControlState.self,
            from: WallpaperControlState.fileURL
        ) {
            fresh = loaded
        } else {
            debugLog("[WallpaperControl] reconcile: file missing/unreadable; skipping")
            return
        }

        let previous: WallpaperControlState = lock.withLock {
            let prev = lastApplied
            if fresh.version != prev.version {
                lastApplied = fresh
            }
            return prev
        }

        if fresh.version == previous.version {
            // Re-delivered notification for a state we already applied.
            return
        }

        if fresh.version < previous.version {
            // The writer's version lineage went BACKWARDS (a new
            // Companion instance, an external edit, a restored file).
            // The old strict gate went silently deaf here until the
            // counter caught back up. Instead: adopt the fresh state as
            // the new baseline (done above), skip counter/generation
            // actions (they would spuriously re-fire on adoption), and
            // push the ABSOLUTE state to the live renderers.
            debugLog("⚠️ [WallpaperControl] lineage reset v\(previous.version) → v\(fresh.version) — re-baselined")
            resyncAbsoluteState()
            writeWallpaperStatus(reason: "rebaseline")
            return
        }

        debugLog("[WallpaperControl] reconcile v\(previous.version) → v\(fresh.version)")
        // Any accepted control change (resume, speed, jump…) may set
        // frames moving — restore idle presenters to vsync first so the
        // mirror doesn't show the first second at the 1 Hz poll rate.
        wakeContentsSwapPresenters()
        applyDeltas(from: previous, to: fresh)
        dumpTopology(reason: "control-reconcile v\(fresh.version)")
        writeWallpaperStatus(reason: "reconcile")
    }

    /// Push the last-applied ABSOLUTE state (speed, transition, pause
    /// reasons) to every live renderer — used after a lineage
    /// re-baseline so renderers don't run stale values until the next
    /// legit write. Counters/generations are deliberately NOT replayed.
    private func resyncAbsoluteState() {
        wakeContentsSwapPresenters()
        let state = lock.withLock { lastApplied }
        let config = TransitionConfig(
            style: state.transitionStyleValue,
            duration: state.transitionDuration
        )
        forEachRenderer { shared in
            shared.renderer.setNominalRate(state.speed)
            shared.renderer.setTransitionConfig(config)
            let inputs = state.effectivePauseInputs(
                rendererKey: shared.rendererKey, isBroadcast: shared.rendererKey == broadcastRendererKey
            )
            shared.renderer.syncCompanionPauseReasons(
                user: inputs.user,
                battery: state.batteryPaused,
                coverage: inputs.coverage,
                thermal: state.thermalPaused,
                camera: state.cameraPaused
            )
        }
        reassertAudioOwnership(context: "rebaseline")
    }

    private func applyDeltas(from prev: WallpaperControlState, to next: WallpaperControlState) {
        // 1. Global speed change.
        if next.speed != prev.speed {
            debugLog("[WallpaperControl] speed \(prev.speed) → \(next.speed)")
            forEachRenderer { $0.renderer.setNominalRate(next.speed) }
        }

        // 1a-bis. Transition style/duration change — takes effect at
        //         each renderer's next video boundary.
        if next.transitionStyle != prev.transitionStyle
            || next.transitionDuration != prev.transitionDuration {
            debugLog("[WallpaperControl] transition \(prev.transitionStyle)/\(prev.transitionDuration)s → \(next.transitionStyle)/\(next.transitionDuration)s")
            let config = TransitionConfig(
                style: next.transitionStyleValue,
                duration: next.transitionDuration
            )
            forEachRenderer { $0.renderer.setTransitionConfig(config) }
        }

        // 1b. Global pause flags. Each source lands as its OWN reason on
        //     every renderer; the reason set inside the renderer IS the
        //     arbitration — a battery clear can't un-pause a user pause,
        //     a user resume can't override coverage, and the saver/lock
        //     inhibition defers and re-lands reasons automatically. The
        //     old ad-hoc gates (saver-skip, covered-resume-hold) fell
        //     out of exactly those rules and are gone.
        // 1b-pre. Desktop wallpaper active ↔ screensaver-only. User and
        //         coverage flags only apply to an ACTIVE desktop wallpaper
        //         (a saver-only session must never inherit a stale pause
        //         — the 2026-09-17 frozen-first-start report); on a flip,
        //         drop or re-land both reasons everywhere.
        if next.desktopWallpaperActive != prev.desktopWallpaperActive {
            debugLog("[WallpaperControl] desktop wallpaper active \(prev.desktopWallpaperActive) → \(next.desktopWallpaperActive)\(next.desktopWallpaperActive ? "" : " — user/coverage pause flags ignored")")
            forEachRenderer { shared in
                let inputs = next.effectivePauseInputs(
                    rendererKey: shared.rendererKey, isBroadcast: shared.rendererKey == broadcastRendererKey
                )
                inputs.user ? shared.renderer.pause(reason: .user) : shared.renderer.resume(reason: .user)
                inputs.coverage ? shared.renderer.pause(reason: .coverage) : shared.renderer.resume(reason: .coverage)
            }
        }
        if next.paused != prev.paused {
            debugLog("[WallpaperControl] user pause \(prev.paused) → \(next.paused)\(next.desktopWallpaperActive ? "" : " (desktop wallpaper inactive — ignored)")")
            if next.desktopWallpaperActive {
                forEachRenderer { shared in
                    next.paused
                        ? shared.renderer.pause(reason: .user)
                        : shared.renderer.resume(reason: .user)
                }
            }
        }
        if next.batteryPaused != prev.batteryPaused {
            debugLog("[WallpaperControl] battery pause \(prev.batteryPaused) → \(next.batteryPaused)")
            forEachRenderer { shared in
                next.batteryPaused
                    ? shared.renderer.pause(reason: .battery)
                    : shared.renderer.resume(reason: .battery)
            }
        }
        if next.thermalPaused != prev.thermalPaused {
            debugLog("[WallpaperControl] thermal pause \(prev.thermalPaused) → \(next.thermalPaused)")
            forEachRenderer { shared in
                next.thermalPaused
                    ? shared.renderer.pause(reason: .thermal)
                    : shared.renderer.resume(reason: .thermal)
            }
        }
        if next.cameraPaused != prev.cameraPaused {
            debugLog("[WallpaperControl] camera pause \(prev.cameraPaused) → \(next.cameraPaused)")
            forEachRenderer { shared in
                next.cameraPaused
                    ? shared.renderer.pause(reason: .camera)
                    : shared.renderer.resume(reason: .camera)
            }
        }

        // 1b-bis. Audio enable/volume — converge every renderer through
        //     the owner policy (exactly one renderer sounds).
        if next.audioEnabled != prev.audioEnabled || next.audioVolume != prev.audioVolume {
            debugLog("[WallpaperControl] audio \(prev.audioEnabled)/\(prev.audioVolume) → \(next.audioEnabled)/\(next.audioVolume)")
            reassertAudioOwnership(context: "control-delta")
        }

        // 1c. Dock/menubar insets relayed by Companion (the appex can't
        //     measure them itself — NSScreen geometry is frozen at first
        //     access without an NSApplication run loop). Refresh every
        //     overlay driver so wallpaper overlays follow dock moves live.
        if next.dockInsets != prev.dockInsets {
            debugLog("[WallpaperControl] dock insets changed — refreshing overlay drivers")
            let drivers = sharedHandlerState.allWallpapers()
                .compactMap { $0.wallpaper.overlayDriver }
            Task { @MainActor in
                for driver in drivers {
                    driver.refreshDockInset()
                }
            }
            // Companion re-publishes insets on every screen-parameter
            // change — the same event that moves the "main display"
            // crown — so this is also the audio-owner re-check for a
            // main-display change that re-keys nothing.
            reassertAudioOwnership(context: "screen-params")
            // The same event also means the display set/arrangement
            // may have changed — re-slice spanned windows if it did.
            refreshTopologyAndResliceIfChanged(reason: "screen-params")
        }

        // 2. Per-screen counters. We iterate the UNION so a screen
        //    that's brand-new (didn't exist in prev) gets its counter
        //    values recorded as baseline without firing actions.
        let allKeys = Set(prev.screens.keys).union(next.screens.keys)
        // The shared (broadcast) renderer is reachable via any screen key;
        // jump it only once per reconcile so a global jump doesn't overshoot.
        var broadcastJumped = false
        // Playlist-changed bookkeeping: act on each renderer once —
        // Companion's playlistDidChange(nil) bumps EVERY screen key
        // (including stale ones), which used to hit the broadcast
        // renderer with one cut per key.
        var playlistHandledRendererKeys = Set<String>()
        // Renderers that executed an explicit jump in THIS reconcile.
        // Companion's "Play this view" sends regenerate + jump
        // back-to-back and the two mutations usually collapse into one
        // reconcile; the playlist branch must not re-cut (or arm a
        // deferred cut off the pre-swap asset) after the jump already
        // landed the renderer on the new playlist.
        var jumpedRendererKeys = Set<String>()
        // Explicit-navigation coalescing: Companion's advance(all) /
        // regress(all) bumps EVERY screens-dict entry — including stale
        // UUIDs left by retired display numbering — and each delta used
        // to land its own advanceNow() on the shared broadcast renderer
        // (2026-08-29 field bundle: SIX advances per hourly auto-advance
        // on four displays, every hour, for weeks). One explicit skip
        // per renderer per reconcile.
        var advancedRendererKeys = Set<String>()
        var regressedRendererKeys = Set<String>()

        // Companion rewrites screensaver.json (the new filter) together
        // with playlists.json. Refresh the load-once caches BEFORE the
        // per-screen branches: the jump branch runs ahead of the
        // playlist branch, and seeking against a stale settings cache
        // made tryPersistedPlaylist reject the fresh shared playlist
        // ("filter mismatch") and fall back to a random rotation video.
        let anyPlaylistChanged = allKeys.contains { key in
            (next.screens[key] ?? WallpaperScreenControl()).playlistGeneration
                != (prev.screens[key] ?? WallpaperScreenControl()).playlistGeneration
        }
        if anyPlaylistChanged {
            ScreensaverSettingsManager.shared.reloadFromDisk()
            // Companion regenerates playlists exactly when the catalog
            // changed (My Videos add/remove, downloads, first-launch
            // source creation) — re-read it so the fresh playlist's ids
            // resolve. SourceList/VideoList are otherwise load-once here:
            // a source created after this process started (My Videos on
            // first launch) never appeared until a respawn, and every
            // "My Videos" entry fell back to a random rotation video.
            VideoList.instance.refreshCatalogFromDisk(reason: "playlist-changed")
            // Drop cached playlist state so the next getNextVideo
            // re-reads playlists.json from disk.
            ExtensionVideoLoader.shared.resetPlaylistCache()
            // Windows showing the no-video fallback: Companion bumps the
            // playlist after every finished download, so this is the
            // moment a fresh install's first video becomes playable.
            retryAttachForUnfedWindows(reason: "playlist-changed")
        }
        for uuid in allKeys {
            let prevS = prev.screens[uuid] ?? WallpaperScreenControl()
            let nextS = next.screens[uuid] ?? WallpaperScreenControl()

            // Only react to *changes*; equal values mean no command.
            if nextS.advanceCounter != prevS.advanceCounter {
                debugLog("[WallpaperControl] advance screen=\(uuid.prefix(8))…")
                applyToScreen(uuid: uuid) { shared in
                    guard advancedRendererKeys.insert(shared.rendererKey).inserted else {
                        debugLog("[WallpaperControl] advance coalesced — renderer \(shared.rendererKey.prefix(8)) already advanced this reconcile")
                        return
                    }
                    // A queued live↔file engine switch wins over a plain
                    // advance — the user is skipping INTO that entry.
                    if let pending = sharedHandlerState.takePendingSwitch(key: shared.rendererKey) {
                        let scope: String? = shared.rendererKey == broadcastRendererKey ? nil : shared.rendererKey
                        switchSharedRenderer(key: shared.rendererKey, to: pending, playlistScreenUUID: scope)
                    } else {
                        let scope: String? = shared.rendererKey == broadcastRendererKey ? nil : shared.rendererKey
                        if ExtensionVideoLoader.shared.cycleMode(for: scope) == .repeatOne {
                            // Repeat-one pins the pre-buffered reader to the
                            // current asset — advanceNow() would just restart
                            // the clip. jumpNow() re-invokes the provider for
                            // a real pop; the next video then loops.
                            shared.renderer.jumpNow()
                        } else {
                            shared.renderer.advanceNow()
                        }
                    }
                }
            }
            if nextS.regressCounter != prevS.regressCounter {
                debugLog("[WallpaperControl] regress screen=\(uuid.prefix(8))…")
                applyToScreen(uuid: uuid) { shared in
                    guard regressedRendererKeys.insert(shared.rendererKey).inserted else {
                        debugLog("[WallpaperControl] regress coalesced — renderer \(shared.rendererKey.prefix(8)) already regressed this reconcile")
                        return
                    }
                    shared.renderer.regressNow()
                }
            }
            if nextS.jumpToken != prevS.jumpToken {
                let targetIndex = nextS.jumpIndex
                debugLog("[WallpaperControl] jump screen=\(uuid.prefix(8))… → index \(targetIndex)")
                applyToScreen(uuid: uuid) { shared in
                    if shared.rendererKey == broadcastRendererKey {
                        if broadcastJumped { return }
                        broadcastJumped = true
                    }
                    jumpedRendererKeys.insert(shared.rendererKey)
                    // Seek scope matches the renderer: broadcast → shared
                    // playlist (nil); per-screen → its UUID. seekPlaylist
                    // sets currentIndex + resume; jumpNow() rebuilds the
                    // buffered reader from the provider so the target lands
                    // on the FIRST jump (advanceNow would swap the stale
                    // pre-buffered next, taking two jumps).
                    let scope: String? = shared.rendererKey == broadcastRendererKey ? nil : shared.rendererKey
                    // The jump supersedes any queued engine switch.
                    sharedHandlerState.clearPendingSwitch(key: shared.rendererKey)
                    ExtensionVideoLoader.shared.seekPlaylist(to: targetIndex, screenUUID: scope)
                    shared.renderer.jumpNow()
                }
            }
            if nextS.autoPaused != prevS.autoPaused {
                debugLog("[WallpaperControl] autoPause \(prevS.autoPaused) → \(nextS.autoPaused) screen=\(uuid.prefix(8))…")
                applyToScreen(uuid: uuid) { shared in
                    // The broadcast renderer serves every display, so its
                    // coverage reason is "ANY screen covered"; per-screen
                    // renderers map 1:1. All other arbitration (user
                    // pause, saver deferral) lives in the reason set.
                    let covered = next.desktopWallpaperActive && (shared.rendererKey == broadcastRendererKey
                        ? next.screens.values.contains { $0.autoPaused }
                        : nextS.autoPaused)
                    covered
                        ? shared.renderer.pause(reason: .coverage)
                        : shared.renderer.resume(reason: .coverage)
                }
            }
            if nextS.playlistGeneration != prevS.playlistGeneration {
                debugLog("[WallpaperControl] playlist-changed screen=\(uuid.prefix(8))…")
                // Only cut the current video if it didn't survive the
                // regeneration — Companion signals on real content
                // changes, but a broadened filter (or new download)
                // usually keeps the playing video valid, and cutting it
                // is needlessly jarring.
                applyToScreen(uuid: uuid) { shared in
                    guard playlistHandledRendererKeys.insert(shared.rendererKey).inserted else { return }
                    let scope: String? = shared.rendererKey == broadcastRendererKey ? nil : shared.rendererKey
                    // A queued engine switch belongs to the OLD playlist.
                    sharedHandlerState.clearPendingSwitch(key: shared.rendererKey)
                    // Push the (possibly changed) cycle mode: repeat-one is
                    // enforced by the renderer, and the setter re-primes the
                    // pre-buffered reader so a mid-video flip applies at the
                    // very next boundary.
                    let repeatOne = ExtensionVideoLoader.shared.cycleMode(for: scope) == .repeatOne
                    (shared.renderer as? VideoRenderer)?.setLoopCurrentVideo(repeatOne)
                    if jumpedRendererKeys.contains(shared.rendererKey) {
                        // An explicit jump in this same reconcile already
                        // landed this renderer on the new playlist. The
                        // verdict below would read the pre-swap asset
                        // (rebuildAndSwap loads tracks asynchronously),
                        // see .removed, and arm a deferred cut that fires
                        // an unwanted swap at the next resume.
                        debugLog("[WallpaperControl] jump already applied this reconcile — skipping playlist verdict (screen=\(uuid.prefix(8)))")
                        (shared.renderer as? VideoRenderer)?.cancelDeferredJump()
                        return
                    }
                    let currentPath = shared.renderer.currentAssetURL.path
                    switch ExtensionVideoLoader.shared.playlistVerdict(forLocalPath: currentPath, screenUUID: scope) {
                    case .survives:
                        debugLog("[WallpaperControl] current video survives new playlist — not cutting (screen=\(uuid.prefix(8)))")
                        // A cut deferred by an earlier (paused) reconcile is
                        // moot now — drop it so resume doesn't jump.
                        (shared.renderer as? VideoRenderer)?.cancelDeferredJump()
                    case .unavailable:
                        // Empty or unloadable playlist — no evidence the
                        // current video was removed, so keep it. Cutting
                        // here is what turned a transient empty regeneration
                        // into a visible swap on paused wallpapers.
                        debugLog("[WallpaperControl] playlist empty/unloadable — keeping current video (screen=\(uuid.prefix(8)))")
                    case .removed:
                        // jumpNow(), not advanceNow(): the pre-buffered next
                        // was popped from the OLD playlist before this bump —
                        // re-invoke the provider for a fresh pop of the new
                        // one (post-reset it resumes at the new playlist's
                        // current entry). advanceNow() would swap the stale
                        // pick and play one more old video.
                        if let renderer = shared.renderer as? VideoRenderer {
                            // Paused screens must not visibly change — defer
                            // the cut to the next resume.
                            renderer.jumpWhenResumed()
                        } else {
                            shared.renderer.jumpNow()
                        }
                    }
                }
            }
        }

        // 3. Displays settings changed (viewing mode / display mode /
        //    aspect / margins). The settings cache is load-once per
        //    process, so re-read it, refresh display topology, and
        //    reshape every active wallpaper in place — WallpaperAgent
        //    never re-acquires on our behalf.
        if next.settingsGeneration != prev.settingsGeneration {
            debugLog("[WallpaperControl] settings-changed (gen \(prev.settingsGeneration) → \(next.settingsGeneration)) — reload + reconfigure")
            ScreensaverSettingsManager.shared.reloadFromDisk()
            // Location settings may have changed with them — drop the
            // memoized cache/Expansions roots and re-scan sources so
            // packs on a newly-configured external root become playable
            // without waiting for the extension to respawn.
            Cache.invalidateCachePath()
            Cache.invalidateSourcesRoots()
            SourceList.rescan()
            VideoList.instance.reloadSources()
            DisplayDetection.sharedInstance.detectDisplays()
            reconfigureAllWallpapers()
        }

        // 3b. Display layout changed: Companion's didChangeScreenParameters
        //     saw a different NSScreen id/frame set (monitor added,
        //     removed, or dragged in System Settings). Insets may be
        //     identical, so this rides its own counter.
        if next.screenLayoutGeneration != prev.screenLayoutGeneration {
            refreshTopologyAndResliceIfChanged(reason: "screen-layout gen \(next.screenLayoutGeneration)")
        }

        // 4. Overlay config changed (separate-desktop toggle, editor
        //    saves). Re-read and rebuild the per-acquire overlay
        //    drivers; the desktop gate applies inside
        //    OverlayRenderingDriver.create.
        if next.overlayGeneration != prev.overlayGeneration {
            debugLog("[WallpaperControl] overlay-config-changed (gen \(prev.overlayGeneration) → \(next.overlayGeneration)) — reload + rebuild drivers")
            OverlayConfigManager.shared.reloadFromDisk()
            rebuildAllOverlayDrivers()
        }
    }

    // MARK: - Helpers

    /// Iterate all currently-active SharedRenderers on the renderer's
    /// own queue (the renderer's API methods dispatch internally).
    private func forEachRenderer(_ body: (SharedRenderer) -> Void) {
        for shared in sharedHandlerState.allRenderers() {
            body(shared)
        }
    }

    /// Find the SharedRenderer for this screenUUID and invoke the
    /// callback if found. Renderer keys ARE screen UUIDs now (stable
    /// across display-ID re-enumeration), so this is a direct compare.
    ///
    /// In shared (cloned/spanned) mode there's only one broadcast
    /// SharedRenderer (keyed by `broadcastRendererKey`); per-screen
    /// commands collapse to "act on the single broadcast renderer."
    private func applyToScreen(uuid: String, _ body: (SharedRenderer) -> Void) {
        for shared in sharedHandlerState.allRenderers() {
            if shared.rendererKey == broadcastRendererKey || shared.rendererKey == uuid {
                body(shared)
                return
            }
        }
    }
}
