import XCTest
@testable import VaultlineLabsDriveInspector

final class DuplicateFinderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("drive-inspector-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testReportsOnlyFullContentMatchesAndCalculatesReclaimableBytes() async throws {
        let bytes = patterned(size: 5 * 1024 * 1024, middle: 0x42)
        let a = try entry("a.mov", data: bytes)
        let b = try entry("b.mov", data: bytes)
        let c = try entry("c.mov", data: bytes)

        let result = await finish(DuplicateFinder.makeSession([a, b, c]))

        XCTAssertEqual(result.changedFiles, 0)
        XCTAssertEqual(result.unreadableFiles, 0)
        XCTAssertEqual(result.remainingCandidateFiles, 0)
        XCTAssertTrue(result.scopeComplete)
        XCTAssertEqual(result.verifiedGroupCount, 1)
        XCTAssertEqual(result.duplicateFileCount, 2)
        XCTAssertEqual(result.recoverableBytes, Int64(bytes.count * 2))
        if let group = result.groups.first {
            XCTAssertEqual(group.paths, [a.path, b.path, c.path].sorted())
        }
    }

    func testMatchingFirstAndLastChunksWithDifferentMiddleIsNotDuplicate() async throws {
        let a = try entry("same-edges-a.mov", data: patterned(size: 5 * 1024 * 1024, middle: 0x11))
        let b = try entry("same-edges-b.mov", data: patterned(size: 5 * 1024 * 1024, middle: 0x99))

        let result = await finish(DuplicateFinder.makeSession([a, b]))

        XCTAssertEqual(result.changedFiles, 0)
        XCTAssertEqual(result.unreadableFiles, 0)
        XCTAssertEqual(result.remainingCandidateFiles, 0)
        XCTAssertTrue(result.scopeComplete)
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(result.recoverableBytes, 0)
    }

    func testFilesBelowFourMegabytesAreOutsideDuplicateScope() async throws {
        let data = Data(repeating: 0x5A, count: 1024 * 1024)
        let result = await finish(DuplicateFinder.makeSession([
            try entry("small-a.mov", data: data),
            try entry("small-b.mov", data: data)
        ]))

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.candidatesTotal, 0)
        XCTAssertTrue(result.groups.isEmpty)
    }

    func testBudgetPausesWithoutDilutingVerifiedTotalsAndContinueFinishes() async throws {
        let five = patterned(size: 5 * 1024 * 1024, middle: 0x51)
        let six = patterned(size: 6 * 1024 * 1024, middle: 0x61)
        let session = DuplicateFinder.makeSession([
            try entry("five-a.mov", data: five), try entry("five-b.mov", data: five),
            try entry("six-a.mov", data: six), try entry("six-b.mov", data: six)
        ])

        let paused = await finish(session, budget: 15 * 1024 * 1024)
        XCTAssertTrue(paused.isPaused)
        XCTAssertEqual(paused.verifiedGroupCount, 1)
        XCTAssertGreaterThan(paused.remainingCandidateFiles, 0)

        let complete = await finish(session, budget: 15 * 1024 * 1024)
        XCTAssertTrue(complete.scopeComplete)
        XCTAssertEqual(complete.verifiedGroupCount, 2)
        XCTAssertEqual(complete.recoverableBytes, Int64(five.count + six.count))
    }

    func testChangedFileIsExcludedFromHardNumberResult() async throws {
        let data = patterned(size: 5 * 1024 * 1024, middle: 0x77)
        let a = try entry("stable.mov", data: data)
        let b = try entry("changed.mov", data: data)
        try Data(repeating: 0x22, count: data.count + 1).write(to: URL(fileURLWithPath: b.path))

        let result = await finish(DuplicateFinder.makeSession([a, b]))

        XCTAssertEqual(result.changedFiles, 1)
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(result.recoverableBytes, 0)
        XCTAssertFalse(result.scopeComplete)
    }

    private func finish(_ session: DuplicateFinder.Session, budget: Int64 = DuplicateFinder.defaultReadBudget) async -> DuplicateSummary {
        var result = DuplicateSummary()
        for await update in DuplicateFinder.run(session, readBudget: budget) { result = update }
        return result
    }

    private func entry(_ name: String, data: Data) throws -> FileEntry {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return FileEntry(path: url.path, size: Int64(values.fileSize ?? 0),
                         modified: values.contentModificationDate, category: .video)
    }

    private func patterned(size: Int, middle: UInt8) -> Data {
        var data = Data(repeating: middle, count: size)
        data.replaceSubrange(0..<(1024 * 1024), with: repeatElement(UInt8(0xAA), count: 1024 * 1024))
        data.replaceSubrange((size - 1024 * 1024)..<size,
                             with: repeatElement(UInt8(0xBB), count: 1024 * 1024))
        return data
    }
}
