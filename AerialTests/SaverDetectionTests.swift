//
//  SaverDetectionTests.swift
//  AerialTests
//
//  The 2026-09-17 "screensaver stays still on start" report: a saver-only
//  install's acquire carried `placement=Crop` and the freshly spawned
//  process had missed the didstart notification. These pin the pure
//  rules the fix hangs on: how an acquire is classified, that a control
//  file from an older Companion still reads as "desktop active", and that
//  an inactive desktop wallpaper drops the desktop-only pause inputs.
//

import Foundation
import Testing
@testable import Aerial

@Suite("Saver acquire rule")
struct SaverAcquireRuleTests {

    @Test("screensaver-only install: every non-preview idle acquire is the saver, placement or not")
    func saverOnly() {
        let withPlacement = SaverAcquireRule.classify(presentationMode: "idle", isPreview: false,
                                                      placement: "Crop", desktopWallpaperActive: false)
        #expect(withPlacement == .init(isSaverRole: true, saverRunning: true))
        let bare = SaverAcquireRule.classify(presentationMode: "idle", isPreview: false,
                                             placement: nil, desktopWallpaperActive: false)
        #expect(bare == .init(isSaverRole: true, saverRunning: true))
    }

    @Test("Aerial also the desktop wallpaper: placement marks the desktop window, the saver is still running")
    func desktopAndSaver() {
        let desktopWindow = SaverAcquireRule.classify(presentationMode: "idle", isPreview: false,
                                                      placement: "Crop", desktopWallpaperActive: true)
        #expect(desktopWindow == .init(isSaverRole: false, saverRunning: true))
        let saverWindow = SaverAcquireRule.classify(presentationMode: "idle", isPreview: false,
                                                    placement: nil, desktopWallpaperActive: true)
        #expect(saverWindow == .init(isSaverRole: true, saverRunning: true))
    }

    @Test("advance at launch: only a running saver on a Mac where Aerial is not the desktop wallpaper")
    func advancesAtLaunch() {
        let saverOnly = SaverAcquireRule.classify(presentationMode: "idle", isPreview: false,
                                                  placement: "Crop", desktopWallpaperActive: false)
        #expect(SaverAcquireRule.advancesAtLaunch(saverOnly, desktopWallpaperActive: false, optionEnabled: true))
        #expect(!SaverAcquireRule.advancesAtLaunch(saverOnly, desktopWallpaperActive: false, optionEnabled: false))
        // Aerial also the wallpaper: the saver window shares the desktop renderer — never.
        let saverWindow = SaverAcquireRule.classify(presentationMode: "idle", isPreview: false,
                                                    placement: nil, desktopWallpaperActive: true)
        #expect(saverWindow.isSaverRole)
        #expect(!SaverAcquireRule.advancesAtLaunch(saverWindow, desktopWallpaperActive: true, optionEnabled: true))
        let preview = SaverAcquireRule.classify(presentationMode: "idle", isPreview: true,
                                                placement: nil, desktopWallpaperActive: false)
        #expect(!SaverAcquireRule.advancesAtLaunch(preview, desktopWallpaperActive: false, optionEnabled: true))
    }

    @Test("previews and non-idle acquires are never the saver")
    func neverSaver() {
        let off = SaverAcquireRule.Verdict(isSaverRole: false, saverRunning: false)
        #expect(SaverAcquireRule.classify(presentationMode: "idle", isPreview: true,
                                          placement: nil, desktopWallpaperActive: false) == off)
        #expect(SaverAcquireRule.classify(presentationMode: "default", isPreview: false,
                                          placement: nil, desktopWallpaperActive: false) == off)
        #expect(SaverAcquireRule.classify(presentationMode: "?", isPreview: false,
                                          placement: "Crop", desktopWallpaperActive: true) == off)
    }
}

@Suite("Desktop wallpaper activation in the control file")
struct DesktopWallpaperActiveTests {

    @Test("a control file from an older Companion decodes as active")
    func legacyDefaultsToActive() throws {
        let json = Data(#"{"version": 3, "paused": true}"#.utf8)
        let state = try JSONDecoder().decode(WallpaperControlState.self, from: json)
        #expect(state.desktopWallpaperActive == true)
        #expect(state.paused == true)
    }

    @Test("false round-trips")
    func roundTrip() throws {
        var state = WallpaperControlState()
        state.desktopWallpaperActive = false
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WallpaperControlState.self, from: data)
        #expect(decoded.desktopWallpaperActive == false)
    }

