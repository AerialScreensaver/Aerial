//
//  SparkleGentleDelegate.swift
//  Aerial
//
//  Implements Sparkle "gentle reminders" for background/menu-bar apps.
//  When a scheduled update is found, we surface it via dock badge,
//  status-bar icon change, and a user notification — instead of
//  popping a modal behind the active window.
//

import Cocoa
import Sparkle
import UserNotifications

final class SparkleGentleDelegate: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {

    @Published var updateAvailable: Bool = false
    @Published var immediateInstallHandler: (() -> Void)?

    var supportsGentleScheduledUpdateReminders: Bool { true }

    // Return false when not in immediate focus so the delegate handles
    // showing the update via gentle reminders instead of a modal alert.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        return immediateFocus
    }

    // Called right before the update UI is shown. When handleShowingUpdate
    // is false (we declined above), we set up gentle reminder indicators.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // Always flag that an update exists (for the popover bar)
        updateAvailable = true

        guard !handleShowingUpdate else { return }

        // Show the app in the Dock so a badge is visible
        NSApp.setActivationPolicy(.regular)
        NSApp.dockTile.badgeLabel = "1"

        // Change menu-bar icon to attention state
        AppDelegate.shared?.setIcon(mode: .notification)

        // Post a user notification
        requestNotification(
            title: "Aerial Update Available",
            body: "A new version of Aerial is ready to install."
        )
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        // User is looking at the Sparkle update dialog — clear intrusive
        // indicators (dock badge, notification) but keep updateAvailable
        // and the menu bar dot in case they dismiss without updating.
        NSApp.dockTile.badgeLabel = ""
        NSApp.setActivationPolicy(.accessory)
        AppDelegate.shared?.setIcon(mode: .notification)
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ["aerial-update-available"]
        )
    }

    func standardUserDriverWillFinishUpdateSession() {
        // Session ended (user dismissed or update started).
        // Keep updateAvailable and menu bar dot so the popover bar
        // persists if they chose "Remind me later".
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let mode = UserDefaults.standard.string(forKey: "autoInstallMode") ?? AutoInstallMode.off.rawValue
        if mode == AutoInstallMode.immediately.rawValue {
            self.immediateInstallHandler = immediateInstallHandler
            updateAvailable = true
            AppDelegate.shared?.setIcon(mode: .notification)
            // Call it right away for fully automatic behavior
            immediateInstallHandler()
            return true
        }
        // Install on quit — let Sparkle handle it
        return false
    }

    // MARK: - Helpers

    private func requestNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: "aerial-update-available",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }
}
