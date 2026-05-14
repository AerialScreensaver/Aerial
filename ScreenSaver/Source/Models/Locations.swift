//
//  Location.swift
//  Aerial
//
//  Simplified version: reads cached coordinates from PrefsTime.
//  The Companion app's LocationProvider handles CLLocationManager
//  and writes to PrefsTime.cachedLatitude/cachedLongitude.
//

import Foundation
import CoreLocation

class Locations: NSObject {
    static let sharedInstance = Locations()

    func getCoordinates(failure: @escaping (_ error: String) -> Void,
                        success: @escaping (_ response: CLLocationCoordinate2D) -> Void) {
        let lat = PrefsTime.cachedLatitude
        let lon = PrefsTime.cachedLongitude
        guard lat != 0 || lon != 0 else {
            debugLog("Locations: no cached coordinates available")
            failure("No cached coordinates")
            return
        }
        debugLog("Locations: using cached coordinates (\(lat), \(lon))")
        success(CLLocationCoordinate2DMake(lat, lon))
    }
}
