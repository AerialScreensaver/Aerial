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
    private let delayBeforeKill: TimeInterval = 5.0 // 5 seconds
    private var pendingCheckWorkItem: DispatchWorkItem?

    // Termination retry delays
    private let gracefulTerminationWait: TimeInterval = 2.0 // Wait 2s after SIGTERM
    private let forceTerminationWait: TimeInterval = 1.0    // Wait 1s after SIGKILL

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
        // Listen for screen unlock events
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleScreenUnlock(_:)),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
        CompanionLogging.debugLog("ScreensaverWatchdog: Listening for screen unlock events")
    }

    private func removeNotificationObserver() {
        DistributedNotificationCenter.default().removeObserver(
            self,
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
        CompanionLogging.debugLog("ScreensaverWatchdog: Removed screen unlock observer")
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

    /// Force kill a process using SIGKILL (kill -9) as last resort
    /// - Parameter pid: The process identifier to kill
    /// - Returns: true if signal was sent successfully
    private func forceKillProcess(pid: pid_t) -> Bool {
        let result = kill(pid, SIGKILL)
        return result == 0
    }

    /// Terminate a process with verification and escalation
    /// - Parameter process: The NSRunningApplication to terminate
    ///
    /// This method uses an escalating approach:
    /// 1. Try graceful termination (SIGTERM)
    /// 2. Wait and verify
    /// 3. If still running, try force termination (SIGKILL)
    /// 4. Wait and verify
    /// 5. If still running, try system kill -9
    /// 6. Final verification
    private func terminateProcess(_ process: NSRunningApplication) {
        let pid = process.processIdentifier

        CompanionLogging.debugLog("ScreensaverWatchdog: Starting termination of \(targetProcessName) (PID: \(pid))")

        // Step 1: Try graceful termination (SIGTERM)
        _ = process.terminate()
        CompanionLogging.debugLog("ScreensaverWatchdog: Sent SIGTERM to \(targetProcessName) (PID: \(pid)), waiting \(gracefulTerminationWait)s...")

        // Step 2: Wait and check if graceful termination worked
        DispatchQueue.main.asyncAfter(deadline: .now() + gracefulTerminationWait) { [weak self] in
            guard let self = self else { return }

            if !self.isProcessRunning(pid: pid) {
                CompanionLogging.debugLog("ScreensaverWatchdog: ✓ Process \(self.targetProcessName) (PID: \(pid)) terminated gracefully")
                return
            }

            // Step 3: Graceful termination failed, try force termination
            CompanionLogging.debugLog("ScreensaverWatchdog: Process still running, sending SIGKILL via forceTerminate()")
            _ = process.forceTerminate()

            // Step 4: Wait and check if force termination worked
            DispatchQueue.main.asyncAfter(deadline: .now() + self.forceTerminationWait) { [weak self] in
                guard let self = self else { return }

                if !self.isProcessRunning(pid: pid) {
                    CompanionLogging.debugLog("ScreensaverWatchdog: ✓ Process \(self.targetProcessName) (PID: \(pid)) force terminated")
                    return
                }

                // Step 5: Force termination failed, try system kill -9
                CompanionLogging.debugLog("ScreensaverWatchdog: Process still running, using kill -9 as last resort")
                if self.forceKillProcess(pid: pid) {
                    CompanionLogging.debugLog("ScreensaverWatchdog: Sent kill -9 to PID \(pid)")

                    // Step 6: Final verification
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.forceTerminationWait) { [weak self] in
                        guard let self = self else { return }

                        if !self.isProcessRunning(pid: pid) {
                            CompanionLogging.debugLog("ScreensaverWatchdog: ✓ Process \(self.targetProcessName) (PID: \(pid)) killed via kill -9")
                        } else {
                            CompanionLogging.errorLog("ScreensaverWatchdog: ✗ Failed to terminate \(self.targetProcessName) (PID: \(pid)) - process is still running after all attempts")
                        }
                    }
                } else {
                    CompanionLogging.errorLog("ScreensaverWatchdog: ✗ Failed to send kill -9 to PID \(pid)")
                }
            }
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
