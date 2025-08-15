//
//  LocalVersion.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 25/07/2020.
//

import Foundation

@objcMembers class Constant: NSObject {
    static let aerialPath = LocalVersion.aerialPath
}

struct LocalVersion {
    static let aerialAllUsersPath: String = {
        let path = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .localDomainMask, true)[0] as String
        let url = NSURL(fileURLWithPath: path)
        if let pathComponent = url.appendingPathComponent("Screen Savers/Aerial.saver") {
            return pathComponent.path
        } else {
            return ""
        }
    }()

    static let aerialPath: String = {
        let path = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true)[0] as String
        let url = NSURL(fileURLWithPath: path)
        if let pathComponent = url.appendingPathComponent("Screen Savers/Aerial.saver") {
            return pathComponent.path
        } else {
            return ""
        }
    }()

    static let userLibraryScreenSaverPath: String = {
        let path = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true)[0] as String
        let url = NSURL(fileURLWithPath: path)
        if let pathComponent = url.appendingPathComponent("Screen Savers/") {
            return pathComponent.path
        } else {
            return ""
        }
    }()
    
    static func isInstalledForAllUsers() -> Bool {
        return FileManager.default.fileExists(atPath: aerialAllUsersPath)
    }

    
    static func isInstalled() -> Bool {
        return FileManager.default.fileExists(atPath: aerialPath)
    }
    
    static func get() -> String {
        if !isInstalled() {
            return "Not installed"
        }
        
        let plistPath = aerialPath.appending("/Contents/Info.plist")

        if let output = Helpers.shell(launchPath: "/usr/bin/defaults", arguments: ["read","\(plistPath)","CFBundleShortVersionString"]) {
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return "Cannot read version number, please report"
        }
    }
    
    // This does not work so in the meantime we'll prompt the user
    // https://stackoverflow.com/questions/36957837/how-to-delete-system-domain-files-on-os-x-using-swift-2#36973684
    // https://developer.apple.com/documentation/servicemanagement/1431078-smjobbless
    /*static func removeForAllUsers() {
        if isInstalledForAllUsers() {
            do {
                try FileManager.default.removeItem(atPath: aerialAllUsersPath)
            } catch {
                print(error)
            }
        }
    }*/
}


