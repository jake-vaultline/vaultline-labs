import XCTest
@testable import VaultlineLabsDriveInspector

/// The CSV's per-file inventory is only as good as what Pass 1 keeps. These
/// cover the collection side; `ReportRegressionTests` covers the formatting.
final class InventoryTests: XCTestCase {

    func testWalkKeepsEveryFileNotJustMediaAndNotJustTheLargest() async throws {
        let root = try makeTree([
            ("clip.mov", 9_000_000),
            ("take.wav", 5_000_000),
            ("notes.txt", 40),          // neither media nor large enough to dedupe
            ("nested/sheet.csv", 90),
            ("nested/still.jpg", 300_000)
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let index = MediaIndex()
        var seed = ScanSnapshot()
        seed.rootPath = root.path
        var last = ScanSnapshot()
        for await snap in Walker.walk(root: root, seed: seed, index: index) { last = snap }

        XCTAssertEqual(last.filesScanned, 5)
        XCTAssertEqual(index.all.count, 5, "the inventory is every file the walk saw")
        XCTAssertEqual(index.allOverflow, 0)

        let names = Set(index.all.map { ($0.path as NSString).lastPathComponent })
        XCTAssertEqual(names, ["clip.mov", "take.wav", "notes.txt", "sheet.csv", "still.jpg"])

        // The inventory is the superset. The narrower indexes still hold only
        // what their own pass needs.
        XCTAssertEqual(Set(index.refs.map(\.path)).count, 3)          // mov, wav, jpg
        XCTAssertTrue(index.large.allSatisfy { $0.size >= DuplicateFinder.minimumSize })
        XCTAssertTrue(Set(index.refs.map(\.path)).isSubset(of: Set(index.all.map(\.path))))
        XCTAssertTrue(Set(index.large.map(\.path)).isSubset(of: Set(index.all.map(\.path))))
    }

    /// The inventory has to reach the export intact. It deliberately does not
    /// travel on ScanSnapshot, so this is the one seam where it could go
    /// missing without anything failing to compile.
    @MainActor
    func testInventoryReachesTheCsv() async throws {
        let root = try makeTree([("clip.mov", 9_000_000), ("notes.txt", 40)])
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = ScanEngine()
        engine.scan(root)
        try await waitUntil { !engine.isBusy && engine.snapshot.isComplete }

        let inventory = engine.inventory
        XCTAssertEqual(inventory.files.count, 2)

        let csv = Exporter.csv(from: engine.snapshot, inventory: inventory)
        XCTAssertTrue(csv.contains("notes.txt"), "a non-media file must still appear in the CSV")
        XCTAssertTrue(csv.contains("clip.mov"))
    }

    // MARK: Helpers

    private func makeTree(_ files: [(String, Int)]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("inventory-\(UUID().uuidString)")
        for (name, size) in files {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(count: size).write(to: url)
        }
        return root
    }

    private func waitUntil(timeout: TimeInterval = 10,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: condition) { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTFail("timed out waiting for the scan to finish")
    }
}
