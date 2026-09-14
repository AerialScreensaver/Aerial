//
//  Aerial4WallpaperPanel.swift
//  Aerial Companion
//
//  RETIRED (2026-06-12): no longer reachable — removed from the
//  Settings sidebar. The main controls (pause, skip) moved to the
//  Home dashboard's `DashboardSystemRow`; speed is unified with the
//  recap strip's speed card via `PlaybackManager.globalSpeed`.
//  Kept compiled to avoid pbxproj surgery; delete from Xcode at the
//  next project-file touch.
//
//  Settings panel for the new wallpaper-extension mode (Aerial 4).
//  Drives the Companion → wallpaper-extension control channel via
//  `WallpaperControl.shared`. The extension only acts on these
//  commands while Aerial 4 is the user's selected wallpaper in
//  System Settings → Wallpaper; otherwise file writes happen but
//  no rendering responds (acceptable for the beta).
//
//  This panel is intentionally separate from the legacy "Wallpaper"
//  settings panel (`DesktopSettingsPanel`) so we can iterate on the
//  new mode's controls without touching anything that drives the old
//  NSWindow-based wallpaper.
//

import AppKit
import SwiftUI

/// A row representing one display we can target with prev/next.
private struct DisplayRow: Identifiable {
    let id: String           // screenUUID (used as id)
    let name: String         // user-facing label
    let displayID: UInt32    // for diagnostics
}

struct Aerial4WallpaperPanel: View {
    @State private var speed: Double = 0.125
    @State private var paused: Bool = false
    @State private var displays: [DisplayRow] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Aerial 4 Wallpaper")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.bottom, 8)

                introSection
                pauseSection
                speedSection
                playbackSection

                Spacer()
            }
            .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            speed = WallpaperControl.shared.currentSpeed
            paused = WallpaperControl.shared.currentPaused
            refreshDisplays()
        }
    }

    // MARK: - Sections

    private var introSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Beta — Live wallpaper-extension controls", systemImage: "sparkles")
                .font(.headline)
                .foregroundColor(.aerial)
            Text("These controls drive the new Aerial 4 wallpaper extension. They take effect when Aerial 4 is set as your wallpaper in System Settings → Wallpaper. The legacy wallpaper mode (Wallpaper panel) is unaffected by these settings.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color.aerial.opacity(0.08))
        .cornerRadius(8)
    }

    private var pauseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playback")
                .font(.system(size: 18, weight: .semibold))

            HStack(spacing: 12) {
                Button {
                    paused.toggle()
                    WallpaperControl.shared.setPaused(paused)
                } label: {
                    Label(paused ? "Resume" : "Pause",
                          systemImage: paused ? "play.fill" : "pause.fill")
                        .frame(minWidth: 80)
                }
                .controlSize(.large)
                .keyboardShortcut(" ", modifiers: [])

                Text(paused ? "Wallpaper is paused" : "Wallpaper is playing")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Text("Pause stops every Aerial 4 renderer (timebase rate 0). Resume restores the configured speed. Pause is global — the toggle affects all displays.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playback Speed")
                .font(.system(size: 18, weight: .semibold))

            HStack {
                Slider(value: $speed, in: 0.05 ... 1.0, step: 0.05)
                    .onChange(of: speed) { _, newValue in
                        WallpaperControl.shared.setSpeed(newValue)
                    }
                    .frame(maxWidth: 360)
                Text(String(format: "%.2f×", speed))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }

            HStack(spacing: 16) {
                Button("0.125× (default)") {
                    speed = 0.125
                    WallpaperControl.shared.setSpeed(0.125)
                }
                Button("0.5×") {
                    speed = 0.5
                    WallpaperControl.shared.setSpeed(0.5)
                }
                Button("1.0× (native)") {
                    speed = 1.0
                    WallpaperControl.shared.setSpeed(1.0)
                }
            }
            .controlSize(.small)

            Text("Global rate applied to every Aerial 4 renderer. Defaults to 0.125× — Aerial videos are designed to play slowed-down.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Skip Video")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button {
                    refreshDisplays()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }

            // "All screens" row.
            controlRow(name: "All screens", subtitle: "All connected displays", screenUUID: nil)

            // Per-display rows.
            ForEach(displays) { d in
                controlRow(
                    name: d.name,
                    subtitle: "did=\(d.displayID) · \(d.id.prefix(8))…",
                    screenUUID: d.id,
                )
            }

            Text("Skips take effect immediately on the next frame boundary. If Aerial 4 isn't currently the selected wallpaper, the click is logged but has no visible effect.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func controlRow(name: String, subtitle: String, screenUUID: String?) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                WallpaperControl.shared.regressVideo(screenUUID: screenUUID)
            } label: {
                Label("Previous", systemImage: "backward.fill")
            }
            .controlSize(.small)
            Button {
                WallpaperControl.shared.advanceVideo(screenUUID: screenUUID)
            } label: {
                Label("Next", systemImage: "forward.fill")
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Helpers

    private func refreshDisplays() {
        var rows: [DisplayRow] = []
        for screen in NSScreen.screens {
            let did = screen.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            guard did != 0,
                  let cfUUID = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue()
            else { continue }
            let uuid = CFUUIDCreateString(nil, cfUUID) as String
            rows.append(DisplayRow(id: uuid, name: screen.localizedName, displayID: did))
        }
        displays = rows
    }
}

#if DEBUG
struct Aerial4WallpaperPanel_Previews: PreviewProvider {
    static var previews: some View {
        Aerial4WallpaperPanel().frame(width: 720, height: 600)
    }
}
#endif
