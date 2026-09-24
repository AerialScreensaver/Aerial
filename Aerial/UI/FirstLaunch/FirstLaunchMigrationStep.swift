//
//  FirstLaunchMigrationStep.swift
//  Aerial Companion
//
//  Polished replacement for the "found a previous version" branch of
//  the migration step. Visually matches Mode / Overlays / Thanks: two
//  FirstLaunchCard tiles (Migrate / Start fresh) with a conditional
//  reclaim toggle below when Start fresh is selected, and a settings
//  listicle that mirrors the chosen option. Runs the chosen
//  PathMigration operation off-main and advances on completion.
//
//  Custom-cache scenario is still handled by the legacy
//  `PathMigrationView` — this step only covers the legacy-container
//  case ("you ran a previous Aerial — here's what to do with it").
//

import SwiftUI

struct FirstLaunchMigrationStep: View {
    @ObservedObject var state: FirstLaunchWizardState

    /// Local selection state — kept out of `FirstLaunchWizardState`
    /// because this step lives outside the polished three-step trio.
    private enum Choice: Hashable {
        case migrate
        case startFresh
    }

    @State private var choice: Choice? = nil
    @State private var reclaimDiskSpace: Bool = true
    @State private var phase: Phase = .choosing
    @State private var progressMessage: String = ""

    /// Populated when entering `.complete` based on what legacy
    /// artifacts the filesystem still has lying around.
    @State private var cleanupOptions: [CleanupOption] = []
    /// id → selected. All entries default to `true` so the user can
    /// just click Continue in the common case.
    @State private var cleanupSelections: [String: Bool] = [:]

    private enum Phase: Equatable {
        case choosing
        case running
        case failed(String)   // the operation reported an error (not a permission one)
        case complete   // intermediary confirmation + optional cleanup
        case done       // terminal; immediately advances out of the step
    }

    /// One optional cleanup target shown as a checkbox on the
    /// `.complete` screen — the file path is offered for deletion
    /// only when it actually exists on disk.
    private struct CleanupOption: Identifiable, Hashable {
        let id: String
        let label: String
        let url: URL
    }

