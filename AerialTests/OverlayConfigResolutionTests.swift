//
//  OverlayConfigResolutionTests.swift
//  AerialTests
//
//  Tests for OverlayConfig.resolvedLayout(for:isDesktop:) —
//  the 6 code paths for layout resolution.
//

import Testing
import Foundation
@testable import Aerial

@Suite("Overlay Config Layout Resolution")
struct OverlayConfigResolutionTests {

    private func makeLayout(marker: String) -> OverlayLayout {
        var layout = OverlayLayout.empty
        layout.addInstance(OverlayInstance(
            id: UUID(),
            kind: .message,
            position: .center,
            fontName: marker,
            fontSize: 20,
            typeSettings: [:]
        ))
        return layout
    }

    // MARK: - Non-desktop, non-perScreen → sharedLayout

    @Test("Screensaver shared: returns sharedLayout")
    func screensaverShared() {
        let config = OverlayConfig(
            version: 1,
            perScreen: false,
            separateDesktopConfig: false,
            sharedLayout: makeLayout(marker: "shared"),
            screenLayouts: [:],
            desktopSharedLayout: nil,
            desktopScreenLayouts: nil
        )
        let layout = config.resolvedLayout(for: nil, isDesktop: false)
        #expect(layout.allInstances.first?.fontName == "shared")
    }

    // MARK: - Non-desktop, perScreen → screenLayouts[uuid]

    @Test("Screensaver per-screen: returns screen-specific layout")
    func screensaverPerScreen() {
        let config = OverlayConfig(
            version: 1,
            perScreen: true,
            separateDesktopConfig: false,
            sharedLayout: makeLayout(marker: "shared"),
            screenLayouts: ["screen1": makeLayout(marker: "screen1")],
            desktopSharedLayout: nil,
            desktopScreenLayouts: nil
        )
        let layout = config.resolvedLayout(for: "screen1", isDesktop: false)
        #expect(layout.allInstances.first?.fontName == "screen1")
    }

    @Test("Screensaver per-screen: unknown screen returns empty")
    func screensaverPerScreenUnknown() {
        let config = OverlayConfig(
            version: 1,
            perScreen: true,
            separateDesktopConfig: false,
            sharedLayout: makeLayout(marker: "shared"),
            screenLayouts: [:],
            desktopSharedLayout: nil,
            desktopScreenLayouts: nil
        )
        let layout = config.resolvedLayout(for: "unknown", isDesktop: false)
        #expect(layout.allInstances.isEmpty)
    }

    // MARK: - Desktop, separateDesktopConfig off → falls through to screensaver path

    @Test("Desktop without separate config: uses sharedLayout")
    func desktopNoSeparateConfig() {
        let config = OverlayConfig(
            version: 1,
            perScreen: false,
            separateDesktopConfig: false,
            sharedLayout: makeLayout(marker: "shared"),
            screenLayouts: [:],
            desktopSharedLayout: makeLayout(marker: "desktop-shared"),
            desktopScreenLayouts: nil
        )
        let layout = config.resolvedLayout(for: nil, isDesktop: true)
        #expect(layout.allInstances.first?.fontName == "shared")
    }

    // MARK: - Desktop, separateDesktopConfig on, non-perScreen → desktopSharedLayout

    @Test("Desktop shared: returns desktopSharedLayout")
    func desktopShared() {
        let config = OverlayConfig(
            version: 1,
            perScreen: false,
            separateDesktopConfig: true,
            sharedLayout: makeLayout(marker: "shared"),
            screenLayouts: [:],
            desktopSharedLayout: makeLayout(marker: "desktop-shared"),
            desktopScreenLayouts: nil
        )
        let layout = config.resolvedLayout(for: nil, isDesktop: true)
        #expect(layout.allInstances.first?.fontName == "desktop-shared")
    }

    @Test("Desktop shared: nil desktopSharedLayout returns empty")
    func desktopSharedNilFallback() {
        let config = OverlayConfig(
            version: 1,
            perScreen: false,
            separateDesktopConfig: true,
            sharedLayout: makeLayout(marker: "shared"),
            screenLayouts: [:],
            desktopSharedLayout: nil,
            desktopScreenLayouts: nil
        )
        let layout = config.resolvedLayout(for: nil, isDesktop: true)
        #expect(layout.allInstances.isEmpty)
    }

