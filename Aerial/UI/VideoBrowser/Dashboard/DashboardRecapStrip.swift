//
//  DashboardRecapStrip.swift
//  Aerial Companion
//
//  At-a-glance recap of the global (not per-screen) settings, as a row of
//  three equal cards: "Adapt by time" and "Displays" are interactive
//  selectors (current state shown large + a ⋯ menu of quick picks and
//  "More options…" → Settings), and a live playback-speed slider.
//

import SwiftUI

struct DashboardRecapStrip: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject var playbackManager: PlaybackManager

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TimeRecapCard(model: model)
            CacheRecapCard()
            speedCard
            orderCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var speedCard: some View {
        RecapCard(title: "Speed", showsMenu: false, menu: { EmptyView() }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "speedometer")
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 18))
                    Text(SpeedSliderView.label(for: playbackManager.globalSpeed))
                        .font(.system(size: 17, weight: .semibold))
                }
                SpeedSliderView(speed: Binding(
                    get: { playbackManager.globalSpeed },
                    set: { playbackManager.globalSpeed = $0 }
                ), showsLabel: false)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Tappable playback-mode card for all playlists. Mirrors the popover's
    /// cycle-mode selector: the whole card cycles loop → shuffle → repeat
    /// one, and switching to shuffle reshuffles immediately (see
    /// `DashboardModel.cyclePlaybackMode`).
    private var orderCard: some View {
        let mode = model.playbackMode
        return Button(action: { model.cyclePlaybackMode() }) {
            RecapCard(title: "Order", showsMenu: false, menu: { EmptyView() }) {
                HStack(spacing: 10) {
                    Image(systemName: orderIcon(for: mode))
                        .font(.system(size: 26))
                        .foregroundColor(orderColor(for: mode))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(orderTitle(for: mode))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.primary)
                        Text(orderSubtitle(for: mode))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(.plain)
        .help(orderHelp(for: mode))
    }

    private func orderIcon(for mode: PlaylistCycleMode) -> String {
        switch mode {
        case .loop: return "repeat"
        case .shuffle: return "shuffle"
        case .repeatOne: return "repeat.1"
        }
    }

    private func orderColor(for mode: PlaylistCycleMode) -> Color {
        switch mode {
        case .loop: return .blue
        case .shuffle: return .orange
        case .repeatOne: return .purple
        }
    }

    private func orderTitle(for mode: PlaylistCycleMode) -> String {
        switch mode {
        case .loop: return "Loop"
        case .shuffle: return "Shuffle"
        case .repeatOne: return "Loop One"
        }
    }

    private func orderSubtitle(for mode: PlaylistCycleMode) -> String {
        switch mode {
        case .loop: return "Same order"
        case .shuffle: return "Random order"
        case .repeatOne: return "Repeats current video"
        }
    }

    private func orderHelp(for mode: PlaylistCycleMode) -> String {
        switch mode {
        case .loop:
            return "Loop: replays the same order. Click to switch to shuffle."
        case .shuffle:
            return "Shuffle: plays in a random order, reshuffled now and on each loop. Click to switch to loop one."
        case .repeatOne:
            return "Loop One: keeps replaying the current video. Click to switch to loop."
        }
    }
}

// MARK: - Card chrome

/// Shared chrome for the Home recap cards: a title, an optional ⋯ menu, and
/// large content. Equal-width (`maxWidth: .infinity`) so the row stays
/// balanced and readable.
struct RecapCard<MenuContent: View, CardBody: View>: View {
    let title: String
    var showsMenu: Bool = true
    @ViewBuilder var menu: () -> MenuContent
    @ViewBuilder var content: () -> CardBody

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if showsMenu {
                    Menu {
                        menu()
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 17))
                            .foregroundColor(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Change")
                }
            }
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 124, maxHeight: 124, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

// MARK: - Adapt by time

struct TimeRecapCard: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.openWindow) private var openWindow

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = DateFormatter.dateFormat(fromTemplate: "j:mm", options: 0, locale: .current)
        return f
    }()

    private var isOn: Bool { PrefsTime.timeMode != .disabled }

    var body: some View {
        RecapCard(title: "Adapt by time", menu: { menuContent }) {
            if isOn { onContent } else { offContent }
        }
    }

    @ViewBuilder private var menuContent: some View {
        let mode = PrefsTime.timeMode
        Button { model.setTimeAdaptation(.locationService) } label: {
            if mode != .disabled { Label("Yes — use Location Services", systemImage: "checkmark") }
            else { Text("Yes — use Location Services") }
        }
        Button { model.setTimeAdaptation(.disabled) } label: {
            if mode == .disabled { Label("No", systemImage: "checkmark") }
            else { Text("No") }
        }
        Divider()
        Button("More options…") {
            SettingsWindowController.show(panel: .time, via: openWindow)
        }
    }

    @ViewBuilder private var onContent: some View {
        let (active, slice) = TimeManagement.sharedInstance.shouldRestrictPlaybackToDayNightVideo()
        let transition = TimeManagement.sharedInstance.nextTransitionDate()

        VStack(alignment: .leading, spacing: 6) {
            stateLabel("Yes", color: .aerial, system: "checkmark.circle.fill")

            if active, let transition {
                let next = nextTimeSlice(slice)
                HStack(spacing: 5) {
                    glyph(timeOfDayIcon(slice))
                    Text(slice.capitalized).font(.system(size: 13, weight: .medium))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    glyph(timeOfDayIcon(next))
                    Text(next.capitalized).font(.system(size: 13, weight: .medium))
                }
                Text("at \(Self.timeFormatter.string(from: transition))")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                Text(model.timeModeName())
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder private var offContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            stateLabel("No", color: .secondary, system: "xmark.circle.fill")
            Text("Plays day & night anytime")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private func stateLabel(_ text: String, color: Color, system: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: system)
                .foregroundColor(color)
                .font(.system(size: 15))
            Text(text).font(.system(size: 17, weight: .semibold))
        }
    }

    private func glyph(_ system: String) -> some View {
        Image(systemName: system)
            .symbolRenderingMode(.multicolor)
            .font(.system(size: 15))
    }
}

