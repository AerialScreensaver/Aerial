//
//  FirstLaunchCard.swift
//  Aerial Companion
//
//  Reusable selectable card used by both Mode and Overlay steps of the
//  first-launch wizard. Big SF Symbol thumbnail at the top, title +
//  one-line tagline below; selection highlight follows the same Color
//  .aerial pattern used elsewhere in the app for primary accent.
//

import SwiftUI

struct FirstLaunchCard: View {
    let symbol: String
    let title: String
    let tagline: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                // Thumbnail strip — accent-tinted block with a centered
                // SF Symbol. Solid block when selected, faint tint when
                // not, so the card the user has chosen reads at a glance.
                ZStack {
                    Rectangle()
                        .fill(isSelected ? Color.aerial.opacity(0.2) : Color.secondary.opacity(0.08))
                    Image(systemName: symbol)
                        .font(.system(size: 44, weight: .light))
                        .foregroundColor(isSelected ? Color.aerial : .secondary)
                }
                .frame(height: 96)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(tagline)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        // Reserve 2 lines worth of height even when
                        // the tagline only fills one — keeps sibling
                        // cards in the row at matching heights.
                        .lineLimit(2, reservesSpace: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.aerial : Color.secondary.opacity(0.25),
                                  lineWidth: isSelected ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }
}
