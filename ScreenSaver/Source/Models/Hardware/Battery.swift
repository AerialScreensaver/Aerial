//
//  Battery.swift
//  Aerial
//
//  Created by Guillaume Louel on 06/12/2019.
//

import Foundation
import IOKit.ps

struct Battery {

    // MARK: - Battery detection
    static func hasBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            debugLog("🔋 IOPSCopyPowerSourcesInfo returned nil")
            return false
        }
        guard let sources: NSArray = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() else {
            debugLog("🔋 IOPSCopyPowerSourcesList returned nil")
            return false
        }
        let result = sources.count > 0
        debugLog("🔋 hasBattery = \(result) (sources: \(sources.count))")
        return result
    }

    static func isUnplugged() -> Bool {
        let estimate = IOPSGetTimeRemainingEstimate()
        let result = estimate != kIOPSTimeRemainingUnlimited
        debugLog("🔋 isUnplugged = \(result) (timeEstimate: \(estimate))")
        return result
    }

    static func isLow() -> Bool {
        let batteryLevel = getRemainingPercent()

        if batteryLevel == 0 {
            return false
        }

        return batteryLevel < 20
    }

    static func getRemainingPercent() -> Int {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            debugLog("🔋 getRemainingPercent — no snapshot")
            return 0
        }

        guard let sources: NSArray = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() else {
            debugLog("🔋 getRemainingPercent — no sources list")
            return 0
        }

        // swiftlint:disable:next empty_count
        if sources.count > 0 {
            for ps in sources {
                guard let info: NSDictionary = IOPSGetPowerSourceDescription(snapshot, ps as CFTypeRef)?.takeUnretainedValue() else {
                    debugLog("🔋 getRemainingPercent — no description for source")
                    return 0
                }

                if let capacity = info[kIOPSCurrentCapacityKey] as? Int,
                    let max = info[kIOPSMaxCapacityKey] as? Int {
                    let percent = Int(Double(capacity)/Double(max)*100)
                    debugLog("🔋 getRemainingPercent = \(percent)% (\(capacity)/\(max))")
                    return percent
                }
            }
        }

        debugLog("🔋 getRemainingPercent — no sources found")
        return 0
    }
}
