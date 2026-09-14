//
//  Solar.swift
//  SolarExample
//
//  Created by Chris Howell on 16/01/2016.
//  Copyright © 2016 Chris Howell. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the “Software”), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//
//  Modifications for Aerial/glouel
//      26/10/2018: - added an intermediate mode that's closer to night shift sunset/sunrise times
//                  - added a isDaylight(zenith: Zenith) function

import Foundation
import CoreLocation

public struct Solar {

    /// The coordinate that is used for the calculation
    public let coordinate: CLLocationCoordinate2D

    /// The date to generate sunrise / sunset times for
    public fileprivate(set) var date: Date

    public fileprivate(set) var sunrise: Date?
    public fileprivate(set) var sunset: Date?
    public fileprivate(set) var civilSunrise: Date?
    public fileprivate(set) var civilSunset: Date?
    public fileprivate(set) var strictSunrise: Date?
    public fileprivate(set) var strictSunset: Date?
    public fileprivate(set) var nauticalSunrise: Date?
    public fileprivate(set) var nauticalSunset: Date?
    public fileprivate(set) var astronomicalSunrise: Date?
    public fileprivate(set) var astronomicalSunset: Date?

    // MARK: Init

    public init?(for date: Date = Date(), coordinate: CLLocationCoordinate2D) {
        self.date = date

        guard CLLocationCoordinate2DIsValid(coordinate) else {
            return nil
        }

        self.coordinate = coordinate

        // Fill this Solar object with relevant data
        calculate()
    }

    // MARK: - Public functions

    /// Sets all of the Solar object's sunrise / sunset variables, if possible.
    /// - Note: Can return `nil` objects if sunrise / sunset does not occur on that day.
    public mutating func calculate() {
        strictSunrise = calculate(.sunrise, for: date, and: .strict)
        strictSunset = calculate(.sunset, for: date, and: .strict)
        sunrise = calculate(.sunrise, for: date, and: .official)
        sunset = calculate(.sunset, for: date, and: .official)
        civilSunrise = calculate(.sunrise, for: date, and: .civil)
        civilSunset = calculate(.sunset, for: date, and: .civil)
        nauticalSunrise = calculate(.sunrise, for: date, and: .nautical)
        nauticalSunset = calculate(.sunset, for: date, and: .nautical)
        astronomicalSunrise = calculate(.sunrise, for: date, and: .astronimical)
        astronomicalSunset = calculate(.sunset, for: date, and: .astronimical)
    }

    // MARK: - Private functions

    fileprivate enum SunriseSunset {
        case sunrise
        case sunset
    }

    /// Used for generating several of the possible sunrise / sunset times
    public enum Zenith: Double {
        case strict = 90
        case official = 90.83
        case civil = 96
        case nautical = 102
        case astronimical = 108
    }

