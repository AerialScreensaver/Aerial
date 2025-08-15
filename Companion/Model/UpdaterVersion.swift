//
//  UpdaterVersion.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 03/08/2020.
//

import Foundation

struct UpdaterVersion {
    
    static func needsUpdating() -> Bool {
        if let manifest = CachedManifest.instance.manifest {
            if manifest.updaterVersion > Helpers.version {
                return true
            }
        }
        
        return false
    }

}