    @Test("inactive desktop drops the user and coverage inputs; active keeps them, broadcast covers any screen")
    func pauseInputs() {
        var state = WallpaperControlState()
        state.paused = true
        state.screens["A"] = WallpaperScreenControl(autoPaused: true)
        state.screens["B"] = WallpaperScreenControl(autoPaused: false)

        state.desktopWallpaperActive = false
        let off = state.effectivePauseInputs(rendererKey: "A", isBroadcast: false)
        #expect(off.user == false && off.coverage == false)

        state.desktopWallpaperActive = true
        let a = state.effectivePauseInputs(rendererKey: "A", isBroadcast: false)
        #expect(a.user == true && a.coverage == true)
        let b = state.effectivePauseInputs(rendererKey: "B", isBroadcast: false)
        #expect(b.user == true && b.coverage == false)
        let broadcast = state.effectivePauseInputs(rendererKey: "broadcast", isBroadcast: true)
        #expect(broadcast.coverage == true)
    }
}

@Suite("Wallpaper store summary")
struct WallpaperStoreSummaryTests {

    private func slot(provider: String, options: [String: Any]?) -> [String: Any] {
        var content: [String: Any] = ["Choices": [["Provider": provider, "Files": [], "Configuration": Data()]]]
        if let options {
            content["EncodedOptionValues"] = try! PropertyListSerialization.data(
                fromPropertyList: ["values": options], format: .binary, options: 0)
        }
        return ["Content": content]
    }

    @Test("individual sections list provider and option keys per slot")
    func individual() {
        let plist: [String: Any] = [
            "AllSpacesAndDisplays": [
                "Type": "individual",
                "Desktop": slot(provider: "com.apple.wallpaper.choice.aerials", options: [:]),
                "Idle": slot(provider: "com.glouel.Aerial-App.Aerial4WallpaperExtension",
                             options: ["placement": ["picker": ["_0": ["id": "Crop"]]]]),
            ],
        ]
        let lines = WallpaperStoreSummary.describe(plist: plist)
        #expect(lines.contains("Store AllSpacesAndDisplays.Desktop [individual]: com.apple.wallpaper.choice.aerials options=empty"))
        #expect(lines.contains("Store AllSpacesAndDisplays.Idle [individual]: com.glouel.Aerial-App.Aerial4WallpaperExtension options=[placement]"))
        #expect(lines.contains("Store SystemDefault: missing"))
    }

    @Test("linked sections, missing and undecodable option values")
    func linkedAndOdd() {
        let plist: [String: Any] = [
            "AllSpacesAndDisplays": [
                "Type": "linked",
                "Linked": slot(provider: "default", options: nil),
            ],
            "SystemDefault": [
                "Type": "individual",
                "Desktop": ["Content": ["Choices": [["Provider": "x"]], "EncodedOptionValues": Data([1, 2, 3])]],
            ],
            "Spaces": ["S1": [:]],
        ]
        let lines = WallpaperStoreSummary.describe(plist: plist)
        #expect(lines.contains("Store AllSpacesAndDisplays.Linked [linked]: default options=none"))
        #expect(lines.contains("Store SystemDefault.Desktop [individual]: x options=undecodable"))
        #expect(lines.contains("Store Spaces: 1 per-space section(s)"))
    }
}

// MARK: - Idle exit rule

@Suite("Idle exit rule")
struct IdleExitRuleTests {

    @Test("the agent's disconnect exits when nothing is hosted")
    func exitWhenIdle() {
        #expect(IdleExitRule.decide(contexts: 0, renderers: 0) == .exit)
    }

    @Test("a hosted window or a renderer still in its grace period keeps the process")
    func stayWhenHosting() {
        #expect(IdleExitRule.decide(contexts: 1, renderers: 0) == .stay(reason: "hosting contexts=1 renderers=0"))
        #expect(IdleExitRule.decide(contexts: 0, renderers: 1) == .stay(reason: "hosting contexts=0 renderers=1"))
        #expect(IdleExitRule.decide(contexts: 2, renderers: 2) == .stay(reason: "hosting contexts=2 renderers=2"))
    }
}
