//
//  InstallFromLinkView.swift
//  Aerial Companion
//
//  Sheet shown when the user clicks "Got an install link?" on the
//  Expansions page. Reuses `SourceList.fetchOnlineManifest(url:)` —
//  the same flow the old Manage Source popover triggered.
//

import SwiftUI
import AppKit

/// One newly-installed source's display info, reported back to the
/// parent so the thank-you sheet can list multiple sources from a
/// meta-manifest install.
struct InstalledSource: Identifiable, Hashable {
    let name: String
    let description: String
    let isCachable: Bool
    var id: String { name }
}

/// Outcome of an install-from-link attempt, reported back to the
/// parent so it can present the right follow-up sheet (thank-you on
/// fresh installs, "Already installed" when the user pasted a URL for
/// packs they already have). Both cases carry lists so the meta-
/// manifest path (multiple sources at once) lands in the same UX as
/// the single-manifest path.
enum InstallFromLinkResult {
    /// One or more sources were installed. The list may include any
    /// mix of free / paid. The parent shows the thank-you sheet only
    /// when at least one `added` entry has `isCachable == false`.
    /// Empty `added` means a network or parse failure — the install
    /// path's own error alert has already surfaced, so the parent
    /// silently no-ops.
    case installed(added: [InstalledSource])
    /// Every proposed source was already in `SourceList.list`.
    /// Nothing was downloaded. Lists all skipped names for the
    /// already-installed sheet's body.
    case alreadyInstalled(names: [String])
}

struct InstallFromLinkView: View {
    let onComplete: (InstallFromLinkResult) -> Void
    let onCancel: () -> Void

    @State private var urlString: String = ""
    @State private var isInstalling: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "link.badge.plus")
                        .foregroundColor(.aerial)
                    Text("Install from link")
                }
                .font(.system(size: 28, weight: .bold))

                Text("Paste the install URL you received. This is typically a manifest URL from a paid expansion's confirmation email or a community pack you'd like to add.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("https://...", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 16))
                .disabled(isInstalling)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isInstalling)

                Button(isInstalling ? "Installing…" : "Install") {
                    install()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValidURL || isInstalling)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    /// Whitespace-and-newline trimmed view of the user's input. Used
    /// for validation and the install call so a stray leading space
    /// or trailing newline (common when pasting from email) doesn't
    /// produce a malformed URL.
    private var trimmedURLString: String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValidURL: Bool {
        guard let url = URL(string: trimmedURLString) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    private func install() {
        let cleaned = trimmedURLString
        guard let url = URL(string: cleaned) else { return }
        // Reflect the cleaned URL back into the field so the user
        // sees exactly what we're using if the install fails.
        if urlString != cleaned {
            urlString = cleaned
        }
        isInstalling = true

        // Pre-flight: peek at the manifest's `name` field(s) before
        // committing to the full install path. Lets us short-circuit
        // the all-already-installed case (single or meta-manifest).
        // Even when we DO install, the dedup in `fetchOnlineManifest`
        // ensures `SourceList.list` never grows a duplicate entry.
        DispatchQueue.global(qos: .userInitiated).async {
            let proposedNames = Self.peekManifestNames(at: url)
            DispatchQueue.main.async {
                let existing = Set(SourceList.list.map { $0.name })
                let proposed = Set(proposedNames)
                let dupes = proposed.intersection(existing)
                let toAdd = proposed.subtracting(existing)

                // All proposed sources are already installed → no
                // install attempt. (When `proposedNames` is empty —
                // peek failed — `toAdd` is also empty but we fall
                // through so the normal install path can surface its
                // own error alert.)
                if !proposedNames.isEmpty && toAdd.isEmpty {
                    isInstalling = false
                    onComplete(.alreadyInstalled(names: dupes.sorted()))
                    return
                }
                performInstall(url: url)
            }
        }
    }

    /// Runs the actual `fetchOnlineManifest` + settle + diff cycle.
    /// Reached when at least one proposed source is new (or when the
    /// peek failed and we want the regular install path's error
    /// alert to fire).
    private func performInstall(url: URL) {
        let beforeNames = Set(SourceList.list.map { $0.name })

        SourceList.fetchOnlineManifest(url: url)
        // `fetchOnlineManifest` is async internally and triggers
        // `VideoList.instance.reloadSources()` on success. The 1s delay
        // matches the existing pattern from `SourceManagementPopover`
        // and gives the catalog time to refresh before we dismiss.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            isInstalling = false
            NotificationCenter.default.post(name: ExpansionStore.didChangeNotification, object: nil)

            let afterNames = Set(SourceList.list.map { $0.name })
            let addedNames = afterNames.subtracting(beforeNames)
            let added: [InstalledSource] = addedNames.compactMap { name in
                guard let s = SourceList.list.first(where: { $0.name == name }) else { return nil }
                return InstalledSource(
                    name: name,
                    description: s.description,
                    isCachable: s.isCachable
                )
            }.sorted { $0.name < $1.name }
            onComplete(.installed(added: added))
        }
    }

    /// Synchronously fetch manifest.json at the given URL and return
    /// every source name it proposes to install:
    ///   - single manifest → `[manifest.name]`
    ///   - meta-manifest    → `[sources[0].name, sources[1].name, …]`
    /// Returns `[]` on any error (network, parse, missing field) —
    /// the caller treats that as "no pre-flight information" and
    /// falls through to the normal install path, which surfaces its
    /// own error alert if the fetch later fails. Must be called off
    /// the main thread.
    private static func peekManifestNames(at url: URL) -> [String] {
        let manifestURL = url.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        if let dict = json as? [String: Any] {
            // Meta-manifest first: `{"sources": [{ "name": … }, …]}`
            if let arr = dict["sources"] as? [[String: Any]] {
                return arr.compactMap { $0["name"] as? String }
            }
            // Single manifest: `{"name": …}`
            if let name = dict["name"] as? String {
                return [name]
            }
        }
        return []
    }
}
