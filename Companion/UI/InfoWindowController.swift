//
//  InfoWindowController.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 03/08/2020.
//

import Cocoa

class InfoWindowController: NSWindowController {

    @IBOutlet var versionLabel: NSTextField!
    override func windowDidLoad() {
        super.windowDidLoad()

        versionLabel.stringValue = "Version " + Helpers.version
    }
    
    @IBAction func donateButtonClick(_ sender: Any) {
        print("donate")
        let workspace = NSWorkspace.shared
        let url = URL(string: "https://ko-fi.com/A0A32385Y")!
        workspace.open(url)
    }
    
    @IBAction func githubButtonClick(_ sender: Any) {
        print("github")
        let workspace = NSWorkspace.shared
        let url = URL(string: "https://github.com/glouel/AerialCompanion")!
        workspace.open(url)
    }
    
    @IBAction func iconButtonClick(_ sender: Any) {
        let workspace = NSWorkspace.shared
        let url = URL(string: "https://infernodesign.com")!
        workspace.open(url)
    }
    
}
