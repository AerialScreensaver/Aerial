//
//  Location.swift
//  Aerial
//
//  Simplified: reads cached coordinates from PrefsTime.
//  LocationProvider handles CLLocationManager updates.
//  This file is retained for any indirect references but
//  the Companion target primarily uses LocationProvider.
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