    // swiftlint:disable identifier_name
    fileprivate func calculate(_ sunriseSunset: SunriseSunset, for date: Date, and zenith: Zenith) -> Date? {
        guard let utcTimezone = TimeZone(identifier: "UTC") else { return nil }

        // Get the day of the year — anchored to the LOCAL calendar day of
        // `date`, not the UTC day. West of Greenwich the UTC day rolls over
        // during the evening (5 PM in UTC-7), which made us compute
        // *tomorrow's* sunrise/sunset and report "night" for the rest of
        // the evening; far-eastern zones got *yesterday's* all morning.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcTimezone
        let localDay = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let dayAnchor = calendar.date(from: localDay) else { return nil }
        guard let dayInt = calendar.ordinality(of: .day, in: .year, for: dayAnchor) else { return nil }
        let day = Double(dayInt)

        // Convert longitude to hour value and calculate an approx. time
        let lngHour = coordinate.longitude / 15

        let hourTime: Double = sunriseSunset == .sunrise ? 6 : 18
        let t = day + ((hourTime - lngHour) / 24)

        // Calculate the suns mean anomaly
        let M = (0.9856 * t) - 3.289

        // Calculate the sun's true longitude
        let subexpression1 = 1.916 * sin(M.degreesToRadians)
        let subexpression2 = 0.020 * sin(2 * M.degreesToRadians)
        var L = M + subexpression1 + subexpression2 + 282.634

        // Normalise L into [0, 360] range
        L = normalise(L, withMaximum: 360)

        // Calculate the Sun's right ascension
        var RA = atan(0.91764 * tan(L.degreesToRadians)).radiansToDegrees

        // Normalise RA into [0, 360] range
        RA = normalise(RA, withMaximum: 360)

        // Right ascension value needs to be in the same quadrant as L...
        let Lquadrant = floor(L / 90) * 90
        let RAquadrant = floor(RA / 90) * 90
        RA += (Lquadrant - RAquadrant)

        // Convert RA into hours
        RA /= 15

        // Calculate Sun's declination
        let sinDec = 0.39782 * sin(L.degreesToRadians)
        let cosDec = cos(asin(sinDec))

        // Calculate the Sun's local hour angle
        let cosH = (cos(zenith.rawValue.degreesToRadians) - (sinDec * sin(coordinate.latitude.degreesToRadians))) / (cosDec * cos(coordinate.latitude.degreesToRadians))

        // No sunrise
        guard cosH < 1 else {
            return nil
        }

        // No sunset
        guard cosH > -1 else {
            return nil
        }

        // Finish calculating H and convert into hours
        let tempH = sunriseSunset == .sunrise ? 360 - acos(cosH).radiansToDegrees : acos(cosH).radiansToDegrees
        let H = tempH / 15.0

        // Calculate local mean time of rising
        let T = H + RA - (0.06571 * t) - 6.622

        // Adjust time back to UTC
        var UT = T - lngHour

        // Normalise UT into [0, 24] range
        UT = normalise(UT, withMaximum: 24)

        // Calculate all of the sunrise's / sunset's date components
        let hour = floor(UT)
        let minute = floor((UT - hour) * 60.0)
        let second = (((UT - hour) * 60) - minute) * 60.0

        let shouldBeYesterday = lngHour > 0 && UT > 12 && sunriseSunset == .sunrise
        let shouldBeTomorrow = lngHour < 0 && UT < 12 && sunriseSunset == .sunset

        let setDate: Date
        if shouldBeYesterday {
            setDate = Date(timeInterval: -(60 * 60 * 24), since: dayAnchor)
        } else if shouldBeTomorrow {
            setDate = Date(timeInterval: (60 * 60 * 24), since: dayAnchor)
        } else {
            setDate = dayAnchor
        }

        var components = calendar.dateComponents([.day, .month, .year], from: setDate)
        components.hour = Int(hour)
        components.minute = Int(minute)
        components.second = Int(second)

        calendar.timeZone = utcTimezone
        return calendar.date(from: components)
    }
    // swiftlint:enable identifier_name

    /// Normalises a value between 0 and `maximum`, by adding or subtracting `maximum`
    fileprivate func normalise(_ value: Double, withMaximum maximum: Double) -> Double {
        var value = value

        if value < 0 {
            value += maximum
        }

        if value > maximum {
            value -= maximum
        }

        return value
    }

}

extension Solar {

    /// Whether the location specified by the `latitude` and `longitude` is in daytime on `date`
    /// - Complexity: O(1)
    public var isDaytime: Bool {
        guard
            let sunrise = sunrise,
            let sunset = sunset
            else {
                return false
        }

        let beginningOfDay = sunrise.timeIntervalSince1970
        let endOfDay = sunset.timeIntervalSince1970
        let currentTime = self.date.timeIntervalSince1970

        let isSunriseOrLater = currentTime >= beginningOfDay
        let isBeforeSunset = currentTime < endOfDay

        return isSunriseOrLater && isBeforeSunset
    }

    /// Whether the location specified by the `latitude` and `longitude` is in nighttime on `date`
    /// - Complexity: O(1)
    public var isNighttime: Bool {
        return !isDaytime
    }

    /// Whether the location specified by the `latitude` and `longitude` is in daytime on `date`
    /// Takes an extra Zenith parameter to handle all cases
    /// - Complexity: O(1)
    public func isDaytime(zenith: Zenith) -> Bool {
        guard
            let _ = sunrise,
            let _ = sunset
            else {
                return false
        }

        var lsunrise, lsunset: Date
        switch zenith {
        case .strict:
            lsunrise = strictSunrise!
            lsunset = strictSunset!
        case .civil:
            lsunrise = civilSunrise!
            lsunset = civilSunset!
        case .nautical:
            lsunrise = nauticalSunrise!
            lsunset = nauticalSunset!
        case .astronimical:
            lsunrise = astronomicalSunrise!
            lsunset = astronomicalSunset!
        default:
            lsunrise = sunrise!
            lsunset = sunset!
        }

        let beginningOfDay = lsunrise.timeIntervalSince1970
        let endOfDay = lsunset.timeIntervalSince1970
        let currentTime = self.date.timeIntervalSince1970

        let isSunriseOrLater = currentTime >= beginningOfDay
        let isBeforeSunset = currentTime < endOfDay

        return isSunriseOrLater && isBeforeSunset
    }

