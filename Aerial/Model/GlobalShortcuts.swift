//
//  GlobalShortcuts.swift
//  Aerial Companion
//
//  System-wide hotkeys for the three core playback actions —
//  toggle pause, previous video, next video — that work even when
//  Aerial isn't focused. Implementation is deliberately thin:
//  Sindre Sorhus's `KeyboardShortcuts` package handles registration,
//  persistence and the recorder UI; we just wire the actions.
//
//  Master switch is `Preferences.globalShortcutsEnabled` (defaults
//  to `false`). Default key combos are four-modifier presses
//  (⌃⌥⌘ + Space / ← / →) so the feature can ship "on with sane
//  defaults" without trampling other apps' shortcuts when the user
//  flips the toggle.
//

import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let togglePause = Self(
        "aerialTogglePause",
        default: .init(.space, modifiers: [.control, .option, .command])
    )
    static let previousVideo = Self(
        "aerialPreviousVideo",
        default: .init(.leftArrow, modifiers: [.control, .option, .command])
    )
    static let nextVideo = Self(
        "aerialNextVideo",
        default: .init(.rightArrow, modifiers: [.control, .option, .command])
    )
    /// Toggle fullscreen mode on the currently active screen. Default
    /// is F15 with no modifiers — uncommon enough on modern keyboards
    /// that it shouldn't trample other apps' shortcuts.
    static let toggleFullscreen = Self(
        "aerialToggleFullscreen",
        default: .init(.f15)
    )
}

enum GlobalShortcutsManager {
    /// Brings the registered handlers in line with the master pref.
    /// Idempotent — call from launch and from the toggle's onChange.
    /// Must be called on the main thread (AppKit launch + SwiftUI
    /// onChange both satisfy that).
    static func refresh() {
        // Always remove first so a re-register doesn't double-fire.
        KeyboardShortcuts.removeAllHandlers()
        guard Preferences.globalShortcutsEnabled else { return }

        // KeyboardShortcuts hands us non-isolated closures; the
        // PlaybackManager helpers we call are MainActor-isolated, so
        // hop onto main explicitly.
        KeyboardShortcuts.onKeyDown(for: .togglePause) {
            Task { @MainActor in PlaybackManager.shared.togglePause() }
        }
        KeyboardShortcuts.onKeyDown(for: .previousVideo) {
            Task { @MainActor in PlaybackManager.shared.previousVideo() }
        }
        KeyboardShortcuts.onKeyDown(for: .nextVideo) {
            Task { @MainActor in PlaybackManager.shared.nextVideo() }
        }
        KeyboardShortcuts.onKeyDown(for: .toggleFullscreen) {
            Task { @MainActor in PlaybackManager.shared.toggleFullscreen() }
        }
    }
}
