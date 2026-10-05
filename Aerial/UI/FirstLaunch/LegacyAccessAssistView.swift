//
//  LegacyAccessAssistView.swift
//  Aerial Companion
//
//  Aerial 3 data was found but macOS refuses to let this process read it
//  (see `LegacyContainerAccess` for why nothing can prompt for it). Shown
//  in place of the migration choices by the first-launch wizard and by the
//  launch-time upgrade prompt, so it carries its own buttons.
//
//  Screen A offers the user-intent grant through the Open panel, Full Disk
//  Access as the alternative, or the manual route. Screen B is the manual
//  route: start fresh (the user deletes the old folder in Finder), or drag
//  the old files into a staging folder Aerial can read and let
//  `PathMigration` lay them out from there.
//

import SwiftUI

@MainActor
final class LegacyMigrationAssistant: ObservableObject {
    enum Phase: Equatable {
        case intro
        case manual
        case running(String)
        case complete(String)
        case failed(String)
    }

    enum ManualChoice: Hashable {
        case startFresh
        case moveManually
    }

    @Published var phase: Phase = .intro
    @Published var manualChoice: ManualChoice?
    /// Inline notes: a refused grant on A, an empty staging folder on B.
    @Published var note: String?
    /// After a refused or cancelled grant the manual route takes the
    /// prominent button.
    @Published var grantFailed = false
    /// Reveals "Check Again" once System Settings was opened.
    @Published var fullDiskAccessOpened = false

    // MARK: Screen A

    /// Tier 1. True when the data can be read now.
    func requestGrant() -> Bool {
        note = nil
        switch LegacyContainerAccess.requestAccess() {
        case .granted:
            return true
        case .cancelled:
            grantFailed = true
            note = "No access was granted — try again, or migrate manually."
            return false
        case .refused(let selectedPath):
            grantFailed = true
            note = selectedPath == LegacyContainerAccess.grantFolderPath
                ? "macOS still refuses access — you can migrate manually."
                : "A folder was selected in the panel — try again and click Grant Access without selecting anything."
            return false
        }
    }

    func openFullDiskAccess() {
        PathMigration.openFullDiskAccessSettings()
        fullDiskAccessOpened = true
    }

    /// True when the probe no longer blocks: readable now, or the data is
    /// gone (deleted in Finder).
    func reprobe() -> Bool {
        PathMigration.probeLegacyData()
        let unblocked = !PathMigration.legacyDataFound || PathMigration.legacyDataReadable
        if !unblocked {
            note = "macOS still refuses access. If you just granted Full Disk Access, quit and reopen Aerial."
        }
        return unblocked
    }

    func showManual() {
        note = nil
        phase = .manual
    }

    func backToIntro() {
        note = nil
        phase = .intro
    }

    // MARK: Screen B

    func revealOldFiles() {
        LegacyContainerAccess.revealContainer(selectAerialFolder: true)
    }

    func openBothFolders() {
        do {
            try LegacyContainerAccess.prepareStaging()
        } catch {
            note = "Could not create \(LegacyContainerAccess.stagingPath): \(error.localizedDescription)"
            return
        }
        note = nil
        LegacyContainerAccess.revealContainer(selectAerialFolder: false)
        LegacyContainerAccess.revealStaging()
    }

    /// Start fresh: the user removes the old folder themselves; Aerial only
    /// writes its defaults (never a delete attempt on the container).
    func runStartFresh() {
        note = nil
        phase = .running("Setting up Aerial 4…")
        PathMigration.performMigration(type: .startFresh, progressCallback: { _ in }) { [weak self] result in
            DispatchQueue.main.async { self?.finish(result) }
        }
    }

    func runStagedMove() {
        guard LegacyContainerAccess.stagingHasContent() else {
            note = "Nothing found in Aerial-migrate yet — move the old files there first."
            return
        }
        note = nil
        phase = .running("Moving your data to the new location…")
        PathMigration.performMigration(
            type: .moveStaged(source: LegacyContainerAccess.stagingPath),
            progressCallback: { [weak self] message in
                // Background queue; and never regress a finished phase.
                DispatchQueue.main.async {
                    guard let self, case .running = self.phase else { return }
                    self.phase = .running(message)
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async { self?.finish(result) }
            }
        )
    }

    private func finish(_ result: MigrationResult) {
        switch result {
        case .success(let summary):
            phase = .complete(summary)
            // Leftovers kept the staging folder alive: show them.
            if manualChoice == .moveManually,
               FileManager.default.fileExists(atPath: LegacyContainerAccess.stagingPath) {
                LegacyContainerAccess.revealStaging()
            }
        case .skipped:
            phase = .complete("")
        case .failure(let error, _):
            phase = .failed(error)
        }
    }
}

struct LegacyAccessAssistView: View {
    /// The probe no longer blocks (readable, or the data is gone); the host
    /// re-reads `PathMigration`'s statics and routes.
    let onReadable: () -> Void
    /// A manual migration finished (success screen dismissed).
    let onFinished: () -> Void
    /// Leave it for a later launch.
    let onSkip: () -> Void

