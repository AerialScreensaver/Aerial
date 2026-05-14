//
//  ExpansionStore.swift
//  Aerial
//
//  Loads the expansion catalog (bundled `expansions.json` for now;
//  remote fetch is a one-method swap later) and answers
//  "is this expansion installed?" by inspecting `SourceList.list`.
//

import Foundation

final class ExpansionStore {
    static let shared = ExpansionStore()

    /// Fired whenever the in-memory `SourceList` mutates and our
    /// installed-state for any expansion may have changed. UI views
    /// observe this to refresh their cards.
    static let didChangeNotification = Notification.Name("com.glouel.aerial.expansionsDidChange")

    private(set) var expansions: [Expansion] = []

    private init() {
        reload()
    }

    /// Re-decode the bundled catalog. Logged failures fall back to an
    /// empty list (the UI shows the header and install-link button so
    /// the user is never stranded).
    func reload() {
        guard let url = Bundle.main.url(forResource: "expansions", withExtension: "json") else {
            errorLog("ExpansionStore: bundled expansions.json not found")
            expansions = []
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let catalog = try JSONDecoder().decode(ExpansionCatalog.self, from: data)
            expansions = catalog.expansions
            debugLog("ExpansionStore: loaded \(expansions.count) expansion(s)")
        } catch {
            errorLog("ExpansionStore: failed to decode expansions.json: \(error.localizedDescription)")
            expansions = []
        }
    }

    /// True if a source matching `expansion.sourceName` is currently
    /// in `SourceList.list`. We don't require the source to be enabled
    /// or fully cached — the moment a user installs the expansion's
    /// manifest the entry shows up here, which is what users intuit
    /// "installed" to mean.
    func isInstalled(_ expansion: Expansion) -> Bool {
        SourceList.list.contains { $0.name == expansion.sourceName }
    }
}
