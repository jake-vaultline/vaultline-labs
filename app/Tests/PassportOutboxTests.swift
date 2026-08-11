import Foundation
import XCTest
@testable import VaultlineIngest

final class PassportOutboxTests: XCTestCase {
    private var directory: URL!
    private var outbox: PassportOutbox!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultline-passport-outbox-\(UUID().uuidString)",
                                    isDirectory: true)
        outbox = try PassportOutbox(databaseURL: directory.appendingPathComponent("outbox.sqlite3"))
    }

    override func tearDownWithError() throws {
        outbox = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testEnqueueIsIdempotentAndRemovable() throws {
        let payload = Data("{\"schema_version\":1}".utf8)
        let first = try outbox.enqueue(
            serviceURL: "https://tags.example.test", driveID: "drive-1",
            volumeID: "volume-1", payload: payload, idempotencyKey: "event-1")
        let replay = try outbox.enqueue(
            serviceURL: "https://tags.example.test", driveID: "drive-1",
            volumeID: "volume-1", payload: payload, idempotencyKey: "event-1")

        XCTAssertEqual(first, replay)
        XCTAssertEqual(try outbox.count(), 1)
        XCTAssertEqual(try outbox.ready().first?.payload, payload)

        try outbox.remove(first)
        XCTAssertEqual(try outbox.count(), 0)
    }

    func testFailurePersistsAndBacksOff() throws {
        let id = try outbox.enqueue(
            serviceURL: "https://tags.example.test", driveID: "drive-2",
            volumeID: "volume-2", payload: Data("{}".utf8),
            idempotencyKey: "event-2")

        try outbox.recordFailure(id, attempts: 0, error: "offline")

        XCTAssertEqual(try outbox.count(), 1)
        XCTAssertEqual(try outbox.attempts(for: id), 1)
        XCTAssertTrue(try outbox.ready().isEmpty)
    }
}
