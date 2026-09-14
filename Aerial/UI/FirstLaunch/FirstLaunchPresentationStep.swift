//
//  FirstLaunchPresentationStep.swift
//  Aerial Companion
//
//  Wizard step: where should Aerial live — the menu bar (status item +
//  popover) or the Dock (regular app, Video Library as the main
//  window). Two `FirstLaunchCard`s plus the shared bullet pane, same
//  shape as the wallpaper-mode step. The chooser is reused by the
//  one-time upgrade prompt for existing users.
//

import SwiftUI

// MARK: - Reusable two-card chooser

struct AppPresentationChooser: View {
    @Binding var selection: AppPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(AppPresentation.allCases, id: \.self) { choice in
                    FirstLaunchCard(
                        symbol: choice.thumbnailSymbol,
                        title: choice.title,
                        tagline: choice.tagline,
                        isSelected: selection == choice,
                        onSelect: { selection = choice }
                    )
                    .frame(maxWidth: .infinity)
                }
            }

            FirstLaunchBulletPane(lines: selection.settingsBullets)
        }
    }
}

// MARK: - Wizard step

struct FirstLaunchPresentationStep: View {
    @ObservedObject var state: FirstLaunchWizardState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Where should Aerial live?")
                    .font(.system(size: 20, weight: .semibold))
                Text("Aerial can sit in your menu bar as a compact popover, or run as a regular app in the Dock with the Video Library as its main window. You can switch any time in Settings → Advanced.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AppPresentationChooser(selection: $state.presentation)

            Spacer(minLength: 0)
        }
    }
}
