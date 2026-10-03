//
//  TimeAdaptationCoordinator.swift
//  Aerial Companion
//
//  Single entry point for "the time-slice rule changed under a live
//  process": a time pref edited in Settings › Time or the Dashboard
//  (mode, "only night videos in Dark Mode", sun window, placement,
//  solar mode, manual sunrise/sunset), or the system appearance flipping
//  while the rule depends on Dark Mode.
//
//  Before this existed the handlers only wrote the pref and redrew the
//  time bar: the Video Browser kept its old slice grouping until an
//  unrelated playlist event, and the extension's load-once settings
//  cache kept filtering pops with the OLD mode until a respawn.
//
//  Also owns the Companion-side feed of `DarkMode` (the slice rule's
//  appearance mirror): the 3.x saver seeded it from its view at init, a
//  call lost in the appex migration that left Dark Mode permanently off
//  here. The extension feeds its own mirror from WallpaperAgent.
//
//  Companion-only module.
//

import AppKit

final class TimeAdaptationCoordinator {
    static let shared = TimeAdaptationCoordinator()

    /// Posted on the main thread after the rule may have changed. UI that
    /// groups or filters by slice (Video Browser "Now Playing", popover
    /// strip, Dashboard recap) re-reads `TimeManagement` on it.
    static let didChangeNotification = Notification.Name("com.glouel.aerial.timeSettingsDidChange")

    private var appearanceObservation: NSKeyValueObservation?
    private var started = false

    /// Seed the Dark Mode mirror and watch the app's effective appearance.
    /// Appearance flips refresh the Companion UI only — the extension
    /// learns the appearance from WallpaperAgent on its own.
    func start() {
        guard !started else { return }
        started = true

        DarkMode.update(isDark: Self.isDarkAppearance(NSApp.effectiveAppearance))
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] app, _ in
            guard DarkMode.update(isDark: Self.isDarkAppearance(app.effectiveAppearance)) else { return }
            self?.settingsDidChange(reason: "appearance", notifyExtension: false)
        }
    }

    /// A time pref changed (or the appearance flipped). Recompute the
    /// Companion's solar state, refresh the UI, and bump the extension's
    /// `timeSettingsGeneration` so its pops follow the new rule.
    func settingsDidChange(reason: String, notifyExtension: Bool = true) {
        TimeManagement.sharedInstance.refreshAfterSettingsChange()
        let (restricted, slice) = TimeManagement.sharedInstance.shouldRestrictPlaybackToDayNightVideo()
        debugLog("🌗 time settings changed (\(reason)) → slice=\(restricted ? slice : "none")")

        let post = { NotificationCenter.default.post(name: Self.didChangeNotification, object: nil) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }

        if notifyExtension {
            WallpaperControl.shared.timeSettingsDidChange()
        }
    }

    private static func isDarkAppearance(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
