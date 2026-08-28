import Foundation
import XCTest
@testable import VaultlineIngest

final class OffloadEngineTests: XCTestCase {

    func testConfiguredJobCopiesNestedCardIntoConfiguredLandingFolder() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("CARD", isDirectory: true)
        let nested = source.appendingPathComponent("DCIM/100CAM", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let original = Data("camera-original".utf8)
        try original.write(to: nested.appendingPathComponent("A001.mov"))

        let jobPlan = try ConfiguredJobPlan.make(
            workflow: .standard,
            selectedRoot: root.appendingPathComponent("DESTINATION", isDirectory: true),
            values: .init(fields: ["project": "Launch Film"]))
        _ = try ConfiguredJobBuilder.create(jobPlan)
        let files = OffloadEngine.plan(source: source, naming: NamingConfig())

        let (progress, results) = await OffloadEngine(bufferSize: 4).run(
            files: files,
            destinations: [Destination(root: jobPlan.mediaRoot.path, label: "Shoot", isPrimary: true)],
            algorithm: .xxhash64,
            onProgress: { _ in })

        XCTAssertEqual(progress.phase, .done)
        XCTAssertEqual(progress.filesVerified, 1)
        XCTAssertEqual(results.count, 1)
        let copy = jobPlan.mediaRoot.appendingPathComponent("DCIM/100CAM/A001.mov")
        XCTAssertEqual(try Data(contentsOf: copy), original)
        XCTAssertEqual(try Data(contentsOf: nested.appendingPathComponent("A001.mov")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(jobPlan.projectURL).path))
    }

