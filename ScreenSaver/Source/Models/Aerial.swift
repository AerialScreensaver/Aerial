//
//  Aerial.swift
//  Aerial
//
//  Contains some common helpers used throughout the code
//
//  Created by Guillaume Louel on 17/07/2020.
//  Copyright © 2020 Guillaume Louel. All rights reserved.
//

import Cocoa

class Aerial: NSObject {
    static let helper = Aerial()

    // We use this to track whether we run as a screen saver or an app
    var appMode = false

    // We also track darkmode here now
    var darkMode = false

    // And we track if we are running under Aerial's Companion 
    var underCompanion = false

    // Are we running under Aerial Companion ? Desktop mode/Fullscreen mode
    // Xcode debug mode is also considered as running under Companion
    
    func checkCompanion() {
        logToConsole("Checking for companion")
        if appMode {
            underCompanion = true
            logToConsole("> Running in appMode, simming Companion!")
        } else {
            for bundle in Bundle.allBundles {
                if let bundleId = bundle.bundleIdentifier {
                    if bundleId.contains("com.glouel.Aerial-App") {
                        underCompanion = true
                        logToConsole("> Running under Aerial Companion!")
                    }
                }
            }
        }
    }

    func computeDarkMode(view: NSView) {
        if #available(OSX 10.14, *) {
            //debugLog("Best match appearance : \(view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]))")
            //debugLog("Effective Appearence : \(view.effectiveAppearance)")
            darkMode =  view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        } else {
            darkMode = false
        }
    }

    // Language detection
    func getPreferredLanguage() -> String {
        let printOutputLocale: NSLocale = NSLocale(localeIdentifier: Locale.preferredLanguages[0])
        if let deviceLanguageName: String = printOutputLocale.displayName(forKey: .identifier, value: Locale.preferredLanguages[0]) {
            if #available(OSX 10.12, *) {
                return "Preferred language: \(deviceLanguageName) [\(printOutputLocale.languageCode)]"
            } else {
                return "Preferred language: \(deviceLanguageName)"
            }
        } else {
            return ""
        }
    }

    // Alerts
    func showErrorAlert(question: String, text: String, button: String = "OK") {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = text
        alert.alertStyle = .critical
        alert.icon = NSImage(named: NSImage.cautionName)
        alert.addButton(withTitle: button)
        alert.runModal()
    }

    // Launch a process through shell and capture/return output
    func shell(launchPath: String, arguments: [String] = []) -> (String?, Int32) {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        if #available(OSX 10.13, *) {
            do {
                try task.run()
            } catch {
                // handle errors
                debugLog("Error: \(error.localizedDescription)")
            }
        } else {
            // A non existing command will crash 10.12
            task.launch()
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)
        task.waitUntilExit()

        return (output, task.terminationStatus)
    }

}
