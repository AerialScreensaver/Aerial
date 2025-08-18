//
//  CachedManifest.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 25/07/2020.
//

import Foundation

class CachedManifest {
    static let instance: CachedManifest = CachedManifest()

    var manifest: CompanionManifest?
    
    func updateNow() {
        do {
            let tManifest = try CompanionManifest(fromURL: URL(string: "https://aerialscreensaver.github.io/manifest.json")!)
            
            CompanionLogging.debugLog("Manifest downloaded, alpha: \(String(describing: tManifest.alphaVersion)), beta: \(String(describing:tManifest.betaVersion)), release: \(String(describing:tManifest.releaseVersion))")
            // All good ? Save
            manifest = tManifest
        } catch {
            //
        }
    }
}
