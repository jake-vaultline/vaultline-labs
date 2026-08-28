import XCTest
import PDFKit
@testable import VaultlineLabsDriveInspector

/// The PDF is the copy that gets emailed and printed, and it has failed
/// silently before: a WKWebView that was never placed in a window produced a
/// blank page, and nothing in the pipeline noticed because a blank PDF is
/// still a valid PDF. These assert on extracted text, not on file size.
@MainActor
final class PDFExportTests: XCTestCase {

    func testPdfCarriesTheReportsRealContent() async throws {
        let html = ReportBuilder.html(from: Self.snapshot())
        let data = try await Exporter.pdfData(from: html)

        let doc = try XCTUnwrap(PDFDocument(data: data), "not a readable PDF")
        XCTAssertGreaterThan(doc.pageCount, 0)

        // Documents the known single-page behaviour rather than asserting it is
        // correct. `Exporter.pdfData` explains why, and why the fix is its own
        // task. If this ever starts failing because the export paginated, that
        // is the good outcome: delete this line.
        let bounds = try XCTUnwrap(doc.page(at: 0)?.bounds(for: .mediaBox))
        XCTAssertGreaterThan(bounds.height, 2_000,
                             "export is still one document-height page; see Exporter.pdfData")

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
