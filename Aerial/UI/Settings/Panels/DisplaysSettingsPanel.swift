//
//  DisplaysSettingsPanel.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 13/02/2026.
//

import SwiftUI

struct DisplaysSettingsPanel: View {
    @State private var displayMode: DisplayMode = .allDisplays
    @State private var viewingMode: ViewingMode = .independent
    @State private var aspectMode: AspectMode = .fill
    @State private var horizontalMargin: Double = 0
    @State private var verticalMargin: Double = 0
    @State private var displayMarginsAdvanced: Bool = false

    /// Per-display spanned offsets (cm), keyed by CGDirectDisplayID.
    /// Persisted as the `AdvancedMargin` JSON in
    /// `PrefsDisplays.advancedMargins` — see `writeAdvancedMargins()`.
    @State private var perDisplayOffsets: [CGDirectDisplayID: DisplayOffset] = [:]

    private struct DisplayOffset: Equatable {
        var horizontal: Double = 0
        var vertical: Double = 0
    }

    /// Row model for the per-display margin list.
    private struct AdvancedMarginRow: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        let isMain: Bool
    }

    // Changing this UUID forces the DisplayView to redraw
    @State private var displayViewRefresh = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Displays")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.bottom, 8)

                displayPreviewSection
                displaySettingsSection
                if viewingMode == .spanned {
                    marginsSection
                }

                Spacer()
            }
            .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear { loadSettings() }
    }

    // MARK: - Display Preview

    private var displayPreviewSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                DisplayPreviewView(refreshID: displayViewRefresh) {
                    displayViewRefresh = UUID()
                }
                .frame(height: 260)

                if displayMode == .selection {
                    Text("Click on a display to enable or disable it")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
        } label: {
            Label("Display Arrangement", systemImage: "display.2")
                .font(Font.title3.bold())
                .padding(4)
        }
    }

    // MARK: - Display Settings

    private var displaySettingsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Play videos on")
                        .font(.system(size: 14))
                    Spacer()
                    Picker("", selection: $displayMode) {
                        Text("All displays").tag(DisplayMode.allDisplays)
                        Text("Main display only").tag(DisplayMode.mainOnly)
                        Text("Secondary displays only").tag(DisplayMode.secondaryOnly)
                        Text("Selected displays").tag(DisplayMode.selection)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 220, alignment: .trailing)
                    .onChange(of: displayMode) { newValue in
                        PrefsDisplays.displayMode = newValue
                        DisplayDetection.sharedInstance.detectDisplays()
                        displayViewRefresh = UUID()
                        WallpaperControl.shared.displaysConfigDidChange()
                    }
                }

                Divider()

                HStack {
                    Text("Viewing mode")
                        .font(.system(size: 14))
                    Spacer()
                    Picker("", selection: $viewingMode) {
                        HStack(spacing: 8) {
                            Image(systemName: "display")
                            Text("Independent")
                        }.tag(ViewingMode.independent)
                        HStack(spacing: 8) {
                            Image(systemName: "rectangle.on.rectangle")
                            Text("Cloned")
                        }.tag(ViewingMode.cloned)
                        HStack(spacing: 8) {
                            Image(systemName: "rectangle.split.2x1")
                            Text("Spanned")
                        }.tag(ViewingMode.spanned)
                        HStack(spacing: 8) {
                            Image(systemName: "rectangle.2.swap")
                            Text("Mirrored")
                        }.tag(ViewingMode.mirrored)
                    }
                    .pickerStyle(.menu)
                    .accentColor(.aerial)
                    .frame(width: 220, alignment: .trailing)
                    .onChange(of: viewingMode) { newValue in
                        PrefsDisplays.viewingMode = newValue
                        displayViewRefresh = UUID()
                        WallpaperControl.shared.displaysConfigDidChange()
                    }
                }

                Divider()

                HStack {
                    Text("Aspect")
                        .font(.system(size: 14))
                    Spacer()
                    Picker("", selection: $aspectMode) {
                        HStack(spacing: 8) {
                            Image(systemName: "aspectratio.fill")
                            Text("Fill screen")
                        }.tag(AspectMode.fill)
                        HStack(spacing: 8) {
                            Image(systemName: "aspectratio")
                            Text("Fit to screen")
                        }.tag(AspectMode.fit)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 220, alignment: .trailing)
                    .onChange(of: aspectMode) { newValue in
                        PrefsDisplays.aspectMode = newValue
                        displayViewRefresh = UUID()
                        WallpaperControl.shared.displaysConfigDidChange()
                    }
                }
            }
            .padding(12)
        } label: {
            Label("Display Settings", systemImage: "rectangle.on.rectangle")
                .font(Font.title3.bold())
                .padding(4)
        }
    }

    // MARK: - Margins

    private var marginsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                // The advanced path bypasses the global margins entirely
                // (DisplayDetection uses the per-display offsets instead)
                // — grey them out so the UI tells the truth.
                Group {
                    HStack {
                        Text("Horizontal margin")
                            .font(.system(size: 14))
                        Spacer()
                        TextField("", value: $horizontalMargin, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .onChange(of: horizontalMargin) { newValue in
                                PrefsDisplays.horizontalMargin = newValue
                                displayViewRefresh = UUID()
                                WallpaperControl.shared.displaysConfigDidChange()
                            }
                        Text("cm")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Vertical margin")
                            .font(.system(size: 14))
                        Spacer()
                        TextField("", value: $verticalMargin, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .onChange(of: verticalMargin) { newValue in
                                PrefsDisplays.verticalMargin = newValue
                                displayViewRefresh = UUID()
                                WallpaperControl.shared.displaysConfigDidChange()
                            }
                        Text("cm")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(displayMarginsAdvanced)
                .opacity(displayMarginsAdvanced ? 0.5 : 1)

                Divider()

                Toggle("Advanced per-display margins", isOn: $displayMarginsAdvanced)
                    .font(.system(size: 14))
                    .onChange(of: displayMarginsAdvanced) { newValue in
                        PrefsDisplays.displayMarginsAdvanced = newValue
                        if newValue {
                            // Seed entries for every connected display so
                            // the engine's gate (non-empty displays array)
                            // matches what the UI shows.
                            writeAdvancedMargins()
                        } else {
                            // Keep the stored offsets for re-enabling;
                            // the pref alone gates the advanced path.
                            refreshAfterMarginChange()
                        }
                    }

                if displayMarginsAdvanced {
                    Text("Shifts where each display's slice sits in the spanned video — use it to compensate for bezels and physical alignment. Replaces the global margins above.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(advancedMarginRows) { row in
                        HStack(spacing: 8) {
                            Text(row.name + (row.isMain ? " (main)" : ""))
                                .font(.system(size: 13))
                                .lineLimit(1)
                            Spacer()
                            Text("H")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            TextField("", value: offsetBinding(for: row.id, \.horizontal), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 64)
                            Text("V")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            TextField("", value: offsetBinding(for: row.id, \.vertical), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 64)
                            Text("cm")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(12)
        } label: {
            Label("Margins", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                .font(Font.title3.bold())
                .padding(4)
        }
    }

    // MARK: - Per-display margins plumbing

    /// Connected displays, reading order (left→right, ties top-first).
    private var advancedMarginRows: [AdvancedMarginRow] {
        DisplayDetection.sharedInstance.screens
            .sorted {
                if $0.bottomLeftFrame.origin.x != $1.bottomLeftFrame.origin.x {
                    return $0.bottomLeftFrame.origin.x < $1.bottomLeftFrame.origin.x
                }
                return $0.bottomLeftFrame.origin.y > $1.bottomLeftFrame.origin.y
            }
            .map { screen in
                AdvancedMarginRow(id: screen.id, name: displayName(for: screen), isMain: screen.isMain)
            }
    }

    private func displayName(for screen: Screen) -> String {
        let nsScreen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == screen.id
        }
        return nsScreen?.localizedName ?? "Display (\(screen.width)×\(screen.height))"
    }

    private func offsetBinding(for id: CGDirectDisplayID, _ keyPath: WritableKeyPath<DisplayOffset, Double>) -> Binding<Double> {
        Binding(
            get: { perDisplayOffsets[id]?[keyPath: keyPath] ?? 0 },
            set: { newValue in
                var offset = perDisplayOffsets[id] ?? DisplayOffset()
                offset[keyPath: keyPath] = newValue
                perDisplayOffsets[id] = offset
                writeAdvancedMargins()
            }
        )
    }

    /// Rebuild + persist the AdvancedMargin JSON: one entry per connected
    /// display (identity = its global origin, what
    /// `findDisplayAdvancedMargins` matches on), keeping entries whose
    /// origin matches no live screen (a disconnected display's offsets
    /// survive until it returns).
    private func writeAdvancedMargins() {
        let detection = DisplayDetection.sharedInstance
        let live = detection.screens.map { screen -> DisplayAdvancedMargin in
            let offset = perDisplayOffsets[screen.id] ?? DisplayOffset()
            return DisplayAdvancedMargin(
                zleft: screen.bottomLeftFrame.origin.x,
                ztop: screen.bottomLeftFrame.origin.y,
                offsetleft: offset.horizontal,
                offsettop: offset.vertical
            )
        }
        let liveOrigins = detection.screens.map(\.bottomLeftFrame.origin)
        let disconnected = detection.advancedMargins.displays.filter { entry in
            !liveOrigins.contains { $0.x == entry.zleft && $0.y == entry.ztop }
        }
        detection.advancedMargins = AdvancedMargin(displays: live + disconnected)
        refreshAfterMarginChange()
    }

    /// The advanced zeroed origins are precomputed at detect time, so the
    /// arrangement preview is stale without a re-detect; the extension
    /// re-detects on its own via the settings-generation reconcile.
    private func refreshAfterMarginChange() {
        DisplayDetection.sharedInstance.detectDisplays()
        displayViewRefresh = UUID()
        WallpaperControl.shared.displaysConfigDidChange()
    }

    // MARK: - Load Settings

    private func loadSettings() {
        displayMode = PrefsDisplays.displayMode
        viewingMode = PrefsDisplays.viewingMode
        aspectMode = PrefsDisplays.aspectMode
        horizontalMargin = PrefsDisplays.horizontalMargin
        verticalMargin = PrefsDisplays.verticalMargin
        displayMarginsAdvanced = PrefsDisplays.displayMarginsAdvanced

        // Hydrate per-display offsets from the persisted JSON, matched
        // to connected screens by global origin.
        let detection = DisplayDetection.sharedInstance
        var offsets: [CGDirectDisplayID: DisplayOffset] = [:]
        for screen in detection.screens {
            if let entry = detection.findDisplayAdvancedMargins(
                posx: screen.bottomLeftFrame.origin.x,
                posy: screen.bottomLeftFrame.origin.y
            ) {
                offsets[screen.id] = DisplayOffset(
                    horizontal: Double(entry.offsetleft),
                    vertical: Double(entry.offsettop)
                )
            }
        }
        perDisplayOffsets = offsets
    }

}

// MARK: - Preview

struct DisplaysSettingsPanel_Previews: PreviewProvider {
    static var previews: some View {
        DisplaysSettingsPanel()
            .frame(width: 500, height: 700)
    }
}
