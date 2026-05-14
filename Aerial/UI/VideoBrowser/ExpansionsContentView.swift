//
//  ExpansionsContentView.swift
//  Aerial Companion
//
//  Shown when the "Expansions" sidebar row is selected. Replaces the
//  old gearshape "Manage Source" cog: the install-from-link flow gets
//  a first-class button at the top, the per-source on/off toggles
//  live in a collapsed "Advanced" disclosure at the bottom, and the
//  middle of the page showcases curated free / paid expansions as
//  large horizontal cards.
//

import SwiftUI
import AppKit

struct ExpansionsContentView: View {
    @ObservedObject var state: VideoBrowserState
    @State private var showingInstallSheet = false
    @State private var refreshTick = 0

    /// Non-nil → the thank-you sheet is presented for one or more
    /// just-installed sources (at least one of them non-cacheable).
    /// Set by the install sheet's `onComplete` after a successful
    /// install. Lists every newly-added source for meta-manifest
    /// installs.
    @State private var thankYouContext: ThankYouContext? = nil

    private struct ThankYouContext: Identifiable {
        let installedSources: [InstalledSource]
        /// Concatenated name set so SwiftUI's `.sheet(item:)`
        /// re-presents only when the list actually changes.
        var id: String { installedSources.map(\.name).joined(separator: "|") }
    }

    /// Non-nil → the "Already installed" sheet is presented because
    /// the user pasted an install URL for packs that are already in
    /// `SourceList.list`. Set by the install sheet's pre-flight check.
    /// Lists every duplicate name for meta-manifest installs.
    @State private var alreadyInstalledContext: AlreadyInstalledContext? = nil

    private struct AlreadyInstalledContext: Identifiable {
        let sourceNames: [String]
        var id: String { sourceNames.joined(separator: "|") }
    }

    /// Increase Contrast preference — when on, swap the install-link
    /// row's faint Aerial tint for a saturated solid so it remains
    /// visible at high contrast.
    @Environment(\.colorSchemeContrast) private var contrast
    private var highContrast: Bool { contrast == .increased }

