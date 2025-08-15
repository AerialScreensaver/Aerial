//
//  ReleaseViewController.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 16/08/2020.
//

import Cocoa

class ReleaseViewController: NSViewController {
    @IBOutlet var imageView1: NSImageView!
    @IBOutlet var imageView2: NSImageView!
    
    @IBOutlet var releasesButton: NSButton!
    @IBOutlet var betaButton: NSButton!
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do view setup here.
        imageView1.image = Helpers.getSymbol("clock")?.tinting(with: .secondaryLabelColor)
        imageView2.image = Helpers.getSymbol("ant")?.tinting(with: .secondaryLabelColor)
        if Preferences.desiredVersion == .beta {
            betaButton.state = .on
        } else {
            releasesButton.state = .on
        }
    }
 
    @IBAction func choiceChange(_ sender: NSButton) {
        switch sender {
        case releasesButton:
            Preferences.desiredVersion = .release
        default:
            Preferences.desiredVersion = .beta
        }

        /*let appd = NSApp.delegate as? AppDelegate
        appd?.updateMenu()*/
    }
    
}
