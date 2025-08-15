//
//  CompanionPopoverViewController.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 08/10/2022.
//

import Cocoa
import IOKit.ps

class CompanionPopoverViewController: NSViewController, UpdateCallback {
    lazy var infoWindowController = InfoWindowController()
    lazy var settingsWindowController = SettingsWindowController()
    lazy var updateCheckWindowController = UpdateCheckWindowController()
    lazy var setDefaultWindowController = SetDefaultWindowController()

    var desktopLauncherInstances: [String: DesktopLauncher] = [:]
    
    enum PlaybackMode {
        case none, desktop, monitor
    }
    
    var currentMode:PlaybackMode = .none
    
    var hasUpdate = false
    
    var appDelegate : AppDelegate?

    @IBOutlet weak var wallpaperPickScreenButton: NSButton!
    
    @IBOutlet weak var mainBarBox: NSBox!
    
    @IBOutlet weak var playbackBarBox: NSBox!
    
    @IBOutlet weak var updateBarBox: NSBox!
    
    @IBOutlet weak var notDefaultBox: NSBox!
    
    @IBOutlet weak var warningDisabledBox: NSBox!
    
    @IBOutlet weak var updateButton: NSButton!

    @IBOutlet weak var updateLabel: NSTextField!
    
    @IBOutlet weak var activationTimePopup: NSPopUpButton!
    
    @IBOutlet weak var sleepTimeButton: NSButtonCell!
    
    @IBOutlet weak var versionLabel: NSTextField!
    
    @IBOutlet weak var globalSpeedSlider: NSSlider!
    
    let appMenu = NSMenu()
    
    // UpdateCallback protocol
    
    func updateProgress(string: String, done: Bool) {
        DispatchQueue.main.async {
            if done {
                self.updateLabel.stringValue = string
            } else {
                self.updateLabel.stringValue = string
            }
        }
    }
    
    func updateMenuContent() {
        debugLog("umc")
        DispatchQueue.main.async {
            
            let (statusString, shouldInstall) = Update.instance.check()
            debugLog("\(statusString) \(shouldInstall)")
            
            //self.versionLabel.stringValue = statusString

            if shouldInstall {
                self.hasUpdate = true
                self.update()
                self.setIcon(mode: .notification)
               
            } else {
                self.hasUpdate = false
                self.update()
                self.setIcon(mode: .normal)
            }
        }
    }
    
    func setIcon(mode: IconMode) {
        appDelegate?.setIcon(mode: mode)
    }
    // /UpdateCallback protocol


    override func viewDidLoad() {
        super.viewDidLoad()
        print("viewdidload")
        // Let's make sure our delegate is set
        Update.instance.setCallback(self)

        // Let's check right now the manifest status
        CachedManifest.instance.updateNow()

        // Create our menu & relaunch if needed
        for screen in NSScreen.screens {
            let screenItem = NSMenuItem()
            
            if #available(macOS 10.15, *) {
                screenItem.title = screen.localizedName
            } else {
                screenItem.title = screen.displayName   // This doesn't work on Sonoma?
            }
            
            screenItem.action = #selector(self.wallpaperScreenChange)
            screenItem.target = self
            screenItem.representedObject = screen.screenUuid
            
            if Preferences.enabledWallpaperScreenUuids.contains(screen.screenUuid) {
                screenItem.state = .on
            } else {
                screenItem.state = .off
            }
            
            self.appMenu.addItem(screenItem)

            // We only restart if the option is checked
            if Preferences.restartBackground {
                if Preferences.enabledWallpaperScreenUuids.contains(screen.screenUuid) {
                    if let screen = NSScreen.getScreenByUuid(screen.screenUuid) {
                        self.toggleDesktopLauncher(for: screen.screenUuid)
                    }
                }
            }
        }
        
        // Update the UI
        update()

        // This will start the update process
        updateMenuContent()

        // Then set the callback
        BackgroundCheck.instance.set()
        
