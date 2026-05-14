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

    // MARK: Night Shift

    // swiftlint:disable:next large_tuple
    static func getInformation() -> (Bool, sunrise: Date?, sunset: Date?, error: String?) {
        if isNightShiftDataCached {
            return (nightShiftAvailable,
                    nightShiftAvailable ? nightShiftSunrise : nil,
                    nightShiftAvailable ? nightShiftSunset : nil,
                    nightShiftAvailable ? nil : "Night Shift unavailable (cached)")
        }

        let cbdpath = "/usr/libexec/corebrightnessdiag"

        let nsInfo = Helpers.shell(launchPath: cbdpath, arguments: ["nightshift-internal"])

        let lines = nsInfo?.split(separator: "\n")
        if (lines?.count ?? 0) < 5 {
            // We get a couple of lines of output on unsupported Macs
            isNightShiftDataCached = true
            nightShiftAvailable = false
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
        isNightShiftDataCached = true
        nightShiftAvailable = false
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
