import Foundation
import HushtypeCore
import Security

/// One-time move from the app's previous name (Murmur, bundle id app.murmur.Murmur): settings,
/// history, recordings, learned habits, downloaded models, logs and saved secrets.
enum LegacyMigration {
    static let oldBundleID = "app.murmur.Murmur"
    static let oldSettingsKey = "murmur.settings.v1"
    static let oldFolder = "Murmur"

    static func run() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let moves = [
            (support.appendingPathComponent(oldFolder), support.appendingPathComponent("Hushtype")),
            (library.appendingPathComponent("Logs/\(oldFolder)"), library.appendingPathComponent("Logs/Hushtype")),
        ]
        for (old, new) in moves where fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) {
            try? fm.moveItem(at: old, to: new)
        }

        // Preferences live under the bundle id, which changed.
        let defaults = UserDefaults.standard
        if defaults.data(forKey: HushtypeSettings.key) == nil,
           let old = UserDefaults(suiteName: oldBundleID)?.data(forKey: oldSettingsKey) {
            defaults.set(old, forKey: HushtypeSettings.key)
        }

        // Secrets: copy without ever showing a Keychain prompt (skip if access would need one).
        for account in ["anthropic-api-key", "proxy-token"] {
            guard (try? Keychain.read(service: "app.hushtype.Hushtype", account: account)) == nil,
                  let value = readSilently(service: oldBundleID, account: account) else { continue }
            try? Keychain.write(value, service: "app.hushtype.Hushtype", account: account)
        }
    }

    private static func readSilently(service: String, account: String) -> String? {
        let ctx: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: account,
                                  kSecReturnData as String: true,
                                  kSecMatchLimit as String: kSecMatchLimitOne,
                                  kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip]
        var out: CFTypeRef?
        guard SecItemCopyMatching(ctx as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
