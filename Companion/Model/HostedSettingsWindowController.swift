//
//  HostedSettingsWindowController.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 01/11/2022.
//

import Cocoa

class HostedSettingsWindowController: NSWindowController, NSWindowDelegate {
    var uiController: CompanionPopoverViewController?
    
    func setController(_ controller: CompanionPopoverViewController) {
        uiController = controller
    }
    
    override func windowDidLoad() {
        super.windowDidLoad()
    }
    
    func windowWillClose(_ notification: Notification) {
        print("Hosted Settings Will close")
        uiController?.shouldRefreshPlaybackMode()
    }
}
