//
//  ReleaseNotesWindow.swift
//  Aerial
//
//  "What's New" viewer: fetches the Sparkle appcast, lists released
//  versions (beta-channel items only when the beta channel is on), and
//  renders each item's hosted markdown notes. No WebKit and no
//  packages — the notes' actual shape (headings, bullets, paragraphs
//  with inline bold/code/links) renders fine with a small line-based
//  SwiftUI markdown view.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Appcast model + parser

struct AppcastItem: Identifiable, Equatable {
    var id: String { version }
    var title: String
    var version: String          // sparkle:shortVersionString
    var pubDate: String
    var channel: String?         // "beta" or nil (stable)
    var notesURL: URL?

    var isCurrentVersion: Bool {
        version == (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    }
}

/// Minimal XMLParser pass over the Sparkle RSS: one AppcastItem per
/// <item>, reading title / shortVersionString / pubDate / channel /
/// releaseNotesLink.
final class AppcastParser: NSObject, XMLParserDelegate {
    private var items: [AppcastItem] = []
    private var current: AppcastItem?
    private var text = ""

    static func parse(_ data: Data) -> [AppcastItem] {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if name == "item" {
            current = AppcastItem(title: "", version: "", pubDate: "", channel: nil, notesURL: nil)
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title": current?.title = value
        case "sparkle:shortVersionString": current?.version = value
        case "pubDate": current?.pubDate = value
        case "sparkle:channel": current?.channel = value
        case "sparkle:releaseNotesLink": current?.notesURL = URL(string: value)
        case "item":
            if let item = current, !item.version.isEmpty {
                items.append(item)
            }
            current = nil
        default: break
        }
    }
}

// MARK: - View model

@MainActor
final class ReleaseNotesModel: ObservableObject {
    @Published var items: [AppcastItem] = []
    @Published var selectedVersion: String?
    @Published var notesMarkdown: String?
    @Published var errorMessage: String?
    @Published var isLoading = false

    private var notesCache: [String: String] = [:]

    func load() {
        guard items.isEmpty else { return }
        guard let feedString = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let feedURL = URL(string: feedString) else {
            errorMessage = "No update feed configured."
            return
        }
        isLoading = true
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: feedURL)
                var parsed = AppcastParser.parse(data)
                // Hide beta items for stable-channel users.
                if !BetaChannel.isEnabled {
                    parsed = parsed.filter { $0.channel != "beta" }
                }
                items = parsed
                isLoading = false
                if let first = parsed.first {
                    select(version: first.version)
                }
            } catch {
                isLoading = false
                errorMessage = "Couldn't load the update feed — check your connection.\n(\(error.localizedDescription))"
            }
        }
    }

    func select(version: String) {
        selectedVersion = version
        errorMessage = nil
        if let cached = notesCache[version] {
            notesMarkdown = cached
            return
        }
        notesMarkdown = nil
        guard let item = items.first(where: { $0.version == version }),
              let notesURL = item.notesURL else {
            notesMarkdown = "_No release notes for this version._"
            return
        }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: notesURL)
                let markdown = String(data: data, encoding: .utf8) ?? ""
                notesCache[version] = markdown
                if selectedVersion == version {
                    notesMarkdown = markdown
                }
            } catch {
                if selectedVersion == version {
                    notesMarkdown = "_Couldn't load the notes for this version._"
                }
            }
        }
    }
}

// MARK: - Simple markdown rendering

/// Line-based markdown: #-headings, "- " bullets, paragraphs with
/// inline bold/italic/code/links via Text(.init(_:)). Enough for our
/// release notes; not a general renderer.
struct SimpleMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    Spacer().frame(height: 2)
                } else if line.hasPrefix("### ") {
                    Text(.init(String(line.dropFirst(4))))
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.top, 4)
                } else if line.hasPrefix("## ") {
                    Text(.init(String(line.dropFirst(3))))
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.top, 6)
                } else if line.hasPrefix("# ") {
                    Text(.init(String(line.dropFirst(2))))
                        .font(.system(size: 18, weight: .bold))
                        .padding(.top, 6)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").font(.system(size: 13))
                        Text(.init(String(line.dropFirst(2))))
                            .font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 8)
                } else {
                    Text(.init(line))
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }
}

// MARK: - Main view

struct ReleaseNotesView: View {
    @StateObject private var model = ReleaseNotesModel()

    var body: some View {
        HSplitView {
            // Version list
            List(model.items, selection: Binding(
                get: { model.selectedVersion },
                set: { if let v = $0 { model.select(version: v) } }
            )) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.version)
                            .font(.system(size: 13, weight: .medium))
                        if item.channel == "beta" {
                            Text("beta")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.2))
                                .foregroundColor(.orange)
                                .cornerRadius(3)
                        }
                        if item.isCurrentVersion {
                            Text("installed")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.green.opacity(0.2))
                                .foregroundColor(.green)
                                .cornerRadius(3)
                        }
                    }
                    if !item.pubDate.isEmpty {
                        Text(item.pubDate.prefix(16))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .tag(item.version)
            }
            .frame(minWidth: 170, maxWidth: 240)

            // Notes
            Group {
                if let markdown = model.notesMarkdown {
                    ScrollView {
                        SimpleMarkdownView(markdown: markdown)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                } else if let error = model.errorMessage {
                    VStack(spacing: 8) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary)
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity)
        }
        .frame(minWidth: 560, minHeight: 380)
        .onAppear { model.load() }
    }
}

// MARK: - Window controller

/// Retained window controller (LiveFeedPreviewWindowController pattern):
/// one shared window, deduped/refocused on repeat opens.
final class ReleaseNotesWindowController: NSWindowController {
    private static var current: ReleaseNotesWindowController?

    static func show() {
        if let existing = current {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: ReleaseNotesView())
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "What's New in Aerial"
        window.setContentSize(NSSize(width: 720, height: 480))
        window.isReleasedWhenClosed = false
        window.center()

        let controller = ReleaseNotesWindowController(window: window)
        current = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
