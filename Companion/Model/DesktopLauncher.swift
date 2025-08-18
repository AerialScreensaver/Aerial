//
//  DesktopLauncher.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 02/12/2020.
//

import AppKit

class DesktopLauncher : NSObject, NSWindowDelegate {
    let targetScreen: NSScreen
    let aerialDesktopController = SwiftAerialDesktop()
    var isRunning = false
    
    init(screen: NSScreen = NSScreen.main!) {
        self.targetScreen = screen
    }

    func toggleLauncher() {
        if !isRunning {
            var topLevelObjects: NSArray? = NSArray()
            if !Bundle.main.loadNibNamed(NSNib.Name("AerialDesktop"),
                                         owner: aerialDesktopController,
                                         topLevelObjects: &topLevelObjects) {
                CompanionLogging.errorLog("Could not load nib for AerialDesktop, please report")
            }
            
            // Must be called before windowDidLoad so the created window has the correct size
            aerialDesktopController.window!.setFrameOrigin(self.targetScreen.visibleFrame.origin)
            
            aerialDesktopController.windowDidLoad()
            aerialDesktopController.showWindow(self)
            aerialDesktopController.window!.delegate = self
            aerialDesktopController.window!.toggleFullScreen(nil)
            aerialDesktopController.window!.makeKeyAndOrderFront(nil)
            aerialDesktopController.window!.level = NSWindow.Level.init(rawValue: Int(CGWindowLevelForKey(CGWindowLevelKey.desktopWindow)) - 1) 
            NSApp.activate(ignoringOtherApps: true)
            
            isRunning = true
        } else {
            aerialDesktopController.window!.close()
            isRunning = false
        }
    }
    
    func windowWillClose(_ notification: Notification) {
        CompanionLogging.debugLog("windowWillClose")
        aerialDesktopController.stopScreensaver()
    }
    
    func openSettings() {
        CompanionLogging.debugLog("open hosted settings DT")
        aerialDesktopController.openPanel()
    }
    
    func togglePause() {
        CompanionLogging.debugLog("toggle pause")
        aerialDesktopController.togglePause()
    }
    
    func nextVideo() {
        CompanionLogging.debugLog("next video")
        aerialDesktopController.nextVideo()
    }
    
    func skipAndHide() {
        CompanionLogging.debugLog("skip and hide")
        aerialDesktopController.skipAndHide()
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
        
        aerialDesktopController.changeSpeed(fSpeed)
    }

}
