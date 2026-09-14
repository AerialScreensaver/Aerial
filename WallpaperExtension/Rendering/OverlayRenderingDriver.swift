// Renders the SwiftUI overlay stack (clock, weather, music, etc.) into
// a CALayer in the wallpaper extension.
//
// The wallpaper extension has no NSView/NSWindow/SwiftUI host — just a
// remote CAContext + CALayer tree. So we can't drop `OverlayRootView`
// in as an NSHostingView the way the screensaver does. Instead we run
// SwiftUI's `ImageRenderer` to bake the overlay view to a CGImage on a
// 1Hz timer, and set the image as the `contents` of an overlay CALayer
// parented above the video display layer.
//
// Driven by `OverlayState` for content (it's the same ObservableObject
// the screensaver uses, including its WeatherProvider Combine
// subscriptions, music file polling, etc.). The Location overlay is fed
// via `setCurrentVideo(_:positionProvider:)` — the handler pushes the
// renderer's current video + a CMTimebase-position read at install and
// on every video change; OverlayState polls the position to swap POI
// text (the AVPlayer boundary observer the old saver used is gone with
// AVPlayer itself).
//
// Configuration: only renders if `OverlayConfig.separateDesktopConfig`
// is on AND there's a non-empty `desktopSharedLayout` /
// `desktopScreenLayouts` for this screen. Otherwise `create(...)`
// returns nil and no overlay is rendered.

import AppKit
import Combine
import SwiftUI

@MainActor
final class OverlayRenderingDriver {
    /// The layer whose `contents` we update. Caller parents this
    /// above the video display layer in the rootLayer hierarchy.
    let overlayLayer: CALayer

    private let displaySize: CGSize
    private let contentsScale: CGFloat
    private let displayID: CGDirectDisplayID?
    private let state: OverlayState
    /// Wallpaper (desktop) vs screensaver context. Gates the dock/menu
    /// bar inset — only the wallpaper has a dock to clear.
    private let isDesktop: Bool

    /// Screen UUID for this driver's display — the key into Companion's
    /// relayed dock insets in the control state.
    private let screenUUID: String?
    private var renderTimer: Timer?
    private var screenObserver: NSObjectProtocol?

    /// Drives change-based rendering: every overlay data path
    /// (clock/date tick, weather, music, location, rotation, dock
    /// inset) flows through `state.objectWillChange`.
    private var changeSubscription: AnyCancellable?

    /// Coalesces multiple `objectWillChange` sends in one runloop turn
    /// (e.g. weather updating several properties) into a single bake.
    private var renderScheduled = false

    /// macOS system appearance (`.dark` / `.light`) from the acquire/
    /// update request. Nil = no override (use SwiftUI's environment
    /// default). Applied via `.preferredColorScheme` when rendering.
    private var colorScheme: ColorScheme?

    /// When true, `renderNow()` skips work and the overlay layer is
    /// blank. Toggled by `setHidden(_:)` — used while the screen is
    /// locked so overlays don't peek through under the lock screen UI.
    private var isHidden: Bool = false

    /// Feed the Location overlay: the currently-playing video plus a
    /// playback-position source (the renderer's CMTimebase-derived
    /// in-asset position). Called by the handler at renderer install
    /// and on every video change.
    func setCurrentVideo(_ video: AerialVideo, positionProvider: @escaping () -> Double) {
        state.setVideo(video, positionProvider: positionProvider)
    }

    /// How a `create()` caller asks for the startup version banner. The
    /// banner is an EXPLICIT handler-driven request tied to windows that
    /// actually present the screensaver — never inferred from the
    /// overlay-layout context (isDesktop), which bleeds it onto the
    /// still-visible wallpaper when the saver-fallback rebuild flips
    /// desktop windows to the screensaver layout.
    enum VersionBannerRequest {
        /// Never show (desktop acquires, layout-only rebuilds).
        case none
        /// A saver engagement (saver acquire, or the churn-saver
        /// nil-driver rebuild): config-gated + per-display cooldown.
        case saverEngage
        /// The replaced driver had the banner mid-display — re-show
        /// unconditionally so a rebuild doesn't kill it early.
        case carryOver
    }