        versionLabel.stringValue = Consts.productName + " " + Helpers.version
    }

    
    
    // Handle the wallpaper screen selector
    @objc func wallpaperScreenChange(sender: NSMenuItem) {
        if let screen = NSScreen.getScreenByUuid(sender.representedObject as! String) {
            sender.state = self.toggleDesktopLauncher(for: screen.screenUuid) ? .on : .off
        }
        else {
            sender.isEnabled = false
        }
    }
    
    func setActivationTimePopup() {
        DispatchQueue.global(qos: .userInitiated).async {
            let minutes = SystemPrefs.getSaverActivationTime() ?? 0

            DispatchQueue.main.async { [self] in
                switch minutes {
                case 1:
                    activationTimePopup.selectItem(at: 0)
                case 2:
                    activationTimePopup.selectItem(at: 1)
                case 5:
                    activationTimePopup.selectItem(at: 2)
                case 10:
                    activationTimePopup.selectItem(at: 3)
                case 20:
                    activationTimePopup.selectItem(at: 4)
                case 30:
                    activationTimePopup.selectItem(at: 5)
                case 60:
                    activationTimePopup.selectItem(at: 6)
                case 0:
                    activationTimePopup.selectItem(at: 7)
                default:
                    activationTimePopup.selectItem(at: 8)
                    activationTimePopup.selectedItem?.title = "Custom (" + String(minutes) + " minutes)..."
                }
            }
        }
    }
    
    func setSleepTimeLabel() {
        DispatchQueue.global(qos: .userInitiated).async {
            let sleepTime = SystemPrefs.getDisplaySleep() ?? 0

            DispatchQueue.main.async { [self] in
                if(sleepTime != 0){
                    sleepTimeButton.title = "\(sleepTime) minutes"
                } else {
                    sleepTimeButton.title = "Never (Disabled)"
                }
            }
        }
        
        
    }
    
    func validateSleepSettings() {
        DispatchQueue.global(qos: .userInitiated).async {
            let saverTime = SystemPrefs.getSaverActivationTime() ?? 0
            let displayTime = SystemPrefs.getDisplaySleep() ?? 0

            DispatchQueue.main.async { [self] in
                if displayTime == 0 && saverTime > 0 {
                    warningDisabledBox.isHidden = true
                } else if (saverTime == 0 || saverTime >= displayTime ) {
                    warningDisabledBox.isHidden = false
                } else {
                    warningDisabledBox.isHidden = true
                }
            }
        }
        
    }
    
    @IBAction func activationTimeChange(_ sender: NSPopUpButton) {
        print("test")
        switch(sender.indexOfSelectedItem) {
        case 0:
            SystemPrefs.setSaverActivationTime(time: 1)
        case 1:
            SystemPrefs.setSaverActivationTime(time: 2)
        case 2:
            SystemPrefs.setSaverActivationTime(time: 5)
        case 3:
            SystemPrefs.setSaverActivationTime(time: 10)
        case 4:
            SystemPrefs.setSaverActivationTime(time: 20)
        case 5:
            SystemPrefs.setSaverActivationTime(time: 30)
        case 6:
            SystemPrefs.setSaverActivationTime(time: 60)
        case 7:
            SystemPrefs.setSaverActivationTime(time: 0)
        default:
            print("custom")
        }
        
        validateSleepSettings()
    }
    
    
    @IBAction func openEnergySettings( sender: Any) {
        if #available(macOS 13, *) {
            _ = Helpers.shell(launchPath: "/usr/bin/open", arguments: [
            "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension"])
        } else if #available(macOS 11, *)  {
            let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
            let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
            if(sources.count > 0){
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Battery.prefpane"))
            } else {
                if #available(macOS 12, *) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/EnergySaverPref.prefpane"))
                } else {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/EnergySaver.prefpane"))
                }
            }
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/EnergySaver.prefpane"))
        }

        // eh...
        validateSleepSettings()
    }
    
    @IBAction func setAsDefaultButton(_ sender: NSButton) {
        if #available(macOS 14, *) {
            var topLevelObjects: NSArray? = NSArray()
            if !Bundle.main.loadNibNamed(NSNib.Name("SetDefaultWindowController"),
                                         owner: setDefaultWindowController,
                                         topLevelObjects: &topLevelObjects) {
                errorLog("Could not load nib for SettingsWindow, please report")
            }
            setDefaultWindowController.windowDidLoad()
            setDefaultWindowController.showWindow(self)
            setDefaultWindowController.window!.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            appDelegate?.closePopover(sender: nil)
        } else {
            Update.instance.setAsDefault()
            notDefaultBox.isHidden = true
        }
    }
    
    
    func setDelegate(_ delegate: AppDelegate) {
        appDelegate = delegate
    }

    
    // Update
    func update() {
        print("update")
        debugLog("update")
        if hasUpdate {
            updateBarBox.isHidden = false
        } else {
            updateBarBox.isHidden = true
        }
        
        switch currentMode {
        case .none:
            playbackBarBox.isHidden = true
            mainBarBox.isHidden = false
        case .desktop:
            playbackBarBox.isHidden = false
            mainBarBox.isHidden = true
        case .monitor:
            playbackBarBox.isHidden = false
            mainBarBox.isHidden = true
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let isDefault = SystemPrefs.getSaverSelectedStatus()
            
            DispatchQueue.main.async { [self] in
                notDefaultBox.isHidden = isDefault
            }
        }
        
        globalSpeedSlider.intValue = Int32(Preferences.globalSpeed)
        setActivationTimePopup()
        setSleepTimeLabel()
        
        validateSleepSettings()
    }
    
    public func updatePlaybackMode(mode: PlaybackMode) {
        currentMode = mode
        update()
    }
    
    public func shouldRefreshPlaybackMode() {
        switch currentMode {
        case .none:
            return
        case .desktop:
            for desktopLauncher in desktopLauncherInstances.values {
                desktopLauncher.toggleLauncher()
                desktopLauncher.toggleLauncher()
                desktopLauncher.changeSpeed(Preferences.globalSpeed)
            }
            //DesktopLauncher.instance.toggleLauncher()
            //
            //DesktopLauncher.instance.toggleLauncher()
            //DesktopLauncher.instance.changeSpeed(Preferences.globalSpeed)

        case .monitor:
            SaverLauncher.instance.stopScreensaver()
            SaverLauncher.instance.windowMode()
            SaverLauncher.instance.changeSpeed(Preferences.globalSpeed)
        }
    }

    // Main bar action
    @IBAction func startScreenSaverClick(_ sender: Any) {
        //_ = Helpers.shell(launchPath: "/usr/bin/open", arguments: ["-a","ScreenSaverEngine"])
        
        // Seriously, **this** is a private API...
        
        if let libHandle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY) {
            let sym = dlsym(libHandle, "SACScreenSaverStartNow")
            typealias myFunction = @convention(c) () -> Void
            let SACLockScreenImmediate = unsafeBitCast(sym, to: myFunction.self)
            SACLockScreenImmediate()
            dlclose(libHandle)
        }
    }
    
    @IBAction func startWallpaperClick(_ sender: Any) {
        if let button = sender as? NSButton {
            print(button.tag)
        } else {
            print("not button")
        }

        currentMode = .desktop
        for screen in NSScreen.screens {
            _ = toggleDesktopLauncher(for: screen.screenUuid)
            if let desktopLauncher = desktopLauncherInstances[screen.screenUuid] {
                desktopLauncher.changeSpeed(Preferences.globalSpeed)
            }
        }
        update()
        appDelegate?.closePopover(sender: nil)
    }
    
    @IBAction func wallpaperPickScreen(_ sender: NSButton) {
        let p = NSPoint(x: 0, y: sender.frame.height)
        appMenu.popUp(positioning: nil, at: p, in: sender)
    }
    
    @IBAction func startFullscreenClick(_ sender: Any) {
        currentMode = .monitor
        SaverLauncher.instance.setController(self)
        SaverLauncher.instance.windowMode()
        SaverLauncher.instance.changeSpeed(Preferences.globalSpeed)
        update()
        appDelegate?.closePopover(sender: nil)
    }
    
    @IBAction func openSaverSettings(_ sender: Any) {
        SaverLauncher.instance.setController(self)
        SaverLauncher.instance.openSettings()
        update()
        appDelegate?.closePopover(sender: nil)
    }

    // Secondary bar action (while playing)
    @IBAction func stopSaverClick(_ sender: Any) {
        if currentMode == .desktop {
            for desktopLauncher in desktopLauncherInstances.values {
                if desktopLauncher.isRunning {
                    desktopLauncher.toggleLauncher()
                }
            }
            Preferences.enabledWallpaperScreenUuids = [] // reset what's running in prefs
 
            // Clear the menu
            for item in appMenu.items {
                item.state = .off
            }
        } else {
            SaverLauncher.instance.stopScreensaver()
        }
        currentMode = .none
        update()
    }
    
    @IBAction func pauseSaverClick(_ sender: Any) {
        if currentMode == .desktop {
            for desktopLauncher in desktopLauncherInstances.values {
                desktopLauncher.togglePause()
            }
        } else {
            SaverLauncher.instance.togglePause()
        }
    }
    
    
    @IBAction func skipSaverClick(_ sender: Any) {
        if currentMode == .desktop {
            for desktopLauncher in desktopLauncherInstances.values {
                desktopLauncher.nextVideo()
            }
            //DesktopLauncher.instance.nextVideo()
        } else {
            SaverLauncher.instance.nextVideo()
        }
    }
    
    
    @IBAction func hideSaverClick(_ sender: Any) {
        // TODO : we'd need to find from which screen we clicked
        if currentMode == .desktop {
            for desktopLauncher in desktopLauncherInstances.values {
                desktopLauncher.skipAndHide()
            }
            //DesktopLauncher.instance.skipAndHide()
        } else {
            SaverLauncher.instance.skipAndHide()
        }
    }
    
    @IBAction func globalSpeedSliderChange(_ sender: NSSlider) {
        Preferences.globalSpeed = Int(sender.intValue)

        if currentMode == .desktop {
            for desktopLauncher in desktopLauncherInstances.values {
                desktopLauncher.changeSpeed(Int(sender.intValue))
            }
            //DesktopLauncher.instance.changeSpeed(Int(sender.intValue))
        } else {
            //debugLog("not here")
            SaverLauncher.instance.changeSpeed(Int(sender.intValue))
        }
    }
    

    
    // Update bar
    @IBAction func updateNowClick(_ sender: Any) {
        if UpdaterVersion.needsUpdating() {
            let workspace = NSWorkspace.shared
            let url = URL(string: "https://github.com/glouel/AerialCompanion/releases")!
            workspace.open(url)
            return
        }
        
        updateLabel.stringValue = "Hold on..."
        updateButton.isEnabled = false
        
        // Launch the update
        Update.instance.perform(self)
    }
    
    func toggleDesktopLauncher(for screenUuid: String) -> Bool {
        var isRunning = false
        
        if let desktopLauncher = desktopLauncherInstances[screenUuid] {
            desktopLauncher.toggleLauncher()
            desktopLauncher.changeSpeed(Preferences.globalSpeed)
            isRunning = desktopLauncher.isRunning
        } else if let screen = NSScreen.getScreenByUuid(screenUuid) {
            desktopLauncherInstances[screenUuid] = DesktopLauncher(screen: screen)
            desktopLauncherInstances[screenUuid]?.toggleLauncher()
            desktopLauncherInstances[screenUuid]?.changeSpeed(Preferences.globalSpeed)
            isRunning = desktopLauncherInstances[screenUuid]!.isRunning
        }
        
        // Mark what's running in prefs
        if isRunning {
            if !Preferences.enabledWallpaperScreenUuids.contains(screenUuid) {
                Preferences.enabledWallpaperScreenUuids.append(screenUuid)
            }
        } else {
            Preferences.enabledWallpaperScreenUuids = Preferences.enabledWallpaperScreenUuids.filter {$0 != screenUuid}
        }

        // Workaround to handle our menu modes
        if Preferences.enabledWallpaperScreenUuids.count > 0 {
            currentMode = .desktop
        } else {
            currentMode = .none
        }
        
        update()
        return isRunning    // do we need this ?
    }
    
    
    // Bottom bar action
    
    @IBAction func openInfoClick(_ sender: Any) {
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
        appDelegate?.closePopover(sender: nil)
    }
    
    @IBAction func openSettingsClick(_ sender: Any) {
        var topLevelObjects: NSArray? = NSArray()
        if !Bundle.main.loadNibNamed(NSNib.Name("SettingsWindowController"),
                            owner: settingsWindowController,
                            topLevelObjects: &topLevelObjects) {
            errorLog("Could not load nib for SettingsWindow, please report")
        }
        settingsWindowController.windowDidLoad()
        settingsWindowController.showWindow(self)
        settingsWindowController.window!.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        appDelegate?.closePopover(sender: nil)
    }
    
    @IBAction func openHelpClick(_ sender: Any) {
        let workspace = NSWorkspace.shared
        let url = URL(string: "https://aerialscreensaver.github.io/support.html")!
        workspace.open(url)
        appDelegate?.closePopover(sender: nil)
    }
    
    @IBAction func exitCompanionClick(_ sender: Any) {
        NSApplication.shared.terminate(self)
    }
    
}
