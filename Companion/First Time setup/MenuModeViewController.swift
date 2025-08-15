//
//  MenuModeViewController.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 16/08/2020.
//

import Cocoa

class MenuModeViewController: NSViewController {
    @IBOutlet var imageView1: NSImageView!
    @IBOutlet var imageView2: NSImageView!
    @IBOutlet var imageView3: NSImageView!
    
    @IBOutlet var allBackground: NSButton!
    @IBOutlet var backgroundNotify: NSButton!
    @IBOutlet var menuBarNotify: NSButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do view setup here.
        imageView1.image = Helpers.getSymbol("moon.zzz")?.tinting(with: .secondaryLabelColor)
        imageView2.image = Helpers.getSymbol("exclamationmark.bubble")?.tinting(with: .secondaryLabelColor)
        imageView3.image = Helpers.getSymbol("clock")?.tinting(with: .secondaryLabelColor)
        
        menuBarNotify.state = .on
        Preferences.launchMode = .startup
        Preferences.updateMode = .notifyme
    }
    
    @IBAction func choiceChange(_ sender: NSButton) {
        switch sender {
        case allBackground:
            Preferences.launchMode = .background
            Preferences.updateMode = .automatic
        case allBackground:
            Preferences.launchMode = .background
            Preferences.updateMode = .notifyme
        default:
            Preferences.launchMode = .startup
            Preferences.updateMode = .notifyme
        }

        /*let appd = NSApp.delegate as? AppDelegate
        appd?.updateMenu() */
    }
    
}
