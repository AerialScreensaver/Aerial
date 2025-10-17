//
//  PathMigrationView.swift
//  Aerial Companion
//
//  SwiftUI-based migration interface
//

import SwiftUI

@available(macOS 11.0, *)
enum MigrationViewState {
    case chooseOption
    case migrating(message: String)
    case complete(success: Bool, message: String)
}

@available(macOS 11.0, *)
struct PathMigrationView: View {
    @State private var viewState: MigrationViewState = .chooseOption

    let isCustomCacheUser: Bool
    let description: String
    let onMigrate: (MigrationType, @escaping (String) -> Void, @escaping (MigrationResult) -> Void) -> Void
    let onShowOldLocation: () -> Void
    let onShowNewLocation: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            switch viewState {
            case .chooseOption:
                chooseOptionView
            case .migrating(let message):
                migratingView(message: message)
            case .complete(let success, let message):
                completeView(success: success, message: message)
            }
        }
        .padding(30)
        .frame(width: 500)
    }

    // MARK: - Choose Option View

    private var chooseOptionView: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSImage(named: NSImage.cautionName)!)
                .resizable()
                .frame(width: 64, height: 64)

            Text("Aerial Data Migration")
                .font(.title)
                .fontWeight(.bold)

            Text(description)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                if isCustomCacheUser {
                    // Custom cache user options
                    Button("Migrate to Standard Location") {
                        startMigration(type: .moveData)
                    }
                    .keyboardShortcut(.defaultAction)

                    Button("Keep Custom Location") {
                        startMigration(type: .keepCustom)
                    }
                } else {
                    // Standard user options
                    Button("Move Data to New Location") {
                        startMigration(type: .moveData)
                    }
                    .keyboardShortcut(.defaultAction)

                    Button("Start Fresh") {
                        confirmStartFresh()
                    }
                }
            }
        }
    }

    // MARK: - Migrating View

    private func migratingView(message: String) -> some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .frame(height: 60)

            Text("Migrating...")
                .font(.title2)
                .fontWeight(.semibold)

            Text(message)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Complete View

    private func completeView(success: Bool, message: String) -> some View {
        VStack(spacing: 20) {
            Image(nsImage: NSImage(named: success ? NSImage.statusAvailableName : NSImage.statusUnavailableName)!)
                .resizable()
                .frame(width: 64, height: 64)

            Text(success ? "Migration Complete" : "Migration Failed")
                .font(.title2)
                .fontWeight(.semibold)

            Text(message)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if success {
                HStack(spacing: 12) {
                    Button("Show Old Location") {
                        onShowOldLocation()
                    }

                    Button("Show New Location") {
                        onShowNewLocation()
                    }
                }
            }

            Button("Done") {
                onDismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Actions

    private func startMigration(type: MigrationType) {
        viewState = .migrating(message: "Preparing migration...")

        onMigrate(type, { progressMessage in
            DispatchQueue.main.async {
                if case .migrating = viewState {
                    viewState = .migrating(message: progressMessage)
                }
            }
        }, { result in
            DispatchQueue.main.async {
                handleMigrationResult(result)
            }
        })
    }

    private func confirmStartFresh() {
        let alert = NSAlert()
        alert.messageText = "Start Fresh?"
        alert.informativeText = "Your existing data will remain in the old location but won't be used. You can delete it manually later if desired."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start Fresh")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            startMigration(type: .startFresh)
        }
    }

    private func handleMigrationResult(_ result: MigrationResult) {
        switch result {
        case .success(let summary):
            viewState = .complete(success: true, message: summary)

        case .failure(let error, let log):
            viewState = .complete(success: false, message: error)
            CompanionLogging.errorLog("Migration failed:\n\(log)")

        case .skipped:
            viewState = .complete(success: true, message: "Migration skipped.")
        }
    }
}

@available(macOS 11.0, *)
struct PathMigrationView_Previews: PreviewProvider {
    static var previews: some View {
        PathMigrationView(
            isCustomCacheUser: false,
            description: "We found 2.5 GB of Aerial data in the old location.\n\nAerial now uses a unified data directory at /Users/Shared/Aerial/ that is easier to access.\n\nWhat would you like to do?",
            onMigrate: { _, _, _ in },
            onShowOldLocation: { },
            onShowNewLocation: { },
            onDismiss: { }
        )
    }
}
