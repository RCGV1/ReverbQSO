// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Security
import os

/// Provides secure storage for EchoLink credentials using the iOS Keychain.
enum KeychainService {

    private static let logger = Logger(subsystem: "org.reverbqso.app", category: "Keychain")

    private static let serviceName = "org.OpenEchoLink"
    private static let callsignAccount = "echolink_callsign"
    private static let passwordAccount = "echolink_password"
    private static let proxyPasswordAccount = "echolink_proxy_password"
    private static let savedCallsignsKey = "echolinkSavedCallsigns"

    static func savedCallsigns(defaults: UserDefaults = .standard) -> [String] {
        var callsigns = defaults.stringArray(forKey: savedCallsignsKey) ?? []
        if let legacy = loadCallsign(), !legacy.isEmpty, !callsigns.contains(legacy) {
            callsigns.insert(legacy, at: 0)
        }
        return callsigns
    }

    static func loadPassword(for callsign: String) -> String? {
        let normalized = callsign.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let password = loadItem(account: passwordAccountName(for: normalized)) { return password }
        return loadCallsign() == normalized ? loadPassword() : nil
    }

    @discardableResult
    static func activate(callsign: String) -> Bool {
        let normalized = callsign.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let password = loadPassword(for: normalized) else { return false }
        return saveItem(account: callsignAccount, value: normalized)
            && saveItem(account: passwordAccount, value: password)
    }

    @discardableResult
    static func remove(callsign: String, defaults: UserDefaults = .standard) -> Bool {
        let normalized = callsign.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let removed = deleteItem(account: passwordAccountName(for: normalized))
        defaults.set(savedCallsigns(defaults: defaults).filter { $0 != normalized }, forKey: savedCallsignsKey)
        if loadCallsign() == normalized {
            return deleteItem(account: callsignAccount) && deleteItem(account: passwordAccount) && removed
        }
        return removed
    }

    // MARK: - Public API

    /// Save the callsign and password to the Keychain.
    @discardableResult
    static func save(callsign: String, password: String, makeActive: Bool = true) -> Bool {
        let normalized = callsign.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let accountOk = saveItem(account: passwordAccountName(for: normalized), value: password)
        let callsignOk = !makeActive || saveItem(account: callsignAccount, value: normalized)
        let passwordOk = !makeActive || saveItem(account: passwordAccount, value: password)
        guard accountOk && callsignOk && passwordOk else { return false }
        var accounts = savedCallsigns()
        if !accounts.contains(normalized) { accounts.append(normalized) }
        UserDefaults.standard.set(accounts, forKey: savedCallsignsKey)
        return true
    }

    /// Load the stored callsign, or nil if not found.
    static func loadCallsign() -> String? {
        loadItem(account: callsignAccount)
    }

    /// Load the stored password, or nil if not found.
    static func loadPassword() -> String? {
        loadItem(account: passwordAccount)
    }

    @discardableResult
    static func saveProxyPassword(_ password: String) -> Bool {
        saveItem(account: proxyPasswordAccount, value: password)
    }

    static func loadProxyPassword() -> String? {
        loadItem(account: proxyPasswordAccount)
    }

    @discardableResult
    static func deleteProxyPassword() -> Bool {
        deleteItem(account: proxyPasswordAccount)
    }

    /// Delete all stored credentials from the Keychain.
    @discardableResult
    static func delete() -> Bool {
        guard let callsign = loadCallsign() else {
            return deleteItem(account: passwordAccount)
        }
        return remove(callsign: callsign)
    }

    // MARK: - Private Helpers

    private static func saveItem(account: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query = baseQuery(account: account)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound {
            logger.error("Credential update failed account=\(account, privacy: .public) status=\(updateStatus)")
            return false
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
#if !targetEnvironment(macCatalyst)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
#endif

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("Credential storage failed account=\(account, privacy: .public) status=\(status)")
        }
        return status == errSecSuccess
    }

    private static func loadItem(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func deleteItem(account: String) -> Bool {
        let query = baseQuery(account: account)

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
#if targetEnvironment(macCatalyst)
        // Local Catalyst builds without an application-identifier entitlement
        // cannot access the data-protection keychain. Use the Mac login keychain.
        query[kSecUseDataProtectionKeychain as String] = false
#endif
        return query
    }

    private static func passwordAccountName(for callsign: String) -> String {
        "echolink_password_\(callsign)"
    }
}
