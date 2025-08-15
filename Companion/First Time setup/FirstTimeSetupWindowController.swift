//
//  FirstTimeSetupWindowController.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 16/08/2020.
//

import Cocoa

class FirstTimeSetupWindowController: NSWindowController, UpdateCallback {

    
    var welcomeViewItem: NSSplitViewItem?
    var releaseViewItem: NSSplitViewItem?
    var menuModeViewItem: NSSplitViewItem?
    var thanksViewItem: NSSplitViewItem?
    
    var nextViewItem: NSSplitViewItem?

    lazy var splitVC = NSSplitViewController()
    var nextVC: NextViewController = {
        return NextViewController(nibName: .init("NextViewController"), bundle: Bundle.main)
    }()

    var currentStep = 0

    override func windowDidLoad() {
        super.windowDidLoad()
        splitVC.splitView.isVertical = false

        let welcomeVC = WelcomeViewController(nibName: .init("WelcomeViewController"), bundle: Bundle.main)
        let releaseVC = ReleaseViewController(nibName: .init("ReleaseViewController"), bundle: Bundle.main)
        let menumodeVC = MenuModeViewController(nibName: .init("MenuModeViewController"), bundle: Bundle.main)
        let thanksVC = ThanksViewController(nibName: .init("ThanksViewController"), bundle: Bundle.main)

        nextVC.windowController = self

        welcomeViewItem = NSSplitViewItem(viewController: welcomeVC)
        releaseViewItem = NSSplitViewItem(viewController: releaseVC)
        menuModeViewItem = NSSplitViewItem(viewController: menumodeVC)
        thanksViewItem = NSSplitViewItem(viewController: thanksVC)

        nextViewItem = NSSplitViewItem(viewController: nextVC)

        splitVC.addSplitViewItem(welcomeViewItem!)
        splitVC.addSplitViewItem(nextViewItem!)
        window?.contentViewController = splitVC
    }
    
    func nextAction() {
        currentStep += 1
        redrawVC()
    }

    func previousAction() {
        currentStep -= 1
        redrawVC()
    }

    func redrawVC() {
        splitVC.removeChild(at: 1)
        splitVC.removeChild(at: 0)

        switch currentStep {
        case 0:
            splitVC.addSplitViewItem(welcomeViewItem!)
            splitVC.addSplitViewItem(nextViewItem!)
            nextVC.setNoPrev()
        case 1:
            splitVC.addSplitViewItem(releaseViewItem!)
            splitVC.addSplitViewItem(nextViewItem!)
            nextVC.setPrevNext()
        case 2:
            splitVC.addSplitViewItem(menuModeViewItem!)
            splitVC.addSplitViewItem(nextViewItem!)
            nextVC.setPrevNext()
        case 3:
            splitVC.addSplitViewItem(thanksViewItem!)
            splitVC.addSplitViewItem(nextViewItem!)
            nextVC.setClose()
        default:
            window?.close()
            Preferences.firstTimeSetup = true
            if !LocalVersion.isInstalled() {
                Update.instance.setCallback(self)
                Update.instance.perform(self)
            } else {
                LaunchAgent.update()
            }
        }
    }
    
    func updateProgress(string: String, done: Bool) {
        if done {
            if string == "OK" {
                /*// Open syspref
                let workspace = NSWorkspace.shared
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.desktopscreeneffect?ScreenSaverPref")!
                workspace.open(url)*/
                
                //NSWorkspace.shared.openFile("/System/Library/PreferencePanes/DesktopScreenEffectsPref.prefPane")
                
                // Launch agent
                LaunchAgent.update()
            }
        }
    }
    
    func updateMenuContent() {
        debugLog("donee")
    }
    
    func setIcon(mode: IconMode) {
        //
    }
}
