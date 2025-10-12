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

// MARK: - Update Status

enum UpdateStatus {
    case notInstalled
    case updateAvailable(version: String)
    case upToDate(version: String)

    var needsUpdate: Bool {
        switch self {
        case .notInstalled, .updateAvailable:
            return true
        case .upToDate:
            return false
        }
    }

    var message: String {
        switch self {
        case .notInstalled:
            return "Screensaver not installed"
        case .updateAvailable(let version):
            return "Version \(version) available"
        case .upToDate(let version):
            return "Version \(version) installed"
        }
    }

    /// Legacy tuple format for backward compatibility
    var asTuple: (String, Bool) {
        return (message, needsUpdate)
    }
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
    /// Returns (status message, needs update) - legacy tuple format
    func check() -> (String, Bool) {
        return checkStatus().asTuple
    }

    /// Check update status with structured result
    func checkStatus() -> UpdateStatus {
        CompanionLogging.debugLog("→ Checking screensaver version status...")

        // Check if screensaver is installed
        guard LocalVersion.isInstalled() else {
            CompanionLogging.infoLog("  Screensaver not installed")
            return .notInstalled
        }

        // Get version information
        let info = BundledVersion.getInfo()
        CompanionLogging.debugLog("  Installed: \(info.installed), Bundled: \(info.bundled)")

        // Determine status
        if info.needsUpdate {
            CompanionLogging.infoLog("  Update available: \(info.bundled)")
            return .updateAvailable(version: info.bundled)
        } else {
            CompanionLogging.debugLog("  Up to date: \(info.installed)")
            return .upToDate(version: info.installed)
        }
    }

    /// Check if bundled version needs to be installed
    func unattendedCheck() {
        CompanionLogging.infoLog("→ Checking bundled version...")

        guard BundledVersion.exists() else {
            CompanionLogging.errorLog("✗ No bundled screensaver found")
            return
        }

        if BundledVersion.isNewerThanInstalled() {
            CompanionLogging.infoLog("  Bundled version is newer, updating...")
            unattendedPerform()
        } else if !LocalVersion.isInstalled() {
            CompanionLogging.infoLog("  Screensaver not installed, installing from bundle...")
            unattendedPerform()
        } else {
            CompanionLogging.debugLog("✓ Screensaver up to date, no action needed")
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
        CompanionLogging.infoLog("→ Starting installation process...")

        if let cb = uiCallback {
            cb.setIcon(mode: .updating)
        }

        guard BundledVersion.exists() else {
            CompanionLogging.errorLog("✗ No bundled screensaver found in app Resources")
            report(string: "Error: No bundled screensaver", done: true)
            return
        }

        CompanionLogging.infoLog("  Bundled screensaver found at: \(BundledVersion.bundledSaverPath)")
        report(string: "Preparing installation...", done: false)

        // Verify signature of bundled screensaver
        CompanionLogging.infoLog("  Verifying code signature...")
        report(string: "Verifying signature...", done: false)

        let result = Helpers.shell(launchPath: "/usr/bin/codesign",
                                   arguments: ["-v", "-d", BundledVersion.bundledSaverPath])

        if !checkCodesign(result) {
            CompanionLogging.errorLog("✗ Bundled screensaver codesigning verification failed")
            report(string: "Codesigning verification failed", done: true)
            return
        }

        CompanionLogging.infoLog("✓ Code signature verified")

        // Install the screensaver
        if install(BundledVersion.bundledSaverPath) {
            CompanionLogging.infoLog("✓ Installation completed successfully")
            report(string: "OK", done: true)

            // Optionally enable screensaver via PaperSaver
            Task {
                do {
                    CompanionLogging.debugLog("  Enabling screensaver via PaperSaver...")
                    try await ScreensaverManager.shared.enableAerial()
                    CompanionLogging.infoLog("✓ Screensaver enabled via PaperSaver")
                } catch {
                    CompanionLogging.errorLog("✗ Failed to enable screensaver: \(error.localizedDescription)")
                }
            }
        } else {
            CompanionLogging.errorLog("✗ Installation failed")
            report(string: "Cannot install screensaver", done: true)
        }
    }

    // MARK: - Private Helpers

    /// Codesign verification result
    private struct CodesignVerification {
        let hasValidTeamId: Bool

        var isValid: Bool {
            return hasValidTeamId
        }

        var statusDescription: String {
            return hasValidTeamId ? "✓ Team ID verified" : "✗ Invalid Team ID"
        }

        static func verify(output: String?) -> CodesignVerification {
            guard let output = output else {
                return CodesignVerification(hasValidTeamId: false)
            }

            let lines = output.split(separator: "\n")

            var teamIdValid = false

            for line in lines {
                if line.starts(with: "TeamIdentifier=3L54M5L5KK") {
                    teamIdValid = true
                    break
                }
            }

            return CodesignVerification(hasValidTeamId: teamIdValid)
        }
    }

    /// Verify codesign output (checks Team ID only)
    private func checkCodesign(_ result: String?) -> Bool {
        let verification = CodesignVerification.verify(output: result)

        CompanionLogging.debugLog("    \(verification.statusDescription)")

        if !verification.isValid {
            CompanionLogging.errorLog("    ✗ Code signature verification failed: Team ID mismatch")
        }

        return verification.isValid
    }

    /// Install screensaver from source path to user library
    private func install(_ sourcePath: String) -> Bool {
        CompanionLogging.infoLog("  Installing screensaver...")

        // Remove old version if exists
        if FileManager.default.fileExists(atPath: LocalVersion.aerialPath) {
            CompanionLogging.debugLog("    Removing old version...")
            report(string: "Removing old version...", done: false)

            do {
                try FileManager.default.removeItem(at: URL(fileURLWithPath: LocalVersion.aerialPath))
                CompanionLogging.debugLog("    ✓ Old version removed")
            } catch {
                CompanionLogging.errorLog("    ✗ Cannot delete old screensaver: \(error.localizedDescription)")
                report(string: "Cannot delete old screensaver", done: true)
                return false
            }
        }

        // Create Screen Savers directory if needed
        if !FileManager.default.fileExists(atPath: LocalVersion.userLibraryScreenSaverPath) {
            CompanionLogging.debugLog("    Creating Screen Savers directory...")

            do {
                try FileManager.default.createDirectory(
                    atPath: LocalVersion.userLibraryScreenSaverPath,
                    withIntermediateDirectories: true,
                    attributes: nil)
                CompanionLogging.debugLog("    ✓ Directory created")
            } catch {
                CompanionLogging.errorLog("    ✗ Cannot create Screen Savers directory: \(error.localizedDescription)")
                report(string: "Cannot create Screen Savers directory", done: true)
                return false
            }
        }

        // Copy bundled screensaver to user library
        CompanionLogging.infoLog("    Copying screensaver to user library...")
        report(string: "Installing...", done: false)

        do {
            try FileManager.default.copyItem(atPath: sourcePath,
                                            toPath: LocalVersion.aerialPath)
            CompanionLogging.infoLog("    ✓ Screensaver copied successfully")
            return true
        } catch {
            CompanionLogging.errorLog("    ✗ Cannot copy screensaver: \(error.localizedDescription)")
            return false
        }
    }
}
