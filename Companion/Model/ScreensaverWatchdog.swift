//
//  ScreensaverWatchdog.swift
//  AerialUpdater
//
//  Monitors system events and performs cleanup actions
//  Specifically: kills legacyScreenSaver process on screen unlock
//

import Cocoa
import OSLog

class ScreensaverWatchdog {

    private let targetProcessName = "legacyScreenSaver"
    private var delayBeforeKill: TimeInterval {
        return TimeInterval(Preferences.watchdogTimerDelay)
    }
    private var pendingCheckWorkItem: DispatchWorkItem?
    private var pendingCheckScheduledAt: Date?
    private var actionEventTimestamp: Date?  // Track when .action event occurs for log capture
    private let killVerificationWait: TimeInterval = 1.0 // Wait 1s after SIGKILL

    // MARK: - Initialization

    init() {
        CompanionLogging.debugLog("🐶 initialized")
        setupNotificationObserver()
    }

    deinit {
        pendingCheckWorkItem?.cancel()
        pendingCheckScheduledAt = nil
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

        // Listen for screensaver will start events (checks if legacy process running)
        center.addObserver(
            self,
            selector: #selector(handleScreensaverWillStart(_:)),
            name: NSNotification.Name("com.apple.screensaver.willstart"),
            object: nil
        )

        // Listen for screensaver start events (cancels kill timer)
        center.addObserver(
            self,
            selector: #selector(handleScreensaverStart(_:)),
            name: NSNotification.Name("com.apple.screensaver.didstart"),
            object: nil
        )

        // Listen for screensaver will stop events
        center.addObserver(
            self,
            selector: #selector(handleScreensaverWillStop(_:)),
            name: NSNotification.Name("com.apple.screensaver.willstop"),
            object: nil
        )

        // Listen for screensaver did stop events
        center.addObserver(
            self,
            selector: #selector(handleScreensaverDidStop(_:)),
            name: NSNotification.Name("com.apple.screensaver.didstop"),
            object: nil
        )

        // Listen for screensaver action events
        center.addObserver(
            self,
            selector: #selector(handleScreensaverAction(_:)),
            name: NSNotification.Name("com.apple.screensaver.action"),
            object: nil
        )

        CompanionLogging.debugLog("🐶 Listening for screen events")
    }

