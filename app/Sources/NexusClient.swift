import Foundation
import Combine

/// The client side of Relay.
///
/// This is what replaces the "run this command to install the Relay client"
/// step: a paying client downloads the same app a stranger downloads, pastes a
/// Nexus URL and a pairing code, and their workstation is now reporting.
///
/// Two hard boundaries:
///
/// 1. **Media never moves.** There is no upload path for footage in this file
///    and there never will be. Metadata and checksums only. That boundary is the
///    entire reason a client trusts a local-first system.
/// 2. **Every request is logged** to `NetworkLog` and shown in Settings. Ingest
///    can't prove restraint through entitlements the way Drive Inspector does —
///    it needs the network — so it proves it by showing its work. Unpaired, that
///    log stays empty and the user can watch it stay empty.
@MainActor
final class NexusClient: ObservableObject {

    @Published private(set) var isReachable = false
    @Published private(set) var lastError: String?
    let log = NetworkLog()

    private var bag = Set<AnyCancellable>()

    /// The log is its own ObservableObject, and SwiftUI doesn't observe nested
    /// ones. Forward it here as well as in AppState, so anything watching the
    /// client sees new requests appear.
    init() {
        log.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.httpCookieStorage = nil
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    // MARK: Pairing

    struct PairResult: Decodable {
        let deviceToken: String
        let deviceName: String
        let serverName: String
    }

    func pair(urlString: String, code: String, deviceName: String) async throws -> PairResult {
        let result: PairResult = try await send(
            urlString: urlString, path: "/api/relay/pair", method: "POST", token: nil,
            body: ["pairingCode": code, "deviceName": deviceName,
                   "client": "vaultline-ingest", "version": Self.version])
        let keychainStatus = Keychain.set(result.deviceToken, for: tokenKey(urlString))
        guard keychainStatus == errSecSuccess else { throw NexusError.keychain(keychainStatus) }
        isReachable = true
        return result
    }

    func unpair(urlString: String) {
        Keychain.delete(tokenKey(urlString))
        isReachable = false
    }

    // MARK: Config pull

    func fetchConfig(_ nexus: NexusConfig) async throws -> IngestConfig {
        try await send(urlString: nexus.url, path: "/api/relay/config",
                       method: "GET", token: token(for: nexus.url), body: nil)
    }

    // MARK: Push

    struct IngestContextValue {
        let fieldID: UUID
        let label: String
        let kind: IngestFormField.Kind
        let value: String
    }

    /// Reports a finished ingest: what came in, where it went, and the checksum
    /// of every verified file. No media.
    func reportIngest(_ nexus: NexusConfig,
                      sourceName: String,
                      files: [IngestFile],
                      destinations: [Destination],
                      context: [IngestContextValue]) async throws {
        let payload: [String: Any] = [
            "sourceName": sourceName,
            "completedAt": ISO8601DateFormatter().string(from: Date()),
            "destinations": destinations.map { ["root": $0.root, "label": $0.label] },
            "files": files.compactMap { f -> [String: Any]? in
                guard let hash = f.sourceHash else { return nil }
                let verified = f.destinations.filter { $0.value.isVerified }.map(\.key)
                guard !verified.isEmpty else { return nil }
                return ["path": f.relativePath, "size": f.size,
                        "hash": hash, "verifiedAt": verified]
            },
            // User-configured ingest context is metadata, never media. Stable
            // field IDs let Archive map renamed labels without hardcoding one
            // team's form into this client.
            "context": context.map {
                ["fieldID": $0.fieldID.uuidString, "label": $0.label,
                 "kind": $0.kind.rawValue, "value": $0.value]
            },
        ]
        let _: Empty = try await send(urlString: nexus.url, path: "/api/relay/ingest",
                                      method: "POST", token: token(for: nexus.url),
                                      body: payload)
    }

    /// Registers mounted volumes so Relay's drive registry stays current without
    /// anyone maintaining it by hand.
    func reportVolumes(_ nexus: NexusConfig, volumes: [[String: Any]]) async throws {
        let _: Empty = try await send(urlString: nexus.url, path: "/api/relay/volumes",
                                      method: "POST", token: token(for: nexus.url),
                                      body: ["volumes": volumes])
    }

    // MARK: Transport

    private struct Empty: Decodable {}

    private func send<T: Decodable>(urlString: String,
                                    path: String,
                                    method: String,
                                    token: String?,
                                    body: [String: Any]?) async throws -> T {
        guard var comps = URLComponents(string: urlString) else {
            throw NexusError.badURL
        }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + path
        guard let url = comps.url else { throw NexusError.badURL }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Vaultline Ingest/\(Self.version)", forHTTPHeaderField: "User-Agent")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let entry = log.begin(method: method, url: url, bytesOut: req.httpBody?.count ?? 0)

        do {
            let (data, response) = try await session.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            log.finish(entry, status: code, bytesIn: data.count, error: nil)

            guard (200..<300).contains(code) else {
                lastError = "Server returned \(code)"
                throw NexusError.http(code)
            }
            isReachable = true
            lastError = nil
            if T.self == Empty.self { return Empty() as! T }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            log.finish(entry, status: nil, bytesIn: 0, error: error.localizedDescription)
            isReachable = false
            lastError = error.localizedDescription
            throw error
        }
    }

    private func token(for url: String) -> String? { Keychain.get(tokenKey(url)) }
    private func tokenKey(_ url: String) -> String { "nexus-token::\(url)" }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}

enum NexusError: LocalizedError {
    case badURL, http(Int), keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .badURL:        return "That doesn't look like a valid Media Nexus address."
        case .http(let c):   return "The Media Nexus returned \(c)."
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "This Mac couldn't securely save its Media Nexus credential (\(detail)). Pair again after Keychain access is restored."
        }
    }
}

// MARK: - Network log

/// Every request the app makes, shown in Settings.
///
/// This is the app's substitute for Drive Inspector's provable no-network
/// entitlement. It is only meaningful if it is genuinely complete — if any code
/// path ever bypasses `NexusClient.send`, this stops being evidence and starts
/// being decoration.
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
            let s = status.map(String.init) ?? (error != nil ? "failed" : "…")
            return "\(method) \(host)\(path) → \(s)"
        }
    }

    @Published private(set) var entries: [Entry] = []

    func begin(method: String, url: URL, bytesOut: Int) -> UUID {
        let e = Entry(method: method, host: url.host ?? "?", path: url.path, bytesOut: bytesOut)
        entries.insert(e, at: 0)
        if entries.count > 500 { entries.removeLast() }
        return e.id
    }

    func finish(_ id: UUID, status: Int?, bytesIn: Int, error: String?) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].status = status
        entries[i].bytesIn = bytesIn
        entries[i].error = error
    }
}

// MARK: - Keychain

/// The device token never touches config.json — a file that syncs, backs up and
/// gets screenshotted.
enum Keychain {
    private static let service = "com.vaultline.ingest"

    @discardableResult
    static func set(_ value: String, for key: String) -> OSStatus {
        delete(key)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: Data(value.utf8),
            // This Developer ID build currently uses the traditional macOS
            // keychain. Explicitly prevent iCloud synchronization. A provisioned
            // data-protection keychain is required before claiming device-only
            // backup behavior; see STATUS.md.
        ]
        return SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
