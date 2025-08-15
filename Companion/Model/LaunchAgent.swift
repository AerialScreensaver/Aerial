//
//  LaunchAgent.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 09/08/2020.
//

import Cocoa

struct LaunchAgent {
    // com.glouel.AerialUpdaterAgent.plist
    static let agentPath: String = {
        let path = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true)[0] as String
        let url = NSURL(fileURLWithPath: path)
        if let pathComponent = url.appendingPathComponent("LaunchAgents/com.glouel.AerialUpdaterAgent.plist") {
            return pathComponent.path
        } else {
            return ""
        }
    }()
    
    static let agentFolder: String = {
        let path = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true)[0] as String
        let url = NSURL(fileURLWithPath: path)
        if let pathComponent = url.appendingPathComponent("LaunchAgents/") {
            return pathComponent.path
        } else {
            return ""
        }
    }()
    

    /// Update the Launch Agent to the current settings
    ///
    /// It will remove the Launch Agent first if any exists then install the correct one depending on the mode. In manual mode, nothing is installed.
    static public func update() {
        // Let's start by cleaning up
        removeAgent()

        // If we need to set something, do it
        if Preferences.launchMode != .manual {
            installAgent()
        }
    }
    
    static private func removeAgent() {
        if FileManager.default.fileExists(atPath: agentPath) {
            do {
                debugLog("Removing LaunchAgent")
                try FileManager().removeItem(atPath: agentPath)
            } catch {
                // ERROR
                errorLog("Cannot remove LaunchAgent")
                Helpers.showErrorAlert(question: "Cannot remove launch agent", text: "Please report !")
                return
            }
        }
    }
    
    static private func installAgent() {
        var agent: String = ""
        switch Preferences.launchMode {
        case .manual:
            errorLog("Calling installAgent in manual mode, please report")
            return
        case .startup:
            agent = getStartupAgent()
        case .background:
            agent = getBackgroundAgent()
        }
        
        // We may need to create the "LaunchAgents" folder in library !
        if !FileManager.default.fileExists(atPath: agentFolder) {
            debugLog("Creating /LaunchAgents/ in user library")
            
            do {
                try FileManager.default.createDirectory(
                    atPath:agentFolder,
                    withIntermediateDirectories: true,
                    attributes: nil)
            } catch {
                errorLog("Cannot create LaunchAgent directory in your user library")
                print(error.localizedDescription);
            }
        }
        
        do {
            try agent.write(toFile: agentPath, atomically: true, encoding: .utf8)
            debugLog("LaunchAgent installed")
        } catch {
            Helpers.showErrorAlert(question: "Can't install LaunchAgent", text: "Please report the issue")
        }

        restart()
        if Preferences.launchMode == .background {
            debugLog("Quitting after installing background mode")
            NSApplication.shared.terminate(nil)
        }
    }
    
    // Restarts our agent via launchctl
    // This may not work on very old macOS versions?
    static private func restart() {
        debugLog("Restarting LaunchAgent")
        let out1 = Helpers.shell(launchPath: "/bin/launchctl", arguments: ["unload", agentPath])
        debugLog(out1 ?? "(no output)")
        let out2 = Helpers.shell(launchPath: "/bin/launchctl", arguments: ["load", agentPath])
        debugLog(out2 ?? "(no output)")
    }
    
    static private func getStartupAgent() -> String {
        let top =
"""
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.glouel.AerialUpdater</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
"""

        let bundleLine = "<string>" + Bundle.main.bundlePath + "</string>"
        
        let bottom =
"""

    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
"""
        return top + bundleLine + bottom
    }
    

    static private func getBackgroundAgent() -> String {
        let top =
"""
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.glouel.AerialUpdater</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
"""
        let bundleLine = "<string>" + Bundle.main.bundlePath + "</string>"
        
        let bottom =
"""

        <string>--args</string>
        <string>--silent</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>
"""
        let bottom2 =
        """
</integer>
</dict>
</plist>
"""
        return top + bundleLine + bottom + String(BackgroundCheck.instance.getTimer()) + bottom2
    }

}

