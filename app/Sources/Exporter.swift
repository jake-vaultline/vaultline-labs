import Foundation
import AppKit
import WebKit
import UniformTypeIdentifiers

/// Saves the report. Three formats, one source of truth: the HTML is generated
/// once and the PDF is that HTML printed, so the two can never disagree.
@MainActor
enum Exporter {

    enum Format: String, CaseIterable, Identifiable {
        case html, pdf, csv
        var id: String { rawValue }

        var label: String {
            switch self {
            case .html: return "HTML · one file, opens anywhere"
            case .pdf:  return "PDF · for email and print"
            case .csv:  return "CSV · every file and every finding, for your own analysis"
            }
        }
        var ext: String { rawValue }
        var type: UTType {
            switch self {
            case .html: return .html
            case .pdf:  return .pdf
            case .csv:  return .commaSeparatedText
            }
        }
    }

    static func export(_ snapshot: ScanSnapshot, as format: Format,
                       inventory: FileInventory = FileInventory()) async throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = suggestedName(snapshot, ext: format.ext)
        panel.message = "Save the drive report"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        switch format {
        case .html:
            try ReportBuilder.html(from: snapshot).write(to: url, atomically: true, encoding: .utf8)
        case .csv:
            try csv(from: snapshot, inventory: inventory)
                .write(to: url, atomically: true, encoding: .utf8)
        case .pdf:
            let data = try await pdf(from: ReportBuilder.html(from: snapshot))
            try data.write(to: url)
        }

        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func suggestedName(_ s: ScanSnapshot, ext: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let name = s.volumeName.isEmpty ? "Drive" : s.volumeName
        let safe = name.replacingOccurrences(of: "/", with: "-")
        return "\(safe) Drive Report \(f.string(from: Date())).\(ext)"
    }

    // MARK: PDF

