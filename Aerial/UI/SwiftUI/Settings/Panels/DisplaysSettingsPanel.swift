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
    @State private var advancedMargins: String = ""

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
                        }
                    Text("cm")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }

                Divider()

                Toggle("Advanced per-display margins", isOn: $displayMarginsAdvanced)
                    .font(.system(size: 14))
                    .onChange(of: displayMarginsAdvanced) { newValue in
                        PrefsDisplays.displayMarginsAdvanced = newValue
                    }

                if displayMarginsAdvanced {
                    TextField("Format: top,left,bottom,right per display (semicolon-separated)", text: $advancedMargins)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .onChange(of: advancedMargins) { newValue in
                            PrefsDisplays.advancedMargins = newValue
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

    // MARK: - Load Settings

    private func loadSettings() {
        displayMode = PrefsDisplays.displayMode
        viewingMode = PrefsDisplays.viewingMode
        aspectMode = PrefsDisplays.aspectMode
        horizontalMargin = PrefsDisplays.horizontalMargin
        verticalMargin = PrefsDisplays.verticalMargin
        displayMarginsAdvanced = PrefsDisplays.displayMarginsAdvanced
        advancedMargins = PrefsDisplays.advancedMargins
    }

}

// MARK: - Preview

struct DisplaysSettingsPanel_Previews: PreviewProvider {
    static var previews: some View {
        DisplaysSettingsPanel()
            .frame(width: 500, height: 700)
    }
}
