//
//  AerialLogger.swift
//  Aerial
//
//  Shared logging infrastructure for both Companion app and Screensaver
//

import Cocoa
import os.log

// MARK: - Core Types

enum ErrorLevel: Int {
    case info, debug, warning, error
}

final class LogMessage {
    let date: Date
    let level: ErrorLevel
    let message: String
    var actionName: String?
    var actionBlock: BlockOperation?

    init(level: ErrorLevel, message: String) {
        self.level = level
        self.message = message
        self.date = Date()
    }
}

typealias LoggerCallback = (ErrorLevel) -> Void

// MARK: - Logger Callback System

final class Logger {
    static let sharedInstance = Logger()

    var callbacks = [LoggerCallback]()

    func addCallback(_ callback: @escaping LoggerCallback) {
        callbacks.append(callback)
    }

    func callBack(level: ErrorLevel) {
        DispatchQueue.main.async {
            for callback in self.callbacks {
                callback(level)
            }
        }
    }
}

// MARK: - Logger Configuration

struct LoggerConfiguration {
    /// The log file name (e.g., "Log.txt", "AerialLog.txt")
    let logFileName: String

    /// Closure that returns the support path where logs should be stored
    let supportPath: () -> String

    /// Whether to add timestamps to log entries
    let addTimestamps: Bool

    /// Whether to roll (clear) logs when they exceed 1MB
    let enableLogRolling: Bool

    /// Category name for OSLog (e.g., "Companion", "Screensaver")
    let category: String

    /// Optional: Closure to check if debug mode is enabled
    /// If nil, always logs debug messages
    let debugModeCheck: (() -> Bool)?

    /// Optional: Prefix to add to error messages (e.g., "🚨")
    let errorPrefix: String?

    /// Whether to use separate log file naming (for underCompanion detection)
    let alternateLogFileName: String?

    /// Closure to determine which log file to use (if alternateLogFileName is set)
    let useAlternateLogFile: (() -> Bool)?

    init(
        logFileName: String,
        supportPath: @escaping () -> String,
        addTimestamps: Bool = true,
        enableLogRolling: Bool = true,
        category: String,
        debugModeCheck: (() -> Bool)? = nil,
        errorPrefix: String? = nil,
        alternateLogFileName: String? = nil,
        useAlternateLogFile: (() -> Bool)? = nil
    ) {
        self.logFileName = logFileName
        self.supportPath = supportPath
        self.addTimestamps = addTimestamps
        self.enableLogRolling = enableLogRolling
        self.category = category
        self.debugModeCheck = debugModeCheck
        self.errorPrefix = errorPrefix
        self.alternateLogFileName = alternateLogFileName
        self.useAlternateLogFile = useAlternateLogFile
    }
}

// MARK: - Aerial Logger Core

class AerialLogger {
    let config: LoggerConfiguration
    private(set) var errorMessages: [LogMessage] = []

    init(config: LoggerConfiguration) {
        self.config = config
    }

    // MARK: - Log Rolling

    /// Clear the existing log if it exceeds 1MB
    func rollLogIfNeeded() {
        guard config.enableLogRolling else { return }

        let cacheFileUrl = getLogFileURL()

        if FileManager.default.fileExists(atPath: cacheFileUrl.path) {
            do {
                let resourceValues = try cacheFileUrl.resourceValues(forKeys: [.fileSizeKey])
                let fileSize = Int64(resourceValues.fileSize!)

                if fileSize > 1_000_000 {
                    try FileManager.default.removeItem(at: cacheFileUrl)
                }
            } catch {
                logToConsole("Error rolling log: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Core Logging

    func log(level: ErrorLevel, message: String) {
        #if DEBUG
        print("\(message)\n")
        #endif

        // Store message
        errorMessages.append(LogMessage(level: level, message: message))

        // Apply error prefix if configured
        let finalMessage: String
        if level == .error, let prefix = config.errorPrefix {
            finalMessage = prefix + " " + message
        } else {
            finalMessage = message
        }

        // Report errors to Console.app
        if level == .error {
            if #available(OSX 10.12, *) {
                let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.glouel.aerial", category: config.category)
                os_log("AerialError: %{public}@", log: log, type: .error, finalMessage)
            } else {
                NSLog("AerialError: \(finalMessage)")
            }
        }

        // Fire callbacks for warnings, errors, and debug (if debug mode is on)
        let shouldCallback: Bool
        if let debugCheck = config.debugModeCheck {
            shouldCallback = level == .warning || level == .error || (level == .debug && debugCheck())
        } else {
            shouldCallback = level == .warning || level == .error
        }

        if shouldCallback {
            Logger.sharedInstance.callBack(level: level)
        }

        // Log to console and disk based on debug mode
        if let debugCheck = config.debugModeCheck {
            if debugCheck() {
                logToConsole(finalMessage)
                logToDisk(finalMessage)
            }
        } else {
            // Always log if no debug check is configured
            logToDisk(finalMessage)
        }
    }

    // MARK: - Helper Methods

    private func getLogFileURL() -> URL {
        let cacheDirectory = config.supportPath()
        var cacheFileUrl = URL(fileURLWithPath: cacheDirectory)

        // Determine which log file to use
        if let alternateFileName = config.alternateLogFileName,
           let shouldUseAlternate = config.useAlternateLogFile,
           shouldUseAlternate() {
            cacheFileUrl.appendPathComponent(alternateFileName)
        } else {
            cacheFileUrl.appendPathComponent(config.logFileName)
        }

        return cacheFileUrl
    }

    private func logToConsole(_ message: String) {
        if #available(OSX 10.12, *) {
            let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.glouel.aerial", category: config.category)
            os_log("Aerial: %{public}@", log: log, type: .default, message)
        } else {
            NSLog("Aerial: \(message)")
        }
    }

    private func logToDisk(_ message: String) {
        DispatchQueue.main.async {
            // Prepare message with optional timestamp
            let string: String
            if self.config.addTimestamps {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
                string = dateFormatter.string(from: Date()) + " : " + message + "\n"
            } else {
                string = message + "\n"
            }

            let cacheFileUrl = self.getLogFileURL()
            let data = string.data(using: String.Encoding.utf8, allowLossyConversion: false)!

            if FileManager.default.fileExists(atPath: cacheFileUrl.path) {
                // Append to log
                do {
                    let fileHandle = try FileHandle(forWritingTo: cacheFileUrl)
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                } catch {
                    NSLog("AerialError: Can't open handle for \(self.config.logFileName) - \(error.localizedDescription)")
                }
            } else {
                // Create new log (ensure directory exists first)
                do {
                    let parentDirectory = cacheFileUrl.deletingLastPathComponent()

                    // Create parent directory if it doesn't exist
                    if !FileManager.default.fileExists(atPath: parentDirectory.path) {
                        try FileManager.default.createDirectory(
                            at: parentDirectory,
                            withIntermediateDirectories: true,
                            attributes: nil
                        )
                    }

                    // Now write the log file
                    try data.write(to: cacheFileUrl, options: .atomic)
                } catch {
                    NSLog("AerialError: Can't write to file \(self.config.logFileName) - \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Public Logging Methods

    func debug(_ message: String) {
        if let debugCheck = config.debugModeCheck {
            if debugCheck() {
                log(level: .debug, message: message)
            }
        } else {
            // Always log debug if no check is configured
            log(level: .debug, message: message)
        }
    }

    func info(_ message: String) {
        log(level: .info, message: message)
    }

    func warn(_ message: String) {
        log(level: .warning, message: message)
    }

    func error(_ message: String) {
        log(level: .error, message: message)
    }
}
