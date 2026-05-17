//
//  TimeManagement.swift
//  Aerial
//
//  Created by Guillaume Louel on 05/10/2018.
//  Copyright © 2018 John Coates. All rights reserved.
//

import Foundation
import Cocoa
import CoreLocation
import IOKit.ps

// swiftlint:disable:next type_body_length
final class TimeManagement: NSObject {
    static let sharedInstance = TimeManagement()

    var solar: Solar?
    var lsLatitude: Double?
    var lsLongitude: Double?

    // MARK: - Lifecycle
    override init() {
        super.init()
        debugLog("Time Management initialized")
        if PrefsTime.timeMode == .locationService {
            // This is racy... I think we're ok because time/location gets inited first, but still...
            let location = Locations.sharedInstance

            location.getCoordinates(failure: { (_) in
                errorLog("Location services denied access to your location. Please make sure you allowed Aerial to access your location in System Settings > Security and Privacy > Privacy")
            }, success: { (coordinates) in
                self.lsLatitude = coordinates.latitude
                self.lsLongitude = coordinates.longitude
                debugLog("Location found \(self.lsLatitude ?? 0) \(self.lsLongitude ?? 0)")
                _ = self.calculateFrom(latitude: self.lsLatitude!, longitude: self.lsLongitude!)
            })
        } else {
            _ = calculateFromCoordinates()
        }
    }

    // MARK: - Static Time Filter for Playlists

    /// Check if a video's time-of-day matches the current time restriction.
    /// Returns true if no restriction is active or if the video matches.
    static func videoMatchesCurrentTime(_ video: AerialVideo) -> Bool {
        let (shouldRestrict, restrictTo) = sharedInstance.shouldRestrictPlaybackToDayNightVideo()
        guard shouldRestrict else { return true }
        return video.timeOfDay == restrictTo
    }

    /// Like videoMatchesCurrentTime, but also accepts the next adjacent slice.
    /// Fallback order: night→sunrise→day→sunset→night.
    static func videoMatchesCurrentTimeWithFallback(_ video: AerialVideo) -> Bool {
        let (shouldRestrict, restrictTo) = sharedInstance.shouldRestrictPlaybackToDayNightVideo()
        guard shouldRestrict else { return true }
        return video.timeOfDay == restrictTo || video.timeOfDay == nextSlice(restrictTo)
    }

    /// Circular slice progression: night→sunrise→day→sunset→night
    private static func nextSlice(_ current: String) -> String {
        switch current {
        case "night": return "sunrise"
        case "sunrise": return "day"
        case "day": return "sunset"
        case "sunset": return "night"
        default: return "day"
        }
    }

    /// Returns the date when the current time-of-day slice ends, or nil if unpredictable.
    func nextTransitionDate() -> Date? {
        // Dark mode override — transition depends on user toggling dark mode
        if PrefsTime.darkModeNightOverride && DarkMode.isEnabled() {
            return nil
        }

        switch PrefsTime.timeMode {
        case .disabled, .lightDarkMode:
            return nil

        case .nightShift:
            let (isNSCapable, sunrise, sunset, _) = NightShift.getInformation()
            guard isNSCapable, let sunrise = sunrise, let sunset = sunset else { return nil }
            return computeNextTransition(sunrise: sunrise, sunset: sunset)

        case .manual:
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "HH:mm"
            guard let sunrise = dateFormatter.date(from: PrefsTime.manualSunrise),
                  let sunset = dateFormatter.date(from: PrefsTime.manualSunset) else { return nil }
            return computeNextTransition(sunrise: sunrise, sunset: sunset)

        case .coordinates:
            _ = calculateFromCoordinates()
            guard let (sr, ss) = solarSunriseSunset() else { return nil }
            return computeNextTransition(sunrise: sr, sunset: ss)

        case .locationService:
            if let lat = lsLatitude, let lon = lsLongitude {
                _ = calculateFrom(latitude: lat, longitude: lon)
            }
            guard let (sr, ss) = solarSunriseSunset() else { return nil }
            return computeNextTransition(sunrise: sr, sunset: ss)
        }
    }

