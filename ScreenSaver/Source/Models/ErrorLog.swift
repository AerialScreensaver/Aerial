//
//  ErrorLog.swift
//  Aerial
//
//  Created by Guillaume Louel on 17/10/2018.
//  Copyright © 2018 John Coates. All rights reserved.
//
//  Screensaver logging wrapper using shared AerialLogger infrastructure
//

import Cocoa
import os.log

// Configure shared logger for Screensaver
private let aerialLogger = AerialLogger(config: LoggerConfiguration(
    logFileName: "screensaver.txt",
    supportPath: { "/Users/Shared/Aerial/Logs" },
    addTimestamps: true,
    enableLogRolling: true,
    category: "Screensaver",
    debugModeCheck: { PrefsAdvanced.debugMode },
    errorPrefix: "🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨",
    alternateLogFileName: "desktop-mode.txt",
    useAlternateLogFile: { Aerial.helper.underCompanion }
))

// MARK: - Error Messages Array (for backward compatibility)

var errorMessages: [LogMessage] {
    return aerialLogger.errorMessages
}

// MARK: - Log Rolling

/// This will clear the existing log if > 1MB
/// Call this at startup
func rollLogIfNeeded() {
    aerialLogger.rollLogIfNeeded()
}

// MARK: - Core Logging Functions

/// Main logging function
func Log(level: ErrorLevel, message: String) {
    aerialLogger.log(level: level, message: message)
}

/// Log to Console.app only
func logToConsole(_ message: String) {
    if #available(OSX 10.12, *) {
        let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "Screensaver")
        os_log("Aerial: %{public}@", log: log, type: .default, message)
    } else {
        NSLog("Aerial: \(message)")
    }
}

/// Log to disk only (internal use - prefer Log() function)
func logToDisk(_ message: String) {
    // This is now handled internally by AerialLogger
    // Kept for backward compatibility but does nothing
}

// MARK: - Convenience Logging Functions

func debugLog(_ message: String) {
    aerialLogger.debug(message)
}

func infoLog(_ message: String) {
    aerialLogger.info(message)
}

func warnLog(_ message: String) {
    aerialLogger.warn(message)
}

func errorLog(_ message: String) {
    aerialLogger.error(message)
}

// MARK: - SharedLogger Conformance

/// Wrapper that conforms to SharedLogger protocol for use by shared code
enum ScreensaverLogging: SharedLogger {
    static func debug(_ message: String) {
        debugLog(message)
    }

    static func info(_ message: String) {
        infoLog(message)
    }

    static func warn(_ message: String) {
        warnLog(message)
    }

    static func error(_ message: String) {
        errorLog(message)
    }
}
