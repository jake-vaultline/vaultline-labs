import Foundation
import XCTest
@testable import VaultlineIngest

final class VolumeScannerTests: XCTestCase {
    func testTopLevelTotalsIncludeDeepDescendants() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultline-volume-scanner-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Project/Day01", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Other", isDirectory: true),
            withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4).write(
            to: root.appendingPathComponent("Project/Day01/clip.mov"))
        try Data(repeating: 2, count: 3).write(
            to: root.appendingPathComponent("Project/notes.txt"))
        try Data(repeating: 3, count: 5).write(
            to: root.appendingPathComponent("Other/image.dpx"))
        try Data(repeating: 4, count: 2).write(
            to: root.appendingPathComponent("readme.txt"))

        let snapshot = VolumeScanner.snapshot(of: root)

        XCTAssertEqual(snapshot.fileCount, 4)
        XCTAssertEqual(snapshot.totalBytes, 14)
        XCTAssertEqual(snapshot.topLevel, [
            "Project": 7,
            "Other": 5,
            "readme.txt": 2,
        ])
    }
}
