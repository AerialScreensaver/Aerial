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

        // Log the version/build AND the bundle path of the .appex that
        // actually loaded. With duplicate pluginkit registrations (stale
        // archives / old build copies sharing this bundle id), the system can
        // load the wrong one — and the extension then inits but never gets a
        // view controller. The path here is the tell for which registration won.
        let extBundle = Bundle(for: type(of: self))
        let version = extBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = extBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        debugLog("AerialScreenSaverExtension initialized — v\(version) (build \(build))")
        debugLog("  loaded from: \(extBundle.bundlePath)")

        // Log preferences status for verification
        let settingsFileExists = FileManager.default.fileExists(atPath: ScreensaverSettings.fileURL.path)
        debugLog("  Preferences file exists: \(settingsFileExists) at \(ScreensaverSettings.fileURL.path)")
    }
}
