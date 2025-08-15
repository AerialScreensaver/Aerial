//
//  Location.swift
//  Aerial
//
//  Created by Guillaume Louel on 24/05/2020.
//  Copyright © 2020 Guillaume Louel. All rights reserved.
//

import Foundation
import CoreLocation

class Locations: NSObject {
    static let sharedInstance = Locations()
    let locationManager = CLLocationManager()
    var coordinates: CLLocationCoordinate2D?
    var failures: [(String) -> Void] = []
    var successes: [(CLLocationCoordinate2D) -> Void] = []

    // MARK: - Lifecycle
    override init() {
        super.init()
        locationManager.delegate = self
        debugLog("Starting Location initialization")
    }

    func getCoordinates(failure: @escaping (_ error: String) -> Void,
                        success: @escaping (_ response: CLLocationCoordinate2D) -> Void) {
        // Perhaps they are cached already ?
        if coordinates != nil {
            debugLog("Location using cached data")
            success(coordinates!)
            return
        }

        // Check for access & start
        if CLLocationManager.locationServicesEnabled() {
            debugLog("Location services enabled")
            locationManager.startUpdatingLocation()
        } else {
            debugLog("Location services disabled")
            failure("Location services disabled")
        }

        // This seems super wrong...
        if #available(OSX 10.14, *) {
            // Add our callbacks, as this is the only time we'll really defer
            failures.append(failure)
            successes.append(success)

            locationManager.requestLocation()
        } else {
            // Fallback on earlier versions
            failure("macOS 10.14 is required")
        }
    }
}

extension Locations: CLLocationManagerDelegate {
    // Auth status callback
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        debugLog("LMauth status change : \(status.rawValue)")
        if status == .denied {
            debugLog("Location services are either globally disabled, or disabled for Aerial. Please enable them at least once so Aerial can get your coordinates, or use another Time management mode.")
        }
    }

    // Location fetch Success callback
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let currentLocation = locations[locations.count - 1]
        coordinates = currentLocation.coordinate    // Wondering, why singular?
        debugLog("Location coordinate : \(currentLocation.coordinate)")
        locationManager.stopUpdatingLocation()      // We only want them once

        for success in successes {
            success(currentLocation.coordinate)
        }
        
        successes.removeAll()
        failures.removeAll()
    }

    // Location fetch Failure callback
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // This is a total failure
        for failure in failures {
            failure("Unable to fetch location")
        }

        // Then cleanup
        successes.removeAll()
        failures.removeAll()
    }
}
