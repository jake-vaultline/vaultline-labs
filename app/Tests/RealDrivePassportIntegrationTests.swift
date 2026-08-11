import Foundation
import XCTest
@testable import VaultlineIngest

/// Opt-in proofs against a locally running Passport service and a real mounted
/// drive. The normal unit-test run skips these tests; provide the
/// four VAULTLINE_REAL_* environment variables (or a temporary
/// `/tmp/vaultline-real-drive-test.json`). One test exercises the actual content
/// scanner; the other isolates physical identity and native Passport transport.
@MainActor
final class RealDrivePassportIntegrationTests: XCTestCase {
    func testRealDriveGoldenPath() async throws {
        guard let settings = try integrationSettings() else {
            throw XCTSkip("Set VAULTLINE_REAL_* variables or provide the temporary integration config to run the real-drive proof")
        }

        let volume = try makeVolume(settings: settings, scanContents: true)
        XCTAssertGreaterThan(volume.totalBytes, 0)
        XCTAssertGreaterThanOrEqual(volume.snapshot?.fileCount ?? -1, 0)
        try await exercisePassport(settings: settings, volume: volume)
    }

    /// Separates physical identity + native transport evidence from the full
    /// recursive content scan. This remains read-only on the mounted drive and
    /// must not be cited as proof that `VolumeScanner` completed.
    func testRealDriveIdentityTransportWithoutContentScan() async throws {
        guard let settings = try integrationSettings() else {
            throw XCTSkip("Set VAULTLINE_REAL_* variables or provide the temporary integration config to run the real-drive proof")
        }

        let volume = try makeVolume(settings: settings, scanContents: false)
        XCTAssertGreaterThan(volume.totalBytes, 0)
        XCTAssertNotNil(volume.hardwareIdentity?.hardwareSerial)
        try await exercisePassport(settings: settings, volume: volume)
    }

    private func makeVolume(settings: IntegrationSettings,
                            scanContents: Bool) throws -> KnownVolume {
        let root = URL(fileURLWithPath: settings.drivePath, isDirectory: true)
        let values = try root.resourceValues(forKeys: [
            .volumeNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeIsRemovableKey, .volumeIsInternalKey,
        ])
        guard let volumeID = values.volumeUUIDString else {
            throw IntegrationError.missingVolumeUUID
        }
        let snapshot = scanContents
            ? VolumeScanner.snapshot(of: root)
            : VolumeSnapshot(
                takenAt: Date(), fileCount: 0, totalBytes: 0,
                folders: [:], topLevel: [:])
        return KnownVolume(
            id: volumeID,
            name: values.volumeName ?? root.lastPathComponent,
            lastPath: root.path,
            totalBytes: Int64(values.volumeTotalCapacity ?? 0),
            freeBytes: Int64(values.volumeAvailableCapacity ?? 0),
            isRemovable: (values.volumeIsRemovable ?? false) || !(values.volumeIsInternal ?? true),
            firstSeen: Date(),
            lastSeen: Date(),
            sightings: 1,
            snapshot: snapshot,
            volumeUUID: volumeID,
            hardwareIdentity: VolumeHardwareIdentity.read(from: root),
            isMounted: true)
    }

    private func exercisePassport(settings: IntegrationSettings,
                                  volume: KnownVolume) async throws {
        let client = DrivePassportClient(log: NetworkLog())
        defer { client.disconnect(urlString: settings.serviceURL) }
        _ = try await client.connect(
            urlString: settings.serviceURL,
            code: settings.connectCode,
            deviceName: "Real Drive Integration Test")

        let config = PassportConfig(
            url: settings.serviceURL,
            deviceName: "Real Drive Integration Test",
            connectedAt: Date())
        let prepared = try await client.preparePassport(
            config: config, volume: volume, createPairing: true)
        XCTAssertTrue(prepared.snapshotSynced)
        let pairing = try XCTUnwrap(prepared.pairing)

        try await pairTag(
            serviceURL: settings.serviceURL,
            tagToken: settings.tagToken,
            pairingCode: pairing.code)

        let refreshed = try await client.preparePassport(
            config: config, volume: volume, createPairing: false)
        XCTAssertEqual(refreshed.driveID, prepared.driveID)
        XCTAssertTrue(refreshed.snapshotSynced)
        XCTAssertTrue(refreshed.tagPaired)

        let publicHTML = try await fetchPassport(
            serviceURL: settings.serviceURL, tagToken: settings.tagToken, authenticated: false)
        XCTAssertTrue(publicHTML.contains("Sign in to view this drive"))
        XCTAssertFalse(publicHTML.contains(volume.name))

        let authorizedHTML = try await fetchPassport(
            serviceURL: settings.serviceURL, tagToken: settings.tagToken, authenticated: true)
        XCTAssertTrue(authorizedHTML.contains(volume.name))
        XCTAssertTrue(authorizedHTML.contains("Last observed"))
        XCTAssertTrue(authorizedHTML.contains("Quick summary captured by Vaultline Ingest"))
    }

    private func pairTag(serviceURL: String, tagToken: String,
                         pairingCode: String) async throws {
        var request = URLRequest(url: try endpoint(serviceURL, "/api/v1/tags/\(tagToken)/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addOwnerHeaders(to: &request, serviceURL: serviceURL)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": pairingCode])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func fetchPassport(serviceURL: String, tagToken: String,
                               authenticated: Bool) async throws -> String {
        var request = URLRequest(url: try endpoint(serviceURL, "/d/\(tagToken)"))
        if authenticated { addOwnerHeaders(to: &request, serviceURL: serviceURL) }
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return String(decoding: data, as: UTF8.self)
    }

    private func addOwnerHeaders(to request: inout URLRequest, serviceURL: String) {
        request.setValue("real-drive-owner-20260809", forHTTPHeaderField: "oai-authenticated-user-id")
        request.setValue("jake+real-drive@vaultline.test", forHTTPHeaderField: "oai-authenticated-user-email")
        request.setValue(serviceURL, forHTTPHeaderField: "Origin")
        request.setValue("real-drive-local", forHTTPHeaderField: "x-forwarded-for")
    }

    private func endpoint(_ base: String, _ path: String) throws -> URL {
        guard var components = URLComponents(string: base) else { throw IntegrationError.badURL }
        components.path = path
        guard let url = components.url else { throw IntegrationError.badURL }
        return url
    }

    private func integrationSettings() throws -> IntegrationSettings? {
        let environment = ProcessInfo.processInfo.environment
        if let drivePath = environment["VAULTLINE_REAL_DRIVE_PATH"],
           let serviceURL = environment["VAULTLINE_REAL_SERVICE_URL"],
           let connectCode = environment["VAULTLINE_REAL_CONNECT_CODE"],
           let tagToken = environment["VAULTLINE_REAL_TAG_TOKEN"] {
            return IntegrationSettings(
                drivePath: drivePath, serviceURL: serviceURL,
                connectCode: connectCode, tagToken: tagToken)
        }
        let file = URL(fileURLWithPath: "/tmp/vaultline-real-drive-test.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(IntegrationSettings.self, from: Data(contentsOf: file))
    }

    private struct IntegrationSettings: Codable {
        let drivePath: String
        let serviceURL: String
        let connectCode: String
        let tagToken: String
    }

    private enum IntegrationError: Error { case badURL, missingVolumeUUID }
}
