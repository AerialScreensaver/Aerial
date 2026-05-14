//
//  FirstLaunchWizardView.swift
//  Aerial Companion
//
//  Top-level SwiftUI view that drives the first-launch wizard. Owns
//  the WizardState (current step + selections + burn-in toggle) and
//  the bottom action bar (Back / Next / Done). Includes a conditional
//  step 0 that embeds `PathMigrationView` when migration is needed,
//  consolidating both flows in a single window.
//

import SwiftUI

// MARK: - Wizard state

final class FirstLaunchWizardState: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome    // always first; gates the legacy-container probe
        case migration  // conditional — only after the user clicks Go ahead AND data is found
        case mode
        case overlays
        case thanks
    }

    @Published var step: Step = .welcome
    @Published var mode: FirstLaunch.ModeChoice?
    @Published var wallpaperContinuity: Bool = true
    @Published var overlay: FirstLaunch.OverlayPreset? = .modern
    @Published var rotateForBurnIn: Bool = false

    /// True once the user has clicked "Go ahead" AND the legacy
    /// container probe found data. Drives whether the `.migration`
    /// step appears in `visibleSteps`. Set only by `advanceFromWelcome`.
    @Published private(set) var migrationNeeded: Bool = false

    init() {
        self.mode = FirstLaunch.initialModeChoice
        self.wallpaperContinuity = FirstLaunch.initialWallpaperContinuity
    }

    /// Steps that actually render (skipping welcome/migration from
    /// the user-visible "Step X of Y" indicator; both are present in
    /// the flow but not counted in the polished three-step progress).
    var visibleSteps: [Step] {
        Step.allCases.filter { $0 != .migration || migrationNeeded }
    }

    /// 1-based progress index for the dot indicator. Counts only the
    /// polished three (mode / overlays / thanks).
    var stepIndex: Int {
        let counted = visibleSteps.filter { $0 != .welcome && $0 != .migration }
        return (counted.firstIndex(of: step) ?? 0) + 1
    }

    var stepCount: Int {
        visibleSteps.filter { $0 != .welcome && $0 != .migration }.count
    }

    /// True only on the first counted step (mode). Welcome and
    /// migration aren't "first steps" in the user's mental model.
    var isFirstStep: Bool { step == .mode }
    var isLastStep: Bool { step == .thanks }

    var canAdvance: Bool {
        switch step {
        // Welcome + Migration own their own action chrome — the
        // standard Next button is hidden on both, so canAdvance is
        // irrelevant. They drive transitions via custom methods.
        case .welcome:   return false
        case .migration: return false
        case .mode:      return mode != nil
        case .overlays:  return overlay != nil
        case .thanks:    return true
        }
    }

    func goNext() {
        guard let idx = visibleSteps.firstIndex(of: step), idx + 1 < visibleSteps.count else { return }
        step = visibleSteps[idx + 1]
    }

    func goBack() {
        guard let idx = visibleSteps.firstIndex(of: step), idx > 0 else { return }
        step = visibleSteps[idx - 1]
    }

    /// Called by the Welcome step.
    ///   - `probe: false` → Skip; never touch the legacy container path.
    ///     macOS TCC prompt never fires.
    ///   - `probe: true`  → Go ahead; call `PathMigration.needsMigration()`
    ///     (which triggers the TCC prompt on first read). If old data
    ///     is found we transition to `.migration`, otherwise straight
    ///     to `.mode`. Permission denial returns false and we fall
    ///     through to `.mode` without surfacing an error.
    func advanceFromWelcome(probe: Bool) {
        if probe {
            migrationNeeded = PathMigration.needsMigration()
        } else {
            migrationNeeded = false
        }
        step = migrationNeeded ? .migration : .mode
    }

    /// Called by the migration step once the chosen operation finishes.
    func advanceFromMigration() {
        step = .mode
    }
}

// MARK: - Top-level view

struct FirstLaunchWizardView: View {
    @StateObject private var state = FirstLaunchWizardState()
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            stepBody
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            actionBar
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
        }
        .frame(width: 720, height: 560)
    }

    // MARK: - Step routing

    @ViewBuilder
    private var stepBody: some View {
        switch state.step {
        case .welcome:
            FirstLaunchWelcomeStep(state: state)
        case .migration:
            // Custom-cache scenario keeps the legacy `PathMigrationView`
            // (its own UI). The "found a previous version" container
            // case uses the polished `FirstLaunchMigrationStep`.
            if PathMigration.isCustomCacheUser() {
                customCacheMigrationStep
            } else {
                FirstLaunchMigrationStep(state: state)
            }
        case .mode:
            FirstLaunchModeStep(state: state)
        case .overlays:
            FirstLaunchOverlayStep(state: state)
        case .thanks:
            FirstLaunchThankYouStep()
        }
    }

    /// Embeds the legacy `PathMigrationView` ONLY for the custom-cache
    /// scenario. The container-found case now uses the redesigned
    /// `FirstLaunchMigrationStep`.
    @ViewBuilder
    private var customCacheMigrationStep: some View {
        PathMigrationView(
            isCustomCacheUser: true,
            description: PathMigration.getMigrationDescription(),
            onMigrate: { type, progress, completion in
                PathMigration.performMigration(type: type,
                                               progressCallback: progress,
                                               completion: completion)
            },
            onShowOldLocation: { PathMigration.showOldContainerInFinder() },
            onShowNewLocation: { PathMigration.showNewLocationInFinder() },
            onDismiss: { state.advanceFromMigration() }
        )
    }

    // MARK: - Action bar

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 12) {
            stepIndicator
            Spacer()

            // Welcome + Migration own their own action chrome (their
            // step views embed the buttons). Hide the standard
            // Back / Next on those screens.
            if state.step != .welcome && state.step != .migration {
                if !state.isFirstStep {
                    Button("Back") { state.goBack() }
                        .keyboardShortcut(.cancelAction)
                }
                Button(state.isLastStep ? "Get Started" : "Next") {
                    handleAdvance()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!state.canAdvance)
            }
        }
    }

    /// Apply the chosen prefs at the right step boundaries. Mode is
    /// committed when leaving the mode step; overlays when leaving the
    /// overlays step; the completion sentinel is set when finishing
    /// the thanks step. Welcome + Migration are handled by their own
    /// step views — they don't reach this method.
    private func handleAdvance() {
        switch state.step {
        case .welcome, .migration:
            return  // their step views drive their own transitions
        case .mode:
            if let mode = state.mode {
                FirstLaunch.apply(mode: mode, wallpaperContinuity: state.wallpaperContinuity)
            }
            state.goNext()
        case .overlays:
            if let overlay = state.overlay {
                FirstLaunch.apply(overlay: overlay, rotateForBurnIn: state.rotateForBurnIn)
            }
            state.goNext()
        case .thanks:
            Preferences.firstLaunchCompleted = true
            onComplete()
        }
    }

    /// Tiny step-of-N indicator pinned to the bottom-leading corner.
    /// Welcome + Migration are excluded from the count so users always
    /// see "1 of 3" / "2 of 3" / "3 of 3" for the polished trio.
    @ViewBuilder
    private var stepIndicator: some View {
        if state.step != .welcome && state.step != .migration {
            let countedSteps = state.visibleSteps.filter { $0 != .welcome && $0 != .migration }
            let currentIdx = (countedSteps.firstIndex(of: state.step) ?? 0) + 1
            HStack(spacing: 6) {
                ForEach(0..<countedSteps.count, id: \.self) { i in
                    Circle()
                        .fill(i < currentIdx ? Color.aerial : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
                Text("Step \(currentIdx) of \(countedSteps.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
            }
        }
    }
}
