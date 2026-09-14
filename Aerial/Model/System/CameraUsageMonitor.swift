//
//  CameraUsageMonitor.swift
//  Aerial
//
//  Watches whether ANY camera device is in use system-wide, via
//  CoreMediaIO's kCMIODevicePropertyDeviceIsRunningSomewhere. This
//  reads device STATE only — no capture session, no frames, and no TCC
//  camera permission prompt. Event-driven through CMIO property
//  listeners (per-device running state + the system device list for
//  plug/unplug); nothing polls.
//
//  Listeners are only registered while the "pause on camera" pref is
//  on (PlaybackManager starts/stops the monitor with the pref).
//

import CoreMediaIO
import Foundation

final class CameraUsageMonitor {
    static let shared = CameraUsageMonitor()

    /// Fired on the main queue whenever `anyCameraInUse` may have
    /// changed (consumers re-read the property).
    var onChange: (() -> Void)?

    private(set) var anyCameraInUse = false

    private var started = false
    /// Devices we hold a running-state listener on.
    private var watchedDevices: [CMIOObjectID] = []
    private var deviceListListener: CMIOObjectPropertyListenerBlock?
    private var runningListener: CMIOObjectPropertyListenerBlock?

    private init() {}

    // MARK: - Lifecycle (main queue)

    func start() {
        guard !started else { return }
        started = true

        // React to camera plug/unplug by re-subscribing to the new list.
        var devicesAddress = Self.devicesAddress
        let listListener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebuildDeviceListeners()
            self?.refresh()
        }
        deviceListListener = listListener
        CMIOObjectAddPropertyListenerBlock(
            CMIOObjectID(kCMIOObjectSystemObject), &devicesAddress, .main, listListener
        )

        rebuildDeviceListeners()
        refresh()
        debugLog("📷 CameraUsageMonitor started (\(watchedDevices.count) device(s))")
    }

    func stop() {
        guard started else { return }
        started = false

        var devicesAddress = Self.devicesAddress
        if let listListener = deviceListListener {
            CMIOObjectRemovePropertyListenerBlock(
                CMIOObjectID(kCMIOObjectSystemObject), &devicesAddress, .main, listListener
            )
            deviceListListener = nil
        }
        removeDeviceListeners()
        anyCameraInUse = false
        debugLog("📷 CameraUsageMonitor stopped")
    }

    // MARK: - Device listeners

    private func rebuildDeviceListeners() {
        removeDeviceListeners()

        let devices = Self.allDevices()
        var runningAddress = Self.runningAddress
        let listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refresh()
        }
        runningListener = listener
        for device in devices {
            CMIOObjectAddPropertyListenerBlock(device, &runningAddress, .main, listener)
        }
        watchedDevices = devices
    }

    private func removeDeviceListeners() {
        guard let listener = runningListener else {
            watchedDevices = []
            return
        }
        var runningAddress = Self.runningAddress
        for device in watchedDevices {
            CMIOObjectRemovePropertyListenerBlock(device, &runningAddress, .main, listener)
        }
        watchedDevices = []
        runningListener = nil
    }

    private func refresh() {
        let inUse = watchedDevices.contains { Self.isRunningSomewhere($0) }
        guard inUse != anyCameraInUse else { return }
        anyCameraInUse = inUse
        debugLog("📷 camera in use → \(inUse)")
        onChange?()
    }

    // MARK: - CMIO plumbing

    private static var devicesAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )

    private static var runningAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
    )

    private static func allDevices() -> [CMIOObjectID] {
        var address = devicesAddress
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize
        ) == kCMIOHardwareNoError, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, dataSize, &dataUsed, &devices
        ) == kCMIOHardwareNoError else { return [] }
        return devices
    }

    private static func isRunningSomewhere(_ device: CMIOObjectID) -> Bool {
        var address = runningAddress
        guard CMIOObjectHasProperty(device, &address) else { return false }
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == kCMIOHardwareNoError,
              dataSize > 0 else { return false }
        var value: UInt32 = 0
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, dataSize, &dataUsed, &value) == kCMIOHardwareNoError
        else { return false }
        return value != 0
    }
}