    func testPlannerKeepsHiddenCameraMetadataAndSkipsOnlyOperatingSystemDebris() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("CARD", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("PRIVATE/M4ROOT", isDirectory: true),
            withIntermediateDirectories: true)
        try Data("camera-metadata".utf8).write(
            to: source.appendingPathComponent("PRIVATE/M4ROOT/.MEDIAPRO.XML"))
        try Data("finder-junk".utf8).write(to: source.appendingPathComponent(".DS_Store"))
        try Data("apple-double".utf8).write(
            to: source.appendingPathComponent("PRIVATE/M4ROOT/._.MEDIAPRO.XML"))
        try Data("apple-double".utf8).write(
            to: source.appendingPathComponent("PRIVATE/M4ROOT/._A001.mov"))
        let outside = root.appendingPathComponent("outside.mov")
        try Data("outside-source".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("linked.mov"), withDestinationURL: outside)
        let outsideDirectory = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try Data("outside-directory".utf8).write(
            to: outsideDirectory.appendingPathComponent("linked-directory.mov"))
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("LINKED-DIRECTORY"),
            withDestinationURL: outsideDirectory)
        let spotlight = source.appendingPathComponent(".Spotlight-V100/Store", isDirectory: true)
        try FileManager.default.createDirectory(at: spotlight, withIntermediateDirectories: true)
        try Data("index-junk".utf8).write(to: spotlight.appendingPathComponent("index"))

        let files = OffloadEngine.plan(source: source, naming: NamingConfig())

        XCTAssertEqual(files.map(\.relativePath), ["PRIVATE/M4ROOT/.MEDIAPRO.XML"])
    }

    func testCapacityPreflightCountsOnlyMissingFilesAndBlocksEveryDestinationUpFront() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationRoot = root.appendingPathComponent("DEST", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 10).write(to: destinationRoot.appendingPathComponent("existing.mov"))
        let destination = Destination(root: destinationRoot.path, label: "Field SSD", isPrimary: true)
        let files = [
            IngestFile(sourcePath: "/CARD/existing.mov", relativePath: "existing.mov",
                       destinationRelativePath: "existing.mov", size: 10),
            IngestFile(sourcePath: "/CARD/new.mov", relativePath: "new.mov",
                       destinationRelativePath: "new.mov", size: 20),
        ]

        XCTAssertEqual(DestinationCapacity.missingBytes(files: files, destination: destination), 20)
        let issue = DestinationCapacity.issue(
            files: files, destinations: [destination],
            availableCapacity: { _ in DestinationCapacity.safetyReserve + 19 })
        XCTAssertNotNil(issue)
        XCTAssertTrue(issue?.contains("Field SSD") == true)
        XCTAssertNil(DestinationCapacity.issue(
            files: files, destinations: [destination],
            availableCapacity: { _ in DestinationCapacity.safetyReserve + 20 }))
    }

    func testFanOutVerifiesTwoDestinationsAndLeavesSourceUntouched() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeCard(in: root, data: Data("only-copy-this".utf8))
        let first = root.appendingPathComponent("FIRST", isDirectory: true)
        let second = root.appendingPathComponent("SECOND", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let files = OffloadEngine.plan(source: source, naming: NamingConfig())

        let destinations = [
            Destination(root: first.path, label: "Primary", isPrimary: true),
            Destination(root: second.path, label: "Safety", isPrimary: false),
        ]
        let (progress, results) = await OffloadEngine(bufferSize: 3).run(
            files: files, destinations: destinations, algorithm: .sha1, onProgress: { _ in })

        XCTAssertEqual(progress.phase, .done)
        XCTAssertEqual(progress.filesVerified, 1)
        XCTAssertEqual(try Data(contentsOf: first.appendingPathComponent("clip.mov")), Data("only-copy-this".utf8))
        XCTAssertEqual(try Data(contentsOf: second.appendingPathComponent("clip.mov")), Data("only-copy-this".utf8))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("clip.mov")), Data("only-copy-this".utf8))
        XCTAssertTrue(results[0].destinations.values.allSatisfy(\.isVerified))
    }

    func testOffloadPreservesSourceModificationDate() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeCard(in: root, data: Data("timestamped".utf8))
        let sourceFile = source.appendingPathComponent("clip.mov")
        let expected = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: expected], ofItemAtPath: sourceFile.path)
        let destination = root.appendingPathComponent("DEST", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let (progress, _) = await OffloadEngine(bufferSize: 3).run(
            files: OffloadEngine.plan(source: source, naming: NamingConfig()),
            destinations: [Destination(root: destination.path, label: "Destination", isPrimary: true)],
            algorithm: .xxhash64, onProgress: { _ in })

        XCTAssertEqual(progress.phase, .done)
        let copied = destination.appendingPathComponent("clip.mov")
        let actual = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: copied.path)[.modificationDate] as? Date)
        XCTAssertEqual(actual.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
    }

    func testDifferentExistingFileIsReportedAndNeverOverwritten() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeCard(in: root, data: Data("source-data".utf8))
        let destination = root.appendingPathComponent("DEST", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let existing = Data("other--data".utf8)
        try existing.write(to: destination.appendingPathComponent("clip.mov"))

        let (progress, results) = await OffloadEngine(bufferSize: 2).run(
            files: OffloadEngine.plan(source: source, naming: NamingConfig()),
            destinations: [Destination(root: destination.path, label: "Destination", isPrimary: true)],
            algorithm: .xxhash64,
            onProgress: { _ in })

        XCTAssertEqual(progress.phase, .failed)
        XCTAssertEqual(progress.conflicts.count, 1)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("clip.mov")), existing)
        guard case .conflict = results[0].destinations[destination.path] else {
            return XCTFail("Expected a conflict result")
        }
    }

    func testRerunHashesMatchingCopyAndDoesNotRewriteIt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeCard(in: root, data: Data("resume-me".utf8))
        let destination = root.appendingPathComponent("DEST", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let files = OffloadEngine.plan(source: source, naming: NamingConfig())
        let target = Destination(root: destination.path, label: "Destination", isPrimary: true)
        _ = await OffloadEngine(bufferSize: 2).run(
            files: files, destinations: [target], algorithm: .xxhash64, onProgress: { _ in })
        let copy = destination.appendingPathComponent("clip.mov")
        let firstModification = try copy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        let (progress, results) = await OffloadEngine(bufferSize: 2).run(
            files: files, destinations: [target], algorithm: .xxhash64, onProgress: { _ in })

        XCTAssertEqual(progress.phase, .done)
        XCTAssertEqual(progress.filesAlreadyPresent, 1)
        XCTAssertEqual(progress.bytesCopied, 0)
        XCTAssertEqual(try copy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       firstModification)
        guard case .alreadyVerified(let hash) = results[0].destinations[destination.path] else {
            return XCTFail("Expected an already-verified result")
        }
        XCTAssertFalse(hash.isEmpty)
    }

    func testCancellationRemovesStagingAndNeverPublishesPartialFinalFile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceData = Data(repeating: 0xA5, count: 16 * 1024 * 1024)
        let source = try makeCard(in: root, data: sourceData)
        let destination = root.appendingPathComponent("DEST", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let began = expectation(description: "copy began")
        let signal = OneShot()
        let engine = OffloadEngine(bufferSize: 64 * 1024)
        let files = OffloadEngine.plan(source: source, naming: NamingConfig())

        let run = Task {
            await engine.run(
                files: files,
                destinations: [Destination(root: destination.path, label: "Destination", isPrimary: true)],
                algorithm: .xxhash64,
                onProgress: { progress in
                    if progress.bytesCopied > 0 { signal.run { began.fulfill() } }
                })
        }
        await fulfillment(of: [began], timeout: 3)
        run.cancel()
        let (progress, _) = await run.value

        XCTAssertEqual(progress.phase, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("clip.mov").path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("clip.mov")), sourceData)
        let staging = destination.appendingPathComponent(".vaultline-ingest-staging", isDirectory: true)
        let children = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        XCTAssertTrue(children.isEmpty)
    }

    func testUnavailableDestinationProducesFailureWithoutChangingSource() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("original".utf8)
        let source = try makeCard(in: root, data: original)
        let notADirectory = root.appendingPathComponent("not-a-directory")
        try Data("leave-me".utf8).write(to: notADirectory)

        let (progress, results) = await OffloadEngine(bufferSize: 2).run(
            files: OffloadEngine.plan(source: source, naming: NamingConfig()),
            destinations: [Destination(root: notADirectory.path, label: "Broken", isPrimary: true)],
            algorithm: .xxhash64,
            onProgress: { _ in })

        XCTAssertEqual(progress.phase, .failed)
        XCTAssertEqual(progress.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("clip.mov")), original)
        XCTAssertEqual(try Data(contentsOf: notADirectory), Data("leave-me".utf8))
        guard case .failed = results[0].destinations[notADirectory.path] else {
            return XCTFail("Expected a per-destination failure")
        }
    }

    func testRestartClearsOnlyReservedStagingAndCompletesTransfer() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeCard(in: root, data: Data("restart-me".utf8))
        let destination = root.appendingPathComponent("DEST", isDirectory: true)
        let stale = destination
            .appendingPathComponent(".vaultline-ingest-staging/abandoned/DCIM", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: stale.appendingPathComponent("clip.mov"))
        let unrelated = destination.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)

        let (progress, _) = await OffloadEngine(bufferSize: 2).run(
            files: OffloadEngine.plan(source: source, naming: NamingConfig()),
            destinations: [Destination(root: destination.path, label: "Destination", isPrimary: true)],
            algorithm: .xxhash64,
            onProgress: { _ in })

        XCTAssertEqual(progress.phase, .done)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("clip.mov")),
                       Data("restart-me".utf8))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination
            .appendingPathComponent(".vaultline-ingest-staging").path))
    }

    func testManifestUsesDestinationPathSelectedAlgorithmAndResumedHash() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = Destination(root: root.path, label: "Destination", isPrimary: true)
        let hash = String(repeating: "a", count: 40)
        var file = IngestFile(
            sourcePath: "/CARD/DCIM/clip.mov", relativePath: "DCIM/clip.mov",
            destinationRelativePath: "RENAMED/SHOW_A001.mov", size: 42)
        file.sourceHash = hash
        file.destinations[root.path] = .alreadyVerified(hash: hash)
        let manifest = try MHLWriter.write(
            files: [file], destination: destination, algorithm: .sha1, sourceName: "CARD")
        let xml = try String(contentsOf: manifest)

        XCTAssertTrue(xml.contains("RENAMED/SHOW_A001.mov"))
        XCTAssertFalse(xml.contains(">DCIM/clip.mov<"))
        XCTAssertTrue(xml.contains("<process>transfer</process>"))
        XCTAssertFalse(xml.contains("<roothash>"))
        XCTAssertTrue(xml.contains("<sha1 action=\"original\">\(hash)</sha1>"))
        XCTAssertEqual(manifest.deletingLastPathComponent(), root)
    }

    func testAtomicRecordWriterNeverReplacesExistingFileAndLeavesNoTemporaryRecord() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let final = root.appendingPathComponent("INGEST-NOTES.txt")
        try Data("first".utf8).write(to: final)

        XCTAssertThrowsError(try AtomicNoReplaceWriter.write(Data("second".utf8), to: final))
        XCTAssertEqual(try Data(contentsOf: final), Data("first".utf8))
        let children = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(children, ["INGEST-NOTES.txt"])
    }

    func testPathSafetyRejectsDestinationInsideSourceAndOverlappingDestinations() {
        let source = URL(fileURLWithPath: "/Volumes/CARD")
        XCTAssertNotNil(IngestPathSafety.issue(
            source: source,
            destinations: [Destination(
                root: "/Volumes/CARD/Backup", label: "Unsafe", isPrimary: true)]))
        XCTAssertNotNil(IngestPathSafety.issue(
            source: source,
            destinations: [
                Destination(root: "/Volumes/WORK/Job", label: "First", isPrimary: true),
                Destination(root: "/Volumes/WORK/Job/Safety", label: "Second", isPrimary: false),
            ]))
        XCTAssertNil(IngestPathSafety.issue(
            source: source,
            destinations: [
                Destination(root: "/Volumes/WORK_A/Job", label: "First", isPrimary: true),
                Destination(root: "/Volumes/WORK_B/Job", label: "Second", isPrimary: false),
            ]))
    }

    func testPlanSafetyRejectsTwoSourcesLandingAtSameCaseInsensitivePath() {
        let first = IngestFile(
            sourcePath: "/CARD/A.mov", relativePath: "A.mov",
            destinationRelativePath: "RENAMED/CLIP.mov", size: 1)
        let second = IngestFile(
            sourcePath: "/CARD/B.mov", relativePath: "B.mov",
            destinationRelativePath: "renamed/clip.MOV", size: 1)
        XCTAssertNotNil(IngestPlanSafety.issue(files: [first, second]))
        XCTAssertNil(IngestPlanSafety.issue(files: [first]))
    }

    func testPlanSafetyRejectsDestinationSymlinkThatEscapesSelectedRoot() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationRoot = root.appendingPathComponent("DEST", isDirectory: true)
        let outside = root.appendingPathComponent("OUTSIDE", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: destinationRoot.appendingPathComponent("DCIM"),
            withDestinationURL: outside)
        let file = IngestFile(
            sourcePath: "/CARD/DCIM/A001.mov", relativePath: "DCIM/A001.mov",
            destinationRelativePath: "DCIM/A001.mov", size: 1)
        let destination = Destination(
            root: destinationRoot.path, label: "Destination", isPrimary: true)

        XCTAssertNotNil(IngestPlanSafety.issue(
            files: [file], destinations: [destination]))
    }

    func testChecksumAlgorithmsMatchCanonicalIndependentVectorsWhenStreamed() {
        let chunks = [Data("a".utf8), Data("b".utf8), Data("c".utf8)]
        let vectors: [(ChecksumAlgorithm, String)] = [
            (.xxhash64, "44bc2cf5ad770999"),
            (.md5, "900150983cd24fb0d6963f7d28e17f72"),
            (.sha1, "a9993e364706816aba3e25717850c26c9cd0d89d"),
        ]
        for (algorithm, expected) in vectors {
            var hasher = StreamingHasher(algorithm)
            chunks.forEach { hasher.update($0) }
            XCTAssertEqual(hasher.hexDigest(), expected, algorithm.rawValue)
        }
    }

    private func makeCard(in root: URL, data: Data) throws -> URL {
        let card = root.appendingPathComponent("CARD", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try data.write(to: card.appendingPathComponent("clip.mov"))
        return card
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultline-offload-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func run(_ action: () -> Void) {
        lock.lock()
        guard !fired else { lock.unlock(); return }
        fired = true
        lock.unlock()
        action()
    }
}