    /// When each display last showed the version banner. Anti-reblink
    /// guard: on macOS 26.5.2 the agent re-acquires saver windows
    /// mid-session ("window ID changes" reports) — each is a genuine
    /// `.saverEngage` create, and re-firing on every one produced the
    /// old "blinking" report. MainActor-isolated: `create` only runs
    /// inside `Task { @MainActor }`.
    private static var versionBannerLastShown: [CGDirectDisplayID: Date] = [:]
    private static let versionBannerCooldown: TimeInterval = 10

    /// Build a driver if and only if there's an overlay layout for the
    /// given screenUUID + context. `isDesktop: true` queries the desktop
    /// (wallpaper) layouts; `isDesktop: false` queries the screensaver
    /// layouts. Returns nil if the user hasn't configured anything for
    /// this context on this screen — caller just skips overlay setup.
    static func create(
        screenUUID: String?,
        displayID: CGDirectDisplayID?,
        displaySize: CGSize,
        contentsScale: CGFloat,
        systemAppearance: String? = nil,
        isDesktop: Bool = true,
        versionBanner: VersionBannerRequest = .none
    ) -> OverlayRenderingDriver? {
        // Debug-only: pin the version banner in BOTH wallpaper and
        // screensaver modes. Stripped from Release builds, so a stray
        // `alwaysShowVersion=true` left in the config is inert there.
        #if DEBUG
        let alwaysVersion = OverlayConfigManager.shared.config.alwaysShowVersion
        #else
        let alwaysVersion = false
        #endif

        let desktopOverlaysEnabled = OverlayConfigManager.shared.config.separateDesktopConfig

        // Desktop overlays are opt-in: without the separate-desktop
        // config the resolver falls back to the SCREENSAVER layout,
        // which must not leak onto the wallpaper. (Same gate the
        // Companion saver applies in runSettledSetup.) The debug
        // always-version banner is the lone exception — it renders on the
        // desktop too, but with an EMPTY layout so ONLY the version (never
        // the screensaver overlays) appears.
        if isDesktop && !desktopOverlaysEnabled && !alwaysVersion {
            debugLog("  [OverlayDriver] desktop overlays disabled (separateDesktopConfig off) — skipping")
            return nil
        }

        // On the desktop without a dedicated desktop layout we only get
        // past the gate above when alwaysVersion is on — use an empty
        // layout so nothing but the version banner shows.
        let layout = (isDesktop && !desktopOverlaysEnabled)
            ? .empty
            : OverlayConfigManager.shared.layout(for: screenUUID, isDesktop: isDesktop)
        // The startup version banner needs a rendering surface even when
        // no overlays are configured for this screen, so the empty-layout
        // bail below only applies when there's no banner to show either.
        var wantsVersionBanner = false
        switch versionBanner {
        case .none:
            break
        case .saverEngage:
            wantsVersionBanner = OverlayConfigManager.shared.config.showVersionAtStartup
            if wantsVersionBanner, let did = displayID {
                if let last = versionBannerLastShown[did], Date().timeIntervalSince(last) < versionBannerCooldown {
                    wantsVersionBanner = false
                } else {
                    versionBannerLastShown[did] = Date()
                }
            }
        case .carryOver:
            wantsVersionBanner = true
        }
        guard !layout.allInstances.isEmpty || wantsVersionBanner || alwaysVersion else {
            return nil
        }
        return OverlayRenderingDriver(
            displayID: displayID,
            displaySize: displaySize,
            contentsScale: contentsScale,
            layout: layout,
            colorScheme: colorSchemeFor(appearance: systemAppearance),
            showVersionOnStart: wantsVersionBanner,
            showVersionAlways: alwaysVersion,
            isDesktop: isDesktop,
            screenUUID: screenUUID,
        )
    }

