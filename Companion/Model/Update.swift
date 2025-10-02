//
//  Update.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 25/07/2020.
//  Refactored for bundled installation on 02/10/2024
//

import Cocoa

protocol UpdateCallback {
    func updateProgress(string: String, done: Bool)
    func updateMenuContent()
    func setIcon(mode: IconMode)
}

/// Manages screensaver installation and updates from bundled resources
class Update {
    static let instance: Update = Update()

    var uiCallback: UpdateCallback?
    var shouldReport = false
    var commandLine = false

    func setCallback(_ cb: UpdateCallback) {
        uiCallback = cb
    }

    // MARK: - Version Checking

    /// Check if an update is needed
    /// Returns (status message, needs update)
    func check() -> (String, Bool) {
        if !LocalVersion.isInstalled() {
            return ("Screensaver not installed!", true)
        }

        let info = BundledVersion.getInfo()

        CompanionLogging.debugLog("Versions: installed \(info.installed), bundled \(info.bundled)")

        if info.needsUpdate {
            return ("\(info.bundled) is available", true)
        } else {
            return ("\(info.installed) is installed", false)
        }
    }

    /// Check if bundled version needs to be installed
    func unattendedCheck() {
        CompanionLogging.debugLog("Checking bundled version...")

        if !BundledVersion.exists() {
            CompanionLogging.errorLog("No bundled screensaver found!")
            return
        }

        if BundledVersion.isNewerThanInstalled() {
            CompanionLogging.debugLog("Bundled version is newer, updating...")
            unattendedPerform()
        } else if !LocalVersion.isInstalled() {
            CompanionLogging.debugLog("Screensaver not installed, installing from bundle...")
            unattendedPerform()
        }
    }

    // MARK: - Installation

    func unattendedPerform() {
        shouldReport = false
        doPerform()
    }

    func perform(_ cb: UpdateCallback) {
        uiCallback = cb
        shouldReport = true
        doPerform()
    }

    func report(string: String, done: Bool) {
        CompanionLogging.debugLog("report \(done): \(string)")

        if shouldReport {
            if let cb = uiCallback {
                cb.updateProgress(string: string, done: done)
            }
        }

        if done {
            if let cb = uiCallback {
                cb.setIcon(mode: .normal)
                cb.updateMenuContent()
            }

            if commandLine {
                // Quit after install in command line mode
                DispatchQueue.main.async {
                    CompanionLogging.debugLog("Update process done, quitting in 20sec.")
                    RunLoop.main.run(until: Date() + 0x14)
                    NSApplication.shared.terminate(self)
                }
            }
        }
    }

    /// Perform installation from bundled screensaver
    func doPerform() {
        if let cb = uiCallback {
            cb.setIcon(mode: .updating)
        }

        guard BundledVersion.exists() else {
            CompanionLogging.errorLog("No bundled screensaver found in app Resources")
            report(string: "Error: No bundled screensaver", done: true)
            return
        }

        CompanionLogging.debugLog("Installing from bundled screensaver")
        report(string: "Preparing installation...", done: false)

        // Verify signature of bundled screensaver
        report(string: "Verifying signature...", done: false)

        let result = Helpers.shell(launchPath: "/usr/bin/codesign",
                                   arguments: ["-v", "-d", BundledVersion.bundledSaverPath])

        if !checkCodesign(result) {
            CompanionLogging.errorLog("Bundled screensaver codesigning verification failed")
            report(string: "Codesigning verification failed", done: true)
            return
        }

        CompanionLogging.debugLog("Signature verified")

        // Install the screensaver
        if install(BundledVersion.bundledSaverPath) {
            CompanionLogging.debugLog("Installed successfully!")
            report(string: "OK", done: true)

            // Optionally enable screensaver via PaperSaver
            Task {
                do {
                    try await ScreensaverManager.shared.enableAerial()
                    CompanionLogging.debugLog("Screensaver enabled via PaperSaver")
                } catch {
                    CompanionLogging.errorLog("Failed to enable screensaver: \(error.localizedDescription)")
                }
            }
        } else {
            CompanionLogging.errorLog("Cannot install screensaver")
            report(string: "Cannot install screensaver", done: true)
        }
    }

    // MARK: - Private Helpers

    /// Verify codesign output
    private func checkCodesign(_ result: String?) -> Bool {
        guard let presult = result else {
            return false
        }

        let lines = presult.split(separator: "\n")

        var bundleVer = false
        var devIDVer = false

        for line in lines {
            if line.starts(with: "Identifier=com.JohnCoates.Aerial") {
                bundleVer = true
            }
            if line.starts(with: "TeamIdentifier=3L54M5L5KK") {
                devIDVer = true
            }
        }

        return bundleVer && devIDVer
    }

    /// Install screensaver from source path to user library
    private func install(_ sourcePath: String) -> Bool {
        // Remove old version if exists
        if FileManager.default.fileExists(atPath: LocalVersion.aerialPath) {
            CompanionLogging.debugLog("Removing old version...")
            report(string: "Removing old version...", done: false)

            do {
                try FileManager.default.removeItem(at: URL(fileURLWithPath: LocalVersion.aerialPath))
            } catch {
                CompanionLogging.errorLog("Cannot delete old screensaver: \(error.localizedDescription)")
                report(string: "Cannot delete old screensaver", done: true)
                return false
            }
        }

        // Create Screen Savers directory if needed
        if !FileManager.default.fileExists(atPath: LocalVersion.userLibraryScreenSaverPath) {
            CompanionLogging.debugLog("Creating Screen Savers directory in user library")

            do {
                try FileManager.default.createDirectory(
                    atPath: LocalVersion.userLibraryScreenSaverPath,
                    withIntermediateDirectories: true,
                    attributes: nil)
            } catch {
                CompanionLogging.errorLog("Cannot create Screen Savers directory: \(error.localizedDescription)")
                report(string: "Cannot create Screen Savers directory", done: true)
                return false
            }
        }

        // Copy bundled screensaver to user library
        CompanionLogging.debugLog("Installing...")
        report(string: "Installing...", done: false)

        do {
            try FileManager.default.copyItem(atPath: sourcePath,
                                            toPath: LocalVersion.aerialPath)
            CompanionLogging.debugLog("Installed!")
            return true
        } catch {
            CompanionLogging.errorLog("Cannot copy screensaver: \(error.localizedDescription)")
            return false
        }
    }
}