    /// Extract the sunrise/sunset pair from Solar using the same fallback chain as getTimeSlice().
    private func solarSunriseSunset() -> (Date, Date)? {
        guard let sol = solar else { return nil }
        if let a = sol.astronomicalSunrise, let b = sol.astronomicalSunset { return (a, b) }
        if let a = sol.nauticalSunrise, let b = sol.nauticalSunset { return (a, b) }
        if let a = sol.civilSunrise, let b = sol.civilSunset { return (a, b) }
        if let a = sol.sunrise, let b = sol.sunset { return (a, b) }
        return nil
    }

    /// Given sunrise/sunset, compute when the current time slice boundary ends.
    private func computeNextTransition(sunrise: Date, sunset: Date) -> Date? {
        let now = Date()
        var nsunrise = sunrise
        var nsunset = sunset

        // Todayize if needed (same logic as dayNightCheck)
        if (now < sunrise && now < sunset) || (now > sunrise && now > sunset) {
            guard let tr = todayizeDate(date: sunrise), let ts = todayizeDate(date: sunset) else { return nil }
            nsunrise = tr
            nsunset = ts
        }

        let window = TimeInterval(PrefsTime.sunEventWindow)

        if now < nsunrise {
            // Night before sunrise → next transition at sunrise
            return nsunrise
        } else if now > nsunset {
            // Night after sunset → next transition at tomorrow's sunrise
            return nsunrise.addingTimeInterval(24 * 60 * 60)
        } else if now < nsunrise.addingTimeInterval(window) {
            // Sunrise period → ends at sunrise + window
            return nsunrise.addingTimeInterval(window)
        } else if now > nsunset.addingTimeInterval(-window) {
            // Sunset period → ends at sunset
            return nsunset
        } else {
            // Day → sunset period starts at sunset - window
            return nsunset.addingTimeInterval(-window)
        }
    }

    // MARK: - What should we play ?
    // swiftlint:disable:next cyclomatic_complexity
    func shouldRestrictPlaybackToDayNightVideo() -> (Bool, String) {
        //debugLog("PrefsTime : \(PrefsTime.timeMode)")
        // We override everything on dark mode if we need to
        if PrefsTime.darkModeNightOverride && DarkMode.isEnabled() {
            debugLog("Dark Mode override")
            return (true, "night")
        }

        // If not we check the modes
        if PrefsTime.timeMode == .locationService {
            if let lat = lsLatitude, let lon = lsLongitude {
                _ = calculateFrom(latitude: lat, longitude: lon)

                if solar != nil {
                    return (true, solar!.getTimeSlice())
                }
            } else {
                debugLog("No location available, failing timeMode")
            }

            return (false, "")
        } else if PrefsTime.timeMode == .lightDarkMode {
            return (true, DarkMode.isEnabled() ? "night" : "day")
        } else if PrefsTime.timeMode == .coordinates {
            _ = calculateFromCoordinates()

            if solar != nil {
                return (true, solar!.getTimeSlice())
            } else {
                errorLog("You need to input latitude and longitude for calculations to work")
                return (false, "")
            }
        } else if PrefsTime.timeMode == .nightShift {
            let (isNSCapable, sunrise, sunset, _) = NightShift.getInformation()
            if !isNSCapable {
                errorLog("Trying to use Night Shift on a non capable Mac")
                return (false, "")
            }

            return (true, dayNightCheck(sunrise: sunrise!, sunset: sunset!))
        } else if PrefsTime.timeMode == .manual {
            // We get the manual values from our preferences, as string, and convert them to dates
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "HH:mm"

            guard let dateSunrise = dateFormatter.date(from: PrefsTime.manualSunrise) else {
                errorLog("Invalid sunrise time in preferences")
                return(false, "")
            }
            guard let dateSunset = dateFormatter.date(from: PrefsTime.manualSunset) else {
                errorLog("Invalid sunset time in preferences")
                return(false, "")
            }

            debugLog("Manual : \(dayNightCheck(sunrise: dateSunrise, sunset: dateSunset))")
            return (true, dayNightCheck(sunrise: dateSunrise, sunset: dateSunset))
        }

        // default is show anything
        return (false, "")
    }

