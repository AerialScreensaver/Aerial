//
//  LiveFeedCredentialStore.swift
//  Aerial
//
//  Stores RTSP credentials in the user's Keychain rather than in
//  live-feeds.json. The URL the Companion persists to disk has its
//  user/password components stripped; they're re-injected only when
//  ffmpeg is launched. Keeps credentials off `/Users/Shared/`, which
//  is readable by other local users on the Mac.
//  Companion-only.
//

import Foundation
import Security

enum LiveFeedCredentialStore {

    private static let service = "com.glouel.aerial.livefeed.rtsp"

    // MARK: - Parsing / stripping

    /// If `raw` is an `rtsp[s]://user:pass@host…` URL, returns the stripped
    /// URL (`rtsp[s]://host…`) and the raw `user:password` fragment so
    /// callers can save it to Keychain. Returns `(raw, nil)` when the URL
    /// has no embedded credentials.
    static func extractCredentials(from raw: String) -> (strippedURL: String, credentials: String?) {
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "rtsp" || scheme == "rtsps" else {
            return (raw, nil)
        }
        guard let user = components.user, !user.isEmpty else {
            return (raw, nil)
        }
        let password = components.password ?? ""
        let creds = password.isEmpty ? user : "\(user):\(password)"
        components.user = nil
        components.password = nil
        return (components.string ?? raw, creds)
    }

    /// Inject a `user:password` fragment back into `rtsp://host/…` so
    /// ffmpeg can use it. No-op when `credentials` is nil.
    static func inject(credentials: String?, into raw: String) -> String {
        guard let creds = credentials, !creds.isEmpty,
              var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "rtsp" || scheme == "rtsps" else {
            return raw
        }
        let parts = creds.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        components.user = parts.first
        components.password = parts.count > 1 ? parts[1] : nil
        return components.string ?? raw
    }

    // MARK: - Keychain

    /// Save / replace the credentials associated with `feedID`. Passing
    /// `nil` deletes the stored item.
    static func save(credentials: String?, for feedID: UUID) {
        // Always wipe an existing entry first — SecItemAdd errors out on
        // duplicates, and SecItemUpdate is awkward when the attribute set
        // might have shifted.
        delete(for: feedID)
        guard let creds = credentials, !creds.isEmpty,
              let data = creds.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: feedID.uuidString,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            errorLog("🔐 Keychain SecItemAdd failed (status=\(status)) for live feed \(feedID)")
        }
    }

    /// Read credentials for `feedID`; `nil` when none are stored.
    static func load(for feedID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: feedID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    static func delete(for feedID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: feedID.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            errorLog("🔐 Keychain SecItemDelete failed (status=\(status)) for live feed \(feedID)")
        }
    }
}
