//
//  SolarSlicePropertyTests.swift
//  AerialTests
//
//  Property tests for the solar calculator and the sunrise/sunset slice
//  boundaries. Random coordinates over the whole globe (poles included),
//  random dates over 130 years, random windows and placements — the
//  code must never trap, must reject invalid coordinates, and the
//  time-of-day slices must come out in day order.
//

import CoreLocation
import Foundation
import Testing
@testable import Aerial

@Suite("Solar and time-slice properties")
struct SolarSlicePropertyTests {
    private static let order = ["night", "sunrise", "day", "sunset", "night"]

    private func randomDate(_ rng: inout SeededGenerator) -> Date {
        Date(timeIntervalSince1970: rng.double(0...4_102_444_800))   // 1970 … 2100
    }

    @Test("Solar never traps anywhere on the globe; every event lands within two days of the input")
    func solarNeverTraps() {
        forAll(iterations: 300) { rng, _ in
            let latitude = rng.bool(probability: 0.15) ? [90.0, -90.0, 89.9, -89.9, 66.6, -66.6, 0.0].randomElement(using: &rng)! : rng.double(-90...90)
            let longitude = rng.bool(probability: 0.15) ? [180.0, -180.0, 0.0, 179.99].randomElement(using: &rng)! : rng.double(-180...180)
            let date = randomDate(&rng)
            guard let solar = Solar(for: date, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) else {
                Issue.record("\(rng.trail) valid coordinate rejected: \(latitude),\(longitude)")
                return
            }
            let events = [solar.sunrise, solar.sunset, solar.civilSunrise, solar.civilSunset,
                          solar.strictSunrise, solar.strictSunset, solar.nauticalSunrise, solar.nauticalSunset,
                          solar.astronomicalSunrise, solar.astronomicalSunset]
            for event in events.compactMap({ $0 }) {
                #expect(abs(event.timeIntervalSince(date)) < 48 * 3600, "\(rng.trail) lat=\(latitude) lon=\(longitude) date=\(date) event=\(event)")
            }
            for mode in [SolarMode.strict, .official, .civil, .nautical, .astronomical] {
                _ = solar.sunriseSunset(for: mode)
            }
        }
    }

    @Test("invalid coordinates are rejected, not computed", arguments: [
        (91.0, 0.0), (-91.0, 0.0), (0.0, 181.0), (0.0, -181.0), (Double.nan, 0.0), (0.0, Double.infinity), (1e300, 1e300),
    ])
    func invalidCoordinatesRejected(latitude: Double, longitude: Double) {
        #expect(Solar(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) == nil)
    }

    @Test("mid-latitudes: a wider zenith means an earlier sunrise and a later sunset")
    func zenithOrdering() {
        forAll(iterations: 300) { rng, _ in
            let coordinate = CLLocationCoordinate2D(latitude: rng.double(-50...50), longitude: rng.double(-180...180))
            let date = randomDate(&rng)
            guard let solar = Solar(for: date, coordinate: coordinate) else { return }
            guard let strictRise = solar.strictSunrise, let rise = solar.sunrise, let civilRise = solar.civilSunrise,
                  let nauticalRise = solar.nauticalSunrise, let astroRise = solar.astronomicalSunrise,
                  let strictSet = solar.strictSunset, let set = solar.sunset, let civilSet = solar.civilSunset,
                  let nauticalSet = solar.nauticalSunset, let astroSet = solar.astronomicalSunset else { return }
            let context = "\(rng.trail) lat=\(coordinate.latitude) lon=\(coordinate.longitude) date=\(date)"
            #expect(astroRise <= nauticalRise && nauticalRise <= civilRise && civilRise <= rise && rise <= strictRise, "\(context) sunrise order")
            #expect(strictSet <= set && set <= civilSet && civilSet <= nauticalSet && nauticalSet <= astroSet, "\(context) sunset order")
            #expect(rise < set, "\(context) sunrise after sunset")
        }
    }

    /// Consecutive-duplicate-free `slices` must read as a subsequence of night→sunrise→day→sunset→night.
    private func isDayOrdered(_ slices: [String]) -> Bool {
        var cursor = 0
        for slice in slices {
            guard let next = Self.order[cursor...].firstIndex(of: slice) else { return false }
            cursor = next
        }
        return true
    }

    @Test("slice boundaries partition the day in order, and nextTransition always moves forward")
    func slicesAreDayOrdered() {
        forAll(iterations: 500) { rng, _ in
            let sunrise = randomDate(&rng)
            let sunset = sunrise.addingTimeInterval(rng.double(600...20 * 3600))
            let window = rng.double(0...6 * 3600)
            let placement: SunWindowPlacement = rng.bool() ? .daylight : .centered
            let bounds = SunSliceBoundaries(sunrise: sunrise, sunset: sunset, window: window, placement: placement)

            var slices: [String] = []
            var lastTransition = Date.distantPast
            let start = bounds.sunriseStart.addingTimeInterval(-2 * 3600)
            let span = bounds.sunsetEnd.timeIntervalSince(start) + 2 * 3600
            for step in 0...120 {
                let t = start.addingTimeInterval(span * Double(step) / 120)
                let slice = bounds.slice(at: t)
                #expect(Self.order.contains(slice), "\(rng.trail) unknown slice \(slice)")
                if slices.last != slice { slices.append(slice) }
                let transition = bounds.nextTransition(after: t)
                #expect(transition > t, "\(rng.trail) nextTransition not after t")
                #expect(transition >= lastTransition, "\(rng.trail) nextTransition went backwards")
                lastTransition = transition
            }
            #expect(isDayOrdered(slices), "\(rng.trail) window=\(window) placement=\(placement) slices=\(slices)")
            #expect(slices.first == "night" && slices.last == "night", "\(rng.trail) slices=\(slices)")
        }
    }
}
