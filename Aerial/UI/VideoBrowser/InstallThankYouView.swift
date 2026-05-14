//
//  InstallThankYouView.swift
//  Aerial Companion
//
//  Follow-up sheet shown after a successful install of one or more
//  non-cacheable (paid) expansion packs via the "Got an install link?"
//  flow. Two beats:
//   1. Acknowledge the purchase — paid packs support both the
//      third-party video maker and Aerial.
//   2. Offer a one-click "set this expansion to play now" shortcut so
//      the user doesn't have to find the popover and tick the sources
//      manually.
//
//  Accepts a list so the meta-manifest path (multiple sources from one
//  link) shares the exact same UX.
//
//  Strings are deliberately literal here; if we ever localize, they
//  move to Localizable.strings then.
//

import SwiftUI

struct InstallThankYouView: View {
    let installedSources: [InstalledSource]
    /// Both actions carry the current value of the "Download all
    /// videos now" toggle — the parent decides whether to enqueue.
    let onSetToPlay: (_ downloadAll: Bool) -> Void
    let onDismiss: (_ downloadAll: Bool) -> Void

    @State private var downloadAllNow: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "heart.fill")
                        .foregroundColor(.pink)
                    Text("Thank you for your support")
                }
                .font(.system(size: 28, weight: .bold))

                installedListView

                Text("Thank you for supporting third-party video makers who also support the Aerial project!")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(installedSources.count == 1
                     ? "Do you want to set this expansion to play now?"
                     : "Do you want to set these expansions to play now?")
                    .font(.callout)
                Text("You can always choose what plays yourself by using the selection tools in the main popover.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Download all videos now", isOn: $downloadAllNow)
                .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("I'll do it manually") { onDismiss(downloadAllNow) }
                    .keyboardShortcut(.cancelAction)
                Button("Set to play now") { onSetToPlay(downloadAllNow) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    /// Single-pack vs multi-pack listing. The single case keeps the
    /// pretty "YOU'VE JUST INSTALLED: <description>" layout. The multi
    /// case shows a small checked list with name (bold) + description
    /// (caption) per row.
    @ViewBuilder
    private var installedListView: some View {
        if installedSources.count == 1 {
            let only = installedSources[0]
            Text("You've just installed:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(displayBody(for: only))
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("You've just installed \(installedSources.count) packs:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(installedSources) { source in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.aerial)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name)
                                .font(.callout.bold())
                            let desc = source.description.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !desc.isEmpty {
                                Text(desc)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Prefer the manifest's description (marketing copy) since it
    /// tells the user *what* the pack actually is. Fall back to the
    /// source name when the manifest didn't ship a description.
    private func displayBody(for source: InstalledSource) -> String {
        let trimmed = source.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? source.name : trimmed
    }
}
