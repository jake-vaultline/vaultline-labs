import Foundation
import CryptoKit

/// Client for the narrow hosted Drive Passport service.
///
/// This is intentionally separate from Media Nexus: only bounded drive
/// identity signals and snapshot aggregates leave the Mac. No media, raw local
/// paths, filenames, or hidden-file data are present in these payloads.
@MainActor
final class DrivePassportClient: ObservableObject {
    @Published private(set) var isReachable = false
    @Published private(set) var lastError: String?
    @Published private(set) var pendingUploads = 0
    @Published private(set) var completedOutboxSync: OutboxSync?

    private let log: NetworkLog
    private var outbox: PassportOutbox?
    private var retryTask: Task<Void, Never>?
    private var isFlushing = false
    private static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpCookieStorage = nil
        c.urlCache = nil
        return URLSession(configuration: c)
    }
    private let session: URLSession

    init(log: NetworkLog, outbox injectedOutbox: PassportOutbox? = nil,
         session injectedSession: URLSession? = nil) {
        self.log = log
        session = injectedSession ?? Self.makeSession()
        do {
            let queue = try injectedOutbox ?? PassportOutbox()
            outbox = queue
            pendingUploads = try queue.count()
        } catch {
            outbox = nil
            lastError = error.localizedDescription
        }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                await self.flushOutbox()
            }
        }
        Task { [weak self] in await self?.flushOutbox() }
    }

    struct ConnectResult: Decodable {
        let deviceToken: String
        let deviceID: String
        let workspaceName: String

        private enum CodingKeys: String, CodingKey {
            case deviceToken = "device_token"
            case deviceID = "device_id"
            case workspaceName = "workspace_name"
        }
    }

    struct DiscoverResult: Decodable {
        let driveID: String?
        let match: String
        let reviewRequired: Bool
        let reviewKind: String?
        let resolvable: Bool?
        let candidates: [DriveIdentityCandidate]?

        private enum CodingKeys: String, CodingKey {
            case driveID = "drive_id"
            case match
            case reviewRequired = "review_required"
            case reviewKind = "review_kind"
            case resolvable, candidates
        }
    }

    struct DriveIdentityCandidate: Decodable, Identifiable {
        let driveID: String
        let displayName: String
        let matchedIdentifiers: [String]
        var id: String { driveID }

        private enum CodingKeys: String, CodingKey {
            case driveID = "drive_id"
            case displayName = "display_name"
            case matchedIdentifiers = "matched_identifiers"
        }
    }

    struct DriveIdentityReview {
        let volumeID: String
        let volumeName: String
        let kind: String
        let resolvable: Bool
        let candidates: [DriveIdentityCandidate]
    }

    enum IdentityResolution {
        case bindExisting(String)
        case createNew

        var action: String {
            switch self {
            case .bindExisting: return "bind_existing"
            case .createNew: return "create_new"
            }
        }

        var candidateDriveID: String? {
            if case .bindExisting(let driveID) = self { return driveID }
            return nil
        }
    }

    struct SnapshotResult: Decodable {
        let snapshotID: String
        let idempotentReplay: Bool
        let tagPaired: Bool?

        private enum CodingKeys: String, CodingKey {
            case snapshotID = "snapshot_id"
            case idempotentReplay = "idempotent_replay"
            case tagPaired = "tag_paired"
        }
    }

    struct PairingResult: Decodable {
        let code: String
        let expiresAt: String

        private enum CodingKeys: String, CodingKey {
            case code
            case expiresAt = "expires_at"
        }
    }

    struct PrepareResult {
        let driveID: String
        let pairing: PairingResult?
        let snapshotSynced: Bool
        let tagPaired: Bool
    }

    struct OutboxSync {
        let volumeID: String
        let driveID: String
        let syncedAt: Date
        let tagPaired: Bool
    }

    func connect(urlString: String, code: String, deviceName: String) async throws -> ConnectResult {
        let body = ConnectBody(code: code, deviceName: deviceName,
                               appVersion: NexusClient.version, schemaVersion: 1)
        let result: ConnectResult = try await send(urlString: urlString,
            path: "/api/v1/devices/connect", method: "POST", token: nil, body: body)
        let keychainStatus = Keychain.set(result.deviceToken, for: tokenKey(urlString))
        guard keychainStatus == errSecSuccess else { throw PassportError.keychain(keychainStatus) }
        isReachable = true
        await flushOutbox()
        return result
    }

    func disconnect(urlString: String) {
        Keychain.delete(tokenKey(urlString))
        isReachable = false
    }

    /// Create/match the persistent drive, upload the current quick snapshot,
    /// then issue the five-minute code used by the physical tag page.
    func preparePassport(config: PassportConfig, volume: KnownVolume,
                         createPairing: Bool,
                         identityResolution: IdentityResolution? = nil) async throws -> PrepareResult {
        guard let snapshot = volume.snapshot else { throw PassportError.snapshotRequired }
        guard let token = Keychain.get(tokenKey(config.url)) else { throw PassportError.notConnected }

        let driveID: String
        if let existing = volume.passportDriveID {
            // Refresh identity evidence whenever the service is reachable so
            // volumes enrolled by an older client acquire hardware signals.
            // If the network is down, keep the cached drive ID and let the
            // durable snapshot outbox do its job. Identity conflicts never
            // take that fallback path.
            do {
                let discovered: DiscoverResult = try await send(
                    urlString: config.url, path: "/api/v1/drives/discover",
                    method: "POST", token: token,
                    body: DiscoverBody(
                        displayName: volume.name,
                        identifiers: Self.identifiers(for: volume),
                        resolution: "bind_existing",
                        candidateDriveID: existing,
                        schemaVersion: 1))
                if discovered.reviewRequired {
                    throw PassportError.identityReview(DriveIdentityReview(
                        volumeID: volume.id,
                        volumeName: volume.name,
                        kind: discovered.reviewKind ?? "conflict",
                        resolvable: discovered.resolvable == true,
                        candidates: discovered.candidates ?? []))
                }
                guard discovered.driveID == existing else {
                    throw PassportError.identityCacheConflict
                }
                driveID = existing
            } catch {
                guard shouldRetry(error) else { throw error }
                driveID = existing
            }
        } else {
            let discoverBody = DiscoverBody(
                displayName: volume.name,
                identifiers: Self.identifiers(for: volume),
                resolution: identityResolution?.action,
                candidateDriveID: identityResolution?.candidateDriveID,
                schemaVersion: 1)
            let discovered: DiscoverResult = try await send(
                urlString: config.url, path: "/api/v1/drives/discover",
                method: "POST", token: token, body: discoverBody)
            if discovered.reviewRequired {
                throw PassportError.identityReview(DriveIdentityReview(
                    volumeID: volume.id,
                    volumeName: volume.name,
                    kind: discovered.reviewKind ?? "conflict",
                    resolvable: discovered.resolvable == true,
                    candidates: discovered.candidates ?? []))
            }
            guard let discoveredDriveID = discovered.driveID else {
                throw PassportError.invalidResponse
            }
            driveID = discoveredDriveID
        }

        let encoder = ISO8601DateFormatter()
        encoder.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let observed = encoder.string(from: snapshot.takenAt)
        let manifestHash = Self.manifestHash(snapshot)
        let change = volume.lastChange.map {
            ChangeBody(filesAdded: $0.filesAdded, filesRemoved: $0.filesRemoved,
                       bytesDelta: $0.bytesDelta, foldersChanged: $0.foldersChanged)
        }
        let snapshotBody = SnapshotBody(
            schemaVersion: 1, observedAt: observed, scanMode: "quick",
            fileCount: snapshot.fileCount, totalBytes: volume.totalBytes,
            usedBytes: max(0, volume.totalBytes - volume.freeBytes),
            freeBytes: volume.freeBytes, topLevel: snapshot.topLevel,
            change: change, manifestHash: manifestHash,
            clientEventId: "\(driveID):\(observed):\(manifestHash)")
        let snapshotResult = try await queueAndSendSnapshot(
            config: config, driveID: driveID, volumeID: volume.id,
            token: token, body: snapshotBody)
        guard let snapshotResult else {
            return PrepareResult(driveID: driveID, pairing: nil,
                                 snapshotSynced: false, tagPaired: false)
        }

        let shouldPair = createPairing && snapshotResult.tagPaired != true
        let pairing: PairingResult? = shouldPair ? try await send(
            urlString: config.url, path: "/api/v1/pairing-sessions",
            method: "POST", token: token,
            body: PairingBody(driveID: driveID, schemaVersion: 1)) : nil
        return PrepareResult(driveID: driveID, pairing: pairing,
                             snapshotSynced: true,
                             tagPaired: snapshotResult.tagPaired == true)
    }

    func flushOutbox() async {
        guard !isFlushing, let outbox else { return }
        isFlushing = true
        defer {
            pendingUploads = (try? outbox.count()) ?? pendingUploads
            isFlushing = false
        }
        guard let items = try? outbox.ready() else { return }
        for item in items {
            guard let token = Keychain.get(tokenKey(item.serviceURL)),
                  let body = try? snapshotDecoder.decode(SnapshotBody.self, from: item.payload) else {
                continue
            }
            do {
                let result: SnapshotResult = try await send(
                    urlString: item.serviceURL,
                    path: "/api/v1/drives/\(item.driveID)/snapshots",
                    method: "POST", token: token, body: body)
                try outbox.remove(item.id)
                completedOutboxSync = OutboxSync(
                    volumeID: item.volumeID, driveID: item.driveID,
                    syncedAt: Date(), tagPaired: result.tagPaired == true)
            } catch {
                // A permanent server response must not erase the only queued
                // copy. Keep it durably backed off so a client/server fix can
                // recover it; surface non-retryable failures immediately.
                try? outbox.recordFailure(item.id, attempts: item.attempts,
                                          error: error.localizedDescription)
                if !shouldRetry(error) { lastError = error.localizedDescription }
            }
        }
    }

    private func queueAndSendSnapshot(config: PassportConfig, driveID: String,
                                      volumeID: String, token: String,
                                      body: SnapshotBody) async throws -> SnapshotResult? {
        guard let outbox else { throw PassportError.outboxUnavailable }
        let payload = try snapshotEncoder.encode(body)
        let itemID = try outbox.enqueue(
            serviceURL: config.url, driveID: driveID, volumeID: volumeID,
            payload: payload, idempotencyKey: body.clientEventId)
        pendingUploads = try outbox.count()
        do {
            let result: SnapshotResult = try await send(
                urlString: config.url,
                path: "/api/v1/drives/\(driveID)/snapshots",
                method: "POST", token: token, body: body)
            try outbox.remove(itemID)
            pendingUploads = try outbox.count()
            Task { [weak self] in await self?.flushOutbox() }
            return result
        } catch {
            if !shouldRetry(error) {
                let attempts = (try? outbox.attempts(for: itemID)) ?? 0
                try outbox.recordFailure(itemID, attempts: attempts,
                                         error: error.localizedDescription)
                pendingUploads = try outbox.count()
                lastError = error.localizedDescription
                throw error
            }
            let attempts = (try? outbox.attempts(for: itemID)) ?? 0
            try? outbox.recordFailure(itemID, attempts: attempts,
                                      error: error.localizedDescription)
            pendingUploads = (try? outbox.count()) ?? pendingUploads
            return nil
        }
    }

    private func shouldRetry(_ error: Error) -> Bool {
        guard let passportError = error as? PassportError else { return true }
        switch passportError {
        case .http(let status, _):
            return status == 401 || status == 408 || status == 429 || status >= 500
        case .identityReview, .identityCacheConflict:
            return false
        default:
            return true
        }
    }

    private var snapshotEncoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    private var snapshotDecoder: JSONDecoder {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private func send<T: Decodable, B: Encodable>(urlString: String,
                                                   path: String,
                                                   method: String,
                                                   token: String?,
                                                   body: B) async throws -> T {
        guard var components = URLComponents(string: urlString) else { throw PassportError.badURL }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + path
        guard let url = components.url else { throw PassportError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Vaultline Ingest/\(NexusClient.version)", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let jsonEncoder = JSONEncoder(); jsonEncoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try jsonEncoder.encode(body)

        let entry = log.begin(method: method, url: url, bytesOut: request.httpBody?.count ?? 0)
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            log.finish(entry, status: status, bytesIn: data.count, error: nil)
            guard (200..<300).contains(status) else {
                let serverError = (try? JSONDecoder().decode(ServerError.self, from: data))?.error
                throw PassportError.http(status, serverError)
            }
            isReachable = true; lastError = nil
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            log.finish(entry, status: nil, bytesIn: 0, error: error.localizedDescription)
            isReachable = false; lastError = error.localizedDescription
            throw error
        }
    }

    private static func manifestHash(_ snapshot: VolumeSnapshot) -> String {
        let canonical = snapshot.folders.keys.sorted().map { "\($0)=\(snapshot.folders[$0]!)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Compose bounded identity evidence without ever treating the local
    /// name+capacity registry fallback as a filesystem UUID.
    static func identifiers(for volume: KnownVolume) -> [PassportDriveIdentifier] {
        var result: [PassportDriveIdentifier] = []
        let legacyUUID = UUID(uuidString: volume.id)?.uuidString
        if let uuid = volume.volumeUUID ?? legacyUUID {
            result.append(PassportDriveIdentifier(
                type: "volume_uuid", value: uuid.uppercased(), confidence: 95))
        }
        if let hardware = volume.hardwareIdentity {
            if let serial = hardware.hardwareSerial {
                result.append(PassportDriveIdentifier(
                    type: "hardware_serial", value: serial, confidence: 100))
            }
            if let mediaUUID = hardware.mediaUUID {
                result.append(PassportDriveIdentifier(
                    type: "media_uuid", value: mediaUUID, confidence: 85))
            }
            let model = [hardware.vendor, hardware.model].compactMap { $0 }
                .joined(separator: " | ")
            if !model.isEmpty {
                result.append(PassportDriveIdentifier(
                    type: "device_model", value: model, confidence: 55))
            }
            if let topology = hardware.topology {
                result.append(PassportDriveIdentifier(
                    type: "device_topology", value: topology, confidence: 25))
            }
        }
        result.append(PassportDriveIdentifier(
            type: "capacity", value: String(volume.totalBytes), confidence: 40))
        return result
    }

    private func tokenKey(_ url: String) -> String { "passport-token::\(url)" }

    private struct ConnectBody: Encodable { let code, deviceName, appVersion: String; let schemaVersion: Int }
    private struct DiscoverBody: Encodable {
        let displayName: String
        let identifiers: [PassportDriveIdentifier]
        let resolution: String?
        let candidateDriveID: String?
        let schemaVersion: Int
    }
    struct ChangeBody: Codable { let filesAdded, filesRemoved: Int; let bytesDelta: Int64; let foldersChanged: [String] }
    struct SnapshotBody: Codable {
        let schemaVersion: Int; let observedAt, scanMode: String; let fileCount: Int
        let totalBytes, usedBytes, freeBytes: Int64; let topLevel: [String: Int64]
        let change: ChangeBody?; let manifestHash, clientEventId: String
    }
    private struct PairingBody: Encodable { let driveID: String; let schemaVersion: Int }
    private struct ServerError: Decodable { let error: String }
}

struct PassportDriveIdentifier: Encodable, Equatable {
    let type: String
    let value: String
    let confidence: Int
}

enum PassportError: LocalizedError {
    case badURL, notConnected, snapshotRequired, invalidResponse, outboxUnavailable
    case keychain(OSStatus)
    case identityCacheConflict
    case identityReview(DrivePassportClient.DriveIdentityReview)
    case http(Int, String?)
    var errorDescription: String? {
        switch self {
        case .badURL: return "That doesn't look like a valid Drive Passport address."
        case .notConnected: return "Connect this Mac to your Drive Passport workspace first."
        case .snapshotRequired: return "Scan this drive before creating its passport."
        case .invalidResponse: return "The Drive Passport service returned an incomplete response."
        case .identityReview(let review):
            return review.resolvable
                ? "Confirm whether this is a drive you've enrolled before."
                : "This drive has conflicting strong identity signals and needs administrator review."
        case .identityCacheConflict:
            return "This Mac's saved Drive Passport no longer agrees with the service's identity evidence. No data was uploaded; review the drive record before retrying."
        case .outboxUnavailable: return "The local Drive Passport sync queue is unavailable. Your snapshot remains local and was not uploaded."
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "This Mac couldn't securely save its Drive Passport credential (\(detail)). Connect again after Keychain access is restored."
        case .http(let status, let message): return message ?? "The Drive Passport service returned \(status)."
        }
    }
}
