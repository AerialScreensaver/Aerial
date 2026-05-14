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
