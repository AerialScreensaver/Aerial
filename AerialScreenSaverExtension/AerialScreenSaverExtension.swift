//
//  AerialScreenSaverExtension.swift
//  AerialScreenSaverExtension
//
//  Principal class for the Aerial screensaver extension.
//

import ScreenSaver

/// Principal class for the Aerial screensaver extension.
/// This is the entry point that the system instantiates when loading the extension.
@objc(AerialScreenSaverExtension)
class AerialScreenSaverExtension: ScreenSaverExtension {

    override init() {
        super.init()

        LogBridge.configure(AerialLogger(config: LoggerConfiguration(
            logFileName: "extension.txt",
            supportPath: { AerialPaths.logsPath() },
            category: "Extension"
        )))

        debugLog("AerialScreenSaverExtension initialized")

        // Log preferences status for verification
        let settingsFileExists = FileManager.default.fileExists(atPath: ScreensaverSettings.fileURL.path)
        debugLog("Preferences file exists: \(settingsFileExists) at \(ScreensaverSettings.fileURL.path)")
        if settingsFileExists {
            debugLog("  muteSound: \(PrefsAdvanced.muteSound)")
            debugLog("  debugMode: \(PrefsAdvanced.debugMode)")
        }
    }
}