    public func getSunriseSunset() -> (Date?, Date?) {
        switch PrefsTime.timeMode {
        case .disabled:
            return (nil, nil)
        case .nightShift:
            let (_, sunrise, sunset, _) = NightShift.getInformation()
            return (sunrise, sunset)
        case .manual:
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "HH:mm"

            guard let dateSunrise = dateFormatter.date(from: PrefsTime.manualSunrise) else {
                errorLog("Invalid sunrise time in preferences")
                return(nil, nil)
            }
            guard let dateSunset = dateFormatter.date(from: PrefsTime.manualSunset) else {
                errorLog("Invalid sunset time in preferences")
                return(nil, nil)
            }
            return (dateSunrise, dateSunset)
        case .lightDarkMode:
            return (nil, nil)
        case .coordinates:
            _ = calculateFromCoordinates()
            if let (sr, ss) = solarSunriseSunset() { return (sr, ss) }
            return (nil, nil)
        case .locationService:
            if let lat = lsLatitude, let lon = lsLongitude {
                _ = calculateFrom(latitude: lat, longitude: lon)

                return (solar?.astronomicalSunrise, solar?.astronomicalSunset)
            }
            return(nil, nil)
        }
    }

    /// Returns todayized sunrise/sunset dates ready for boundary computation.
    /// Applies the same normalization logic as dayNightCheck()/computeNextTransition().
    public func todayizedSunriseSunset() -> (sunrise: Date, sunset: Date)? {
        let (rawSunrise, rawSunset) = getSunriseSunset()
        guard let sunrise = rawSunrise, let sunset = rawSunset else { return nil }

        let now = Date()
        var nsunrise = sunrise
        var nsunset = sunset

        if (now < sunrise && now < sunset) || (now > sunrise && now > sunset) {
            guard let tr = todayizeDate(date: sunrise), let ts = todayizeDate(date: sunset) else { return nil }
            nsunrise = tr
            nsunset = ts
        }

        return (nsunrise, nsunset)
    }

    // Check if we are at day or night based on provided sunrise and sunset dates
    private func dayNightCheck(sunrise: Date, sunset: Date) -> String {
        var nsunrise = sunrise
        var nsunset = sunset
        let now = Date()
        // When used with manual mode, sunrise and sunset will always be set to 2000-01-01
        // With night mode, sunrise and sunset are the "current" ones (if at 23:00, sunset = today, sunrise = tomorrow)
        // That may not always be true though, if you mess with your system clock (go back in time), both values
        // can be in the future (and possibly in the past)
        //
        // As a sanity check, we check if we are between a sunset and a sunrise (prefered calculation mode with night
        // shift as it takes into account everything correctly for us), if not we todayize the dates. In manual mode,
        // will always be todayized
        if (now < sunrise && now < sunset) || (now > sunrise && now > sunset) {
            nsunrise = todayizeDate(date: sunrise)!
            nsunset = todayizeDate(date: sunset)!
        }

        if now < nsunrise || now > nsunset {
            // So this is night, before sunrise, after sunset
            return "night"
        } else if now > nsunrise && now < nsunrise.addingTimeInterval(TimeInterval(PrefsTime.sunEventWindow)) {
            // Sunrise-period is a 3hr period after astro sunrise
            return "sunrise"
        } else if now > nsunset.addingTimeInterval(TimeInterval(-PrefsTime.sunEventWindow)) && now < nsunset {
            // Sunset-period is a 3hr period prior astro sunset
            return "sunset"
        } else {
            // Let's say this is day
            return "day"
        }
    }

