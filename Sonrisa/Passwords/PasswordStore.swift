//
//  PasswordStore.swift
//  Sonrisa
//
//  Saved web passwords, stored as internet-password items in the macOS
//  keychain. Items are created as synchronizable data-protection keychain
//  items, so they sync across the user's devices through iCloud Keychain.
//  When the current signing identity cannot use the data-protection keychain
//  (e.g. ad-hoc signed dev builds), items transparently fall back to the
//  local login keychain — same API, no sync.
//

import Foundation
import LocalAuthentication
import Observation
import Security

/// One saved login, identified by site host + username. The secret itself
/// stays in the keychain and is fetched on demand.
struct SavedCredential: Identifiable, Hashable {
    let host: String
    let username: String
    var id: String { "\(host)\u{1}\(username)" }
}

@MainActor
@Observable
final class PasswordStore {
    static let shared = PasswordStore()

    /// Metadata of every saved login (no secrets). Kept in sync with the
    /// keychain for the Settings UI.
    private(set) var credentials: [SavedCredential] = []

    /// Marks Sonrisa's items so queries never touch other apps' passwords.
    private static let itemDescription = "Sonrisa web password"
    private static let neverSaveKey = "passwordNeverSaveHosts"

    /// False once the data-protection keychain has rejected us
    /// (errSecMissingEntitlement); all further writes go to the login keychain.
    private var cloudAvailable = true

    private init() {
        reload()
    }

    // MARK: Realms

    /// Where an item lives: the synchronizable data-protection keychain
    /// (iCloud Keychain) or the legacy local login keychain.
    private enum Realm: CaseIterable {
        case cloud, local
    }

    private func baseQuery(_ realm: Realm) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrDescription as String: Self.itemDescription,
        ]
        if realm == .cloud {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrSynchronizable as String] = true
        }
        return query
    }

    // MARK: Lookup

    /// All saved logins for a host, most useful first. Called from the CEF
    /// autofill bridge; must stay fast and prompt-free.
    func passwords(for host: String) -> [(username: String, password: String)] {
        var results: [(username: String, password: String)] = []
        var seen = Set<String>()
        for realm in Realm.allCases {
            var query = baseQuery(realm)
            query[kSecAttrServer as String] = host
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            query[kSecReturnAttributes as String] = true
            query[kSecReturnData as String] = true

            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let entries = item as? [[String: Any]] else { continue }
            for entry in entries {
                guard let username = entry[kSecAttrAccount as String] as? String,
                      let data = entry[kSecValueData as String] as? Data,
                      let password = String(data: data, encoding: .utf8),
                      seen.insert(username).inserted else { continue }
                results.append((username, password))
            }
        }
        return results
    }

    /// The secret for one saved login, or nil if it disappeared.
    func password(for credential: SavedCredential) -> String? {
        passwords(for: credential.host)
            .first { $0.username == credential.username }?.password
    }

    /// Fetches a secret only after the user authenticates (Touch ID or the
    /// account password). Used by the Settings UI for reveal/copy.
    func passwordAfterAuthentication(for credential: SavedCredential) async -> String? {
        let context = LAContext()
        let reason = "reveal the saved password for \(credential.host)"
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: reason)
            guard ok else { return nil }
        } catch {
            return nil
        }
        return password(for: credential)
    }

    // MARK: Saving

    enum SaveOffer {
        case new, update
    }

    /// Whether submitting these values should show a save/update prompt.
    /// Nil when the host is muted or the exact login is already saved.
    func offer(host: String, username: String, password: String) -> SaveOffer? {
        guard !neverSaveHosts.contains(host) else { return nil }
        guard let existing = passwords(for: host)
            .first(where: { $0.username == username }) else { return .new }
        return existing.password == password ? nil : .update
    }

    /// Adds or updates a login. Tries the synchronizable (iCloud) keychain
    /// first and falls back to the local keychain when unavailable.
    func save(host: String, username: String, password: String) {
        guard let secret = password.data(using: .utf8) else { return }

        func write(to realm: Realm) -> OSStatus {
            var query = baseQuery(realm)
            query[kSecAttrServer as String] = host
            query[kSecAttrAccount as String] = username

            var add = query
            add[kSecAttrProtocol as String] = kSecAttrProtocolHTTPS
            add[kSecAttrLabel as String] = "Sonrisa — \(host)"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            add[kSecValueData as String] = secret

            let status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem {
                return SecItemUpdate(query as CFDictionary,
                                     [kSecValueData as String: secret] as CFDictionary)
            }
            return status
        }

        if cloudAvailable {
            let status = write(to: .cloud)
            if status == errSecSuccess {
                reload()
                return
            }
            // -34018 = errSecMissingEntitlement: signing identity cannot use
            // the data-protection keychain. Remember and fall back.
            cloudAvailable = false
        }
        if write(to: .local) != errSecSuccess {
            NSLog("[Sonrisa] Failed to save password for %@", host)
        }
        reload()
    }

    func delete(_ credential: SavedCredential) {
        for realm in Realm.allCases {
            var query = baseQuery(realm)
            query[kSecAttrServer as String] = credential.host
            query[kSecAttrAccount as String] = credential.username
            SecItemDelete(query as CFDictionary)
        }
        reload()
    }

    // MARK: Never-save list

    private var neverSaveHosts: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.neverSaveKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.neverSaveKey) }
    }

    func markNeverSave(host: String) {
        neverSaveHosts.insert(host)
    }

    // MARK: Index

    private func reload() {
        var found: [SavedCredential] = []
        var seen = Set<String>()
        for realm in Realm.allCases {
            var query = baseQuery(realm)
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            query[kSecReturnAttributes as String] = true

            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let entries = item as? [[String: Any]] else { continue }
            for entry in entries {
                guard let host = entry[kSecAttrServer as String] as? String,
                      let username = entry[kSecAttrAccount as String] as? String else { continue }
                let credential = SavedCredential(host: host, username: username)
                if seen.insert(credential.id).inserted {
                    found.append(credential)
                }
            }
        }
        credentials = found.sorted {
            ($0.host, $0.username) < ($1.host, $1.username)
        }
    }
}
