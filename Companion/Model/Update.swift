//
//  Update.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 25/07/2020.
//

import Cocoa

protocol UpdateCallback {
    func updateProgress(string: String, done: Bool)
    func updateMenuContent()
    func setIcon(mode: IconMode)
}

// Again this is a bit messy...
class Update {
    static let instance: Update = Update()
    
    var uiCallback: UpdateCallback?
    var shouldReport = false
    var commandLine = false
   
    func setCallback(_ cb: UpdateCallback) {
        uiCallback = cb
    }
    
    func unattendedCheck() {
        debugLog("Checking for new version...")
        if !LocalVersion.isInstalled() {
            return
        }
        CachedManifest.instance.updateNow()
        
        var shouldUpdate = false
        if let manifest = CachedManifest.instance.manifest {
            let localVersion = LocalVersion.get()
            
            switch Preferences.desiredVersion {
            case .beta:
                if localVersion != manifest.betaVersion {
                    shouldUpdate = true
                }
            case .release:
                if localVersion != manifest.releaseVersion {
                    shouldUpdate = true
                }
            }
            
            if shouldUpdate {
                debugLog("New version available !")
                if Preferences.updateMode == .automatic {
                    unattendedPerform()
                } else {
                    if let cb = uiCallback {
                        cb.setIcon(mode: .notification)
                    }
                }
            } 
        }
    }
    
    // What should we do, is there a new version available ?
    func check() -> (String, Bool) {
        if !LocalVersion.isInstalled() {
            return ("Plug-in not installed!", true)
        }

        if let manifest = CachedManifest.instance.manifest {
            let localVersion = LocalVersion.get()
            
            debugLog("Versions: local \(localVersion), beta \(manifest.betaVersion), release \(manifest.releaseVersion)")
            
            switch Preferences.desiredVersion {
            case .beta:
                if localVersion == manifest.betaVersion {
                    return ("\(localVersion) is installed", false)
                } else {
                    return ("\(manifest.betaVersion) is available", true)
                }
            case .release:
                if localVersion == manifest.releaseVersion {
                    return ("\(localVersion) is installed", false)
                } else {
                    return ("\(manifest.releaseVersion) is available", true)
                }
            }
        } else {
            return ("No network connection", false)
        }
    }
    
    
    func unattendedPerform() {
        shouldReport = false
        doPerform()
    }
    
    func perform(_ cb: UpdateCallback) {
        uiCallback = cb
        shouldReport = true
        doPerform()
    }
    
    func report(string: String, done: Bool) {
        debugLog("report \(done)")
        if shouldReport {
            if let cb = uiCallback {
                cb.updateProgress(string: string, done: done)
            }
        }

        if done {
            if let cb = uiCallback {
                cb.setIcon(mode: .normal)
                cb.updateMenuContent()
            }
            
            if commandLine {
                // We quit here
                DispatchQueue.main.async {
                    debugLog("Update process done, quitting in 20sec.")
                    RunLoop.main.run(until: Date() + 0x14)
                    NSApplication.shared.terminate(self)
                }
            }
        }
    }
    
    func doPerform() {
        if let cb = uiCallback {
            cb.setIcon(mode: .updating)
        }

        guard let manifest = CachedManifest.instance.manifest else {
            errorLog("Trying to perform update with no manifest, please report")
            report(string: "Error: No manifest", done: true)
            return
        }
        
        debugLog("Performing update")
        
        let supportUrl = URL(fileURLWithPath: Helpers.supportPath)

        let destinationUrl = supportUrl.appendingPathComponent("Aerial.saver.zip")
        let destinationSaverUrl = supportUrl.appendingPathComponent("Aerial.saver")
        
        // Make sure to delete a zip if exists
        if FileManager().fileExists(atPath: destinationUrl.path)
        {
            do {
                debugLog("Deleting old file from AppSupport")
                try FileManager().removeItem(at: destinationUrl)
            } catch {
                // ERROR
                errorLog("Cannot delete zip in AppSupport")
                report(string: "Cannot delete zip in AppSupport", done: true)
                return
            }
        }

        if FileManager().fileExists(atPath: destinationSaverUrl.path)
        {
            do {
                debugLog("Deleting old saver file from AppSupport")
                try FileManager().removeItem(at: destinationSaverUrl)
            } catch {
                // ERROR
                errorLog("Cannot delete Aerial.saver in AppSupport")
                report(string: "Cannot delete Aerial.saver in AppSupport", done: true)
                return
            }
        }

        var zipPath: String = ""

        switch Preferences.desiredVersion {
        case .beta:
            zipPath = "https://github.com/JohnCoates/Aerial/releases/download/v\(manifest.betaVersion)/Aerial.saver.zip"
        case .release:
            zipPath = "https://github.com/JohnCoates/Aerial/releases/download/v\(manifest.releaseVersion)/Aerial.saver.zip"
        }
        debugLog("Downloading...")
        report(string: "Downloading...", done: false)
        
        FileDownloader.loadFileAsync(url: URL(string:zipPath)!) { (path, error) in
            if let perror = error {
                errorLog("Download error: \(perror.localizedDescription)")
                self.report(string: "Error: \(perror.localizedDescription)", done: true)
            } else {
                self.verifyFile(path: path!, manifest: manifest)
            }
        }
    }
    
