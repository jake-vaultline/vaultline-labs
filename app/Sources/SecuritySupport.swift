import Foundation
import SwiftUI

enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}

/// Complete request ledger for the optional Drive Passport service.
@MainActor
final class NetworkLog: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let at = Date()
        let method: String
        let host: String
        let path: String
        var status: Int?
        var bytesOut: Int
        var bytesIn: Int = 0
        var error: String?

        var summary: String {
            let state = status.map(String.init) ?? (error != nil ? "failed" : "…")
            return "\(method) \(host)\(path) → \(state)"
        }
    }

    @Published private(set) var entries: [Entry] = []

    func begin(method: String, url: URL, bytesOut: Int) -> UUID {
        let entry = Entry(method: method, host: url.host ?? "?", path: url.path, bytesOut: bytesOut)
        entries.insert(entry, at: 0)
        if entries.count > 500 { entries.removeLast() }
        return entry.id
    }

    func finish(_ id: UUID, status: Int?, bytesIn: Int, error: String?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].status = status
        entries[index].bytesIn = bytesIn
        entries[index].error = error
    }
}

/// Hosted-service credentials stay in Keychain and never enter the portable
/// team configuration or the app's config.json.
enum Keychain {
    private static let service = "com.vaultline.ingest"

    @discardableResult
    static func set(_ value: String, for key: String) -> OSStatus {
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: Data(value.utf8),
        ]
        return SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var output: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &output) == errSecSuccess,
              let data = output as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
