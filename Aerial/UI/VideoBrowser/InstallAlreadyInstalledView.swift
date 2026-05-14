//
//  InstallAlreadyInstalledView.swift
//  Aerial Companion
//
//  Follow-up sheet shown when the user pastes an install URL via
//  "Got an install link?" for one or more packs that are already
//  present in `SourceList.list`. Replaces the would-be silent
//  duplicate-append with a clear "Already installed" confirmation
//  and a single Done button. Accepts a list so the meta-manifest
//  path (multiple sources in one link) renders consistently.
//

import SwiftUI

struct InstallAlreadyInstalledView: View {
    let sourceNames: [String]
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Already installed")
                }
                .font(.system(size: 24, weight: .bold))

                summary

                if sourceNames.count > 1 {
                    nameList
                }
            }

            HStack {
                Spacer()
                Button("Done") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    @ViewBuilder
    private var summary: some View {
        if sourceNames.count == 1 {
            Text("\(sourceNames[0]) is already in your library — nothing new to add.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("\(sourceNames.count) packs from this link are already in your library — nothing new to add.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nameList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(sourceNames, id: \.self) { name in
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 4))
                        .foregroundStyle(.secondary)
                    Text(name)
                        .font(.callout)
                }
            }
        }
        .padding(.top, 2)
    }
}