// MARK: - Displays

struct DisplaysRecapCard: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject var playbackManager: PlaybackManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RecapCard(title: "Displays", menu: { menuContent }) {
            HStack(spacing: 8) {
                Image(systemName: "display")
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 18))
                Text(stateText).font(.system(size: 17, weight: .semibold))
            }
        }
    }

    private var stateText: String {
        let total = NSScreen.screens.count
        switch PrefsDisplays.displayMode {
        case .allDisplays:   return total <= 1 ? "All screens" : "All \(total) screens"
        case .mainOnly:      return "Main only"
        case .secondaryOnly: return "Secondaries"
        case .selection:     return "Custom (\(selectedDisplayCount) of \(total))"
        }
    }

    /// Number of currently-connected displays enabled for `.selection` mode.
    private var selectedDisplayCount: Int {
        NSScreen.screens.filter { screen in
            guard let did = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return DisplayDetection.sharedInstance.isScreenSelected(id: did)
        }.count
    }

    @ViewBuilder private var menuContent: some View {
        let mode = PrefsDisplays.displayMode
        Button { model.setDisplayMode(.allDisplays) } label: {
            if mode == .allDisplays { Label("All screens", systemImage: "checkmark") } else { Text("All screens") }
        }
        Button { model.setDisplayMode(.mainOnly) } label: {
            if mode == .mainOnly { Label("Main only", systemImage: "checkmark") } else { Text("Main only") }
        }
        Button { model.setDisplayMode(.secondaryOnly) } label: {
            if mode == .secondaryOnly { Label("Secondaries", systemImage: "checkmark") } else { Text("Secondaries") }
        }
        Divider()
        Button("More options…") {
            SettingsWindowController.show(panel: .displays, via: openWindow)
        }
    }
}

// MARK: - Cache

/// Home recap card (in the Displays slot): a ring gauge of the CACHE FOLDER
/// against the configured budget, mirroring the Cache settings panel
/// (`CacheSettingsPanel.diskUsageBar`) the ⋯ menu opens. Expansion packs
/// are stored beside the cache and never count against the limit, so they
/// only appear as a secondary figure.
///
/// Refresh is split by cost so we never re-walk/re-parse on a loop:
/// - **Settings** (budget / periodicity / unlimited / management) are cheap
///   in-memory `PrefsCache` reads. `ScreensaverSettingsManager` posts no change
///   notification, so we re-read them on a 2 s poll to stay live while the user
///   edits cache settings — no disk, no parsing.
/// - **Cache folder size** is an off-main folder walk, refreshed on appear and
///   on download completion (downloads only grow the cache folder).
/// - **Packs size** additionally hits `SourceList.foundSources`, which
///   re-parses every source manifest, so it's computed **once on appear** —
///   never on the poll or per-download.
struct CacheRecapCard: View {
    @Environment(\.openWindow) private var openWindow

