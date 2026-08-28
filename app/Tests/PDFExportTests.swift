import XCTest
import PDFKit
@testable import VaultlineLabsDriveInspector

/// PDF export is NOT offered in the app menu — `Exporter.Format.offered`
/// explains why. These tests cover the code behind it, which still works in
/// this bundle, so the day the shipped-context hang is understood the menu item
/// can come back without rewriting any of it. They also guard the property that
/// matters for the formats that ARE offered: the report makes no external
/// requests.
@MainActor
final class PDFExportTests: XCTestCase {

    func testPdfCarriesTheReportsRealContent() async throws {
        let html = ReportBuilder.html(from: Self.snapshot())
        let data = try await Exporter.pdfData(from: html)

        let doc = try XCTUnwrap(PDFDocument(data: data), "not a readable PDF")
        XCTAssertGreaterThan(doc.pageCount, 1, "a full report has to paginate")

        // Every page is Letter-proportioned. The failure this replaces was a
        // single page 6,809 points tall, which is unreadable printed and, once
        // the report grew past ~11,000 points, did not render at all.
        for i in 0..<doc.pageCount {
            let bounds = try XCTUnwrap(doc.page(at: i)?.bounds(for: .mediaBox))
            XCTAssertEqual(bounds.width, 860, accuracy: 1, "page \(i) width")
            XCTAssertLessThanOrEqual(bounds.height, 1_120, "page \(i) is not a page")
        }

        let text = (0..<doc.pageCount)
            .compactMap { doc.page(at: $0)?.string }
            .joined(separator: "\n")

        // Section headings render as uppercase via CSS but the text layer keeps
        // the source casing, so match case-insensitively.
        for heading in ["Verified duplicates", "Capacity", "What's on it", "Codecs",
                        "Frame rates", "Top formats", "Cameras detected", "Media by year",
                        "Largest folders", "Largest files", "Worth a look"] {
            XCTAssertTrue(text.localizedCaseInsensitiveContains(heading),
                          "\(heading) missing from the PDF text layer")
        }

        // Real figures, not just chrome. A blank-body PDF still carries the
        // masthead, so headings alone would not have caught the old bug.
        XCTAssertTrue(text.contains("SANDBOX"), "volume name missing")
        XCTAssertTrue(text.contains("clip0.mov"), "duplicate rows missing")
        XCTAssertTrue(text.contains("ProRes 422 HQ"), "codec rows missing")
        XCTAssertGreaterThan(text.count, 2_000, "PDF text layer is suspiciously thin")
    }

    /// The size that actually broke it. A 2 TB drive with every duplicate group
    /// and 25 folders listed lays out past 11,000 points, and the old
    /// whole-document render simply stopped returning: app idle, WebContent
    /// idle, export button disabled until the app was force quit. Nothing in
    /// the fixture below is unusual for a real media volume.
    func testAnOversizedReportStillExports() async throws {
        var s = Self.snapshot()
        s.dupes = DuplicateSummary(isComplete: true, candidatesChecked: 400, candidatesTotal: 400,
            groups: (0..<Show.duplicateGroups).map { i in
                DuplicateGroup(size: Int64(4_000_000_000 / (i + 1)), paths: [
                    "/Volumes/SANDBOX/26-006_Drone-Reel-SRE/02_MEDIA/20260625_Shoot-Day-01/CAMERA/DRONE/241126-DJI-01/DJI_0\(i).MP4",
                    "/Volumes/SANDBOX/26-006_Drone-Reel-SRE/07_EXPORTS/STAKEHOLDER_REVIEW/26-006_Drone-Reel_16x9_REVIEW_v\(i).mp4",
                    "/Volumes/SANDBOX/26-006_Drone-Reel-SRE/08_DELIVERABLES/SOCIAL/9x16/26-006_Drone-Reel_9x16_MASTER_\(i).mp4"
                ])
            })

        let html = ReportBuilder.html(from: s)
        let data = try await Exporter.pdfData(from: html)
        let doc = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(doc.pageCount, 10, "a report this size is many pages")
        XCTAssertLessThanOrEqual(doc.pageCount, 120, "page cap not honoured")
    }

    /// The report inlines both logos as data URLs precisely so it never makes a
    /// request. The app has no network entitlement, so if anything external
    /// creeps back in the PDF renderer is where it fails, quietly.
    func testReportMakesNoExternalRequests() {
        let html = ReportBuilder.html(from: Self.snapshot())
        for scheme in ["http://", "https://"] {
            let hits = html.components(separatedBy: scheme).dropFirst()
            for hit in hits {
                let url = scheme + hit.prefix(60)
                XCTAssertTrue(url.contains("vaultlinesolutions.com/offers"),
                              "unexpected external reference: \(url)")
            }
        }
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,"), "logos must be inlined")
    }

    private static func snapshot() -> ScanSnapshot {
        var s = ScanSnapshot()
        s.rootPath = "/Volumes/SANDBOX"
        s.volumeName = "SANDBOX"
        s.volumeTotalBytes = 2_000_000_000_000
        s.volumeFreeBytes = 1_500_000_000_000
        s.filesScanned = 1652
        s.bytesScanned = 458_000_000_000
        s.foldersScanned = 431
        s.isComplete = true
        s.byCategory[.video] = CountAndBytes(count: 623, bytes: 441_000_000_000)
        s.byCategory[.photo] = CountAndBytes(count: 674, bytes: 7_200_000_000)
        s.byExtension["mov"] = CountAndBytes(count: 354, bytes: 373_000_000_000)
        s.byExtension["mp4"] = CountAndBytes(count: 261, bytes: 63_000_000_000)
        s.probe.isComplete = true
        s.probe.filesProbed = 1316
        s.probe.embeddedDateCount = 900
        s.probe.totalDuration = 31617
        s.probe.bytesByCodec = ["ProRes 422 HQ": 360_000_000_000, "H.264": 75_000_000_000]
        s.probe.clipsByResolution = ["4K": 297, "1080p": 250]
        s.probe.clipsByFrameRate = ["24 fps": 487, "30 fps": 42]
        s.probe.byCamera["Panasonic DC-S5M2"] = CountAndBytes(count: 613, bytes: 6_900_000_000)
        s.probe.bytesByYear = [2024: 297_000_000_000, 2025: 2_300_000_000, 2026: 92_000_000_000]
        s.probe.unreadable = CountAndBytes(count: 682, bytes: 11_500_000_000)
        s.emptyFolders = (0..<31).map { "/Volumes/SANDBOX/empty\($0)" }
        s.largestFolders = (0..<25).map {
            FolderStat(path: "/Volumes/SANDBOX/folder\($0)",
                       bytes: Int64(300_000_000_000 / ($0 + 1)), fileCount: 40 - $0)
        }
        s.largestFiles = (0..<30).map {
            FileEntry(path: "/Volumes/SANDBOX/big\($0).mov",
                      size: Int64(30_000_000_000 / ($0 + 1)), modified: Date(), category: .video)
        }
        s.dupes = DuplicateSummary(isComplete: true, candidatesChecked: 60, candidatesTotal: 60,
            groups: (0..<30).map {
                DuplicateGroup(size: Int64(3_800_000_000 / ($0 + 1)),
                               paths: ["/Volumes/SANDBOX/a/clip\($0).mov",
                                       "/Volumes/SANDBOX/b/clip\($0).mov"])
            })
        return s
    }
}