    @StateObject private var model = LegacyMigrationAssistant()

    var body: some View {
        switch model.phase {
        case .intro:
            introScreen
        case .manual:
            manualScreen
        case .running(let message):
            runningScreen(message)
        case .complete(let summary):
            completeScreen(summary)
        case .failed(let message):
            failedScreen(message)
        }
    }

    // MARK: - Screen A: grant

    private var introScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(
                "Aerial 3 data found — macOS needs your OK",
                "macOS\(LegacyContainerAccess.isMacOS27OrLater ? " 27" : "") restricts access to the old screen saver's folder, so the automatic migration can't start on its own. **Grant Access** opens a system file panel on that folder — just click **Grant Access** there, nothing to select. Aerial then carries over your videos, sources and settings as usual."
            )

            noteRow

            VStack(alignment: .leading, spacing: 10) {
                Text("Alternatively, give Aerial **Full Disk Access** in System Settings › Privacy & Security, then come back and click **Check Again** (quit and reopen Aerial if it still fails).")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Full Disk Access…") { model.openFullDiskAccess() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    if model.fullDiskAccessOpened {
                        Button("Check Again") {
                            if model.reprobe() { onReadable() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.06))
            )

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button("Skip") { onSkip() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Spacer()
                if model.grantFailed {
                    Button("Grant Access…") { grant() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    Button("Migrate manually…") { model.showManual() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Migrate manually…") { model.showManual() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    Button("Grant Access…") { grant() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func grant() {
        if model.requestGrant() { onReadable() }
    }

    // MARK: - Screen B: manual

    private var manualScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(
                "Migrate manually",
                "Finder can reach the old folder even though Aerial can't. Pick what you'd like to do."
            )

            HStack(alignment: .top, spacing: 12) {
                FirstLaunchCard(
                    symbol: "sparkles",
                    title: "Start fresh",
                    tagline: "Delete the old Aerial folder yourself and begin with a clean Aerial 4.",
                    isSelected: model.manualChoice == .startFresh,
                    onSelect: { model.manualChoice = .startFresh; model.note = nil }
                )
                .frame(maxWidth: .infinity)

                FirstLaunchCard(
                    symbol: "folder.badge.gearshape",
                    title: "Move my videos manually",
                    tagline: "Drag the old files into a folder Aerial can read; Aerial sorts them into place.",
                    isSelected: model.manualChoice == .moveManually,
                    onSelect: { model.manualChoice = .moveManually; model.note = nil }
                )
                .frame(maxWidth: .infinity)
            }

            if let choice = model.manualChoice {
                stepsBox(for: choice)
            }

            noteRow

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button("Back") { model.backToIntro() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue") {
                    switch model.manualChoice {
                    case .startFresh: model.runStartFresh()
                    case .moveManually: model.runStagedMove()
                    case .none: break
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.manualChoice == nil)
            }
        }
    }

    private func stepsBox(for choice: LegacyMigrationAssistant.ManualChoice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch choice {
            case .startFresh:
                numbered([
                    "Click **Show old files in Finder** — Finder selects the old `Aerial` folder.",
                    "Delete that folder (and, if you like, `Preferences/com.glouel.Aerial.plist` next to it).",
                    "Click **Continue**. Aerial 4 starts with default settings."
                ])
                Button("Show old files in Finder") { model.revealOldFiles() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            case .moveManually:
                numbered([
                    "Click **Open both folders** — the old `Aerial` folder and a new `Aerial-migrate` folder in /Users/Shared.",
                    "Drag `Cache`, `Thumbnails` and any source folders (e.g. “macOS 26”) from the old folder into `Aerial-migrate`. Optional: also `Preferences/com.glouel.Aerial.plist` to keep a custom cache location.",
                    "Click **Continue**. Aerial sorts the files into /Users/Shared/Aerial and removes `Aerial-migrate`."
                ])
                Button("Open both folders") { model.openBothFolders() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func numbered(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).")
                        .foregroundColor(.secondary)
                    Text(.init(line))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 13))
            }
        }
    }

    // MARK: - Running / complete / failed

    private func runningScreen(_ message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func completeScreen(_ summary: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.green)
            Text(model.manualChoice == .startFresh ? "Aerial 4 is ready" : "Migration complete")
                .font(.system(size: 26, weight: .semibold))
            Text(summary)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Continue") { onFinished() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 12)
    }

    private func failedScreen(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.red)
            Text("Migration failed")
                .font(.system(size: 26, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Spacer()
                Button("Skip") { onSkip() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Button("Back") { model.showManual() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 12)
    }

    // MARK: - Pieces

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            Text(.init(subtitle))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var noteRow: some View {
        if let note = model.note {
            Label(note, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