    @State private var cacheGB: Double = 0
    @State private var packsGB: Double = 0
    @State private var limitGB: Double = 0
    @State private var unlimited = false
    @State private var periodicity: CachePeriodicity = .never
    @State private var managementOn = true
    @State private var loaded = false

    // Held in @State so the publisher survives re-renders (an inline
    // `Timer.publish` would be recreated each body pass and never fire).
    @State private var pollTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        RecapCard(title: "Cache", menu: { menuContent }) {
            HStack(spacing: 12) {
                ring
                VStack(alignment: .leading, spacing: 4) {
                    Text(loaded ? String(format: "%.1f GB", cacheGB) : "Calculating…")
                        .font(.system(size: 17, weight: .semibold))
                    Text(budgetLine)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Label(replacementText, systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .task {
            readPrefs()
            await reloadPacks()   // parses source manifests — once, on appear
            await reloadCache()
        }
        .onReceive(pollTimer) { _ in
            readPrefs()           // cheap in-memory reads only — never walk/parse here
        }
        .onReceive(NotificationCenter.default.publisher(for: DownloadCoordinator.downloadDidCompleteNotification)) { _ in
            Task { await reloadCache() }   // cache grew; packs are unaffected by downloads
        }
    }

    @ViewBuilder private var menuContent: some View {
        Button("Cache Settings…") {
            SettingsWindowController.show(panel: .cache, via: openWindow)
        }
    }

    /// Second line: the budget, with the packs figure appended when there
    /// are any (they sit outside the budget, so never in the headline).
    private var budgetLine: String {
        let budget = unlimited ? "Unlimited" : String(format: "of %.0f GB", limitGB)
        guard packsGB > 0.01 else { return budget }
        return budget + String(format: " · packs %.1f GB", packsGB)
    }

    /// Third line: how often cached videos are rotated, per the Cache settings.
    /// Replacement only runs while auto-download (cache management) is on.
    private var replacementText: String {
        guard managementOn else { return "Auto-download off" }
        switch periodicity {
        case .daily:   return "Replaced daily"
        case .weekly:  return "Replaced weekly"
        case .monthly: return "Replaced monthly"
        case .never:   return "Never replaced"
        }
    }

    /// Ring fill = cache / budget (clamped), orange once over budget.
    /// Unlimited has no cap, so the ring renders full. Indigo matches the
    /// cache colour in the settings panel's disk-usage bar.
    private var ring: some View {
        let ratio = unlimited ? 1.0 : (limitGB > 0 ? min(1.0, cacheGB / limitGB) : 0)
        let overBudget = !unlimited && cacheGB > limitGB + 0.05
        return ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.25), lineWidth: 7)
            Circle()
                .trim(from: 0, to: ratio)
                .stroke(overBudget ? Color.orange : Color.indigo, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 64, height: 64)
    }

    /// Cheap, synchronous pref reads — safe on the main actor. Re-read on every
    /// poll tick so budget / periodicity edits reflect quickly. Assigning an
    /// unchanged value is a no-op for `@State`, so this won't churn renders.
    private func readPrefs() {
        limitGB = PrefsCache.cacheLimit
        unlimited = PrefsCache.unlimitedCache
        periodicity = PrefsCache.cachePeriodicity
        managementOn = PrefsCache.enableManagement
    }

    /// Off-main walk of the cache folder (no manifest parsing). Cheap enough to
    /// repeat on download completion.
    private func reloadCache() async {
        let c = await Task.detached(priority: .utility) { Cache.size() }.value
        await MainActor.run {
            cacheGB = c
            loaded = true
        }
    }

    /// Off-main pack sizing. Touches `SourceList.foundSources`, which re-parses
    /// every source manifest, so call this sparingly — once on appear.
    private func reloadPacks() async {
        let p = await Task.detached(priority: .utility) { Cache.packsSize() }.value
        await MainActor.run { packsGB = p }
    }
}
