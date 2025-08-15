//
//  SystemPrefs.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 09/10/2022.
//

import Foundation

struct SystemPrefs {
    
    /// Returns information if our screensaver is defaulted or not
    static func getSaverSelectedStatus() -> Bool {
        let result = Helpers.shell(launchPath: "/usr/bin/defaults",
                                   arguments: ["-currentHost",
                                               "read",
                                               "com.apple.screensaver",
                                               "moduleDict"]) ?? ""
        
        let lines = result.split(whereSeparator: \.isNewline)
        
        for line in lines {
            if line.contains("Aerial") {
                return true
            }
        }
        return false
    }
    
    /// Returns screen saver activation time in minutes
    static func getSaverActivationTime() -> Int?{
        // defaults -currentHost read com.apple.screensaver idleTime
        let result = Helpers.shell(launchPath: "/usr/bin/defaults",
                                   arguments: ["-currentHost",
                                               "read",
                                               "com.apple.screensaver",
                                               "idleTime"]) ?? ""
        if let idleTime = Int(result.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return idleTime / 60
        }
        
        return nil
    }
    
    
    static func setSaverActivationTime(time:Int) {
        // defaults -currentHost write com.apple.screensaver idleTime -int timeInSeconds
        // Note : -int became required at some point in Ventura, if not specified it defaults to string nowadays. This parameter is available since 2003 so this is backward compatible
        _ = Helpers.shell(launchPath: "/usr/bin/defaults",
                           arguments: ["-currentHost",
                                       "write",
                                       "com.apple.screensaver",
                                       "idleTime",
                                       "-int",
                                        String(time*60)])
    }
    
    
    /// Returns display sleep in minutes
    static func getDisplaySleep() -> Int? {
        let result = Helpers.shell(launchPath: "/usr/bin/pmset", arguments: ["-g"]) ?? ""
        
        let lines = result.split(whereSeparator: \.isNewline)
        
        for line in lines {
            if line.contains("displaysleep") {
                let vals = line.split(separator: "p")
                
                if vals.count == 3 {
                    if let sleepTime = Int(vals[2].trimmingCharacters(in: .whitespacesAndNewlines)) {
                        return sleepTime
                    }
                } else if vals.count > 3 {
                    if let sleepTime = Int(vals[2].split(separator: "(")[0].trimmingCharacters(in: .whitespacesAndNewlines)) {
                        return sleepTime
                    }
                }
            }
        }
        
        return nil
    }
}
