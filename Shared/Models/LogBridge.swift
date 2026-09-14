//
//  LogBridge.swift
//  Aerial
//
//  Single logging bridge for all targets (Companion, Extension, ScreenSaver).
//  Each target calls LogBridge.configure() at startup with its own AerialLogger.
//

import Foundation
import os.log

enum LogBridge {
    private static var logger: AerialLogger?
    private static var rollTimer: Timer?

    /// Configure the logger for the current target (call once at startup)
    static func configure(_ logger: AerialLogger) {
        self.logger = logger
        logger.rollLogIfNeeded()

        // Long-running processes (Companion menu-bar app) need a periodic
        // re-check — the startup-only roll lets the file grow forever for
        // users who never quit. 30 min is plenty given typical log rates.
        rollTimer?.invalidate()
        rollTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak logger] _ in
            logger?.rollLogIfNeeded()
        }
    }

    /// Returns the configured logger, or auto-creates a fallback
    static var shared: AerialLogger {
        if let logger { return logger }
        let fallback = AerialLogger(config: LoggerConfiguration(
            logFileName: "aerial.txt",
            supportPath: { "/Users/Shared/Aerial/Logs" },
            category: "Aerial"
        ))
        self.logger = fallback
        return fallback
    }

}

// MARK: - Global Convenience Functions

func debugLog(_ message: String) { LogBridge.shared.debug(message) }
func errorLog(_ message: String) { LogBridge.shared.error(message) }
func warnLog(_ message: String)  { LogBridge.shared.warn(message) }
func infoLog(_ message: String)  { LogBridge.shared.info(message) }

/// Log to Console.app only (OSLog)
func logToConsole(_ message: String) {
    let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.glouel.aerial",
        category: LogBridge.shared.config.category
    )
    os_log("Aerial: %{public}@", log: log, type: .default, message)
}
