//
//  SettingsWindowController.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 06/02/2022.
//

import Cocoa
import SwiftUI

// MARK: - Modern SwiftUI Settings Window Controller (macOS 13+)

@available(macOS 13.0, *)
class SettingsWindowController: NSWindowController {

    convenience init() {
        // Create the SwiftUI view
        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        // Create the window programmatically
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 750, height: 550),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Aerial Companion Settings"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 650, height: 450)
        window.titlebarAppearsTransparent = false
        window.backgroundColor = NSColor.windowBackgroundColor
        window.center()

        self.init(window: window)
    }

    func showSettingsWindow() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Legacy XIB-based Settings Window Controller (macOS 11-12)

class LegacySettingsWindowController: NSWindowController {

    @IBOutlet var betaPopup: NSPopUpButton!
    @IBOutlet var updateModePopup: NSPopUpButton!
    @IBOutlet var checkEveryPopup: NSPopUpButton!
    @IBOutlet var launchCompanionPopup: NSPopUpButton!

    @IBOutlet weak var enableWatchdog: NSButton!

    @IBOutlet weak var watchdogTimer: NSSlider!

    @IBOutlet weak var restartAtLaunchCheckbox: NSButton!

    lazy var updateCheckWindowController = UpdateCheckWindowController()

    override func windowDidLoad() {
        super.windowDidLoad()

        betaPopup.selectItem(at: Preferences.desiredVersion.rawValue)
        updateModePopup.selectItem(at: Preferences.updateMode.rawValue)
        checkEveryPopup.selectItem(at: Preferences.checkEvery.rawValue)
        launchCompanionPopup.selectItem(at: Preferences.launchMode.rawValue)

        restartAtLaunchCheckbox.state = Preferences.restartBackground ? .on : .off
        enableWatchdog.state = Preferences.enableScreensaverWatchdog ? .on : .off
        watchdogTimer.integerValue = Preferences.watchdogTimerDelay
    }

    @IBAction func betaPopupChange(_ sender: NSPopUpButton) {
        Preferences.desiredVersion = DesiredVersion(rawValue: sender.indexOfSelectedItem)!
    }

    @IBAction func updateModePopupChange(_ sender: NSPopUpButton) {
        Preferences.updateMode = CompanionUpdateMode(rawValue: sender.indexOfSelectedItem)!
    }

    @IBAction func checkEveryPopupChange(_ sender: NSPopUpButton) {
        Preferences.checkEvery = CheckEvery(rawValue: sender.indexOfSelectedItem)!
    }

    @IBAction func launchCompanionPopupChange(_ sender: NSPopUpButton) {
        Preferences.launchMode = LaunchMode(rawValue: sender.indexOfSelectedItem)!

        LaunchAgent.update()
    }

    @IBAction func checkNowClick(_ sender: Any) {
        var topLevelObjects: NSArray? = NSArray()
        if !Bundle.main.loadNibNamed(NSNib.Name("UpdateCheckWindowController"),
                            owner: updateCheckWindowController,
                            topLevelObjects: &topLevelObjects) {
            CompanionLogging.errorLog("Could not load nib for UpdateCheckWindow, please report")
        }
        let appd = NSApp.delegate as! AppDelegate
        updateCheckWindowController.setCallback(appd.popoverViewController)
        updateCheckWindowController.windowDidLoad()
        updateCheckWindowController.showWindow(self)
        updateCheckWindowController.window!.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateCheckWindowController.startCheck()
    }

    @IBAction func restartAtLaunchChange(_ sender: NSButton) {
        Preferences.restartBackground = sender.state == .on
    }

    @IBAction func enableWatchdogChange(_ sender: NSButton) {
        Preferences.enableScreensaverWatchdog = sender.state == .on
    }

    @IBAction func watchdogTimerChange(_ sender: NSSlider) {
        Preferences.watchdogTimerDelay = sender.integerValue
    }
}
