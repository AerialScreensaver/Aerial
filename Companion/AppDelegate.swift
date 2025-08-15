//
//  AppDelegate.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 24/07/2020.
//

import Cocoa
import Sparkle

enum IconMode {
    case normal, updating, notification
}

struct PrefTest: Decodable {
    let title: String
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    lazy var firstTimeSetupWindowController = FirstTimeSetupWindowController()

    lazy var menuViewController = MenuViewController()
    
    //lazy var popoverViewController = ModernPopoverViewController()
    lazy var popoverViewController = CompanionPopoverViewController()

    let popover = NSPopover()

    // Sparkle
    var sparkleController : SPUStandardUpdaterController
    
    override init() {
        sparkleController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }
    
    // MARK: - Lifecycle
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        debugLog("Version \(Helpers.version) launched on  \(ProcessInfo.processInfo.operatingSystemVersionString)")
        //Preferences.firstTimeSetup = false
        
        let arguments = ProcessInfo.processInfo.arguments

        // Ensure not in bundle
        ensureNotInBundle()
        
        // This is imperative, breaks everything
        ensureNotInstalledForAllUsers()
        
        // This will go away at some point
        removeOldAerialApp()
        
        if !Preferences.restartBackground {
            Preferences.enabledWallpaperScreenUuids = []

        }
        
        if arguments.contains("--silent") {
            debugLog("Background mode")

            // Returns true if we need to stay around
            if !silentModeCheck() {
                return
            }
            // We're staying then !
            debugLog("Falling back to menu for a notification")
        } else if !Preferences.firstTimeSetup {
            debugLog("Do First Time Setup")
            doFirstTimeSetup()
        }
        
        // Menu mode, we may fall down here from silent mode too in notify mode,
        // or if we must update
        
        
        //createMenu()

        // Set the icon
        setIcon(mode: .normal)

        // Load popover
        var topLevelObjects: NSArray? = NSArray()
        Bundle.main.loadNibNamed(NSNib.Name("CompanionPopoverViewController"),
                            owner: popoverViewController,
                            topLevelObjects: &topLevelObjects)
        popoverViewController.setDelegate(self)
        popoverViewController.viewDidLoad()

        // Make it a real popover
        popover.contentViewController = popoverViewController
        popover.behavior = .transient
        
