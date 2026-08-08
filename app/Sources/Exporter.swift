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
            case .html: return "HTML — one file, opens anywhere"
            case .pdf:  return "PDF — for email and print"
            case .csv:  return "CSV — every file, for your own analysis"
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

    static func export(_ snapshot: ScanSnapshot, as format: Format) async throws {
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
            try csv(from: snapshot).write(to: url, atomically: true, encoding: .utf8)
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
        return "\(safe) — Drive Report \(f.string(from: Date())).\(ext)"
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

    private static func csv(from s: ScanSnapshot) -> String {
        var out = "Vaultline Labs Drive Inspector — Drive Report\n\n"

        out += section("Summary", cols: ["Field", "Value"]) { rows in
            rows.add(["Volume", s.volumeName])
            rows.add(["Path", s.rootPath])
            rows.add(["Scanned", ISO8601DateFormatter().string(from: Date())])
            rows.add(["Files", "\(s.filesScanned)"])
            rows.add(["Media files", "\(s.mediaFileCount)"])
            rows.add(["Bytes scanned", "\(s.bytesScanned)"])
            rows.add(["Volume capacity (bytes)", "\(s.volumeTotalBytes)"])
            rows.add(["Volume free (bytes)", "\(s.volumeFreeBytes)"])
            if s.probe.totalDuration > 0 { rows.add(["Total duration (s)", "\(Int(s.probe.totalDuration))"]) }
            if s.probe.unreadable.count > 0 {
                rows.add(["Unreadable video/audio (files)", "\(s.probe.unreadable.count)"])
                rows.add(["Unreadable video/audio (bytes)", "\(s.probe.unreadable.bytes)"])
            }
        }

        out += section("File types", cols: ["Type", "Files", "Bytes"]) { rows in
            for c in MediaCategory.allCases {
                if let st = s.byCategory[c], st.count > 0 { rows.add([c.displayName, "\(st.count)", "\(st.bytes)"]) }
            }
        }

        out += section("Top extensions", cols: ["Extension", "Files", "Bytes"]) { rows in
            for e in s.topExtensions(50) { rows.add([".\(e.name)", "\(e.count)", "\(e.bytes)"]) }
        }

        out += section("Codecs", cols: ["Codec", "Bytes"]) { rows in
            for c in s.probe.topCodecs(50) { rows.add([c.name, "\(c.bytes)"]) }
        }

        out += section("Resolutions", cols: ["Resolution", "Clips"]) { rows in
            for r in s.probe.topResolutions(50) { rows.add([r.name, "\(r.count)"]) }
        }

        out += section("Frame rates", cols: ["Frame rate", "Clips"]) { rows in
            for r in s.probe.topFrameRates(50) { rows.add([r.name, "\(r.count)"]) }
        }

        out += section("Cameras", cols: ["Camera", "Files", "Bytes"]) { rows in
            for c in s.probe.topCameras(50) { rows.add([c.name, "\(c.count)", "\(c.bytes)"]) }
        }

        out += section("Media by year", cols: ["Year", "Bytes"]) { rows in
            for (y, b) in s.probe.bytesByYear.sorted(by: { $0.key < $1.key }) { rows.add(["\(y)", "\(b)"]) }
        }

        out += section("Largest folders", cols: ["Folder", "Files", "Bytes"]) { rows in
            for f in s.largestFolders { rows.add([f.path, "\(f.fileCount)", "\(f.bytes)"]) }
        }

        out += section("Largest files", cols: ["File", "Type", "Bytes"]) { rows in
            for f in s.largestFiles { rows.add([f.path, f.category.displayName, "\(f.size)"]) }
        }

        out += section("Potential duplicates", cols: ["Group", "File", "Size", "Recoverable if kept once"]) { rows in
            for (i, g) in s.dupes.groups.enumerated() {
                for p in g.paths { rows.add(["\(i + 1)", p, "\(g.size)", "\(g.recoverable)"]) }
            }
            if s.dupes.hitReadBudget {
                rows.add(["", "Stopped early against the read budget — there may be more", "", ""])
            }
        }

        out += section("Empty folders", cols: ["Folder"]) { rows in
            for p in s.emptyFolders.prefix(500) { rows.add([p]) }
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
        var out = "\(title)\n\(cols.map(q).joined(separator: ","))\n"
        out += rows.lines.joined()
        return out + "\n"
    }

    private struct RowCollector {
        var lines: [String] = []
        mutating func add(_ fields: [String]) {
            lines.append(fields.map(q).joined(separator: ",") + "\n")
        }
    }

    private nonisolated static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
