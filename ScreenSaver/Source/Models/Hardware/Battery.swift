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
        #if DEBUG
        switch simulationState {
        case .off: break
        case .onBattery, .onLowBattery: return true
        }
        #endif
        let estimate = IOPSGetTimeRemainingEstimate()
        let result = estimate != kIOPSTimeRemainingUnlimited
        debugLog("🔋 isUnplugged = \(result) (timeEstimate: \(estimate))")
        return result
    }

    static func isLow() -> Bool {
        #if DEBUG
        switch simulationState {
        case .off: break
        case .onBattery:    return false
        case .onLowBattery: return true
        }
        #endif
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

#if COMPANION_APP
import Foundation

/// Companion-only observer for power-source state changes.
/// Subscribes to IOKit's `IOPSNotificationCreateRunLoopSource` which
/// fires whenever the connected power source list, capacity, or any
/// other power-related field changes. The notification doesn't tell us
/// WHAT changed — consumers re-query `Battery.isUnplugged()` /
/// `Battery.isLow()` from the `onChange` callback.
///
/// Singleton so the run-loop source is added at most once per process.
final class BatteryStateMonitor {
    static let shared = BatteryStateMonitor()

    /// Fired on the main queue whenever any power-source field changes.
    /// Callers should re-query Battery.* to determine the new state.
    var onChange: (() -> Void)?

    private var runLoopSource: CFRunLoopSource?

    private init() {}

    func start() {
        guard runLoopSource == nil else { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx = ctx else { return }
            let monitor = Unmanaged<BatteryStateMonitor>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async {
                monitor.onChange?()
            }
        }

        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else {
            errorLog("🔋 BatteryStateMonitor: IOPSNotificationCreateRunLoopSource returned nil")
            return
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        debugLog("🔋 BatteryStateMonitor: started")
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
            debugLog("🔋 BatteryStateMonitor: stopped")
        }
    }
}
#endif

#if DEBUG
extension Battery {
    /// Debug-only simulated power-source state for testing
    /// pause-on-battery on Macs without a battery (Mac mini / Studio
    /// / Pro). Cycled by the "Cycle simulated battery state" global
    /// shortcut in Settings → Accessibility. Stripped from Release
    /// builds entirely (#if DEBUG).
    enum SimulationState {
        case off          // Use real IOPS
        case onBattery    // Pretend we're unplugged, not low
        case onLowBattery // Pretend we're unplugged AND <20%

        var label: String {
            switch self {
            case .off:           return "off (real hardware)"
            case .onBattery:     return "on battery"
            case .onLowBattery:  return "on battery, low (<20%)"
            }
        }
    }

    /// Current simulated state. `.off` means `isUnplugged()` and
    /// `isLow()` fall through to the normal IOPS path.
    static var simulationState: SimulationState = .off

    /// Cycle: off → onBattery → onLowBattery → off. Caller is
    /// responsible for triggering `PlaybackManager.evaluateBatteryState()`
    /// after cycling so the new state propagates immediately.
    static func cycleSimulationState() {
        switch simulationState {
        case .off:           simulationState = .onBattery
        case .onBattery:     simulationState = .onLowBattery
        case .onLowBattery:  simulationState = .off
        }
        debugLog("🔋 Battery simulation → \(simulationState.label)")
    }
}
#endif