    /// Sunrise/sunset pair for the given calculation mode, cascading toward
    /// less extreme zeniths when the chosen twilight doesn't occur at this
    /// latitude/date (e.g. no astronomical night in high-latitude summer).
    func sunriseSunset(for mode: SolarMode) -> (sunrise: Date, sunset: Date)? {
        let cascade: [SolarMode]
        switch mode {
        case .astronomical: cascade = [.astronomical, .nautical, .civil, .official]
        case .nautical: cascade = [.nautical, .civil, .official]
        case .civil: cascade = [.civil, .official]
        case .official: cascade = [.official]
        case .strict: cascade = [.strict, .official]
        }

        for candidate in cascade {
            switch candidate {
            case .strict:
                if let a = strictSunrise, let b = strictSunset { return (a, b) }
            case .official:
                if let a = sunrise, let b = sunset { return (a, b) }
            case .civil:
                if let a = civilSunrise, let b = civilSunset { return (a, b) }
            case .nautical:
                if let a = nauticalSunrise, let b = nauticalSunset { return (a, b) }
            case .astronomical:
                if let a = astronomicalSunrise, let b = astronomicalSunset { return (a, b) }
            }
        }
        return nil
    }

    public func getTimeSlice() -> String {
        guard let (lsunrise, lsunset) = sunriseSunset(for: PrefsTime.solarMode) else {
            return ""
        }

        return SunSliceBoundaries(sunrise: lsunrise, sunset: lsunset).slice(at: self.date)
    }
}

// MARK: - Slice boundaries (Aerial)

/// The four boundary instants that carve a day into night/sunrise/day/sunset
/// slices, derived from sunrise/sunset plus the window prefs. Placement
/// decides where the window sits relative to the event: `.daylight` keeps it
/// inside the day (sunrise period right after sunrise, sunset period right
/// before sunset), `.centered` splits it half before, half after.
struct SunSliceBoundaries {
    let sunriseStart: Date
    let sunriseEnd: Date
    let sunsetStart: Date
    let sunsetEnd: Date

    init(sunrise: Date, sunset: Date, window: TimeInterval, placement: SunWindowPlacement) {
        switch placement {
        case .daylight:
            sunriseStart = sunrise
            sunriseEnd = sunrise.addingTimeInterval(window)
            sunsetStart = sunset.addingTimeInterval(-window)
            sunsetEnd = sunset
        case .centered:
            sunriseStart = sunrise.addingTimeInterval(-window / 2)
            sunriseEnd = sunrise.addingTimeInterval(window / 2)
            sunsetStart = sunset.addingTimeInterval(-window / 2)
            sunsetEnd = sunset.addingTimeInterval(window / 2)
        }
    }

    init(sunrise: Date, sunset: Date) {
        self.init(sunrise: sunrise,
                  sunset: sunset,
                  window: TimeInterval(PrefsTime.sunEventWindow),
                  placement: PrefsTime.sunWindowPlacement)
    }

    /// Same precedence as the historical checks: night → sunrise → sunset → day.
    func slice(at date: Date) -> String {
        if date < sunriseStart || date > sunsetEnd {
            return "night"
        } else if date < sunriseEnd {
            return "sunrise"
        } else if date >= sunsetStart {
            return "sunset"
        } else {
            return "day"
        }
    }

    /// The next boundary after `date`; past the last one, tomorrow's sunrise start.
    func nextTransition(after date: Date) -> Date {
        if date < sunriseStart { return sunriseStart }
        if date < sunriseEnd { return sunriseEnd }
        if date < sunsetStart { return sunsetStart }
        if date < sunsetEnd { return sunsetEnd }
        // Past every boundary of this solar day: the next one is tomorrow's
        // sunrise window. A long day plus its window can span more than
        // 24 h (high latitudes in summer), in which case one day forward
        // is still behind `date` — step whole days until it is not, so the
        // result is always strictly in the future.
        let day: TimeInterval = 24 * 60 * 60
        let tomorrow = sunriseStart.addingTimeInterval(day)
        let behind = date.timeIntervalSince(tomorrow)
        guard behind >= 0 else { return tomorrow }
        return tomorrow.addingTimeInterval((floor(behind / day) + 1) * day)
    }
}

// MARK: - Helper extensions

private extension Double {
    var degreesToRadians: Double {
        return Double(self) * (Double.pi / 180.0)
    }

    var radiansToDegrees: Double {
        return (Double(self) * 180.0) / Double.pi
    }
}
