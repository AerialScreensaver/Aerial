//
//  UpdateCheckWindowController.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 03/08/2020.
//

import Cocoa
enum ProgressStatus {
    case none, working, done, warning
}

class UpdateCheckWindowController:
    NSWindowController, UpdateCallback {

    @IBOutlet var largeGoodTrick: NSProgressIndicator!
    
    @IBOutlet var progressImageView: NSImageView!
    @IBOutlet var progressLabel: NSTextField!
    
    @IBOutlet var actionButton: NSButton!
    
    var menuCallback : UpdateCallback?
    
    override func windowDidLoad() {
        super.windowDidLoad()

        setProgress(to: .none)
        progressLabel.stringValue = "Hold on..."
        actionButton.isHidden = true
        actionButton.isHighlighted = true   // Color our button
    }

    func setCallback(_ cb: UpdateCallback) {
        menuCallback = cb
    }
    
    func setProgress(to: ProgressStatus) {
        switch to {
        case .none:
            progressImageView.isHidden = true
            largeGoodTrick.isHidden = true
            largeGoodTrick.stopAnimation(self)
        case .working:
            largeGoodTrick.isHidden = false
            largeGoodTrick.startAnimation(self)
            progressImageView.isHidden = true
        case .done:
            largeGoodTrick.isHidden = true
            largeGoodTrick.stopAnimation(self)
            progressImageView.isHidden = false
            progressImageView.image = NSImage(named: "checkmark.circle")
        case .warning:
            largeGoodTrick.isHidden = true
            largeGoodTrick.stopAnimation(self)
            progressImageView.isHidden = false
            progressImageView.image = NSImage(named: "exclamationmark.triangle")
        }
    }
    
    
    func startCheck() {
        setProgress(to: .working)
        progressLabel.stringValue = "Looking for new version..."

        // Force a cache update
        CachedManifest.instance.updateNow()

        // Make sure we don't need to update, or redirect you there
        if UpdaterVersion.needsUpdating() {
            setProgress(to: .warning)
            progressLabel.stringValue = "A new version of Aerial Companion is required"
            actionButton.title = "Show me"
            actionButton.isHidden = false
        } else {
            let (statusString, shouldInstall) = Update.instance.check()

            if shouldInstall {
                setProgress(to: .warning)
                progressLabel.stringValue = "New version : \(statusString)"
                actionButton.title = "Install"
                actionButton.isHidden = false

            } else {
                setProgress(to: .done)
                progressLabel.stringValue = "No new version available"
                actionButton.title = "Close"
                actionButton.isHidden = false
            }
        }

        // Then the Menu UI
        menuCallback!.updateMenuContent()
    }
    
    @IBAction func actionButtonClick(_ sender: NSButton) {
        if UpdaterVersion.needsUpdating() {
            let workspace = NSWorkspace.shared
            let url = URL(string: "https://github.com/glouel/AerialUpdater/releases")!
            workspace.open(url)
            return
        } else if sender.title == "Close" || sender.title == "Show me" {
            close()
        }
        
        let (_, shouldInstall) = Update.instance.check()

        if shouldInstall {
            actionButton.title = "Close"
            actionButton.isHidden = true
            setProgress(to: .working)
            Update.instance.perform(self)
        } else {
            close()
        }
    }
    
    
    func updateProgress(string: String, done: Bool) {
        DispatchQueue.main.async {
            self.progressLabel.stringValue = string
            self.actionButton.title = "Close"
            if done {
                self.largeGoodTrick.stopAnimation(self)
                if string == "OK" {
                    self.setProgress(to: .done)
                    self.progressLabel.stringValue = "Update successfully completed"
                } else {
                    self.setProgress(to: .warning)
                    Helpers.showErrorAlert(question: "Installation error", text: "\(string)\n\nPlease report.\n\nPlease report.")
                }
                self.actionButton.isHidden = false

            } else {
                self.actionButton.isHidden = true
            }
        }
    }
    
    func updateMenuContent() {
        if let callback = menuCallback {
            callback.updateMenuContent()
        }
    }
    
    func setIcon(mode: IconMode) {
        if let callback = menuCallback {
            callback.setIcon(mode: mode)
        }
     }
}
