//
//  SaverLauncher.swift
//  Aerial
//
//  Created by Guillaume Louel on 17/11/2020.
//

import AppKit
import ScreenSaver

class SaverLauncher : NSObject, NSWindowDelegate {
    static let instance: SaverLauncher = SaverLauncher()

    let aerialWindowController = SwiftAerialWindow()
    func windowMode() {
        // Window was built in SwiftAerialWindow.init; setupWindowMode
        // installs AerialSaverView as a constrained subview of the
        // window's contentView. Idempotent.
        aerialWindowController.setupWindowMode()
        aerialWindowController.showWindow(self)
        aerialWindowController.window!.delegate = self
        aerialWindowController.window!.toggleFullScreen(nil)
        aerialWindowController.window!.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
    }
    
    /// Forces the menubar (and dock) to auto-hide while the
    /// fullscreen window is up, overriding the system pref
    /// "Automatically hide and show the menu bar in full screen". By
    /// returning these as a SUPERSET of the AppKit-proposed options
    /// we preserve whatever defaults AppKit would have applied,
    /// plus our hide-affordances. Scope is per-window — when the
    /// window leaves fullscreen, presentation reverts automatically.
    func window(
        _ window: NSWindow,
        willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions
    ) -> NSApplication.PresentationOptions {
        proposedOptions.union([.autoHideMenuBar, .autoHideDock])
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow,
           window == aerialWindowController.window {
            debugLog("Aerial window closing")
            aerialWindowController.stopScreensaver()

            Task { @MainActor in
                PlaybackManager.shared.windowModeDidStop()
            }
        }
    }
    
    func stopScreensaver() {
        aerialWindowController.stopScreensaver()
        aerialWindowController.close()
    }

    /// Battery-driven pause. Single-instance variant — only one
    /// window-mode controller exists.
    func applyBatteryPause() {
        debugLog("🔋 Window mode battery pause — pausing playback")
        aerialWindowController.batteryPause()
    }

    func applyBatteryResume() {
        debugLog("🔋 Window mode battery resume — resuming playback")
        aerialWindowController.batteryResume()
    }
    
    func setUserPaused(_ paused: Bool) {
        debugLog("🖱️ set user paused: \(paused)")
        aerialWindowController.setUserPaused(paused)
    }
    
    func skipTo(playlistIndex: Int) {
        debugLog("🖱️ skip to playlist index \(playlistIndex)")
        aerialWindowController.skipTo(playlistIndex: playlistIndex)
    }

    func skipToNext() {
        debugLog("🖱️ skip to next")
        aerialWindowController.skipToNext()
    }

    func skipToPrevious() {
        debugLog("🖱️ skip to previous")
        aerialWindowController.skipToPrevious()
    }

    func changeSpeed(_ speed: Int) {
        debugLog("🖱️ Change speed")
        var fSpeed: Float  = 1.0
        if speed == 80 {
            fSpeed = 2/3
        } else if speed == 60 {
            fSpeed = 1/2
        } else if speed == 40 {
            fSpeed = 1/3
        } else if speed == 20 {
            fSpeed = 1/4
        } else if speed == 0 {
            fSpeed = 1/8
        }
        
        aerialWindowController.changeSpeed(fSpeed)
    }

}
