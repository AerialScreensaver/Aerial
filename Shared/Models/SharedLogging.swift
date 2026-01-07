//
//  SharedLogging.swift
//  Aerial
//
//  Shared logging abstraction for code used by both Companion and Screensaver
//  Each target configures its own logger implementation at startup
//

import Foundation

/// Protocol that both Companion and Screensaver loggers implement
protocol SharedLogger {
    static func debug(_ message: String)
    static func info(_ message: String)
    static func warn(_ message: String)
    static func error(_ message: String)
}

/// Lightweight logging facade for truly shared code (JSONPreferencesStore, etc.)
/// Both targets configure their own logger implementation at startup
enum SharedLogging {
    private static var logger: SharedLogger.Type?

    /// Configure the logger implementation (called once at app startup by each target)
    /// - Parameter logger: The logger type to use (CompanionLogging or ScreensaverLogging)
    static func configure(logger: SharedLogger.Type) {
        self.logger = logger
    }

    /// Log a debug message
    static func debug(_ message: String) {
        logger?.debug(message) ?? print("[DEBUG] \(message)")
    }

    /// Log an info message
    static func info(_ message: String) {
        logger?.info(message) ?? print("[INFO] \(message)")
    }

    /// Log a warning message
    static func warn(_ message: String) {
        logger?.warn(message) ?? print("[WARN] \(message)")
    }

    /// Log an error message
    static func error(_ message: String) {
        logger?.error(message) ?? print("[ERROR] \(message)")
    }
}
