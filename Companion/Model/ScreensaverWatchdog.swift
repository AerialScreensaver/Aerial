//
//  ScreensaverWatchdog.swift
//  AerialUpdater
//
//  Monitors system events and performs cleanup actions
//  Specifically: kills legacyScreenSaver process on screen unlock
//

import Cocoa

class ScreensaverWatchdog {

    private let targetProcessName = "legacyScreenSaver"
    private var delayBeforeKill: TimeInterval {
        return TimeInterval(Preferences.watchdogTimerDelay)
    }
    private var pendingCheckWorkItem: DispatchWorkItem?
    private let killVerificationWait: TimeInterval = 1.0 // Wait 1s after SIGKILL

    // MARK: - Initialization

    init() {
        CompanionLogging.debugLog("ScreensaverWatchdog initialized")
        setupNotificationObserver()
    }

    deinit {
        pendingCheckWorkItem?.cancel()
        removeNotificationObserver()
    }

    // MARK: - Notification Handling

    private func setupNotificationObserver() {
        let center = DistributedNotificationCenter.default()

        // Listen for screen unlock events (triggers kill timer)
        center.addObserver(
            self,
            selector: #selector(handleScreenUnlock(_:)),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )

        // Listen for screen lock events (cancels kill timer)
        center.addObserver(
            self,
            selector: #selector(handleScreenLock(_:)),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )

        // Listen for screensaver start events (cancels kill timer)
        center.addObserver(
            self,
            selector: #selector(handleScreensaverStart(_:)),
            name: NSNotification.Name("com.apple.screensaver.didstart"),
            object: nil
        )

        CompanionLogging.debugLog("ScreensaverWatchdog: Listening for screen events")
    }

    private func removeNotificationObserver() {
        let center = DistributedNotificationCenter.default()

        center.removeObserver(self, name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        center.removeObserver(self, name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        center.removeObserver(self, name: NSNotification.Name("com.apple.screensaver.didstart"), object: nil)

        CompanionLogging.debugLog("ScreensaverWatchdog: Removed screen event observers")
    }

    @objc private func handleScreenUnlock(_ notification: Notification) {
        CompanionLogging.debugLog("ScreensaverWatchdog: Screen unlocked, will check for \(targetProcessName) in \(delayBeforeKill) seconds")

        // Cancel any previously scheduled check
        pendingCheckWorkItem?.cancel()

        // Create a new work item for the delayed check
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            CompanionLogging.debugLog("ScreensaverWatchdog: Delay complete, performing check now")
            self.checkAndTerminateLegacyScreensaver()
        }

        // Store the work item so we can cancel it if needed
        pendingCheckWorkItem = workItem

        // Schedule the check after the delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delayBeforeKill, execute: workItem)
    }

    @objc private func handleScreenLock(_ notification: Notification) {
        CompanionLogging.debugLog("ScreensaverWatchdog: Screen locked, cancelling pending termination")
        pendingCheckWorkItem?.cancel()
        pendingCheckWorkItem = nil
    }

    @objc private func handleScreensaverStart(_ notification: Notification) {
        CompanionLogging.debugLog("ScreensaverWatchdog: Screensaver started, cancelling pending termination")
        pendingCheckWorkItem?.cancel()
        pendingCheckWorkItem = nil
    }

    // MARK: - Process Management

    private func checkAndTerminateLegacyScreensaver() {
        // Check if watchdog is enabled in preferences
        guard Preferences.enableScreensaverWatchdog else {
            CompanionLogging.debugLog("ScreensaverWatchdog: Disabled in preferences, skipping check")
            return
        }

        guard let process = findProcess(named: targetProcessName) else {
            CompanionLogging.debugLog("ScreensaverWatchdog: No \(targetProcessName) process found")
            return
        }

        CompanionLogging.debugLog("ScreensaverWatchdog: Found \(targetProcessName) (PID: \(process.processIdentifier))")
        terminateProcess(process)
    }

    /// Find a running process by name
    /// - Parameter name: The process name to search for
    /// - Returns: NSRunningApplication if found, nil otherwise
    private func findProcess(named name: String) -> NSRunningApplication? {
        let runningApps = NSWorkspace.shared.runningApplications

        return runningApps.first { app in
            // Check both the process name and bundle identifier
            if let processName = app.localizedName, processName == name {
                return true
            }
            if let executableURL = app.executableURL {
                let executableName = executableURL.lastPathComponent
                if executableName == name {
                    return true
                }
            }
            return false
        }
    }

    /// Check if a process with given PID is still running
    /// - Parameter pid: The process identifier to check
    /// - Returns: true if process exists, false otherwise
    private func isProcessRunning(pid: pid_t) -> Bool {
        // Use kill with signal 0 to check if process exists without actually killing it
        // Returns 0 if process exists, -1 if it doesn't
        return kill(pid, 0) == 0
    }

    /// Terminate a process using SIGKILL
    /// - Parameter process: The NSRunningApplication to terminate
    private func terminateProcess(_ process: NSRunningApplication) {
        let pid = process.processIdentifier

        CompanionLogging.debugLog("ScreensaverWatchdog: Terminating \(targetProcessName) (PID: \(pid)) with SIGKILL")

        // Send SIGKILL directly (kill -9)
        let result = kill(pid, SIGKILL)

        if result == 0 {
            CompanionLogging.debugLog("ScreensaverWatchdog: Sent SIGKILL to PID \(pid), verifying...")

            // Wait and verify termination
            DispatchQueue.main.asyncAfter(deadline: .now() + killVerificationWait) { [weak self] in
                guard let self = self else { return }

                if !self.isProcessRunning(pid: pid) {
                    CompanionLogging.debugLog("ScreensaverWatchdog: ✓ Process \(self.targetProcessName) (PID: \(pid)) terminated successfully")
                } else {
                    CompanionLogging.errorLog("ScreensaverWatchdog: ✗ Process \(self.targetProcessName) (PID: \(pid)) still running after SIGKILL")
                }
            }
        } else {
            CompanionLogging.errorLog("ScreensaverWatchdog: ✗ Failed to send SIGKILL to PID \(pid)")
        }
    }

    // MARK: - Manual Trigger (for testing)

    /// Manually trigger a check for the legacy screensaver process
    /// Useful for testing without waiting for screen unlock
    func manualCheck() {
        CompanionLogging.debugLog("ScreensaverWatchdog: Manual check triggered")
        checkAndTerminateLegacyScreensaver()
    }
}
