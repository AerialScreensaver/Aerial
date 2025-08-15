//
//  SettingsWindowController.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 06/02/2022.
//

import Cocoa

class SettingsWindowController: NSWindowController {

    @IBOutlet var betaPopup: NSPopUpButton!
    @IBOutlet var updateModePopup: NSPopUpButton!
    @IBOutlet var checkEveryPopup: NSPopUpButton!
    @IBOutlet var launchCompanionPopup: NSPopUpButton!

    @IBOutlet weak var restartAtLaunchCheckbox: NSButton!
    
    lazy var updateCheckWindowController = UpdateCheckWindowController()

    override func windowDidLoad() {
        super.windowDidLoad()

        // Implement this method to handle any initialization after your window controller's window has been loaded from its nib file.
        
        betaPopup.selectItem(at: Preferences.desiredVersion.rawValue)
        updateModePopup.selectItem(at: Preferences.updateMode.rawValue)
        checkEveryPopup.selectItem(at: Preferences.checkEvery.rawValue)
        launchCompanionPopup.selectItem(at: Preferences.launchMode.rawValue)
        
        restartAtLaunchCheckbox.state = Preferences.restartBackground ? .on : .off
    }
    
    public func setHostController(_controller: NSViewController) {
        
    }
    
    
    @IBAction func betaPopupChange(_ sender: NSPopUpButton) {
        Preferences.desiredVersion = DesiredVersion(rawValue: sender.indexOfSelectedItem)!
    }

    @IBAction func updateModePopupChange(_ sender: NSPopUpButton) {
        Preferences.updateMode = UpdateMode(rawValue: sender.indexOfSelectedItem)!
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
            errorLog("Could not load nib for InfoWindow, please report")
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
        Preferences.restartBackground = sender.state == .on ? true : false
    }
}
