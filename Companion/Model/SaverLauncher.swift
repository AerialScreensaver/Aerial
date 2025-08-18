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
    var uiController: CompanionPopoverViewController?
    var settingsPanelController: PanelWindowController?
    
    func windowMode() {
        var topLevelObjects: NSArray? = NSArray()
        if !Bundle.main.loadNibNamed(NSNib.Name("AerialWindow"),
                            owner: aerialWindowController,
                            topLevelObjects: &topLevelObjects) {
            CompanionLogging.errorLog("Could not load nib for AerialWindow, please report")
        }
        
        aerialWindowController.windowDidLoad()
        aerialWindowController.showWindow(self)
        aerialWindowController.window!.delegate = self
        aerialWindowController.window!.toggleFullScreen(nil)
        aerialWindowController.window!.makeKeyAndOrderFront(nil)
        
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func setController(_ controller: CompanionPopoverViewController) {
        uiController = controller
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            if window == settingsPanelController?.window {
                // Settings panel is closing
                CompanionLogging.debugLog("Settings panel closing")
                uiController?.shouldRefreshPlaybackMode()
                settingsPanelController = nil
            } else if window == aerialWindowController.window {
                // Aerial window is closing
                CompanionLogging.debugLog("Aerial window closing")
                aerialWindowController.stopScreensaver()
                uiController?.updatePlaybackMode(mode: .none)
            }
        }
    }
    
    func stopScreensaver() {
        aerialWindowController.stopScreensaver()
        aerialWindowController.close()
    }
    
    func openSettings() {
        CompanionLogging.debugLog("Opening Aerial settings panel")
        
        // Reuse existing panel if already open
        if let existingPanel = settingsPanelController {
            existingPanel.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // Create PanelWindowController directly - XIB is now in Companion target
        let panelController = PanelWindowController()
        settingsPanelController = panelController
        
        // Access the window property to trigger loading from XIB
        guard let window = panelController.window else {
            CompanionLogging.errorLog("Failed to load settings panel window")
            settingsPanelController = nil
            return
        }
        
        window.title = "Aerial Settings"
        window.styleMask = [.closable, .titled, .resizable]
        window.isReleasedWhenClosed = false  // Keep the window controller alive
        window.delegate = self  // Monitor window events
        
        // Show the window
        panelController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func togglePause() {
        CompanionLogging.debugLog("toggle pause")
        aerialWindowController.togglePause()
    }
    
    func nextVideo() {
        CompanionLogging.debugLog("next video")
        aerialWindowController.nextVideo()        
    }
    
    func skipAndHide() {
        CompanionLogging.debugLog("skip and hide")
        aerialWindowController.skipAndHide()
    }
    
    func changeSpeed(_ speed: Int) {
        CompanionLogging.debugLog("Change speed")
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
