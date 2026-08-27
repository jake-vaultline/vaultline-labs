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

    func testFolderRuleTracksOnlyCompleteMatchingNamesAtAnyDepth() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultline-volume-rules-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Clients/SHOW-0042/Day01", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Clients/SHOW-0042-old", isDirectory: true),
            withIntermediateDirectories: true)
        try Data(repeating: 1, count: 7).write(
            to: root.appendingPathComponent("Clients/SHOW-0042/Day01/A001.mov"))
        try Data(repeating: 2, count: 9).write(
            to: root.appendingPathComponent("Clients/SHOW-0042-old/A002.mov"))

        let rules = DriveScanRules(folderNamePattern: #"SHOW-[0-9]{4}"#)
        let snapshot = VolumeScanner.snapshot(of: root, rules: rules)

        XCTAssertEqual(snapshot.collections?.count, 1)
        let tracked = try XCTUnwrap(snapshot.collections?["Clients/SHOW-0042"])
        XCTAssertEqual(tracked.name, "SHOW-0042")
        XCTAssertEqual(tracked.fileCount, 1)
        XCTAssertEqual(tracked.totalBytes, 7)
    }

    func testCopyAnalyzerSeparatesMatchingSingleAndDiscrepantCollections() {
        let now = Date()
        func volume(_ id: String, _ name: String, _ collections: [ScannedCollection]) -> KnownVolume {
            KnownVolume(
                id: id, name: name, lastPath: "/Volumes/\(name)",
                totalBytes: 100, freeBytes: 50, isRemovable: true,
                firstSeen: now, lastSeen: now, sightings: 1,
                snapshot: VolumeSnapshot(
                    takenAt: now, fileCount: 1, totalBytes: 10,
                    folders: [:], topLevel: [:],
                    collections: Dictionary(uniqueKeysWithValues: collections.map { ($0.relativePath, $0) })))
        }
        func collection(_ name: String, fingerprint: String) -> ScannedCollection {
            ScannedCollection(relativePath: name, name: name, fileCount: 1,
                              totalBytes: 10, inventoryFingerprint: fingerprint)
        }

        let findings = DriveCopyAnalyzer.findings(in: [
            volume("a", "Drive A", [collection("MATCH", fingerprint: "same"),
                                      collection("ODD", fingerprint: "one"),
                                      collection("ONLY", fingerprint: "single")]),
            volume("b", "Drive B", [collection("MATCH", fingerprint: "same"),
                                      collection("ODD", fingerprint: "two")]),
        ])

        XCTAssertEqual(findings.first(where: { $0.name == "MATCH" })?.health, .matchingCopies)
        XCTAssertEqual(findings.first(where: { $0.name == "ODD" })?.health, .discrepancy)
        XCTAssertEqual(findings.first(where: { $0.name == "ONLY" })?.health, .singleCopy)
    }
}
