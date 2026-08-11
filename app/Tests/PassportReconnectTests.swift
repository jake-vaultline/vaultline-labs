import Foundation
import XCTest
@testable import VaultlineIngest

@MainActor
final class PassportReconnectTests: XCTestCase {
    private var directory: URL!
    private var outbox: PassportOutbox!
    private var session: URLSession!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultline-passport-reconnect-\(UUID().uuidString)",
                                    isDirectory: true)
        outbox = try PassportOutbox(databaseURL: directory.appendingPathComponent("outbox.sqlite3"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineThenOnlineURLProtocol.self]
        session = URLSession(configuration: configuration)
        OfflineThenOnlineURLProtocol.reset(failFirstSnapshot: true)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        session = nil
        outbox = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testOfflineSnapshotQueuesThenFlushesAfterReconnect() async throws {
        let serviceURL = "https://offline-reconnect.example.test"
        let client = DrivePassportClient(
            log: NetworkLog(), outbox: outbox, session: session)
        defer { client.disconnect(urlString: serviceURL) }

        _ = try await client.connect(
            urlString: serviceURL, code: "ABC123", deviceName: "Reconnect Test")
        let volume = sampleVolume()
        let config = PassportConfig(
            url: serviceURL, deviceName: "Reconnect Test", connectedAt: Date())

        let offline = try await client.preparePassport(
            config: config, volume: volume, createPairing: false)
        XCTAssertFalse(offline.snapshotSynced)
        XCTAssertEqual(client.pendingUploads, 1)
        XCTAssertEqual(try outbox.count(), 1)
        XCTAssertEqual(OfflineThenOnlineURLProtocol.snapshotAttempts, 1)

        try outbox.makeAllReadyForTesting()
        await client.flushOutbox()

        XCTAssertEqual(OfflineThenOnlineURLProtocol.snapshotAttempts, 2)
        XCTAssertEqual(try outbox.count(), 0)
        XCTAssertEqual(client.pendingUploads, 0)
        XCTAssertEqual(client.completedOutboxSync?.driveID, "drive-reconnect")
        XCTAssertEqual(client.completedOutboxSync?.volumeID, volume.id)
    }

    func testPermanentSnapshotErrorDoesNotDeleteQueuedObservation() async throws {
        OfflineThenOnlineURLProtocol.reset(failFirstSnapshot: false, snapshotStatus: 400)
        let serviceURL = "https://offline-reconnect.example.test"
        let client = DrivePassportClient(
            log: NetworkLog(), outbox: outbox, session: session)
        defer { client.disconnect(urlString: serviceURL) }
        _ = try await client.connect(
            urlString: serviceURL, code: "ABC123", deviceName: "Durability Test")

        do {
            _ = try await client.preparePassport(
                config: PassportConfig(
                    url: serviceURL, deviceName: "Durability Test", connectedAt: Date()),
                volume: sampleVolume(), createPairing: false)
            XCTFail("A rejected snapshot must surface its server error")
        } catch PassportError.http(let status, _) {
            XCTAssertEqual(status, 400)
        }

        XCTAssertEqual(OfflineThenOnlineURLProtocol.snapshotAttempts, 1)
        XCTAssertEqual(try outbox.count(), 1)
        XCTAssertEqual(client.pendingUploads, 1)
        XCTAssertNotNil(client.lastError)
    }

    func testPermanentFlushErrorDoesNotDeletePreviouslyQueuedObservation() async throws {
        let serviceURL = "https://offline-reconnect.example.test"
        let client = DrivePassportClient(
            log: NetworkLog(), outbox: outbox, session: session)
        defer { client.disconnect(urlString: serviceURL) }
        _ = try await client.connect(
            urlString: serviceURL, code: "ABC123", deviceName: "Flush Durability Test")

        let first = try await client.preparePassport(
            config: PassportConfig(
                url: serviceURL, deviceName: "Flush Durability Test", connectedAt: Date()),
            volume: sampleVolume(), createPairing: false)
        XCTAssertFalse(first.snapshotSynced)
        XCTAssertEqual(try outbox.count(), 1)

        OfflineThenOnlineURLProtocol.configureSnapshot(fails: false, status: 400)
        try outbox.makeAllReadyForTesting()
        await client.flushOutbox()

        XCTAssertEqual(OfflineThenOnlineURLProtocol.snapshotAttempts, 2)
        XCTAssertEqual(try outbox.count(), 1)
        XCTAssertEqual(client.pendingUploads, 1)
        XCTAssertNotNil(client.lastError)
    }

    func testCachedDriveRefreshesPhysicalIdentifiersBeforeSnapshot() async throws {
        OfflineThenOnlineURLProtocol.reset(failFirstSnapshot: false)
        let serviceURL = "https://offline-reconnect.example.test"
        let client = DrivePassportClient(
            log: NetworkLog(), outbox: outbox, session: session)
        defer { client.disconnect(urlString: serviceURL) }
        _ = try await client.connect(
            urlString: serviceURL, code: "ABC123", deviceName: "Refresh Test")

        var volume = sampleVolume()
        volume.passportDriveID = "drive-reconnect"
        volume.hardwareIdentity = VolumeHardwareIdentity(
            hardwareSerial: "SERIAL-REFRESH", mediaUUID: "MEDIA-REFRESH",
            vendor: "Example", model: "SSD", transport: "USB", topology: "port-1")
        let result = try await client.preparePassport(
            config: PassportConfig(
                url: serviceURL, deviceName: "Refresh Test", connectedAt: Date()),
            volume: volume, createPairing: false)

        XCTAssertTrue(result.snapshotSynced)
        let body = try XCTUnwrap(OfflineThenOnlineURLProtocol.lastDiscoveryBody)
        XCTAssertEqual(body["resolution"] as? String, "bind_existing")
        XCTAssertEqual(body["candidate_drive_id"] as? String, "drive-reconnect")
        let identifiers = try XCTUnwrap(body["identifiers"] as? [[String: Any]])
        XCTAssertTrue(identifiers.contains { $0["type"] as? String == "hardware_serial" })
    }

    func testCachedDriveConflictBlocksSnapshotUpload() async throws {
        OfflineThenOnlineURLProtocol.reset(failFirstSnapshot: false)
        OfflineThenOnlineURLProtocol.configureDiscovery(driveID: "different-drive")
        let serviceURL = "https://offline-reconnect.example.test"
        let client = DrivePassportClient(
            log: NetworkLog(), outbox: outbox, session: session)
        defer { client.disconnect(urlString: serviceURL) }
        _ = try await client.connect(
            urlString: serviceURL, code: "ABC123", deviceName: "Conflict Test")

        var volume = sampleVolume()
        volume.passportDriveID = "drive-reconnect"
        do {
            _ = try await client.preparePassport(
                config: PassportConfig(
                    url: serviceURL, deviceName: "Conflict Test", connectedAt: Date()),
                volume: volume, createPairing: false)
            XCTFail("A conflicting cached drive ID must block before snapshot upload")
        } catch PassportError.identityCacheConflict {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(OfflineThenOnlineURLProtocol.snapshotAttempts, 0)
        XCTAssertEqual(try outbox.count(), 0)
    }

    func testCachedDriveUsesOfflineFallbackWhenIdentityRefreshCannotConnect() async throws {
        OfflineThenOnlineURLProtocol.reset(failFirstSnapshot: false)
        OfflineThenOnlineURLProtocol.configureDiscovery(fails: true)
        let serviceURL = "https://offline-reconnect.example.test"
        let client = DrivePassportClient(
            log: NetworkLog(), outbox: outbox, session: session)
        defer { client.disconnect(urlString: serviceURL) }
        _ = try await client.connect(
            urlString: serviceURL, code: "ABC123", deviceName: "Fallback Test")

        var volume = sampleVolume()
        volume.passportDriveID = "drive-reconnect"
        let result = try await client.preparePassport(
            config: PassportConfig(
                url: serviceURL, deviceName: "Fallback Test", connectedAt: Date()),
            volume: volume, createPairing: false)

        XCTAssertEqual(result.driveID, "drive-reconnect")
        XCTAssertTrue(result.snapshotSynced)
        XCTAssertEqual(OfflineThenOnlineURLProtocol.snapshotAttempts, 1)
        XCTAssertEqual(try outbox.count(), 0)
    }

    private func sampleVolume() -> KnownVolume {
        KnownVolume(
            id: "54C62B52-9EB8-4DD7-BA10-048F8A0E89E9",
            name: "Offline Drive",
            lastPath: "/Volumes/Offline Drive",
            totalBytes: 2_000_000,
            freeBytes: 1_000_000,
            isRemovable: true,
            firstSeen: Date(), lastSeen: Date(), sightings: 1,
            snapshot: VolumeSnapshot(
                takenAt: Date(), fileCount: 2, totalBytes: 1_000_000,
                folders: ["Footage": "abc-2"], topLevel: ["Footage": 1_000_000]),
            volumeUUID: "54C62B52-9EB8-4DD7-BA10-048F8A0E89E9",
            isMounted: true)
    }
}

private final class OfflineThenOnlineURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var _snapshotAttempts = 0
    private static var _failFirstSnapshot = true
    private static var _snapshotStatus = 201
    private static var _lastDiscoveryBody: [String: Any]?
    private static var _discoveryFails = false
    private static var _discoveryDriveID = "drive-reconnect"

    static var snapshotAttempts: Int {
        lock.withLock { _snapshotAttempts }
    }

    static var lastDiscoveryBody: [String: Any]? {
        lock.withLock { _lastDiscoveryBody }
    }

    static func reset(failFirstSnapshot: Bool, snapshotStatus: Int = 201) {
        lock.withLock {
            _snapshotAttempts = 0
            _failFirstSnapshot = failFirstSnapshot
            _snapshotStatus = snapshotStatus
            _lastDiscoveryBody = nil
            _discoveryFails = false
            _discoveryDriveID = "drive-reconnect"
        }
    }

    static func configureDiscovery(fails: Bool = false,
                                   driveID: String = "drive-reconnect") {
        lock.withLock {
            _discoveryFails = fails
            _discoveryDriveID = driveID
        }
    }

    static func configureSnapshot(fails: Bool, status: Int) {
        lock.withLock {
            _failFirstSnapshot = fails
            _snapshotStatus = status
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/devices/connect") {
            respond(status: 201, json: [
                "device_token": "test-device-token",
                "device_id": "device-reconnect",
                "workspace_name": "Reconnect Workspace",
            ])
        } else if path.hasSuffix("/drives/discover") {
            if let data = requestBodyData(),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                Self.lock.withLock { Self._lastDiscoveryBody = json }
            }
            if Self.lock.withLock({ Self._discoveryFails }) {
                client?.urlProtocol(
                    self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            respond(status: 200, json: [
                "drive_id": Self.lock.withLock { Self._discoveryDriveID },
                "match": "new",
                "review_required": false,
            ])
        } else if path.contains("/snapshots") {
            let attempt = Self.lock.withLock {
                Self._snapshotAttempts += 1
                return Self._snapshotAttempts
            }
            if Self.lock.withLock({ Self._failFirstSnapshot }) && attempt == 1 {
                client?.urlProtocol(
                    self, didFailWithError: URLError(.notConnectedToInternet))
            } else {
                let status = Self.lock.withLock { Self._snapshotStatus }
                if status == 201 {
                    respond(status: status, json: [
                        "snapshot_id": "snapshot-reconnect",
                        "idempotent_replay": false,
                        "tag_paired": false,
                    ])
                } else {
                    respond(status: status, json: ["error": "Snapshot rejected"])
                }
            }
        } else {
            respond(status: 404, json: ["error": "Unexpected test request"])
        }
    }

    override func stopLoading() {}

    private func requestBodyData() -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            body.append(buffer, count: count)
        }
        return body
    }

    private func respond(status: Int, json: [String: Any]) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]),
              let data = try? JSONSerialization.data(withJSONObject: json)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