    private init(displayID: CGDirectDisplayID?, displaySize: CGSize, contentsScale: CGFloat, layout: OverlayLayout, colorScheme: ColorScheme?, showVersionOnStart: Bool, showVersionAlways: Bool = false, isDesktop: Bool = true, screenUUID: String? = nil) {
        self.displayID = displayID
        self.displaySize = displaySize
        self.contentsScale = contentsScale
        self.colorScheme = colorScheme
        self.isDesktop = isDesktop
        self.screenUUID = screenUUID

        self.overlayLayer = CALayer()
        self.overlayLayer.frame = CGRect(origin: .zero, size: displaySize).sanitized("overlay layer")
        self.overlayLayer.contentsScale = contentsScale
        self.overlayLayer.isOpaque = false
        self.overlayLayer.contentsGravity = .resize

        self.state = OverlayState(isPreview: false)
        self.state.startFromConfig(layout: layout)

        // Screensaver acquires show the startup version banner (the flag
        // is re-checked inside). Must precede the initial render so the
        // first bake includes it; the 5 s auto-hide republishes through
        // objectWillChange and the change subscription re-bakes.
        // The debug always-version banner takes precedence and stays
        // pinned (no auto-hide), in both wallpaper and screensaver modes.
        if showVersionAlways {
            self.state.showVersionAlways()
        } else if showVersionOnStart {
            self.state.showVersionIfNeeded()
        }

        // Mirror the screensaver's dock/menubar margin handling: detect
        // the dock for this display and feed it into OverlayState so
        // OverlayRootView shifts the corner/edge overlays clear of it.
        applyDockInsetForCurrentScreen()

        // Initial render (so the overlay isn't blank for the first second).
        renderNow()

        // Render on CHANGE, not on a 1 Hz poll. OverlayState publishes
        // every data update through objectWillChange — including its own
        // adaptive time tick (1 s only when a clock shows seconds /
        // flashes, minute-aligned for seconds-less clocks and dates,
        // nothing for static layouts). The old unconditional 1 Hz
        // ImageRenderer pass per driver rasterized full display
        // resolution N times a second on the main thread even when
        // nothing changed. objectWillChange fires BEFORE the mutation
        // lands, so the actual bake is deferred one runloop turn.
        changeSubscription = state.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.renderScheduled else { return }
                self.renderScheduled = true
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.renderScheduled = false
                        self.renderNow()
                    }
                }
            }
        }

        // Low-frequency safety net for anything that might change
        // without publishing (none known today — insurance against a
        // future provider regressing silently). Jittered start + wide
        // tolerance so N drivers never bake in lockstep.
        let safety = Timer(
            fire: Date(timeIntervalSinceNow: 60 + Double.random(in: 0...10)),
            interval: 60,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.renderNow() }
        }
        safety.tolerance = 10
        RunLoop.main.add(safety, forMode: .common)
        renderTimer = safety

        // Re-detect dock on screen-parameter changes (user moves dock,
        // toggles autohide, plugs/unplugs displays). The extension
        // process may also be respawned by ExtensionKit after such
        // changes; either path keeps the inset fresh.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyDockInsetForCurrentScreen()
            }
        }

        debugLog("  [OverlayDriver] started with \(layout.allInstances.count) instance(s) at \(displaySize)")
    }

    /// Stop the timer and tear down. Safe to call multiple times.
    func stop() {
        changeSubscription?.cancel()
        changeSubscription = nil
        renderTimer?.invalidate()
        renderTimer = nil
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        state.cleanup()
        debugLog("  [OverlayDriver] stopped")
    }

    deinit {
        changeSubscription?.cancel()
        renderTimer?.invalidate()
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Re-detect the dock/menu bar for this driver's display and apply
    /// the inset to the overlay state. Wallpaper only, and user-
    /// disableable — the screensaver has no dock/menu bar to clear, and
    /// the gate explicitly zeroes the inset so rebuilt saver drivers and
    /// toggle-off config changes never inherit a stale offset.
    private func applyDockInsetForCurrentScreen() {
        guard isDesktop, OverlayConfigManager.shared.config.dockOffsetEnabled else {
            state.dockInset = EdgeInsets()
            return
        }
        // Prefer Companion-relayed insets: an appex's NSScreen geometry
        // is frozen at first access (no NSApplication run loop), so
        // local detection can't see dock moves. The local path below
        // remains only as a launch-time fallback for when Companion has
        // never published (extension running with Companion closed).
        if let uuid = screenUUID,
           let relayed = WallpaperControlListener.shared.currentDockInsets[uuid],
           relayed.count == 4 {
            // Four edges, count-checked in the condition above.
            // swiftlint:disable:next index_zero_subscript
            let (top, leading, bottom, trailing) = (relayed[0], relayed[1], relayed[2], relayed[3])
            state.dockInset = EdgeInsets(top: top, leading: leading, bottom: bottom, trailing: trailing)
            debugLog("  [OverlayDriver] dock insets (relayed): top=\(top) leading=\(leading) bottom=\(bottom) trailing=\(trailing)")
            return
        }
        guard let did = displayID else { return }
        let match = NSScreen.screens.first { screen in
            let sid = screen.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return sid == did
        }
        guard let screen = match else { return }
        let info = DockInfo.detect(for: screen)
        state.dockInset = info.swiftUIInsets
        debugLog("  [OverlayDriver] dock detected (local, may be stale): edge=\(info.edge.rawValue) thickness=\(info.thickness) menuBar=\(info.menuBar)")
    }

    /// Public re-detection hook for the dock-change distributed
    /// notification (`com.apple.dock.prefchanged`) — refreshes the inset
    /// without rebuilding the driver.
    func refreshDockInset() {
        applyDockInsetForCurrentScreen()
    }

    /// True while the version banner is on screen — read by the rebuild
    /// path to carry the banner over to the replacement driver.
    var isShowingVersionBanner: Bool { state.showVersionBanner }

    /// Churn-mode saver (fallback engaged, but no saver window was ever
    /// acquired — the agent just flipped desktop windows to idle): the
    /// idle desktop windows ARE the saver presentation, so show the
    /// banner on this existing driver. Same config/cooldown gates as
    /// `.saverEngage`; the visible-banner guard also keeps the pinned
    /// DEBUG always-version banner from being handed a 5 s auto-hide.
    /// `!isDesktop` holds by the time this is called — the fallback
    /// engage already rebuilt these drivers with the screensaver layout.
    func showVersionBannerForChurnSaver() {
        guard !isDesktop, OverlayConfigManager.shared.config.showVersionAtStartup else { return }
        guard !state.showVersionBanner else { return }
        if let did = displayID {
            if let last = Self.versionBannerLastShown[did], Date().timeIntervalSince(last) < Self.versionBannerCooldown { return }
            Self.versionBannerLastShown[did] = Date()
        }
        state.showVersionIfNeeded()
    }

    private func renderNow() {
        // Skip work entirely when hidden — the layer's contents are
        // already nil, and we don't want to burn CPU rendering content
        // that won't be shown.
        if isHidden { return }
        let rootView = OverlayRootView(state: state)
            .frame(width: displaySize.width, height: displaySize.height)
            .preferredColorScheme(colorScheme)
        let renderer = ImageRenderer(content: rootView)
        renderer.scale = contentsScale
        renderer.isOpaque = false
        guard let cgImage = renderer.cgImage else { return }
        // Disable implicit contents cross-fade animation on each 1Hz
        // update — without this, every overlay refresh fades through
        // the previous frame, producing visible smear at 1Hz tick.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlayLayer.contents = cgImage
        CATransaction.commit()
    }

    /// Update the system appearance and re-render. Called from
    /// `WallpaperXPCHandler.update()` when the agent reports a change.
    /// No-op when the scheme is unchanged.
    func setSystemAppearance(_ value: String) {
        let new = colorSchemeFor(appearance: value)
        if new == colorScheme { return }
        colorScheme = new
        renderNow()
    }

    /// Hide the overlay (e.g. while the screen is locked) or restore
    /// it. Hidden state clears the layer contents to nil; the 1Hz
    /// render timer keeps running but early-returns, so unhiding is a
    /// single forced render away.
    func setHidden(_ hidden: Bool) {
        if isHidden == hidden { return }
        isHidden = hidden
        if hidden {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            overlayLayer.contents = nil
            CATransaction.commit()
            debugLog("  [OverlayDriver] hidden")
        } else {
            debugLog("  [OverlayDriver] unhidden")
            renderNow()
        }
    }
}

/// Map the agent-reported appearance string to a SwiftUI `ColorScheme`.
/// Nil = unknown / no override (let SwiftUI inherit).
private func colorSchemeFor(appearance: String?) -> ColorScheme? {
    switch appearance {
    case "dark":  return .dark
    case "light": return .light
    default:      return nil
    }
}