    private func removeNotificationObserver() {
        let center = DistributedNotificationCenter.default()

        center.removeObserver(self, name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        center.removeObserver(self, name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        center.removeObserver(self, name: NSNotification.Name("com.apple.screensaver.willstart"), object: nil)
        center.removeObserver(self, name: NSNotification.Name("com.apple.screensaver.didstart"), object: nil)
        center.removeObserver(self, name: NSNotification.Name("com.apple.screensaver.willstop"), object: nil)
        center.removeObserver(self, name: NSNotification.Name("com.apple.screensaver.didstop"), object: nil)
        center.removeObserver(self, name: NSNotification.Name("com.apple.screensaver.action"), object: nil)

        CompanionLogging.debugLog("🐶 Removed screen event observers")
    }

    @objc private func handleScreenUnlock(_ notification: Notification) {
        CompanionLogging.debugLog("🐶 com.apple.screenIsUnlocked, will check for \(targetProcessName) in \(delayBeforeKill) seconds")

        // Capture and log system errors since .action event
        captureSystemLogs()

        // Cancel any previously scheduled check
        pendingCheckWorkItem?.cancel()
        pendingCheckScheduledAt = nil

        // Create a new work item for the delayed check
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            CompanionLogging.debugLog("🐶 Delay complete, performing check now")
            self.pendingCheckWorkItem = nil     // Clear work item reference
            self.pendingCheckScheduledAt = nil  // Clear timestamp
            self.checkAndTerminateLegacyScreensaver()
        }

        // Store the work item and timestamp
        pendingCheckWorkItem = workItem
        pendingCheckScheduledAt = Date()

        // Schedule the check after the delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delayBeforeKill, execute: workItem)
    }

    @objc private func handleScreenLock(_ notification: Notification) {
        if let workItem = pendingCheckWorkItem {
            let elapsed = pendingCheckScheduledAt.map { String(format: "%.1fs", Date().timeIntervalSince($0)) } ?? "unknown"
            CompanionLogging.debugLog("🐶 com.apple.screenIsLocked, cancelling pending termination (scheduled \(elapsed) ago)")
            workItem.cancel()
            pendingCheckWorkItem = nil
            pendingCheckScheduledAt = nil
        } else {
            CompanionLogging.debugLog("🐶 com.apple.screenIsLocked, no pending termination")
        }
    }

    @objc private func handleScreensaverWillStart(_ notification: Notification) {
        if let process = findProcess(named: targetProcessName) {
            CompanionLogging.debugLog("🐶 com.apple.screensaver.willstart, \(targetProcessName) is running (PID: \(process.processIdentifier))")
        } else {
            CompanionLogging.debugLog("🐶 com.apple.screensaver.willstart, \(targetProcessName) is NOT running")
        }
    }

    @objc private func handleScreensaverStart(_ notification: Notification) {
        var logMessage = "🐶 com.apple.screensaver.didstart"

        // Handle pending work item
        if let workItem = pendingCheckWorkItem {
            let elapsed = pendingCheckScheduledAt.map { String(format: "%.1fs", Date().timeIntervalSince($0)) } ?? "unknown"
            logMessage += ", cancelling pending termination (scheduled \(elapsed) ago)"
            workItem.cancel()
            pendingCheckWorkItem = nil
            pendingCheckScheduledAt = nil
        } else {
            logMessage += ", no pending termination"
        }

        // Check if legacyScreenSaver is running
        let processes = findAllProcesses(named: targetProcessName)
        if !processes.isEmpty {
            let pids = processes.map { "\($0.processIdentifier)" }.joined(separator: ", ")
            logMessage += ", \(targetProcessName) running: \(processes.count) instance(s) [PID: \(pids)]"
        } else {
            logMessage += ", \(targetProcessName) is NOT running"
        }

        CompanionLogging.debugLog(logMessage)
    }

    @objc private func handleScreensaverWillStop(_ notification: Notification) {
        CompanionLogging.debugLog("🐶 com.apple.screensaver.willstop")
    }

    @objc private func handleScreensaverDidStop(_ notification: Notification) {
        CompanionLogging.debugLog("🐶 com.apple.screensaver.didstop")
    }

    @objc private func handleScreensaverAction(_ notification: Notification) {
        // Store timestamp for log capture
        actionEventTimestamp = Date()

        var logMessage = "🐶 com.apple.screensaver.action"

        if let object = notification.object {
            logMessage += ", object: \(object)"
        }

        if let userInfo = notification.userInfo, !userInfo.isEmpty {
            logMessage += ", userInfo: \(userInfo)"
        }

        // Check if legacyScreenSaver is running
        if let process = findProcess(named: targetProcessName) {
            logMessage += ", \(targetProcessName) is running (PID: \(process.processIdentifier))"
        } else {
            logMessage += ", \(targetProcessName) is NOT running"
        }

        CompanionLogging.debugLog(logMessage)
    }

    // MARK: - Process Management

    private func checkAndTerminateLegacyScreensaver() {
        // Check if watchdog is enabled in preferences
        guard Preferences.enableScreensaverWatchdog else {
            CompanionLogging.debugLog("🐶 Disabled in preferences, skipping check")
            return
        }

        let processes = findAllProcesses(named: targetProcessName)

        guard !processes.isEmpty else {
            CompanionLogging.debugLog("🐶 No \(targetProcessName) process found")
            return
        }

        let pids = processes.map { "\($0.processIdentifier)" }.joined(separator: ", ")
        CompanionLogging.debugLog("🐶 Found \(processes.count) \(targetProcessName) instance(s): [PID: \(pids)]")

        // Terminate all instances
        for process in processes {
            terminateProcess(process)
        }
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

    /// Find all running processes by name
    /// - Parameter name: The process name to search for
    /// - Returns: Array of all matching NSRunningApplications
    private func findAllProcesses(named name: String) -> [NSRunningApplication] {
        let runningApps = NSWorkspace.shared.runningApplications

        return runningApps.filter { app in
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

        CompanionLogging.debugLog("🐶 Terminating \(targetProcessName) (PID: \(pid)) with SIGKILL")

        // Send SIGKILL directly (kill -9)
        let result = kill(pid, SIGKILL)

        if result == 0 {
            CompanionLogging.debugLog("🐶 Sent SIGKILL to PID \(pid), verifying...")

            // Wait and verify termination
            DispatchQueue.main.asyncAfter(deadline: .now() + killVerificationWait) { [weak self] in
                guard let self = self else { return }

                if !self.isProcessRunning(pid: pid) {
                    CompanionLogging.debugLog("🐶 ✓ Process \(self.targetProcessName) (PID: \(pid)) terminated successfully")
                } else {
                    CompanionLogging.errorLog("🐶 ✗ Process \(self.targetProcessName) (PID: \(pid)) still running after SIGKILL")
                }
            }
        } else {
            CompanionLogging.errorLog("🐶 ✗ Failed to send SIGKILL to PID \(pid)")
        }
    }

    // MARK: - Manual Trigger (for testing)

    /// Manually trigger a check for the legacy screensaver process
    /// Useful for testing without waiting for screen unlock
    func manualCheck() {
        CompanionLogging.debugLog("🐶 Manual check triggered")
        checkAndTerminateLegacyScreensaver()
    }

    // MARK: - System Log Capture

    /// Capture system logs between .action event and screen unlock
    private func captureSystemLogs() {
        guard let startTime = actionEventTimestamp else {
            return  // No .action event timestamp recorded
        }

        // Clear the timestamp after use
        defer { actionEventTimestamp = nil }

        // Only available on macOS 10.15+
        if #available(macOS 10.15, *) {
            do {
                let logStore = try OSLogStore(scope: .system)
                let position = logStore.position(date: startTime)

                // Create predicate to filter for errors/faults from screensaver-related processes
                let predicate = NSPredicate(format: """
                    (processImagePath CONTAINS 'screensaver' OR processImagePath CONTAINS 'ScreenSaver' OR \
                     process == 'legacyScreenSaver' OR subsystem CONTAINS 'screensaver') AND \
                    (messageType == 'error' OR messageType == 'fault')
                    """)

                let entries = try logStore.getEntries(at: position, matching: predicate)

                var capturedLogs: [String] = []
                for entry in entries {
                    if let logEntry = entry as? OSLogEntryLog {
                        // Only capture logs up to now
                        if logEntry.date > Date() { break }

                        let timestamp = logEntry.date.formatted()
                        let process = logEntry.process
                        let message = logEntry.composedMessage
                        let level = logEntry.level.rawValue

                        capturedLogs.append("[\(timestamp)] [\(process)] [\(level)] \(message)")
                    }
                }

                if !capturedLogs.isEmpty {
                    CompanionLogging.debugLog("🐶 Captured \(capturedLogs.count) system error(s) between .action and unlock:")
                    for log in capturedLogs {
                        CompanionLogging.debugLog("🐶 SYS: \(log)")
                    }
                } else {
                    CompanionLogging.debugLog("🐶 No system errors captured between .action and unlock")
                }

            } catch {
                CompanionLogging.errorLog("🐶 Failed to capture system logs: \(error)")
            }
        }
    }
}
