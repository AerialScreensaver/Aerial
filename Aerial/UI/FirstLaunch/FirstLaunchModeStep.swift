//
//  FirstLaunchModeStep.swift
//  Aerial Companion
//
//  Step 1 of the first-launch wizard — two mode cards (screensaver
//  only / screensaver + desktop) plus a shared listicle pane and an
//  opt-in wallpaper-continuity toggle that's only meaningful when
//  desktop mode is on. Selection lives on the parent `WizardState`;
//  this view is presentation-only.
//

import SwiftUI

struct FirstLaunchModeStep: View {
    @ObservedObject var state: FirstLaunchWizardState

    private let choices: [FirstLaunch.ModeChoice] = [
        .screensaverOnly,
        .screensaverPlusDesktop,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose how Aerial fits your setup")
                    .font(.system(size: 20, weight: .semibold))
                Text("Pick a starting point. Nothing here is permanent — every option can be changed later in Settings.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                ForEach(choices, id: \.self) { choice in
                    FirstLaunchCard(
                        symbol: choice.thumbnailSymbol,
                        title: choice.title,
                        tagline: choice.tagline,
                        isSelected: state.mode == choice,
                        onSelect: { state.mode = choice }
                    )
                    .frame(maxWidth: .infinity)
                }
            }

            settingsListicle

            if state.mode == .screensaverPlusDesktop {
                wallpaperContinuityToggle
            }

            Spacer(minLength: 0)
        }
    }

    /// Shared pane that mirrors the selected card's bullet list. Empty
    /// fallback should never render in practice — we pre-select a card
    /// in the parent.
    @ViewBuilder
    private var settingsListicle: some View {
        if let mode = state.mode {
            VStack(alignment: .leading, spacing: 8) {
                Text("This will:")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(mode.settingsBullets, id: \.self) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .foregroundColor(.secondary)
                            Text(.init(line))
                                .font(.system(size: 13))
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.06))
            )
        }
    }

    /// Opt-in for replacing the System Settings wallpaper too, so
    /// the still frame stays consistent in places that read it
    /// (menu bar, Exposé, Mission Control). Folded out of the mode
    /// cards because it's a sub-choice of "screensaver + desktop"
    /// — meaningless on its own without desktop mode.
    private var wallpaperContinuityToggle: some View {
        Toggle(isOn: $state.wallpaperContinuity) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Also replace my System Settings wallpaper")
                    .font(.system(size: 13, weight: .medium))
                Text("Aerial takes over the macOS wallpaper too, for a better experience with your menu bar, Exposé, and Mission Control. Optional and can be change in **Settings > Wallpaper**. You will be prompted for permission to access macOS Wallpaper cache.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}