    private var expansions: [Expansion] {
        ExpansionStore.shared.expansions
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    installLinkRow
                    cards
                    advancedDisclosure
                }
                .padding(20)
                .id(refreshTick)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { consumePendingScroll(proxy) }
            .onChange(of: state.pendingExpansionScroll) { _ in consumePendingScroll(proxy) }
        }
        .sheet(isPresented: $showingInstallSheet) {
            InstallFromLinkView(
                onComplete: { result in
                    showingInstallSheet = false
                    refreshTick &+= 1
                    // Defer a tick so the first sheet's dismissal
                    // animation doesn't fight the next sheet's
                    // presentation.
                    DispatchQueue.main.async {
                        handleInstallResult(result)
                    }
                },
                onCancel: { showingInstallSheet = false }
            )
        }
        .sheet(item: $thankYouContext) { ctx in
            InstallThankYouView(
                installedSources: ctx.installedSources,
                onSetToPlay: { downloadAll in
                    let names = ctx.installedSources.map(\.name)
                    applySetToPlay(sourceNames: names)
                    if downloadAll {
                        for name in names {
                            DownloadCoordinator.shared.enqueueAllVideos(forSource: name)
                        }
                    }
                    thankYouContext = nil
                },
                onDismiss: { downloadAll in
                    if downloadAll {
                        for name in ctx.installedSources.map(\.name) {
                            DownloadCoordinator.shared.enqueueAllVideos(forSource: name)
                        }
                    }
                    thankYouContext = nil
                }
            )
        }
        .sheet(item: $alreadyInstalledContext) { ctx in
            InstallAlreadyInstalledView(
                sourceNames: ctx.sourceNames,
                onDismiss: { alreadyInstalledContext = nil }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: ExpansionStore.didChangeNotification)) { _ in
            refreshTick &+= 1
        }
    }

    /// Route the install sheet's outcome to the right follow-up:
    /// thank-you when at least one newly-added source is non-cacheable,
    /// "Already installed" when the pre-flight detected every proposed
    /// source as a duplicate, silent dismiss for everything else
    /// (free-only install, network error). Called one runloop tick
    /// after the install sheet dismisses to keep sheet-transition
    /// animations clean.
    private func handleInstallResult(_ result: InstallFromLinkResult) {
        switch result {
        case .alreadyInstalled(let names) where !names.isEmpty:
            alreadyInstalledContext = AlreadyInstalledContext(sourceNames: names)
        case .alreadyInstalled:
            break  // empty list = nothing meaningful to surface
        case .installed(let added):
            // Thank-you only when at least one newly-installed source
            // is non-cacheable. All-free installs (e.g. a free
            // community meta-manifest) keep the silent-dismiss path.
            guard added.contains(where: { !$0.isCachable }) else { return }
            thankYouContext = ThankYouContext(installedSources: added)
        }
    }

    /// Commit the play-selection change from the thank-you sheet.
    /// Mirrors `NowPlayingSectionView.commitGlobalFilter()` for shared /
    /// spanned / mirrored display modes, and also commits to each
    /// per-screen playlist in `.independent` mode (where the popover
    /// reads its filter state from per-screen playlists, not from the
    /// global prefs — so a global-only write wouldn't reflect in the UI
    /// or actually flip what each display plays).
    private func applySetToPlay(sourceNames: [String]) {
        let entries = sourceNames.map { "source:\($0)" }

        // Step 1: Always update global prefs. In shared/spanned/mirrored
        // modes this drives playback. In independent mode, it keeps the
        // global default coherent for any future switch back to shared.
        let globalFilters: [String]
        if PrefsVideos.newShouldPlay == .expansions {
            var current = PrefsVideos.newShouldPlayString
            for entry in entries where !current.contains(entry) {
                current.append(entry)
            }
            globalFilters = current
        } else {
            PrefsVideos.newShouldPlay = .expansions
            globalFilters = entries
        }
        PrefsVideos.newShouldPlayString = globalFilters
        PlaylistManager.shared.regenerate(for: nil, mode: .expansions, filterStrings: globalFilters)
        PlaybackManager.shared.refreshPlayback()

        // Step 2: In independent mode, the popover and playback both
        // consult per-screen playlists. Commit the same intent to
        // every screen.
        if PrefsDisplays.viewingMode == .independent {
            for screen in NSScreen.screens {
                let uuid = screen.screenUuid
                let perScreenFilters: [String]
                if let info = PlaylistManager.shared.filterInfo(for: uuid),
                   info.mode == .expansions {
                    // Already on expansions for this screen — append
                    // any of the new entries that aren't there yet.
                    var current = info.filterStrings
                    for entry in entries where !current.contains(entry) {
                        current.append(entry)
                    }
                    perScreenFilters = current
                } else {
                    // Different mode (or no playlist yet) — switch to
                    // expansions with the new packs as the selection.
                    perScreenFilters = entries
                }
                PlaylistManager.shared.regenerate(for: uuid, mode: .expansions, filterStrings: perScreenFilters)
                PlaybackManager.shared.refreshPlayback(for: uuid)
            }
        }

        DownloadCoordinator.shared.selectionDidChange()
    }

    /// Read `state.pendingExpansionScroll`, scroll to that card, and
    /// clear the request. Called from `.onAppear` (covers the
    /// navigate-then-mount case) and `.onChange` (covers the
    /// already-here-scroll-to-a-different-pack case). Also schedules
    /// auto-clear of the matching reticle highlight a couple seconds
    /// later so it doesn't linger.
    private func consumePendingScroll(_ proxy: ScrollViewProxy) {
        guard let id = state.pendingExpansionScroll else { return }
        // The view's LazyVStack may need a tick to lay out the target
        // before scrollTo can find it. Defer to the next runloop.
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(id, anchor: .top)
            }
            state.pendingExpansionScroll = nil

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                // Guard so a fresh route to a different card doesn't
                // get its highlight wiped by this delayed callback.
                if state.highlightedExpansionId == id {
                    state.highlightedExpansionId = nil
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Expansions")
                .font(.system(size: 28, weight: .bold))
            Text("""
            Aerial is free and open source. Expansions are extra video packs from independent artists — \
            some are free, others are paid. Buying a paid expansion supports both the creator and Aerial's \
            continued development. It's how we keep the project moving without ads or telemetry.
            """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Install-from-link row

    private var installLinkRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 18))
                .foregroundColor(highContrast ? .white : .aerial)
            VStack(alignment: .leading, spacing: 2) {
                Text("Got an install link?")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(highContrast ? Color.white : .primary)
                Text("Paste a manifest URL to install a pack you've purchased or received.")
                    .font(.caption)
                    .foregroundStyle(highContrast ? Color.white.opacity(0.85) : .secondary)
            }
            Spacer()
            Button {
                showingInstallSheet = true
            } label: {
                Label("Install from link…", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Opens a sheet to paste an install URL")
        }
        .padding(14)
        .background(highContrast ? Color.aerial : Color.aerial.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(highContrast ? Color.aerial : Color.aerial.opacity(0.25),
                        lineWidth: highContrast ? 1 : 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Cards

    @ViewBuilder
    private var cards: some View {
        if expansions.isEmpty {
            Text("No expansions available right now.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(expansions) { expansion in
                    let installed = ExpansionStore.shared.isInstalled(expansion)
                    let isHighlighted = state.highlightedExpansionId == expansion.id
                    ExpansionCard(
                        expansion: expansion,
                        isInstalled: installed,
                        onInstall: { install(expansion) },
                        onVisitSite: { visitSite(expansion) },
                        onOpenCategory: installed ? { openCategory(expansion) } : nil
                    )
                    .id(expansion.id)
                    .overlay(
                        // "Reticle" that fades in when this card is the
                        // navigation target, then fades out after the
                        // auto-clear in consumePendingScroll. Negative
                        // padding sits the stroke just outside the card's
                        // own 10pt corner so it reads as an exterior frame.
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                isHighlighted ? Color.aerial : Color.clear,
                                lineWidth: 3
                            )
                            .padding(-4)
                    )
                    .shadow(
                        color: isHighlighted ? Color.aerial.opacity(0.45) : .clear,
                        radius: 10
                    )
                    .animation(.easeInOut(duration: 0.35), value: state.highlightedExpansionId)
                }
            }
        }
    }

    // MARK: - Advanced disclosure (toggles + More Videos link)

    private var advancedDisclosure: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(filteredHeaders, id: \.name) { header in
                    sourceSection(header)
                }

                Divider()

                Button {
                    if let url = URL(string: "https://aerialscreensaver.github.io/morevideos.html") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("More videos…", systemImage: "globe")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundColor(.aerial)
            }
            .padding(.top, 12)
        } label: {
            Label("Advanced — manage installed sources", systemImage: "slider.horizontal.3")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var filteredHeaders: [SourceHeader] {
        SourceList.categorizedSourceList().filter { $0.name != "Local Sources" }
    }

    private func sourceSection(_ header: SourceHeader) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(header.name.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            ForEach(header.sources, id: \.name) { source in
                sourceRow(source)
            }
        }
    }

    private func sourceRow(_ source: Source) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name)
                    .font(.system(size: 13))
                if !source.description.isEmpty {
                    Text(source.description)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { source.isEnabled() },
                set: { newValue in
                    source.setEnabled(newValue)
                    refreshTick &+= 1
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel(source.name)
            .accessibilityHint("Includes or excludes this source from playback")
        }
    }

    // MARK: - Actions

    private func install(_ expansion: Expansion) {
        guard let manifest = expansion.manifestURL,
              let url = URL(string: manifest) else { return }
        SourceList.fetchOnlineManifest(url: url)
        // Same async pattern as InstallFromLinkView — give the catalog
        // time to refresh, then bump our local refreshTick so the card
        // flips to Installed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            refreshTick &+= 1
            NotificationCenter.default.post(name: ExpansionStore.didChangeNotification, object: nil)
        }
    }

    private func visitSite(_ expansion: Expansion) {
        guard let url = URL(string: expansion.websiteURL) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Jump from the showcase straight to the pack's filtered video
    /// list. Same selection the sidebar's child row drives, so the
    /// user lands in the familiar grid view for that source.
    private func openCategory(_ expansion: Expansion) {
        state.clearSelection()
        state.selectedSidebarItem = .source(expansion.sourceName)
    }
}
