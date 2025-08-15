//
//  PluginBridge.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 09/10/2023.
//

import Foundation

struct PluginBridge {
    
    static func setNotifications() {
        debugLog("🌉 seting up PluginBridge")

        // Get nightshift
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.glouel.aerial.getnightshift"), object: nil, queue: nil) { notification in
            debugLog("🌉😻 received nightshift, replying")
            debugLog(notification.debugDescription)
            
            // Do the thing
            sendNightShift()
        }

        // Get location
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.glouel.aerial.getlocation"), object: nil, queue: nil) { notification in
            debugLog("🌉😻 received location, replying")
            debugLog(notification.debugDescription)
            
            // Do the thing
            sendLocation()
        }

    }

    // Fetch and send back night shift data
    static func sendNightShift() {
        let (isNSCapable, sunrise, sunset, _) = NightShift.getInformation()
        if !isNSCapable {
            errorLog("Trying to use Night Shift on a non capable Mac")
            return
        }

        debugLog("🌉 Night shift sunrise: \(sunrise!), sunset: \(sunset!))")
        DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("com.glouel.aerial.nightshift"), object: nil, userInfo: ["sunrise": sunrise!, "sunset": sunset!], deliverImmediately: true)
    }
    
    static func sendLocation() {
        // Get the location
        let location = Locations.sharedInstance
        location.getCoordinates(failure: { (_) in
            errorLog("Could not get coordinates")
        }, success: { (coordinates) in
            // Anonymize a bit
            let lat: Double = (coordinates.latitude*100).rounded() / 100
            let long: Double = (coordinates.longitude*100).rounded() / 100

            debugLog("🌉 Location check: \(lat), sunset: \(long))")
            DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("com.glouel.aerial.location"), object: nil, userInfo: ["latitude": lat, "longitude": long], deliverImmediately: true)
        })
    }
        
   
}