    /// Renders the report HTML to PDF with WKWebView.
    ///
    /// This works inside the sandbox with no network entitlement because the
    /// HTML is fully self-contained — every style and image is inlined, so the
    /// web view never makes a request. If a future version references anything
    /// remote, this silently starts producing broken PDFs. Keep it inlined.
    ///
    /// The web view must live inside a real window while it renders. A
    /// WKWebView that's never been placed in a window has no backing surface
    /// for WebKit to composite into, and `.pdf(configuration:)` on one
    /// reliably comes back empty or truncated — the "PDF export didn't work"
    /// bug. An offscreen, borderless window gives it a real surface without
    /// ever appearing on screen.
    private static func pdf(from html: String) async throws -> Data {
        let frame = NSRect(x: 0, y: 0, width: 860, height: 1100)
        let web = WKWebView(frame: frame, configuration: WKWebViewConfiguration())

        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))   // off any real screen
        window.contentView = web

        let loader = NavigationWaiter()
        web.navigationDelegate = loader
        web.loadHTMLString(html, baseURL: nil)
        try await loader.wait()

        // Give layout a beat to settle after load; without this the first page
        // occasionally renders before fonts have applied.
        try? await Task.sleep(nanoseconds: 250_000_000)

        defer { window.contentView = nil }
        let cfg = WKPDFConfiguration()
        return try await web.pdf(configuration: cfg)
    }

    /// Bridges WKNavigationDelegate's callbacks into async/await.
    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var finished = false

        func wait() async throws {
            if finished { return }
            try await withCheckedThrowingContinuation { c in self.continuation = c }
        }
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { resume(nil) }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { resume(e) }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { resume(e) }

        private func resume(_ error: Error?) {
            guard !finished else { return }
            finished = true
            if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
            continuation = nil
        }
    }

    // MARK: CSV
    //
    // One table per section, each with its own header row naming exactly the
    // columns that follow it — no shared table where the same column means a
    // different thing on different rows, and no section label doubling as a
    // column value. Every section is separated by a blank line and a plain
    // title line, which every spreadsheet app treats as harmless filler.
    //
    // Three rules this file holds to, learned from the version before it:
    //
    // 1. Nothing here is capped by `Show`. The HTML report is the readable
    //    summary; this is the complete export, and every "not shown in the
    //    report" note points here. If a cap is ever unavoidable, the table
    //    says how many rows it dropped rather than stopping silently.
    // 2. Every byte figure ships beside a human-readable size and, where the
    //    total is meaningful, a share. Raw bytes alone sort correctly and read
    //    like nothing; "441360000000" is not an answer anyone can use.
    // 3. Numbers are unquoted so spreadsheets type them as numbers. Text is
    //    always quoted. A quoted "16000000" imports as a string in Excel and
    //    every subsequent SUM silently returns zero.

    static func csv(from s: ScanSnapshot, inventory: FileInventory = FileInventory()) -> String {
        // UTF-8 BOM. Camera names and paths are not ASCII, and Excel on
        // Windows mojibakes a BOM-less UTF-8 file without ever warning.
        var out = "\u{FEFF}"
        out += "Vaultline Labs Drive Inspector · Drive Report\n\n"

        out += section("Scan", cols: ["Field", "Value"]) { rows in
            rows.add([t(s.volumeName.isEmpty ? "Volume" : "Volume"), t(s.volumeName)])
            rows.add([t("Path"), t(s.rootPath)])
            rows.add([t("Scanned"), t(ISO8601DateFormatter().string(from: Date()))])
            rows.add([t("Inspector version"), t(ReportBuilder.appVersion)])
            rows.add([t("Scan completed"), t(s.isComplete ? "Yes" : (s.wasCancelled ? "No, stopped early" : "No, still running"))])
            rows.add([t("Media analysis completed"), t(s.probe.isComplete ? "Yes" : "No")])
            rows.add([t("Duplicate verification"), t(duplicateState(s.dupes))])
            rows.add([t("Elapsed (s)"), n(String(format: "%.1f", s.elapsed))])
        }

        out += section("Totals", cols: ["Field", "Value", "Readable"]) { rows in
            rows.add([t("Files scanned"), n("\(s.filesScanned)"), t(Fmt.count(s.filesScanned))])
            rows.add([t("Media files"), n("\(s.mediaFileCount)"), t(Fmt.count(s.mediaFileCount))])
            rows.add([t("Project files"), n("\(s.projectFiles.count)"), t(Fmt.count(s.projectFiles.count))])
            rows.add([t("Folders scanned"), n("\(s.foldersScanned)"), t(Fmt.count(s.foldersScanned))])
            rows.add([t("Empty folders"), n("\(s.emptyFolders.count)"), t(Fmt.count(s.emptyFolders.count))])
            rows.add([t("Bytes scanned"), n("\(s.bytesScanned)"), t(Fmt.bytes(s.bytesScanned))])
            rows.add([t("Volume capacity (bytes)"), n("\(s.volumeTotalBytes)"), t(Fmt.bytes(s.volumeTotalBytes))])
            rows.add([t("Volume free (bytes)"), n("\(s.volumeFreeBytes)"), t(Fmt.bytes(s.volumeFreeBytes))])
            rows.add([t("Earliest media date"), t(Fmt.isoDay(s.earliest)), t("")])
            rows.add([t("Latest media date"), t(Fmt.isoDay(s.latest)), t("")])
            if s.probe.totalDuration > 0 {
                rows.add([t("Total footage (s)"), n("\(Int(s.probe.totalDuration))"),
                          t(Fmt.duration(s.probe.totalDuration))])
            }
            rows.add([t("Date source"), t(s.probe.usedEmbeddedDates ? "Embedded capture dates" : "File modification dates"), t("")])
            if s.probe.unreadable.count > 0 {
                rows.add([t("Unreadable video/audio (files)"), n("\(s.probe.unreadable.count)"),
                          t(Fmt.count(s.probe.unreadable.count))])
                rows.add([t("Unreadable video/audio (bytes)"), n("\(s.probe.unreadable.bytes)"),
                          t(Fmt.bytes(s.probe.unreadable.bytes))])
            }
            if s.probe.estimatedProxyBytes > 0 {
                rows.add([t("Estimated proxy storage (bytes)"), n("\(s.probe.estimatedProxyBytes)"),
                          t(Fmt.bytes(s.probe.estimatedProxyBytes))])
            }
            rows.add([t("Verified duplicate groups"), n("\(s.dupes.groups.count)"), t(Fmt.count(s.dupes.groups.count))])
            rows.add([t("Verified extra copies"), n("\(s.dupes.duplicateFileCount)"), t(Fmt.count(s.dupes.duplicateFileCount))])
            rows.add([t("Reclaimable (bytes)"), n("\(s.dupes.recoverableBytes)"), t(Fmt.bytes(s.dupes.recoverableBytes))])
        }

        out += section("File types", cols: ["Type", "Files", "Bytes", "Size", "Share of scanned %"]) { rows in
            for c in MediaCategory.allCases {
                guard let st = s.byCategory[c], st.count > 0 else { continue }
                rows.add([t(c.displayName), n("\(st.count)"), n("\(st.bytes)"),
                          t(Fmt.bytes(st.bytes)), n(Fmt.share(st.bytes, of: s.bytesScanned))])
            }
        }

        out += section("Extensions", cols: ["Extension", "Files", "Bytes", "Size", "Share of scanned %"]) { rows in
            for e in s.topExtensions(s.byExtension.count) {
                rows.add([t(".\(e.name)"), n("\(e.count)"), n("\(e.bytes)"),
                          t(Fmt.bytes(e.bytes)), n(Fmt.share(e.bytes, of: s.bytesScanned))])
            }
        }

        out += section("Codecs", cols: ["Codec", "Bytes", "Size", "Share of media storage %"]) { rows in
            let total = s.probe.codecBytesTotal
            for c in s.probe.topCodecs(s.probe.bytesByCodec.count) {
                rows.add([t(c.name), n("\(c.bytes)"), t(Fmt.bytes(c.bytes)), n(Fmt.share(c.bytes, of: total))])
            }
        }

        out += section("Resolutions", cols: ["Resolution", "Clips", "Share of clips %"]) { rows in
            let total = s.probe.resolutionClipsTotal
            for r in s.probe.topResolutions(s.probe.clipsByResolution.count) {
                rows.add([t(r.name), n("\(r.count)"), n(Fmt.share(r.count, of: total))])
            }
        }

        out += section("Frame rates", cols: ["Frame rate", "Clips", "Share of clips %"]) { rows in
            let total = s.probe.frameRateClipsTotal
            for r in s.probe.topFrameRates(s.probe.clipsByFrameRate.count) {
                rows.add([t(r.name), n("\(r.count)"), n(Fmt.share(r.count, of: total))])
            }
        }

        out += section("Cameras", cols: ["Camera", "Files", "Bytes", "Size"]) { rows in
            for c in s.probe.topCameras(s.probe.byCamera.count) {
                rows.add([t(c.name), n("\(c.count)"), n("\(c.bytes)"), t(Fmt.bytes(c.bytes))])
            }
        }

        out += section("Media by year", cols: ["Year", "Bytes", "Size"]) { rows in
            for (y, b) in s.probe.bytesByYear.sorted(by: { $0.key < $1.key }) {
                rows.add([n("\(y)"), n("\(b)"), t(Fmt.bytes(b))])
            }
        }

        out += section("Largest folders", cols: ["Rank", "Folder", "Path", "Files", "Bytes", "Size", "Share of scanned %"]) { rows in
            for (i, f) in s.largestFolders.enumerated() {
                rows.add([n("\(i + 1)"), t(f.name), t(f.path), n("\(f.fileCount)"),
                          n("\(f.bytes)"), t(Fmt.bytes(f.bytes)), n(Fmt.share(f.bytes, of: s.bytesScanned))])
            }
        }

        out += section("Largest files", cols: ["Rank", "File", "Path", "Type", "Bytes", "Size", "Modified"]) { rows in
            for (i, f) in s.largestFiles.enumerated() {
                rows.add([n("\(i + 1)"), t(f.name), t(f.path), t(f.category.displayName),
                          n("\(f.size)"), t(Fmt.bytes(f.size)), t(Fmt.isoDay(f.modified))])
            }
        }

        out += section("Verified duplicates (files 4 MB and larger)",
                       cols: ["Group", "Copies", "File", "Path", "Size (bytes)", "Size",
                              "Group reclaimable (bytes)", "Group reclaimable", "Verification"]) { rows in
            for (i, g) in s.dupes.groups.enumerated() {
                for p in g.paths {
                    rows.add([n("\(i + 1)"), n("\(g.paths.count)"),
                              t((p as NSString).lastPathComponent), t(p),
                              n("\(g.size)"), t(Fmt.bytes(g.size)),
                              n("\(g.recoverable)"), t(Fmt.bytes(g.recoverable)),
                              t("Full SHA-256")])
                }
            }
            for note in duplicateExclusions(s.dupes) {
                rows.add([t(""), t(""), t(""), t(note.0), t(""), t(""), t(""), t(""), t(note.1)])
            }
        }

        out += section("Empty folders", cols: ["Folder"]) { rows in
            for p in s.emptyFolders { rows.add([t(p)]) }
        }

        out += section("Project files", cols: ["File", "Path", "Bytes", "Size"]) { rows in
            for f in s.projectFiles {
                rows.add([t(f.name), t(f.path), n("\(f.size)"), t(Fmt.bytes(f.size))])
            }
        }

        // The per-file inventory the CSV has always claimed to be. Last,
        // because it is the longest table by orders of magnitude and nobody
        // scrolling for the summary should have to page past it.
        out += section("All files", cols: ["Path", "File", "Extension", "Type", "Bytes", "Size", "Modified"]) { rows in
            for f in inventory.files {
                rows.add([t(f.path), t(f.name), t((f.path as NSString).pathExtension.lowercased()),
                          t(f.category.displayName), n("\(f.size)"), t(Fmt.bytes(f.size)),
                          t(Fmt.isoDay(f.modified))])
            }
            if inventory.notKept > 0 {
                rows.add([t("\(inventory.notKept) further files were scanned but not listed here; the inventory is capped at \(Walker.maxMediaRefs) rows"),
                          t(""), t(""), t(""), t(""), t(""), t("")])
            }
        }

        return out
    }

    private static func duplicateState(_ d: DuplicateSummary) -> String {
        if d.wasCancelled { return "Cancelled" }
        if d.isRunning { return "Running" }
        if d.isPaused { return "Paused, candidates remain" }
        if d.scopeComplete { return "Complete" }
        if d.isComplete { return "Complete with exclusions" }
        return "Not started"
    }

    /// Reasons files were left out of the verified totals. Each becomes a row
    /// in the duplicates table so the export never reads as more complete than
    /// the run behind it.
    private static func duplicateExclusions(_ d: DuplicateSummary) -> [(String, String)] {
        var out: [(String, String)] = []
        if d.remainingCandidateFiles > 0 {
            out.append(("\(d.remainingCandidateFiles) candidate files remain unverified and are excluded", "Incomplete"))
        }
        if d.unreadableFiles > 0 || d.changedFiles > 0 {
            out.append(("Excluded: \(d.unreadableFiles) unreadable; \(d.changedFiles) changed during scan", "Excluded"))
        }
        if d.wasCancelled {
            out.append(("Excluded: \(d.cancelledFiles) unfinished when verification was cancelled", "Cancelled"))
        }
        return out
    }

    /// One CSV table: a plain title line, a header row, its data rows, then a
    /// blank line. Omitted entirely if nothing was added — an empty "Codecs"
    /// table with just a header is more confusing than no table at all.
    private static func section(_ title: String, cols: [String], _ build: (inout RowCollector) -> Void) -> String {
        var rows = RowCollector()
        build(&rows)
        guard !rows.lines.isEmpty else { return "" }
        var out = "\(title)\n\(cols.map(t).joined(separator: ","))\n"
        out += rows.lines.joined()
        return out + "\n"
    }

    /// Fields arrive already escaped by `t` or `n`, so the collector only joins
    /// them. Quoting here as well would double-quote every value.
    private struct RowCollector {
        var lines: [String] = []
        mutating func add(_ fields: [String]) {
            lines.append(fields.joined(separator: ",") + "\n")
        }
    }

    /// A text field: quoted and escaped per RFC 4180.
    private nonisolated static func t(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// A numeric field: bare, so spreadsheets type it as a number. A quoted
    /// "16000000" imports as text in Excel and every SUM over the column comes
    /// back zero. Anything that isn't a plain number falls back to a text
    /// field rather than emitting a malformed row.
    private nonisolated static func n(_ s: String) -> String {
        let ok = !s.isEmpty && s.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" }
        return ok ? s : t(s)
    }
}
