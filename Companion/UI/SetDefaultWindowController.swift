//
//  SetDefaultWindowController.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 26/09/2023.
//

import Cocoa

class SetDefaultWindowController: NSWindowController {

    override func windowDidLoad() {
        super.windowDidLoad()

        // Implement this method to handle any initialization after your window controller's window has been loaded from its nib file.
    }
    
    @IBAction func openSettings(_ sender: Any) {
        _ = Helpers.shell(launchPath: "/usr/bin/open", arguments: ["x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension"])
    }
    
    
    @IBAction func closeInstructions(_ sender: Any) {
        close()
    }
}