    // Change a date's day to today
    private func todayizeDate(date: Date) -> Date? {
        // Get today's date as a string
        let dateFormatter = DateFormatter()
        let current = Date()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: current)

        // Extract hour from date
        dateFormatter.dateFormat = "HH:mm:ss +zzzz"
        let format = today + " " + dateFormatter.string(from: date)

        // Now return the todayized string
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss +zzzz"
        if let newdate = dateFormatter.date(from: format) {
            return newdate
        } else {
            return nil
        }
    }

    // MARK: Calculate using Solar
    func calculateFromCoordinates() -> (Bool, String) {
        if PrefsTime.timeMode == .locationService {
            // This is racy... I think we're ok because time/location gets inited first, but still...
            let location = Locations.sharedInstance

            location.getCoordinates(failure: { (_) in
                errorLog("Location services denied access to your location. Please make sure you allowed Aerial to access your location in System Settings > Security and Privacy > Privacy")
            }, success: { (coordinates) in
                self.lsLatitude = coordinates.latitude
                self.lsLongitude = coordinates.longitude
                _ = self.calculateFrom(latitude: self.lsLatitude!, longitude: self.lsLongitude!)
            })
        } else {
            if PrefsTime.latitude != "" && PrefsTime.longitude != "" {
                return calculateFrom(latitude: Double(PrefsTime.latitude) ?? 0, longitude: Double(PrefsTime.longitude) ?? 0)
            }
        }

        return (false, "Can't process your coordinates, please verify")
    }

    private func calculateFrom(latitude: Double, longitude: Double) -> (Bool, String) {
        solar = Solar.init(coordinate: CLLocationCoordinate2D(
            latitude: latitude,
            longitude: longitude))

        if solar != nil {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "j:mm:ss", options: 0, locale: Locale.current)

            let (sunrise, sunset) = getSunriseSunsetForMode(PrefsTime.solarMode)

            if sunrise == nil || sunset == nil {
               return (false, "Can't process your coordinates, please verify")
            }

            let sunriseString = dateFormatter.string(from: sunrise!)
            let sunsetString = dateFormatter.string(from: sunset!)

            if PrefsTime.solarMode == .official || PrefsTime.solarMode == .strict {
                return(true, "Today’s sunrise: " + sunriseString + "  Today’s sunset: " + sunsetString)
            } else {
                return(true, "Today’s dawn: " + sunriseString + "  Today’s dusk: " + sunsetString)
            }
        }

        return (false, "Can't process your coordinates, please verify")
    }

    // Helper to get the correct sunrise/sunset
    func getSunriseSunsetForMode(_ mode: SolarMode) -> (Date?, Date?) {
        if let sol = solar {
            switch mode {
            case .official:
                return (sol.sunrise, sol.sunset)
            case .strict:
                return (sol.strictSunrise, sol.strictSunset)
            case .civil:
                return (sol.civilSunrise, sol.civilSunset)
            case .nautical:
                return (sol.nauticalSunrise, sol.nauticalSunset)
            default:
                return (sol.astronomicalSunrise, sol.astronomicalSunset)
            }
        }

        return (nil, nil)
    }

/*
    // MARK: - Location detection
    func startLocationDetection() {
        let locationManager = CLLocationManager()
        locationManager.delegate = self

        if CLLocationManager.locationServicesEnabled() {
            debugLog("Location services enabled")
            locationManager.startUpdatingLocation()
        } else {
            errorLog("Location services are disabled, please check your macOS settings!")
        }

        if #available(OSX 10.14, *) {
            locationManager.requestLocation()
        } else {
            // Fallback on earlier versions
        }
    }*/

}
/*
// MARK: - Core Location Delegates
extension TimeManagement: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        _ = locations[locations.count - 1]
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        errorLog("Location Manager error : \(error)")
    }
}*/
