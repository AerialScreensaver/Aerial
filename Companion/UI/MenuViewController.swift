//
//  MenuViewController.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 03/08/2020.
//

import Cocoa
import ScreenSaver

class MenuViewController: NSViewController, UpdateCallback {
    lazy var infoWindowController = InfoWindowController()
    lazy var updateCheckWindowController = UpdateCheckWindowController()
    
    var desktopLauncherInstances: [String: DesktopLauncher] = [:]

    // This is for the custom views on top
    @IBOutlet var versionLabel: NSTextField!
    @IBOutlet var versionImageView: NSImageView!
    @IBOutlet var versionInstallNow: NSButton!
    
    @IBOutlet var companionTitleLabel: NSTextField!
    @IBOutlet var goodTrick: NSProgressIndicator!
    
    // Menu entries
    // Desired version
    @IBOutlet var menuBeta: NSMenuItem!
    @IBOutlet var menuRelease: NSMenuItem!
    
    // Update mode
    @IBOutlet var menuAutomatic: NSMenuItem!
    @IBOutlet var menuNotifyMe: NSMenuItem!
    
    // Check every
    @IBOutlet var menuHour: NSMenuItem!
    @IBOutlet var menuDay: NSMenuItem!
    @IBOutlet var menuWeek: NSMenuItem!
    

    // Settings
    @IBOutlet var menuLaunchManually: NSMenuItem!
    @IBOutlet var menuLaunchAtStartup: NSMenuItem!
    @IBOutlet var menuLaunchInBackground: NSMenuItem!

    @IBOutlet var menuDebugMode: NSMenuItem!
    
    // Experimental
    @IBOutlet var launchAsWallpaperMenu: NSMenu!
    
    
    // The menu itself
    @IBOutlet var statusMenu: NSMenu!
    
    var appDelegate : AppDelegate?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        companionTitleLabel.stringValue = Consts.productName + " " + Helpers.version
        
        // Let's make sure our delegate is set
        Update.instance.setCallback(self)

        // Let's check right now the manifest status
        CachedManifest.instance.updateNow()

        updateMenuSettings()
        updateMenuContent()
        