    var body: some View {
        switch phase {
        case .choosing:
            VStack(alignment: .leading, spacing: 16) {
                header
                cards
                conditionalReclaimToggle
                listicle
                Spacer(minLength: 0)
                bottomBar
            }
        case .running:
            runningView
        case .failed(let message):
            failedView(message)
        case .complete:
            completeView
        case .done:
            EmptyView()  // advanceFromMigration was called; the wizard
                         // is about to swap us out for the Mode step.
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Found a previous version")
                .font(.system(size: 20, weight: .semibold))
            Text("We detected an existing Aerial install on your Mac. You can carry over your data, or start with a clean Aerial 4 — your choice.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cards: some View {
        HStack(alignment: .top, spacing: 12) {
            FirstLaunchCard(
                symbol: "arrow.down.doc.fill",
                title: "Migrate",
                tagline: "Carry over your existing videos, sources, and settings from the old Aerial install.",
                isSelected: choice == .migrate,
                onSelect: { choice = .migrate }
            )
            .frame(maxWidth: .infinity)

            FirstLaunchCard(
                symbol: "sparkles",
                title: "Start fresh",
                tagline: "Begin with a clean Aerial 4. Nothing is carried over from the previous install.",
                isSelected: choice == .startFresh,
                onSelect: { choice = .startFresh }
            )
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var conditionalReclaimToggle: some View {
        if choice == .startFresh {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Delete old Aerial data to reclaim disk space", isOn: $reclaimDiskSpace)
                    .font(.system(size: 13))
                Text("Removes the legacy install entirely. Uncheck if you want to keep the old data as a backup — you can clean it up later.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.06))
            )
        }
    }

    @ViewBuilder
    private var listicle: some View {
        if let choice {
            VStack(alignment: .leading, spacing: 8) {
                Text("This will:")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(bullets(for: choice), id: \.self) { line in
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

    private var bottomBar: some View {
        HStack {
            Spacer()
            Button("Continue") { startMigration() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(choice == nil)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var runningView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(progressMessage.isEmpty ? "Working…" : progressMessage)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 32)
    }

    // MARK: - Bullets

    private func bullets(for choice: Choice) -> [String] {
        switch choice {
        case .migrate:
            return [
                "Move your downloaded videos and any custom source packs to Aerial 4",
                "Carry over some key basic settings",
                "Filters, favorites, overlays and other detailed settings start fresh in Aerial 4",
                "The old container is moved (not copied) — disk space is freed automatically"
            ]
        case .startFresh:
            if reclaimDiskSpace {
                return [
                    "Start Aerial 4 with default settings — nothing is carried over",
                    "*Delete* the legacy install to reclaim disk space"
                ]
            } else {
                return [
                    "Start Aerial 4 with default settings — nothing is carried over",
                    "Leave the old install untouched (you can remove it manually later)"
                ]
            }
        }
    }

    // MARK: - Actions

    private func startMigration() {
        guard let choice else { return }
        let type: MigrationType
        switch choice {
        case .migrate:    type = .moveData
        case .startFresh: type = reclaimDiskSpace ? .startFreshAndReclaim : .startFresh
        }
        phase = .running
        progressMessage = (choice == .migrate)
            ? "Moving your data to the new location…"
            : (reclaimDiskSpace ? "Setting up Aerial 4 and reclaiming disk space…"
                                : "Setting up Aerial 4…")

        PathMigration.performMigration(
            type: type,
            progressCallback: { message in
                // `migrateContainerData` invokes this on a background
                // queue. Hop to main so the @State update actually
                // re-renders the running view.
                DispatchQueue.main.async {
                    progressMessage = message
                }
            },
            completion: { result in
                // Same story for the terminal callback — the legacy
                // `.moveData` path completes on its background queue.
                // Hop to main. A failure is shown, never swallowed: the
                // usual cause is that macOS refuses the container without
                // Full Disk Access, and the wizard state then swaps in the
                // permission screen. Otherwise populate cleanup options
                // and transition to the intermediary `.complete` screen.
                DispatchQueue.main.async {
                    switch result {
                    case .failure(let error, _):
                        if state.migrationFailed() { return }
                        phase = .failed(error)
                    case .success, .skipped:
                        let options = Self.detectCleanupOptions()
                        cleanupOptions = options
                        cleanupSelections = Dictionary(uniqueKeysWithValues: options.map { ($0.id, true) })
                        phase = .complete
                    }
                }
            }
        )
    }

    // MARK: - Failure view

    private func failedView(_ message: String) -> some View {
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
                Button("Skip") { state.skipMigration() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Button("Try Again") { phase = .choosing }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 12)
    }

    // MARK: - Complete view + cleanup

    private var completeView: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.green)

                VStack(spacing: 10) {
                    Text(completeTitle)
                        .font(.system(size: 26, weight: .semibold))
                        .multilineTextAlignment(.center)
                    Text(completeSubtext)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 520)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)

            if !cleanupOptions.isEmpty {
                cleanupBox
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Continue") { finishCleanupAndAdvance() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var cleanupBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Found a few leftovers from the previous Aerial:")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(cleanupOptions) { option in
                    Toggle(option.label, isOn: Binding(
                        get: { cleanupSelections[option.id] ?? true },
                        set: { cleanupSelections[option.id] = $0 }
                    ))
                    .font(.system(size: 13))
                }
            }

            Text("These belonged to a previous Aerial version and aren't needed anymore.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private var completeTitle: String {
        switch choice {
        case .migrate:
            return "Migration complete"
        case .startFresh, .none:
            return "Aerial 4 is ready"
        }
    }

    private var completeSubtext: String {
        switch choice {
        case .migrate:
            return "Your data has been moved to /Users/Shared/Aerial. You're one step away from finishing setup."
        case .startFresh where reclaimDiskSpace:
            return "Your previous Aerial install has been removed to reclaim disk space."
        case .startFresh:
            return "Your previous Aerial install was left untouched. You can remove it manually later if you want."
        case .none:
            return ""
        }
    }

    /// Probe filesystem for legacy artifacts that live outside the
    /// container path (so neither the move nor the reclaim handled
    /// them). Only paths that actually exist become checkbox options;
    /// nothing else clutters the cleanup screen.
    ///
    /// The `companionPath != Bundle.main.bundlePath` guard prevents
    /// offering to delete the currently-running app — defensive in
    /// case anyone ever ships a build at `/Applications/Aerial Companion.app`.
    private static func detectCleanupOptions() -> [CleanupOption] {
        var options: [CleanupOption] = []
        let fm = FileManager.default

        let companionPath = "/Applications/Aerial Companion.app"
        if fm.fileExists(atPath: companionPath),
           companionPath != Bundle.main.bundlePath {
            options.append(CleanupOption(
                id: "companion-app",
                label: "Remove Aerial Companion.app from /Applications",
                url: URL(fileURLWithPath: companionPath)
            ))
        }

        let saverPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Screen Savers/Aerial.saver")
        if fm.fileExists(atPath: saverPath) {
            options.append(CleanupOption(
                id: "saver",
                label: "Remove Aerial.saver from ~/Library/Screen Savers",
                url: URL(fileURLWithPath: saverPath)
            ))
        }

        return options
    }

    /// Continue button on the complete screen: run any selected
    /// deletions (best-effort, errors logged but not surfaced), then
    /// advance out of the migration step.
    private func finishCleanupAndAdvance() {
        for option in cleanupOptions where cleanupSelections[option.id] == true {
            do {
                try FileManager.default.removeItem(at: option.url)
                infoLog("Cleanup: removed \(option.url.path)")
            } catch {
                errorLog("Cleanup: failed to remove \(option.url.path): \(error.localizedDescription)")
            }
        }
        phase = .done
        state.advanceFromMigration()
    }
}

// MARK: - Permission screen

/// Aerial 3 data was found but this process may not read it. On macOS 26
/// and later the legacy screen saver engine has no app record, so macOS
/// cannot show its "access data from other apps" prompt for the container:
/// only Full Disk Access opens it, and nothing asks for that on its own.
/// Explain, open System Settings, re-check — or skip and get the offer
/// again at a later launch (`Preferences.legacyMigrationPending`).
struct LegacyDataPermissionStep: View {
    @ObservedObject var state: FirstLaunchWizardState

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 56, weight: .light))
                .foregroundColor(.aerial)

            VStack(spacing: 13) {
                Text("Aerial needs permission to read Aerial 3's data")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
                Text("Aerial found data from a previous version, but macOS doesn't let it read the old screen saver's files. On this version of macOS that only works with **Full Disk Access**, and macOS won't ask for it on its own.")
                Text("1. Click **Open System Settings** and add Aerial to Full Disk Access.\n2. Come back here and click **Check Again**. If it still fails, quit and reopen Aerial.")
                Text("You can also skip this: Aerial will offer the migration again the next time it starts, once it can read the data.")
            }
            .font(.system(size: 15))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 650)

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button("Skip") {
                    state.skipMigration()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Open System Settings") {
                    PathMigration.openFullDiskAccessSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Check Again") {
                    state.reprobeLegacyData()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 16)
    }
}
