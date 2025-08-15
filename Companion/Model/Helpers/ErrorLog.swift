//
//  ErrorLog.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 25/07/2020.
//

import Foundation
import Cocoa
import os.log

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


func Log(level: ErrorLevel, message: String) {
    #if DEBUG
    print("\(message)\n")
    #endif

    // We report errors to Console.app
    if level == .error {
        if #available(OSX 10.12, *) {
            // This is faster when available
            let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "Screensaver")
            os_log("AerialError: %{public}@", log: log, type: .error, message)
        } else {
            NSLog("AerialError: \(message)")
        }
    }


    // Log to disk
    logToDisk(message)
}

func logToDisk(_ message: String) {
    DispatchQueue.main.async {
        // Prefix message with date
        //let dateFormatter = DateFormatter()
        //dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        //let string = dateFormatter.string(from: Date()) + " : " + message + "\n"
        let string = message + "\n"

        var cacheFileUrl = URL(fileURLWithPath: Helpers.supportPath as String)
        cacheFileUrl.appendPathComponent("Log.txt")

        let data = string.data(using: String.Encoding.utf8, allowLossyConversion: false)!

        if FileManager.default.fileExists(atPath: cacheFileUrl.path) {
            // Append to log
            do {
                let fileHandle = try FileHandle(forWritingTo: cacheFileUrl)
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.synchronizeFile()
                fileHandle.closeFile()
            } catch {
                NSLog("AerialUpdater: Can't open handle for Log.txt \(error.localizedDescription)")
            }
        } else {
            // Create new log
            do {
                try data.write(to: cacheFileUrl, options: .atomic)
            } catch {
                NSLog("AerialUpdater: Can't write to Log.txt")
            }
        }
    }
}

func debugLog(_ message: String) {
    //if Preferences.debugMode {
    Log(level: .debug, message: message)
    //}
}

func infoLog(_ message: String) {
    Log(level: .info, message: message)
}

func warnLog(_ message: String) {
    Log(level: .warning, message: message)
}

func errorLog(_ message: String) {
    Log(level: .error, message: message)
}