        // Action button
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
        }
        
        DistributedNotificationCenter.default.addObserver(self,
            selector: #selector(self.test2(_:)),
            name: Notification.Name("com.glouel.aerial.nextvideo"), object: nil)

        
        PluginBridge.setNotifications()
        
        /*// We may auto start the background based on user pref
        if Preferences.restartBackground {
            // Only if it was running previously
            if Preferences.wasRunningBackground {
                popoverViewController.startWallpaperClick(self)
            }
        }*/

        //testSonoma()
    }
    
    func testSonoma() {
        print("TEST SONOMA")
        /*
        let defaultFile = "/Users/guillaume/Library/Application Support/com.apple.wallpaper/Store/Index_v2.plist"

        let plistURL = URL(fileURLWithPath: defaultFile)
        let data = try? Data(contentsOf: plistURL)
        
        
        var plistDictionary = try? PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), options: [], format: nil) as? [String: AnyObject]
        
        guard var configurationPlist = try? PropertyListSerialization.propertyList(from: (plistDictionary?["AllSpacesAndDisplays"] as? NSDictionary)?["Idle"] [?? Data(), options: [], format: nil) as? [String: AnyObject] else {
            return
        }
        
        // Modify the `configurationPlist` dictionary as needed
        configurationPlist["NewKey"] = "NewValue" as AnyObject
        
        // Update the `plistDictionary` with the modified `configurationPlist`
        if var content = (plistDictionary?["AllSpacesAndDisplays"] as? NSDictionary)?["Idle"] as? NSDictionary??.content {
            if var choices = content["Choices"] as? NSArray {
                if var choicesDict = choices[0] as? NSDictionary {
                    choicesDict["Configuration"] = try? PropertyListSerialization.data(fromPropertyList: configurationPlist, format: .xml, options: 0) as AnyObject
                    choices[0] = choicesDict
                    content["Choices"] = choices
                    if var idle = (plistDictionary?["AllSpacesAndDisplays"] as? NSDictionary)?["Idle"] as? NSDictionary {
                        idle["Content"] = content
                        plistDictionary?["AllSpacesAndDisplays"] = ["Idle": idle] as AnyObject
                    }
                }
            }
        }*/
        /*
        // Write the modified `plistDictionary` to the plist file
        if let data = try? PropertyListSerialization.data(fromPropertyList: plistDictionary as Any, format: .xml, options: 0) {
            try? data.write(to: plistURL, options: .atomic)
        }
        
        */
        
        /*
        guard let plistDictionary = try? PropertyListSerialization.propertyList(from: data!, options: [], format: nil) as? [String: AnyObject] else {
            return
        }*/
        /*
        let allDisplays = plistDictionary["AllSpacesAndDisplays"] as! NSDictionary
        let idle = allDisplays["Idle"] as! NSDictionary
        let content = idle["Content"] as! NSDictionary
        let choices = content["Choices"] as! NSArray
        let choicesDict = choices[0] as! NSDictionary

        let encodedData = choicesDict["Configuration"] // This is our data
        //print(encodedData.debugDescription)
        
        guard let configurationPlist = try? PropertyListSerialization.propertyList(from: encodedData as! Data, options: [], format: nil) as? [String: AnyObject] else {
            return
        }
        */
/*
        guard var configurationPlist = try? PropertyListSerialization.propertyList(from: (plistDictionary?["AllSpacesAndDisplays"] as? NSDictionary)?["Idle"] as? NSDictionary??.self??.content??.choices?[0]??.configuration ?? Data(), options: [], format: nil) as? [String: AnyObject] else {
            return
        }
        print(configurationPlist)*/
    }
    
    
    @objc func test2(_ aNotification: Notification) {
        debugLog("############ test2")
        print("receiveed")
        print(aNotification.debugDescription)
    }
    
    
    // Popover handling
    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover(sender: sender)
        } else {
            showPopover(sender: sender)
        }
    }

    func showPopover(sender: Any?) {
        if let button = statusItem.button {
            (popover.contentViewController! as! CompanionPopoverViewController).update()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func closePopover(sender: Any?) {
        popover.performClose(sender)
    }
    
    func removeOldAerialApp() {
        if FileManager.default.fileExists(atPath: "/Applications/Aerial.app") {
            debugLog("Removing old version of Aerial.app")
            
            do {
                try FileManager().removeItem(at: URL(fileURLWithPath: "/Applications/Aerial.app"))
            } catch {
                // ERROR
                errorLog("Cannot delete old Aerial.app in /Applications directory")
            }
        }
    }
    
    func ensureNotInBundle() {
        do {
            let info = try Bundle.main.bundleURL.resourceValues(forKeys: [.volumeNameKey])
            if let volume = info.volumeName {
                if volume.starts(with: "Aerial") {
                    Helpers.showErrorAlert(question: "Oops", text: "Aerial can only be run from the Applications folder. Drag Aerial to Applications, then open Applications and run it again.", button: "Ok")
                    
                    NSApplication.shared.terminate(self)
                }
            }
        } catch {
            errorLog("Ensure bundle error")
        }
    }
    
    func doFirstTimeSetup() {
        var topLevelObjects: NSArray? = NSArray()
        if !Bundle.main.loadNibNamed(NSNib.Name("FirstTimeSetupWindowController"),
                            owner: firstTimeSetupWindowController,
                            topLevelObjects: &topLevelObjects) {
            errorLog("Could not load nib for FirstTimeSetup, please report")
        }
        firstTimeSetupWindowController.windowDidLoad()
        firstTimeSetupWindowController.showWindow(self)
        firstTimeSetupWindowController.window!.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // This returns true if we should stay around, and false if we can safely return
    func silentModeCheck() -> Bool {
        Update.instance.commandLine = true

        // Force a cache update
        CachedManifest.instance.updateNow()

        // Make sure we don't need to update, or redirect you there
        if UpdaterVersion.needsUpdating() {
            return true         // Then stay around !
        }
        
        let (stringVersion, shouldInstall) = Update.instance.check()

        if shouldInstall {
            debugLog(stringVersion)
            if Preferences.updateMode == .automatic {
                Update.instance.unattendedPerform()
                return false    // We are done
            } else {
                return true     // Stay around !
            }
        } else {
            // We need to stay around for a bit, because if not
            // launchd will think we are crashing...
            debugLog("No new version, quitting in 20sec.")
            RunLoop.main.run(until: Date() + 0x14)
            NSApplication.shared.terminate(self)

            return false
        }
    }
    
    // Ensure we don't have something in /Library/Screen Savers/
    func ensureNotInstalledForAllUsers() {
        if LocalVersion.isInstalledForAllUsers() {
            NSApp.activate(ignoringOtherApps: true)
            // Open finder with the file selected
            NSWorkspace.shared.selectFile(LocalVersion.aerialAllUsersPath, inFileViewerRootedAtPath: "/Library/Screen Savers/")

            while LocalVersion.isInstalledForAllUsers() {
                let result = Helpers.showAlert(question: "Aerial is currently installed for All Users", text: "In order for the updater to work, you need to uninstall the current version of Aerial. \n\nYou can do this by deleting the Aerial.saver file in the Finder window that just opened. Press Try Again when done.", button1: "Try Again", button2: "Quit")

                if !result {
                    // Quit !
                    NSApplication.shared.terminate(self)
                }
            }
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
        if popoverViewController.currentMode == .desktop {
            Preferences.wasRunningBackground = true
        } else {
            Preferences.wasRunningBackground = false
        }
    }
    
    // Change the icon based on status
    func setIcon(mode: IconMode) {
        
        DispatchQueue.main.async {
            print("setIcon \(mode)")
            switch mode {
            case .normal:
                self.statusItem.image = NSImage(named: "Status48")
            case .updating:
                self.statusItem.image = NSImage(named: "StatusTransp48")
            case .notification:
                self.statusItem.image = NSImage(named: "Status48Attention")
            }
            
            self.statusItem.image?.size.width = 17
            self.statusItem.image?.size.height = 17
        }
    }
    
    // MARK: - Menu Content Setup and Update
    // Load the menu from MenuView.xib and attach it to our StatusItem
    /*
    func createMenu() {
        var topLevelObjects: NSArray? = NSArray()

        menuViewController.setDelegate(self)
        // Grab the menu from the nib
        Bundle.main.loadNibNamed("MenuView", owner: menuViewController, topLevelObjects: &topLevelObjects)
        
        // This bugs me a lot, I shouldn't have to call this manually ?
        menuViewController.viewDidLoad()

        // Grab the menu from the nib and set it
        let objs = topLevelObjects! as [AnyObject]
        for obj in objs {
            if obj is NSMenu {
                // Menu found, set it on our statusItem !
                statusItem.menu = obj as? NSMenu
            }
        }
    }
    
    func updateMenu() {
        print("upd")
        menuViewController.updateMenuSettings()
    }
    func updateMenuContent() {
        menuViewController.updateMenuContent()
    }*/
}

