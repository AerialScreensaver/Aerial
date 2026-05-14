//
//  WeatherSymbols.swift
//  AerialScreenSaverExtension
//
//  SF Symbol mapping for OpenWeather condition codes.
//  Extracted from the old ConditionSymbolLayer for use in SwiftUI.
//

import Foundation

enum WeatherSymbols {

    /// Day-time SF Symbol names keyed by OpenWeather condition code
    static let mainSymbols: [Int: String] = [
        200: "cloud.bolt.rain",
        201: "cloud.bolt.rain",
        202: "cloud.bolt.rain",
        210: "cloud.sun.bolt",
        211: "cloud.bolt",
        212: "cloud.bolt",
        221: "cloud.bolt",
        230: "cloud.bolt.rain",
        231: "cloud.bolt.rain",
        232: "cloud.bolt.rain",

        300: "cloud.drizzle",
        301: "cloud.drizzle",
        302: "cloud.drizzle",
        310: "cloud.drizzle",
        311: "cloud.drizzle",
        312: "cloud.drizzle",
        313: "cloud.drizzle",
        314: "cloud.drizzle",
        321: "cloud.drizzle",

        500: "cloud.sun.rain",
        501: "cloud.rain",
        502: "cloud.heavyrain",
        503: "cloud.heavyrain",
        504: "cloud.heavyrain",

        511: "cloud.sleet",

        520: "cloud.rain",
        521: "cloud.rain",
        522: "cloud.heavyrain",
        531: "cloud.rain",

        600: "snow",
        601: "snow",
        602: "cloud.snow",

        611: "cloud.sleet",
        612: "cloud.sleet",
        613: "cloud.sleet",
        615: "cloud.sleet",
        616: "cloud.sleet",

        620: "snow",
        621: "snow",
        622: "cloud.snow",

        701: "sun.haze",
        711: "smoke",
        721: "sun.haze",
        731: "sun.dust",
        741: "sun.haze",
        751: "sun.dust",
        761: "sun.dust",
        762: "sun.dust",
        781: "tornado",

        800: "sun.max",
        801: "sun.max",
        802: "cloud.sun",
        803: "cloud.sun",
        804: "cloud",
    ]

    /// Night-time overrides (condition codes that have a different night symbol)
    static let nightSymbols: [Int: String] = [
        210: "cloud.moon.bolt",
        500: "cloud.moon.rain",
        800: "moon.stars",
        801: "moon",
        802: "cloud.moon",
        803: "cloud.moon",
    ]

    /// Returns the SF Symbol name for a given condition code and day/night state
    static func symbolName(for conditionCode: Int, isNight: Bool) -> String {
        if isNight, let nightSymbol = nightSymbols[conditionCode] {
            return nightSymbol
        }
        return mainSymbols[conditionCode] ?? "wrench"
    }

    /// Returns the colored (`.fill`) variant of the symbol name
    static func colorSymbolName(for conditionCode: Int, isNight: Bool) -> String {
        let name = symbolName(for: conditionCode, isNight: isNight)
        // Some symbols don't have a .fill variant
        if name == "wrench" || name == "snow" || name == "tornado" {
            return name
        }
        return name + ".fill"
    }

    /// Determines whether the given timestamp falls in nighttime
    static func isNight(dt: Int, sunrise: Int, sunset: Int) -> Bool {
        return dt < sunrise || dt > sunset
    }
}
