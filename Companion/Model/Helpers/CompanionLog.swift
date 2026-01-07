//
//  CompanionLog.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 25/07/2020.
//
//  Companion app logging wrapper using shared AerialLogger infrastructure
//

import Foundation
import Cocoa
import os.log

// Configure shared logger for Companion app
private let companionLogger = AerialLogger(config: LoggerConfiguration(
    logFileName: "app.txt",
    supportPath: { UnifiedPaths.logsPath() },
    addTimestamps: true,
    enableLogRolling: true,
    category: "Companion",
    debugModeCheck: nil,  // Always log debug in Companion
    errorPrefix: nil
))

enum CompanionLogging {
    /// Call this at app startup to roll logs if needed
    static func initialize() {
        companionLogger.rollLogIfNeeded()
    }

    /// Main logging function
    static func log(level: ErrorLevel, message: String) {
        companionLogger.log(level: level, message: message)
    }

    /// Log a debug message
    static func debugLog(_ message: String) {
        companionLogger.debug(message)
    }

    /// Log an info message
    static func infoLog(_ message: String) {
        companionLogger.info(message)
    }

    /// Log a warning message
    static func warnLog(_ message: String) {
        companionLogger.warn(message)
    }

    /// Log an error message
    static func errorLog(_ message: String) {
        companionLogger.error(message)
    }

    /// Access to error messages (for compatibility)
    static var errorMessages: [LogMessage] {
        return companionLogger.errorMessages
    }

    /// Add a callback for log level changes (for UI updates)
    static func addCallback(_ callback: @escaping LoggerCallback) {
        Logger.sharedInstance.addCallback(callback)
    }
}

// MARK: - SharedLogger Conformance

extension CompanionLogging: SharedLogger {
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
