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
        var topLevelObjects: NSArray? = NSArray()
        if !Bundle.main.loadNibNamed(NSNib.Name("AerialWindow"),
                            owner: aerialWindowController,
                            topLevelObjects: &topLevelObjects) {
            errorLog("Could not load nib for AerialWindow, please report")
        }
        
        aerialWindowController.windowDidLoad()
        aerialWindowController.showWindow(self)
        aerialWindowController.window!.delegate = self
        aerialWindowController.window!.toggleFullScreen(nil)
        aerialWindowController.window!.makeKeyAndOrderFront(nil)
        
        NSApp.activate(ignoringOtherApps: true)
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
