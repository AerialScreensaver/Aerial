//
//  ContentHeader.swift
//  Aerial Companion
//
//  Reusable header card for Video Library content views. Standardises
//  the icon + title + description + actions layout so every section
//  (My Videos, named sources, Live Feeds, user playlists, categories)
//  shares the same shape.
//
//  Single trailing actions slot — 0/1/2 buttons that sit trailing the
//  title row, vertically centered against the leading text block.
//  No "buttons below description" path; that variant caused asymmetric
//  vertical padding via an empty phantom row.
//

import SwiftUI

struct ContentHeader<Actions: View>: View {
    let icon: String
    let title: String
    var description: String? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 18))
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                }

                if let description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                actions()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