    // MARK: - Desktop, separateDesktopConfig on, perScreen → desktopScreenLayouts[uuid]

    @Test("Desktop per-screen: returns desktop screen-specific layout")
    func desktopPerScreen() {
        let config = OverlayConfig(
            version: 1,
            perScreen: true,
            separateDesktopConfig: true,
            sharedLayout: makeLayout(marker: "shared"),
            screenLayouts: [:],
            desktopSharedLayout: nil,
            desktopScreenLayouts: ["screen1": makeLayout(marker: "desktop-screen1")]
        )
        let layout = config.resolvedLayout(for: "screen1", isDesktop: true)
        #expect(layout.allInstances.first?.fontName == "desktop-screen1")
    }

    @Test("Desktop per-screen: unknown screen returns empty")
    func desktopPerScreenUnknown() {
        let config = OverlayConfig(
            version: 1,
            perScreen: true,
            separateDesktopConfig: true,
            sharedLayout: makeLayout(marker: "shared"),
            screenLayouts: [:],
            desktopSharedLayout: nil,
            desktopScreenLayouts: [:]
        )
        let layout = config.resolvedLayout(for: "unknown", isDesktop: true)
        #expect(layout.allInstances.isEmpty)
    }
}

// MARK: - Lock-screen rule

/// `OverlayLockScreenRule` — the lock screen (`locked` presentationMode)
/// and the password prompt (login shield) used to be one "login is up"
/// verdict; "show overlays on the lock screen" splits them. The default-off
/// rows must reproduce the historical `hideDuringLogin && (locked || shield)`.
@Suite("Overlay lock-screen rule")
struct OverlayLockScreenRuleTests {
    private func hidden(locked: Bool, shield: Bool, hide: Bool = true, lockScreen: Bool = false) -> Bool {
        OverlayLockScreenRule.hidden(anyLocked: locked, shieldVisible: shield,
                                     hideDuringLogin: hide, showOnLockScreen: lockScreen)
    }

    @Test("default options: lock and prompt both blank (historical behaviour)")
    func defaults() {
        #expect(hidden(locked: true, shield: false) == true)
        #expect(hidden(locked: false, shield: true) == true)
        #expect(hidden(locked: true, shield: true) == true)
        #expect(hidden(locked: false, shield: false) == false)
    }

    @Test("lock-screen overlays on: the locked state alone no longer blanks")
    func lockScreenOptIn() {
        #expect(hidden(locked: true, shield: false, lockScreen: true) == false)
        #expect(hidden(locked: false, shield: false, lockScreen: true) == false)
    }

    @Test("lock-screen overlays on: the password prompt still blanks")
    func promptStillHides() {
        #expect(hidden(locked: false, shield: true, lockScreen: true) == true)
        #expect(hidden(locked: true, shield: true, lockScreen: true) == true)
    }

    @Test("hide-during-login off is the master switch: nothing ever blanks")
    func masterSwitchOff() {
        #expect(hidden(locked: true, shield: true, hide: false) == false)
        #expect(hidden(locked: true, shield: true, hide: false, lockScreen: true) == false)
        #expect(hidden(locked: true, shield: false, hide: false) == false)
    }

    private func desktop(saver: Bool = false, fallback: Bool = false, mode: String, lockScreen: Bool = false) -> Bool {
        OverlayLockScreenRule.usesDesktopLayout(isScreenSaver: saver, saverFallbackActive: fallback,
                                                presentationMode: mode, showOnLockScreen: lockScreen)
    }

    @Test("layout: saver windows and the saver fallback use the screensaver layout")
    func saverLayout() {
        #expect(desktop(saver: true, mode: "idle") == false)
        #expect(desktop(saver: true, mode: "locked") == false)
        #expect(desktop(fallback: true, mode: "idle") == false)
        #expect(desktop(fallback: true, mode: "locked") == false)
    }

    @Test("layout: a locked wallpaper window takes the screensaver layout only when opted in")
    func lockedLayout() {
        #expect(desktop(mode: "locked", lockScreen: true) == false)
        #expect(desktop(mode: "locked", lockScreen: false) == true)
    }

    @Test("layout: the desktop stays on the wallpaper layout")
    func desktopLayout() {
        #expect(desktop(mode: "default") == true)
        #expect(desktop(mode: "default", lockScreen: true) == true)
    }
}
