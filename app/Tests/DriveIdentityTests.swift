import XCTest
@testable import VaultlineIngest

@MainActor
final class DriveIdentityTests: XCTestCase {
    func testPossibleMatchResponseDecodesCandidateEvidence() throws {
        let payload = Data(#"""
        {
          "drive_id": null,
          "match": "possible",
          "review_required": true,
          "review_kind": "possible_match",
          "resolvable": true,
          "candidates": [{
            "drive_id": "drive-1",
            "display_name": "Archive A",
            "matched_identifiers": ["capacity"]
          }]
        }
        """#.utf8)
        let decoder = JSONDecoder()

        let result = try decoder.decode(DrivePassportClient.DiscoverResult.self, from: payload)

        XCTAssertTrue(result.reviewRequired)
        XCTAssertEqual(result.reviewKind, "possible_match")
        XCTAssertEqual(result.candidates?.first?.driveID, "drive-1")
        XCTAssertEqual(result.candidates?.first?.matchedIdentifiers, ["capacity"])
    }

    func testIdentityResolutionEncodesIntentWithoutInventingCandidate() {
        let bind = DrivePassportClient.IdentityResolution.bindExisting("drive-1")
        XCTAssertEqual(bind.action, "bind_existing")
        XCTAssertEqual(bind.candidateDriveID, "drive-1")

        let create = DrivePassportClient.IdentityResolution.createNew
        XCTAssertEqual(create.action, "create_new")
        XCTAssertNil(create.candidateDriveID)
    }

    func testServiceResponsesDecodeSnakeCaseIdentifiers() throws {
        let decoder = JSONDecoder()
        let connect = try decoder.decode(
            DrivePassportClient.ConnectResult.self,
            from: Data(#"{"device_token":"secret","device_id":"device-1","workspace_name":"Vaultline"}"#.utf8))
        XCTAssertEqual(connect.deviceID, "device-1")
        XCTAssertEqual(connect.deviceToken, "secret")

        let snapshot = try decoder.decode(
            DrivePassportClient.SnapshotResult.self,
            from: Data(#"{"snapshot_id":"snapshot-1","idempotent_replay":false,"tag_paired":true}"#.utf8))
        XCTAssertEqual(snapshot.snapshotID, "snapshot-1")
        XCTAssertTrue(snapshot.tagPaired == true)

        let pairing = try decoder.decode(
            DrivePassportClient.PairingResult.self,
            from: Data(#"{"code":"ABC123","expires_at":"2026-08-09T12:00:00Z"}"#.utf8))
        XCTAssertEqual(pairing.code, "ABC123")
        XCTAssertEqual(pairing.expiresAt, "2026-08-09T12:00:00Z")
    }

    func testQueuedSnapshotPayloadRoundTripsItsIdempotencyKey() throws {
        let body = DrivePassportClient.SnapshotBody(
            schemaVersion: 1,
            observedAt: "2026-08-09T12:00:00Z",
            scanMode: "quick",
            fileCount: 3,
            totalBytes: 100,
            usedBytes: 40,
            freeBytes: 60,
            topLevel: ["Projects": 40],
            change: nil,
            manifestHash: "hash",
            clientEventId: "drive:time:hash")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let payload = try encoder.encode(body)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let decoded = try decoder.decode(DrivePassportClient.SnapshotBody.self, from: payload)

        XCTAssertEqual(decoded.clientEventId, "drive:time:hash")
    }
}