        // Then set the callback
        BackgroundCheck.instance.set()
    }
    
    func setDelegate(_ delegate: AppDelegate) {
        appDelegate = delegate
    }
    
    // This is only called once at startup
    func updateMenuSettings() {
        debugLog("ums")
        // Desired video format
        switch Preferences.desiredVersion {
        case .beta:
            menuBeta.state = .on
            menuRelease.state = .off
        case .release:
            menuBeta.state = .off
            menuRelease.state = .on
        }
        
        switch Preferences.updateMode {
        case .automatic:
            menuAutomatic.state = .on
            menuNotifyMe.state = .off
        case .notifyme:
            menuAutomatic.state = .off
            menuNotifyMe.state = .on
        }

        switch Preferences.checkEvery {
        case .hour:
            menuHour.state = .on
        case .day:
            menuDay.state = .on
        case .week:
            menuWeek.state = .on
        }
        
        switch Preferences.launchMode {
        case .manual:
            menuLaunchManually.state = .on
            menuLaunchAtStartup.state = .off
            menuLaunchInBackground.state = .off
        case .startup:
            menuLaunchManually.state = .off
            menuLaunchAtStartup.state = .on
            menuLaunchInBackground.state = .off
        case .background:
            menuLaunchManually.state = .off
            menuLaunchAtStartup.state = .off
            menuLaunchInBackground.state = .on
        }
        
        menuDebugMode.state = Preferences.debugMode ? .on : .off
    }
    
    // This is called periodically to refresh the view
    func updateMenuContent() {
        debugLog("umc")
        DispatchQueue.main.async {
            // If we have fetched the versions, put them in the UI
            if let manifest = CachedManifest.instance.manifest {
                self.menuBeta.title = "Beta (\(manifest.betaVersion))"
                self.menuRelease.title = "Release (\(manifest.releaseVersion))"
                
                // We may need to update AerialUpdater. This will be done as infrequently as possible, only in case of a security issue (not for features)
                if UpdaterVersion.needsUpdating() {
                    self.setIcon(mode: .notification)
                    print(manifest.updaterVersion)
                    print(Helpers.version)
                    self.versionLabel.stringValue = "New updater version"
                    self.versionImageView.isHidden = true
                    self.versionInstallNow.isHidden = false
                    self.goodTrick.isHidden = true
                    return
                }
            }
            
            let (statusString, shouldInstall) = Update.instance.check()
            debugLog("\(statusString) \(shouldInstall)")
            
            self.versionLabel.stringValue = statusString
            self.goodTrick.isHidden = true

            if shouldInstall {
                // Make the button visible
                self.setIcon(mode: .notification)

                self.versionImageView.isHidden = true
                self.versionInstallNow.isHidden = false
            } else {
                // Make the button visible
                self.setIcon(mode: .normal)
                self.versionImageView.isHidden = false
                self.versionInstallNow.isHidden = true
            }
            
            for screen in NSScreen.screens {
                let screenItem = NSMenuItem()
                screenItem.title = screen.displayName
                screenItem.action = #selector(self.wallpaperScreenChange)
                screenItem.target = self
                screenItem.representedObject = screen.screenUuid
                
                if Preferences.enabledWallpaperScreenUuids.contains(screen.screenUuid) {
                    screenItem.state = .on
                    
                    if let screen = NSScreen.getScreenByUuid(screen.screenUuid) {
                        self.toggleDesktopLauncher(for: screen.screenUuid)
                    }
                }
                
                
                self.launchAsWallpaperMenu.addItem(screenItem)
            }
        }
    }
    
    
    // This is our callback for the update proper
    func updateProgress(string: String, done: Bool) {
        DispatchQueue.main.async {
            if done {
                self.goodTrick.stopAnimation(self)
                self.goodTrick.isHidden = true
                self.versionLabel.stringValue = string
                
                if string == "OK" {
                    self.updateMenuContent()
                } else {
                    Helpers.showErrorAlert(question: "Installation error", text: "\(string) \n\nPlease report.)")
                }
            } else {
                self.versionLabel.stringValue = string
            }
        }
    }

    func setIcon(mode: IconMode) {
        appDelegate?.setIcon(mode: mode)
    }
    
    func toggleDesktopLauncher(for screenUuid: String) -> Bool {
        var isRunning = false
        
        if let desktopLauncher = desktopLauncherInstances[screenUuid] {
            desktopLauncher.toggleLauncher()
            isRunning = desktopLauncher.isRunning
        }
        else if let screen = NSScreen.getScreenByUuid(screenUuid) {
            desktopLauncherInstances[screenUuid] = DesktopLauncher(screen: screen)
            desktopLauncherInstances[screenUuid]?.toggleLauncher()
            isRunning = desktopLauncherInstances[screenUuid]!.isRunning
        }
        
        if isRunning {
            if !Preferences.enabledWallpaperScreenUuids.contains(screenUuid) {
                Preferences.enabledWallpaperScreenUuids.append(screenUuid)
            }
        }
        else {
            Preferences.enabledWallpaperScreenUuids = Preferences.enabledWallpaperScreenUuids.filter {$0 != screenUuid}
        }
        
        return isRunning
    }
    
    
    // MARK: - Custom UI Actions
    
    // Handle the wallpaper screen selector
    @objc func wallpaperScreenChange(sender: NSMenuItem) {
        if let screen = NSScreen.getScreenByUuid(sender.representedObject as! String) {
            sender.state = self.toggleDesktopLauncher(for: screen.screenUuid) ? .on : .off
        }
        else {
            sender.isEnabled = false
        }
    }
    
    
    // Installation Button
    @IBAction func versionInstallNowClick(_ sender: Any) {
        if UpdaterVersion.needsUpdating() {
            let workspace = NSWorkspace.shared
            let url = URL(string: "https://github.com/glouel/AerialCompanion/releases")!
            workspace.open(url)
            return
        }
        
        versionInstallNow.isHidden = true
        versionLabel.stringValue = "Hold on..."

        // Start spinning
        goodTrick.isHidden = false
        goodTrick.startAnimation(self)
        
        // Launch the update
        Update.instance.perform(self)
    }
    
    // MARK: - Menu callbacks
    
    // MARK: - Screen Saver
    @IBAction func openScreenSaverSettings(_ sender: Any) {
        _ = Helpers.shell(launchPath: "/usr/bin/osascript", arguments: [
        "-e", "tell application \"System Preferences\"",
        "-e","set the current pane to pane id \"com.apple.preference.desktopscreeneffect\"",
        "-e","reveal anchor \"ScreenSaverPref\" of pane id \"com.apple.preference.desktopscreeneffect\"",
        "-e","activate",
        "-e","end tell"])
    }
    
    @IBAction func aerialAsScreenSaver(_ sender: Any) {
        if let libHandle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY) {
            let sym = dlsym(libHandle, "SACScreenSaverStartNow")
            typealias myFunction = @convention(c) () -> Void
            let SACLockScreenImmediate = unsafeBitCast(sym, to: myFunction.self)
            SACLockScreenImmediate()
            dlclose(libHandle)
        }
    }
    
    // MARK: - Updates

    @IBAction func desiredVersionChange(_ sender: NSMenuItem) {
        // There's probably a better way to do this...
        sender.state = .on
        if sender == menuBeta {
            menuRelease.state = .off
            Preferences.desiredVersion = .beta
        } else if sender == menuRelease {
            menuBeta.state = .off
            Preferences.desiredVersion = .release
        }
        
        updateMenuContent()
    }
    
    @IBAction func updateModeChange(_ sender: NSMenuItem) {
        sender.state = .on
        if sender == menuAutomatic {
            menuNotifyMe.state = .off
            Preferences.updateMode = .automatic
        } else if sender == menuNotifyMe {
            menuAutomatic.state = .off
            Preferences.updateMode = .notifyme
        }
    }
    
    @IBAction func checkEveryChange(_ sender: NSMenuItem) {
        sender.state = .on
        if sender == menuHour {
            menuDay.state = .off
            menuWeek.state = .off
            Preferences.checkEvery = .hour
        } else if sender == menuDay {
            menuHour.state = .off
            menuWeek.state = .off
            Preferences.checkEvery = .day
        } else if sender == menuWeek {
            menuHour.state = .off
            menuDay.state = .off
            Preferences.checkEvery = .week
        }
    }

    @IBAction func checkNow(_ sender: NSMenuItem) {
        var topLevelObjects: NSArray? = NSArray()
        if !Bundle.main.loadNibNamed(NSNib.Name("UpdateCheckWindowController"),
                            owner: updateCheckWindowController,
                            topLevelObjects: &topLevelObjects) {
            errorLog("Could not load nib for InfoWindow, please report")
        }
        //updateCheckWindowController.setCallback(self)
        updateCheckWindowController.windowDidLoad()
        updateCheckWindowController.showWindow(self)
        updateCheckWindowController.window!.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateCheckWindowController.startCheck()
    }
    
    // MARK: - Companion

    
    // MARK: - Launch Companion
    
   
    /// Show About Updater version window
    @IBAction func aboutUpdater(_ sender: NSMenuItem) {
        var topLevelObjects: NSArray? = NSArray()
        if !Bundle.main.loadNibNamed(NSNib.Name("InfoWindowController"),
                            owner: infoWindowController,
                            topLevelObjects: &topLevelObjects) {
            errorLog("Could not load nib for InfoWindow, please report")
        }
        infoWindowController.windowDidLoad()
        infoWindowController.showWindow(self)
        infoWindowController.window!.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    
    @IBAction func debugMode(_ sender: Any) {
        Preferences.debugMode = !Preferences.debugMode
        
        menuDebugMode.state = Preferences.debugMode ? .on : .off
    }
    
    /// Handle the launch submenu
    @IBAction func launchModeChange(_ sender: NSMenuItem) {
        if sender == menuLaunchInBackground {
            // Let's make sure they understand
            if !Helpers.showAlert(question: "Background mode", text: "By enabling background mode, Aerial Companion will shedule itself to run for a few seconds at the frequency you selected.\n\nThe updater will quit the menu so make sure you change your other settings first. You can launch Aerial Companion manually at any time to change your settings.", button1: "Quit and run in background", button2: "Cancel") {
                return
            }
        }

        sender.state = .on
        if sender == menuLaunchManually {
            menuLaunchAtStartup.state = .off
            menuLaunchInBackground.state = .off
            Preferences.launchMode = .manual
        } else if sender == menuLaunchAtStartup {
            menuLaunchManually.state = .off
            menuLaunchInBackground.state = .off
            Preferences.launchMode = .startup
        } else if sender == menuLaunchInBackground {
            menuLaunchManually.state = .off
            menuLaunchAtStartup.state = .off
            Preferences.launchMode = .background
        }
        
        LaunchAgent.update()
    }
    
    // MARK: - Experimental

    @IBAction func readMeFirst(_ sender: Any) {
        if Helpers.showAlert(question: "Copy and adapt Aerial settings?", text: "When you use the functions below on macOS 10.15 or later, Aerial will run as a separate instance, with separate settings, and a separate cache from its screen saver mode that you know. In order to bridge that gap, Aerial Companion can copy your settings and try to adapt them to use the same cache.\n\nPlease note that when running this way, Aerial is no longer limited by the sandboxing restrictions, which means you can manually set a cache folder on a secondary or remote disk, or use the right arrow key to skip a video.", button1: "I understand, try to copy my settings!", button2: "I'll configure things separately") {
            
        }
    }

    @IBAction func launchHostedSettings(_ sender: Any) {
        SaverLauncher.instance.openSettings()
    }
    
    @IBAction func aerialInWindow(_ sender: Any) {
        //let launcher = SaverLauncher()
        //launcher.windowMode()
        
        SaverLauncher.instance.windowMode()
    }
    
    
    @IBAction func testPause(_ sender: Any) {
        //DesktopLauncher.instance.togglePause()
    }
    
    // Bye
    @IBAction func quitButton(_ sender: Any) {
        NSApplication.shared.terminate(self)
    }
}
