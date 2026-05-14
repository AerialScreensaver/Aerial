//
//  FirstLaunchOverlayStep.swift
//  Aerial Companion
//
//  Step 2 of the wizard — three overlay-preset cards plus a burn-in
//  rotation toggle and a "you can adjust this later in Settings →
//  Overlays" footnote.
//

import SwiftUI

struct FirstLaunchOverlayStep: View {
    @ObservedObject var state: FirstLaunchWizardState

    private let choices: [FirstLaunch.OverlayPreset] = [.none, .classic, .modern]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up overlays")
                    .font(.system(size: 20, weight: .semibold))
                Text("Pick how much information rides on top of the video. The Modern preset is a starting point — you can fine-tune everything later.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                ForEach(choices, id: \.self) { choice in
                    FirstLaunchCard(
                        symbol: choice.thumbnailSymbol,
                        title: choice.title,
                        tagline: choice.tagline,
                        isSelected: state.overlay == choice,
                        onSelect: { state.overlay = choice }
                    )
                    .frame(maxWidth: .infinity)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Rotate overlays to reduce burn-in risk on your monitors", isOn: $state.rotateForBurnIn)
                    .font(.system(size: 13))
                Text("Cycles overlays through positions every minute. Useful for OLED panels or any display you keep on for long stretches.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.06))
            )

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text("Adjustable any time in Settings → Overlays.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)
        }
    }
}
