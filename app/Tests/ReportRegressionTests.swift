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

    /// The bar fill is an `<i>`. Without `display:block` it is an inline box,
    /// width and height do not apply, and every bar in "What's on it", Codecs
    /// and Resolutions renders as an empty track. The report shipped that way.
    func testBarFillIsABlockSoItActuallyRenders() {
        let css = ReportBuilder.css
        let rule = css.range(of: ".bar .fl{")
        let end = rule.map { css.range(of: "}", range: $0.upperBound..<css.endIndex) }
        XCTAssertNotNil(rule)
        guard let rule, let end = end ?? nil else { return XCTFail("no .bar .fl rule") }
        let body = String(css[rule.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("display:block"), "bar fill must be a block: \(body)")
        XCTAssertTrue(body.contains("width:") == false, "width comes from the inline style")
    }

    /// Two right-aligned numeric columns with no gutter run together, which is
    /// how "Copies" and "Reclaimable" rendered as one word.
    func testAdjacentTableColumnsHaveAGutter() {
        XCTAssertTrue(ReportBuilder.css.contains("th+th,td+td{padding-left:26px}"))
    }

    func testFooterDropsThePriceTheDomainAndTheLocalScanLine() {
        let html = ReportBuilder.html(from: ScanSnapshot())
        XCTAssertFalse(html.contains("$499"))
        XCTAssertFalse(html.contains("scanned locally, never uploaded"))
        XCTAssertFalse(html.contains("<span class=\"s\">vaultlinesolutions.com</span>"))
        XCTAssertTrue(html.contains("See the Media Operations Blueprint"))
    }

    /// Every surface has to be able to say what it left out, and neither
    /// surface may quietly show less than the other.
    func testReportShowsEveryDuplicateGroupUpToTheSharedLimit() {
        var s = ScanSnapshot()
        s.rootPath = "/V"
        s.dupes = DuplicateSummary(isComplete: true, candidatesChecked: 60, candidatesTotal: 60,
            groups: (0..<30).map {
                DuplicateGroup(size: 5_000_000, paths: ["/V/a\($0).mov", "/V/b\($0).mov"])
            })

        let html = ReportBuilder.html(from: s)
        XCTAssertGreaterThanOrEqual(Show.duplicateGroups, 30)
        for i in 0..<30 {
            XCTAssertTrue(html.contains("/a\(i).mov"), "group \(i) missing from the report")
        }
        // Both copies of a group are listed, not just the first.
        XCTAssertTrue(html.contains("/b0.mov"))
        XCTAssertFalse(html.contains("see the exported report for the full list"))
    }

    /// The window used to show five cameras where the report showed ten. The
    /// limits now come from one place, so a change moves both together.
    func testAppAndReportShareOneSetOfLimits() {
        XCTAssertEqual(Show.largestFolders, Walker.largestFoldersKept)
        XCTAssertGreaterThan(Show.cameras, 10)
        XCTAssertGreaterThan(Show.frameRates, 0)
    }

    func testCsvCarriesThePerFileInventoryItsLabelPromises() {
        var s = ScanSnapshot()
        s.rootPath = "/V"
        s.volumeName = "V"
        s.filesScanned = 2
        s.bytesScanned = 12_000_000
        let inventory = FileInventory(files: [
            FileEntry(path: "/V/a.mov", size: 8_000_000, modified: Date(), category: .video),
            FileEntry(path: "/V/b.wav", size: 4_000_000, modified: Date(), category: .audio)
        ], notKept: 0)

        let csv = Exporter.csv(from: s, inventory: inventory)
        XCTAssertTrue(csv.contains("All files"))
        XCTAssertTrue(csv.contains("\"/V/a.mov\""))
        XCTAssertTrue(csv.contains("\"/V/b.wav\""))
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}"), "Excel needs the BOM to read UTF-8")
        // Numbers unquoted, or every SUM over the column returns zero.
        XCTAssertTrue(csv.contains("\"Files scanned\",2,"))
        XCTAssertFalse(csv.contains("\"Files scanned\",\"2\""))
        XCTAssertFalse(csv.contains("every file, for your own analysis"),
                       "the old label promised an inventory the file did not contain")
    }

    func testCsvSaysWhenTheInventoryWasCapped() {
        let inventory = FileInventory(
            files: [FileEntry(path: "/V/a.mov", size: 8_000_000, modified: nil, category: .video)],
            notKept: 12)
        let csv = Exporter.csv(from: ScanSnapshot(), inventory: inventory)
        XCTAssertTrue(csv.contains("12 further files were scanned but not listed here"))
    }
}
