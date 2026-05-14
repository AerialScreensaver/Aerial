//
//  WeatherCacheKeyTests.swift
//  AerialTests
//
//  Tests for WeatherLocationSource.cacheKey deduplication
//  and WeatherCache.isFresh time logic.
//

import Testing
import Foundation
@testable import Aerial

@Suite("Weather Cache Keys")
struct WeatherCacheKeyTests {

    // MARK: - cacheKey

    @Test("Coordinates round to 2 decimal places")
    func coordinatesRounding() {
        let loc = WeatherLocationSource.coordinates(lat: 48.8566, lon: 2.3522)
        #expect(loc.cacheKey == "coords:48.86,2.35")
    }

    @Test("Same logical coordinates produce same key")
    func coordinatesSameKey() {
        let a = WeatherLocationSource.coordinates(lat: 48.856, lon: 2.352)
        let b = WeatherLocationSource.coordinates(lat: 48.8564, lon: 2.3519)
        #expect(a.cacheKey == b.cacheKey)
    }

    @Test("Different coordinates produce different keys")
    func coordinatesDifferentKey() {
        let a = WeatherLocationSource.coordinates(lat: 48.86, lon: 2.35)
        let b = WeatherLocationSource.coordinates(lat: 40.71, lon: -74.01)
        #expect(a.cacheKey != b.cacheKey)
    }

    @Test("Negative coordinates handled correctly")
    func negativeCoordinates() {
        let loc = WeatherLocationSource.coordinates(lat: -33.8688, lon: 151.2093)
        #expect(loc.cacheKey == "coords:-33.87,151.21")
    }

    @Test("City names are lowercased")
    func cityLowercase() {
        let a = WeatherLocationSource.city(name: "Paris")
        let b = WeatherLocationSource.city(name: "paris")
        #expect(a.cacheKey == b.cacheKey)
    }

    @Test("City names are trimmed")
    func cityTrimmed() {
        let a = WeatherLocationSource.city(name: "Paris")
        let b = WeatherLocationSource.city(name: "  Paris  ")
        #expect(a.cacheKey == b.cacheKey)
    }

    @Test("City key format is city:<name>")
    func cityKeyFormat() {
        let loc = WeatherLocationSource.city(name: "New York")
        #expect(loc.cacheKey == "city:new york")
    }

    // MARK: - isFresh (extracted static function)

    @Test("Fresh entry is within TTL")
    func isFreshWithinTTL() {
        let now = Date()
        let fetchedAt = now.addingTimeInterval(-60) // 1 min ago
        let fresh = WeatherCache.isFresh(fetchedAt: fetchedAt, ttl: WeatherCache.ttl, now: now)
        #expect(fresh == true)
    }

    @Test("Stale entry exceeds TTL")
    func isStaleExceedsTTL() {
        let now = Date()
        let fetchedAt = now.addingTimeInterval(-1000) // 16+ min ago
        let fresh = WeatherCache.isFresh(fetchedAt: fetchedAt, ttl: WeatherCache.ttl, now: now)
        #expect(fresh == false)
    }

    @Test("Nil fetchedAt is not fresh")
    func isNotFreshWhenNil() {
        let fresh = WeatherCache.isFresh(fetchedAt: nil, ttl: WeatherCache.ttl, now: Date())
        #expect(fresh == false)
    }

    @Test("Exact TTL boundary is not fresh")
    func exactTTLBoundary() {
        let now = Date()
        let fetchedAt = now.addingTimeInterval(-WeatherCache.ttl)
        let fresh = WeatherCache.isFresh(fetchedAt: fetchedAt, ttl: WeatherCache.ttl, now: now)
        #expect(fresh == false)
    }
}
