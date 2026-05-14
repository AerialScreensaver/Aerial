//
//  NightShift.swift
//  Aerial
//
//  Created by Guillaume Louel on 19/12/2019.
//  Copyright © 2019 Guillaume Louel. All rights reserved.
//

import Foundation

struct NightShift {

    static var isNightShiftDataCached = false
    static var nightShiftAvailable = false
    static var nightShiftSunrise = Date()
    static var nightShiftSunset = Date()

    // swiftlint:disable:next large_tuple
    static func getInformation() -> (Bool, sunrise: Date?, sunset: Date?, error: String?) {
        // Primary path: cached NightShift times written by the Companion's
        // LocationProvider to PrefsTime. This is the canonical source on
        // modern macOS (Sonoma+), where the sandboxed extension cannot run
        // /usr/libexec/corebrightnessdiag itself.
        let cachedSunrise = PrefsTime.cachedNightShiftSunrise
        let cachedSunset = PrefsTime.cachedNightShiftSunset
        if cachedSunrise > 0 && cachedSunset > 0 {
            let sunrise = Date(timeIntervalSinceReferenceDate: cachedSunrise)
            let sunset = Date(timeIntervalSinceReferenceDate: cachedSunset)
            nightShiftSunrise = sunrise
            nightShiftSunset = sunset
            nightShiftAvailable = true
            isNightShiftDataCached = true
            debugLog("NightShift using PrefsTime cached data")
            return (true, sunrise, sunset, nil)
        }

        if isNightShiftDataCached {
            return (nightShiftAvailable, nightShiftSunrise, nightShiftSunset, nil)
        }

        // On Catalina, corebrightnessdiag was moved to /usr/libexec/ !
        var cbdpath = "/usr/bin/corebrightnessdiag"
        if #available(OSX 10.15, *) {
            cbdpath = "/usr/libexec/corebrightnessdiag"
        }

        let (nsInfo, ts) = Aerial.helper.shell(launchPath: cbdpath, arguments: ["nightshift-internal"])
        

        if ts != 0 {
            // Task didn't return correctly ? Abort
            return (false, nil, nil, "Your Mac does not support Night Shift")
        }
        let lines = nsInfo?.split(separator: "\n")
        if (lines?.count ?? 0) < 5 {
            // We get a couple of lines of output on unsupported Macs
            return (false, nil, nil, "Your Mac does not support Night Shift")
        }
        var sunrise: Date?, sunset: Date?

        for line in lines ?? [""] {
            if line.contains("sunrise") {
                if let gdate = getDateFromLine(String(line)) {
                    sunrise = gdate
                }
            } else if line.contains("sunset") {
                if let gdate = getDateFromLine(String(line)) {
                    sunset = gdate
                }
            }
        }

        if sunset != nil && sunrise != nil {
            nightShiftSunrise = sunrise!
            nightShiftSunset = sunset!
            nightShiftAvailable = true
            isNightShiftDataCached = true

            return (true, sunrise, sunset, nil)
        }

        // /usr/bin/corebrightnessdiag nightshift-internal | grep nextSunset | cut -d \" -f2
        warnLog("Location services may be disabled, Night Shift can't detect Sunrise and Sunset times without them")
        return (false, nil, nil, "Location services may be disabled")
    }

    // Helpers
    private static func getDateFromLine(_ line: String) -> Date? {
        let tmp = line.split(separator: "\"")

        if tmp.count > 1 {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZ"

            if let dateObj = dateFormatter.date(from: String(tmp[1])) {
                return dateObj
            }
        }

        return nil
    }

}