    // MARK: - Private helpers
    private func verifyFile(path: String, manifest: Manifest) {
        debugLog("Verifying...")
        report(string: "Verifying...", done: false)
        
        if FileManager.default.fileExists(atPath: path) {
            let dlsha = getZipSHA256(path: path)
            var tsha: String
            
            switch Preferences.desiredVersion {
            case .beta:
                tsha = manifest.betaSHA256
            case .release:
                tsha = manifest.releaseSHA256
            }

            if tsha == dlsha {
                debugLog("Unzipping...")
                report(string: "Unzipping...", done: false)

                _ = Helpers.shell(launchPath: "/usr/bin/unzip", arguments: ["-d", String(path[...path.lastIndex(of: "/")!]), path])
                
                var saverPath = path
                saverPath.removeLast(4)
                debugLog("Verifying signature...")
                report(string: "Verifying signature...", done: false)

                if FileManager.default.fileExists(atPath: saverPath) {
                    let result = Helpers.shell(launchPath: "/usr/bin/codesign", arguments: ["-v", "-d", saverPath])
                    
                    if checkCodesign(result) {
                        if install(saverPath) {
                            // Pfew...
                            debugLog("Installed ! Setting up as default")
                            //setAsDefault()
                            report(string: "OK", done: true)
                        } else {
                            errorLog("Cannot copy .saver")
                            report(string: "Cannot copy .saver", done: true)
                        }
                        
                    } else {
                        errorLog("Codesigning verification failed")
                        report(string: "Codesigning verification failed", done: true)
                    }
                } else {
                    errorLog("Aerial.saver not found in zip")
                    report(string: "Aerial.saver not found in zip", done: true)
                }
            } else {
                errorLog("Downloaded file is corrupted")
                report(string: "Downloaded file is corrupted", done: true)
            }
        } else {
            errorLog("Downloaded file not found")
            report(string: "Downloaded file not found", done: true)
        }
        
    }
    
    public func setAsDefault() {
        // defaults -currentHost write com.apple.screensaver moduleDict -dict moduleName Flurry path /System/Library/Screen\ Savers/Flurry.saver/ type 0
        
        _ = Helpers.shell(launchPath: "/usr/bin/defaults", arguments: ["-currentHost","write","com.apple.screensaver","moduleDict","-dict","moduleName","Aerial","path",LocalVersion.aerialPath,"type","0"])
        //debugLog(ret ?? "Defaults didn't return error")
    }

    private func checkCodesign(_ result: String?) -> Bool {
        if let presult = result {
            let lines = presult.split(separator: "\n")
            
            var bundleVer = false
            var devIDVer = false
            
            for line in lines {
                if line.starts(with: "Identifier=com.JohnCoates.Aerial") {
                    bundleVer = true
                }
                if line.starts(with: "TeamIdentifier=3L54M5L5KK") {
                    devIDVer = true
                }
            }
            
            if bundleVer && devIDVer {
                return true
            } else {
                return false
            }

        } else {
            return false
        }
    }
    
    private func install(_ path: String) -> Bool {
        if FileManager.default.fileExists(atPath: LocalVersion.aerialPath) {
            debugLog("Removing old version...")
            report(string: "Removing old version...", done: false)
            if FileManager().fileExists(atPath: LocalVersion.aerialPath)
            {
                do {
                    try FileManager().removeItem(at: URL(fileURLWithPath: LocalVersion.aerialPath))
                } catch {
                    // ERROR
                    errorLog("Cannot delete zip in downloads directory")
                    report(string: "Cannot delete zip in downloads directory", done: true)
                    return false
                }
            }
        }
        
        // We may need to create the "Screen Savers" folder in library !
        if !FileManager.default.fileExists(atPath: LocalVersion.userLibraryScreenSaverPath) {
            debugLog("Creating /Screen Savers/ in user library")
            
            do {
                try FileManager.default.createDirectory(
                    atPath:LocalVersion.userLibraryScreenSaverPath,
                    withIntermediateDirectories: true,
                    attributes: nil)
            } catch {
                errorLog("Cannot create Screen Savers directory in your user library")
                report(string: "Cannot create Screen Savers directory in your user library", done: true)

                print(error.localizedDescription);
            }
        }
        
        debugLog("Installing...")
        report(string: "Installing...", done: false)

        do {
            try FileManager.default.moveItem(atPath: path, toPath: LocalVersion.aerialPath)
            
            debugLog("Installed!")
            return true
        } catch {
            return false
        }
        
    }
    
    private func getZipSHA256(path: String) -> String {
        if FileManager.default.fileExists(atPath: path) {
            return String(Helpers.shell(launchPath: "/usr/bin/shasum",arguments: ["-a","256",path])!.split(separator: " ")[0])
        }
        return ""
    }
    
}
