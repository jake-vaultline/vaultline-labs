import XCTest
@testable import VaultlineLabsDriveInspector

@MainActor
final class ReportRegressionTests: XCTestCase {
    func testDuplicateFirstReportRetainsExistingDriveIntelligence() {
        let file = FileEntry(path: "/Volumes/TEST/Project/clip.mov", size: 8_000_000,
                             modified: Date(), category: .video)
        var snapshot = ScanSnapshot()
        snapshot.rootPath = "/Volumes/TEST"
        snapshot.volumeName = "TEST"
        snapshot.volumeTotalBytes = 1_000_000_000
        snapshot.volumeFreeBytes = 250_000_000
        snapshot.filesScanned = 8
        snapshot.bytesScanned = 750_000_000
        snapshot.foldersScanned = 3
        snapshot.byCategory[.video] = CountAndBytes(count: 2, bytes: 16_000_000)
        snapshot.byExtension["mov"] = CountAndBytes(count: 2, bytes: 16_000_000)
        snapshot.largestFiles = [file]
        snapshot.largestFolders = [FolderStat(path: "/Volumes/TEST/Project", bytes: 16_000_000, fileCount: 2)]
        snapshot.emptyFolders = ["/Volumes/TEST/Empty"]
        snapshot.projectFiles = [FileEntry(path: "/Volumes/TEST/Project/edit.prproj", size: 5_000_000,
                                           modified: Date(), category: .project)]
        snapshot.probe.bytesByCodec["ProRes 422"] = 16_000_000
        snapshot.probe.clipsByResolution["4K"] = 2
        snapshot.probe.clipsByFrameRate["23.98"] = 2
        snapshot.probe.byCamera["Sony FX6"] = CountAndBytes(count: 2, bytes: 16_000_000)
        snapshot.probe.bytesByYear[2025] = 8_000_000
        snapshot.probe.bytesByYear[2026] = 8_000_000
        snapshot.dupes = DuplicateSummary(isComplete: true, candidatesChecked: 2, candidatesTotal: 2,
            groups: [DuplicateGroup(size: 8_000_000, paths: [
                "/Volumes/TEST/Project/clip.mov", "/Volumes/TEST/Backup/clip.mov"
            ])])

        let html = ReportBuilder.html(from: snapshot)
        for expected in ["Verified duplicates", "Capacity", "What's on it", "Codecs", "Resolutions",
                         "Frame rates", "Cameras detected", "Media by year", "Largest folders",
                         "Largest files", "Worth a look"] {
            XCTAssertTrue(html.contains(expected), expected)
        }
        XCTAssertTrue(html.contains("entry_context=duplicate-finder-report"))
        XCTAssertTrue(html.range(of: "<section><h2>Verified duplicates")!.lowerBound
                      < html.range(of: "<section><h2>Capacity")!.lowerBound)

        let csv = Exporter.csv(from: snapshot)
        XCTAssertTrue(csv.contains("Verified duplicates (files 4 MB and larger)"))
        XCTAssertTrue(csv.contains("Full SHA-256"))
        XCTAssertTrue(csv.contains("File types"))
        XCTAssertTrue(csv.contains("Cameras"))

        var cancelled = snapshot
        cancelled.dupes = DuplicateSummary(wasCancelled: true, candidatesChecked: 1,
            candidatesTotal: 4, cancelledFiles: 3)
        let cancelledHTML = ReportBuilder.html(from: cancelled)
        let cancelledCSV = Exporter.csv(from: cancelled)
        XCTAssertTrue(cancelledHTML.contains("Verification was cancelled; 3 files were unfinished and excluded."))
        XCTAssertTrue(cancelledCSV.contains("Excluded: 3 unfinished when verification was cancelled"))
    }
}
