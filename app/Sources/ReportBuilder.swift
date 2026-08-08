import Foundation
import AppKit

/// Generates the shareable drive report.
///
/// The report — not the app window — is the thing that travels. Someone runs a
/// scan once, then emails the report to a producer or pastes it into Slack. So
/// it is a single self-contained HTML file: every style and both logos inlined,
/// no external requests, opens offline forever.
///
/// Design of record: `../report/report-spec.md` and `report-template.html`.
enum ReportBuilder {

    // MARK: Entry point

    static func html(from s: ScanSnapshot) -> String {
        let generated = DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .none)
        let cap = s.volumeTotalBytes > 0
            ? "<span class=\"cap\">\(Fmt.bytes(s.volumeTotalBytes))</span>" : ""

        var body = ""
        body += capacityBlock(s)
        body += typeBlock(s)
        body += codecBlock(s)
        body += frameRateBlock(s)
        body += cameraBlock(s)
        body += yearBlock(s)
        body += foldersBlock(s)
        body += filesBlock(s)
        body += duplicatesBlock(s)
        body += attentionBlock(s)

        var out = "<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n"
        out += "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n"
        out += "<title>Drive Report — \(esc(s.volumeName)) · Vaultline</title>\n"
        out += "<style>\(css)</style></head>\n<body><div class=\"page\">\n"

        out += "<header class=\"mast\"><div class=\"wordmark\">"
        out += img("report-wordmark-white", cls: "logo", alt: "Vaultline Solutions")
        out += "<span class=\"line\"></span><span class=\"sub\">Drive Report</span></div>"
        out += "<h1>\(esc(s.volumeName)) \(cap)</h1>"
        out += "<div class=\"meta\">Scanned \(generated) · \(Fmt.count(s.filesScanned)) files "
        out += "in \(String(format: "%.1f", s.elapsed))s</div></header>\n"

        out += heroBlock(s)
        out += "<main class=\"body\">\n\(body)\n</main>\n"
        out += footer(s)
        out += "</div></body></html>"
        return out
    }

    // MARK: Blocks

    private static func heroBlock(_ s: ScanSnapshot) -> String {
        let duration = s.probe.totalDuration > 0 ? Fmt.duration(s.probe.totalDuration) : "—"
        let clips = s.byCategory[.video]?.count ?? 0
        let dateSource = s.probe.usedEmbeddedDates ? "from capture dates" : "from file dates"

        var out = "<div class=\"hero\">"
        out += tile("Media files", Fmt.count(s.mediaFileCount),
                    "\(Fmt.count(s.projectFiles.count)) project files")
        out += tile("Footage", duration, "across \(Fmt.count(clips)) clips")
        out += tile("Date range", Fmt.dateRange(s.earliest, s.latest), dateSource)
        if s.dupes.recoverableBytes > 0 {
            out += tile("Recoverable", Fmt.bytes(s.dupes.recoverableBytes),
                        "\(Fmt.count(s.dupes.duplicateFileCount)) likely duplicates")
        } else {
            out += tile("Largest folder", Fmt.bytes(s.largestFolders.first?.bytes ?? 0),
                        s.largestFolders.first?.name ?? "—")
        }
        return out + "</div>\n"
    }

    private static func capacityBlock(_ s: ScanSnapshot) -> String {
        guard s.volumeTotalBytes > 0 else { return "" }
        let used = s.volumeTotalBytes - s.volumeFreeBytes
        let pct = Double(used) / Double(s.volumeTotalBytes) * 100

        var out = "<section><h2>Capacity</h2>"
        out += "<p class=\"lede\">\(Fmt.bytes(used)) used of \(Fmt.bytes(s.volumeTotalBytes)).</p>"
        out += "<div class=\"cap-bar\"><i style=\"width:\(String(format: "%.1f", pct))%\"></i></div>"
        out += "<div class=\"cap-legend\">"
        out += "<span><i class=\"sw\" style=\"background:var(--mark-blue)\"></i>Used \(Fmt.bytes(used))</span>"
        out += "<span><i class=\"sw\" style=\"background:var(--track)\"></i>Free \(Fmt.bytes(s.volumeFreeBytes))</span>"
        return out + "</div></section>\n"
    }

    private static func typeBlock(_ s: ScanSnapshot) -> String {
        let rows = MediaCategory.allCases.compactMap { cat -> String? in
            guard let st = s.byCategory[cat], st.count > 0 else { return nil }
            return bar(label: cat.displayName,
                       fraction: frac(st.bytes, s.bytesScanned),
                       trailing: Fmt.percent(st.bytes, of: s.bytesScanned),
                       sub: "\(Fmt.files(st.count)) · \(Fmt.bytes(st.bytes))")
        }.joined()
        guard !rows.isEmpty else { return "" }
        return "<section><h2>What's on it</h2><p class=\"lede\">Share of scanned data.</p>"
             + "<div class=\"bars\">\(rows)</div></section>\n"
    }

    private static func codecBlock(_ s: ScanSnapshot) -> String {
        let p = s.probe
        guard !p.bytesByCodec.isEmpty || !p.clipsByResolution.isEmpty else { return "" }

        let codecs = p.topCodecs(6).map {
            bar(label: $0.name, fraction: frac($0.bytes, p.codecBytesTotal),
                trailing: Fmt.percent($0.bytes, of: p.codecBytesTotal), sub: nil)
        }.joined()

        let res = p.topResolutions(6).map {
            bar(label: $0.name,
                fraction: Double($0.count) / Double(max(1, p.resolutionClipsTotal)),
                trailing: Fmt.percent($0.count, of: p.resolutionClipsTotal), sub: nil)
        }.joined()

        var out = "<section class=\"cols2\">"
        if !codecs.isEmpty {
            out += "<div><h2>Codecs</h2><p class=\"lede\">Share of media storage.</p>"
                 + "<div class=\"bars\">\(codecs)</div></div>"
        }
        if !res.isEmpty {
            out += "<div><h2>Resolutions</h2><p class=\"lede\">Share of clips.</p>"
                 + "<div class=\"bars\">\(res)</div></div>"
        }
        return out + "</section>\n"
    }

    private static func frameRateBlock(_ s: ScanSnapshot) -> String {
        let rates = s.probe.topFrameRates(8)
        guard !rates.isEmpty else { return "" }
        let rows = rates.map {
            "<tr><td>\(esc($0.name))</td><td class=\"n\">\(Fmt.count($0.count))</td>"
            + "<td class=\"n\">\(Fmt.percent($0.count, of: s.probe.frameRateClipsTotal))</td></tr>"
        }.joined()
        return "<section><h2>Frame rates</h2><table><thead><tr><th>Rate</th>"
             + "<th style=\"text-align:right\">Clips</th><th style=\"text-align:right\">Share</th>"
             + "</tr></thead><tbody>\(rows)</tbody></table></section>\n"
    }

    private static func cameraBlock(_ s: ScanSnapshot) -> String {
        let cams = s.probe.topCameras(10)
        guard !cams.isEmpty else { return "" }
        let chips = cams.map {
            "<div class=\"cam\"><b>\(esc($0.name))</b>"
            + "<span>\(Fmt.files($0.count)) · \(Fmt.bytes($0.bytes))</span></div>"
        }.joined()
        return "<section><h2>Cameras detected</h2><p class=\"lede\">"
             + "Read from clip metadata, sidecars and card structure.</p>"
             + "<div class=\"cams\">\(chips)</div></section>\n"
    }

    private static func yearBlock(_ s: ScanSnapshot) -> String {
        let years = s.probe.bytesByYear.sorted { $0.key < $1.key }
        guard years.count > 1 else { return "" }
        let peak = years.map(\.value).max() ?? 1

        let cols = years.map { y -> String in
            let h = max(3, Int(Double(y.value) / Double(peak) * 100))
            return "<div class=\"yr\"><div class=\"col\" style=\"height:\(h)%\"></div>"
                 + "<div class=\"lb\"><b>\(Fmt.bytes(y.value))</b>\(y.key)</div></div>"
        }.joined()

        // Being explicit here matters: a cloned drive with no embedded dates
        // reports everything as the copy year, and a confidently wrong timeline
        // is worse than no timeline at all.
        let source = s.probe.usedEmbeddedDates
            ? "From embedded capture dates."
            : "From file modification dates — little of this drive's media carried an embedded capture date, so copied files may appear in the wrong year."

        return "<section><h2>Media by year</h2><p class=\"lede\">\(source)</p>"
             + "<div class=\"years\" style=\"grid-template-columns:repeat(\(years.count),1fr)\">"
             + "\(cols)</div></section>\n"
    }

    private static func foldersBlock(_ s: ScanSnapshot) -> String {
        guard !s.largestFolders.isEmpty else { return "" }
        let peak = s.largestFolders.first?.bytes ?? 1
        let rows = s.largestFolders.prefix(10).map { f -> String in
            let w = Int(Double(f.bytes) / Double(max(1, peak)) * 100)
            return "<tr><td>\(esc(f.name))<div class=\"path\">\(esc(rel(f.path, s.rootPath)))</div>"
                 + "<div class=\"minibar\"><i style=\"width:\(w)%\"></i></div></td>"
                 + "<td class=\"n\">\(Fmt.count(f.fileCount))</td>"
                 + "<td class=\"n\">\(Fmt.bytes(f.bytes))</td></tr>"
        }.joined()
        return "<section><h2>Largest folders</h2><table><thead><tr><th>Folder</th>"
             + "<th style=\"text-align:right\">Files</th><th style=\"text-align:right\">Size</th>"
             + "</tr></thead><tbody>\(rows)</tbody></table></section>\n"
    }

    private static func filesBlock(_ s: ScanSnapshot) -> String {
        guard !s.largestFiles.isEmpty else { return "" }
        let rows = s.largestFiles.prefix(10).map { f -> String in
            let dir = rel((f.path as NSString).deletingLastPathComponent, s.rootPath)
            return "<tr><td>\(esc(f.name))<div class=\"path\">\(esc(dir))</div></td>"
                 + "<td class=\"n\">\(f.category.displayName)</td>"
                 + "<td class=\"n\">\(Fmt.bytes(f.size))</td></tr>"
        }.joined()
        return "<section><h2>Largest files</h2><table><thead><tr><th>File</th>"
             + "<th style=\"text-align:right\">Type</th><th style=\"text-align:right\">Size</th>"
             + "</tr></thead><tbody>\(rows)</tbody></table></section>\n"
    }

    private static func duplicatesBlock(_ s: ScanSnapshot) -> String {
        let d = s.dupes
        guard !d.groups.isEmpty else { return "" }
        let rows = d.groups.prefix(10).map { g -> String in
            let others = g.paths.dropFirst().map { rel($0, s.rootPath) }.joined(separator: "\n")
            return "<tr><td>\(esc(g.name))<div class=\"path\">\(esc(rel(g.paths[0], s.rootPath)))</div>"
                 + "<div class=\"path\">+ \(g.paths.count - 1) more: \(esc(others))</div></td>"
                 + "<td class=\"n\">\(g.paths.count)×</td>"
                 + "<td class=\"n\">\(Fmt.bytes(g.recoverable))</td></tr>"
        }.joined()

        // "Potential" is doing real work in that heading. Matching on size plus
        // both ends of the file is strong evidence, not proof.
        var lede = "Matched by size and content hash. Verify before deleting anything."
        if d.hitReadBudget {
            lede += " This check stopped early against its read budget, so there may be more."
        }
        return "<section><h2>Potential duplicates</h2><p class=\"lede\">\(lede)</p>"
             + "<table><thead><tr><th>File</th><th style=\"text-align:right\">Copies</th>"
             + "<th style=\"text-align:right\">Recoverable</th></tr></thead>"
             + "<tbody>\(rows)</tbody></table></section>\n"
    }

    private static func attentionBlock(_ s: ScanSnapshot) -> String {
        var items: [String] = []

        if s.dupes.recoverableBytes > 0 {
            items.append(item(
                "\(Fmt.count(s.dupes.duplicateFileCount)) likely duplicate files — \(Fmt.bytes(s.dupes.recoverableBytes)) recoverable",
                "Across \(Fmt.count(s.dupes.groups.count)) groups. Check them before deleting."))
        }
        if !s.emptyFolders.isEmpty {
            items.append(item(
                "\(Fmt.count(s.emptyFolders.count)) empty folders",
                "Left behind by moves or aborted offloads."))
        }
        let proxy = s.probe.estimatedProxyBytes
        if proxy > 0 {
            items.append(item(
                "Proxies for this drive would need about \(Fmt.bytes(proxy))",
                "Rough estimate for everything 4K and above. An order of magnitude, not a quote."))
        }
        if let other = s.byCategory[.other], other.bytes > s.bytesScanned / 20 {
            items.append(item(
                "\(Fmt.bytes(other.bytes)) in unrecognised file types",
                "Caches, renders, archives or formats this tool doesn't classify yet."))
        }
        if s.probe.unreadable.count > 0 {
            items.append(item(
                "\(Fmt.files(s.probe.unreadable.count)) couldn't be read for codec, resolution or duration",
                "\(Fmt.bytes(s.probe.unreadable.bytes)) counted as video/audio above has no metadata behind it — often RAW formats like R3D or BRAW that need the camera vendor's own software installed."))
        }
        // NOTE: "files with no verified second copy" is deliberately absent.
        // A single-drive scan cannot know what exists elsewhere, and claiming it
        // without evidence would discredit every number above it. That check is
        // what the full Vaultline system does — see report-spec.md §5.

        guard !items.isEmpty else { return "" }
        return "<section><h2>Worth a look</h2><div class=\"att\">\(items.joined())</div></section>\n"
    }

    private static func footer(_ s: ScanSnapshot) -> String {
        var out = "<footer class=\"foot\">"
        out += "<div class=\"q\">You already captured this footage. "
        out += "The hard part is finding it again three years later.</div>"
        out += "<div class=\"p\">This report covers one drive. Vaultline indexes every drive your "
        out += "team owns — searchable, tagged, transcribed — built around your existing storage, "
        out += "without moving your original media.</div>"
        out += "<div class=\"r\"><span class=\"t\">"
        out += img("report-icon-white", cls: "", alt: "")
        out += "Custom software for serious footage libraries.</span>"
        out += "<span class=\"s\">vaultlinesolutions.com</span></div>"
        out += "<div class=\"r\" style=\"border:0;padding-top:8px;margin-top:2px\">"
        out += "<span class=\"s\">Generated by Vaultline Labs Drive Inspector \(appVersion) · "
        out += "scanned locally, never uploaded</span>"
        out += "<span class=\"s\">\(esc(s.rootPath))</span></div></footer>"
        return out
    }

    // MARK: Pieces

    private static func tile(_ key: String, _ value: String, _ note: String) -> String {
        "<div><div class=\"k\">\(esc(key))</div><div class=\"v\">\(esc(value))</div>"
        + "<div class=\"n\">\(esc(note))</div></div>"
    }

    private static func item(_ title: String, _ detail: String) -> String {
        "<div class=\"it\"><svg class=\"ic\" viewBox=\"0 0 16 16\" fill=\"none\" "
        + "stroke=\"currentColor\" stroke-width=\"1.5\"><path d=\"M8 1.6 15 14H1L8 1.6Z\"/>"
        + "<path d=\"M8 6.4v3.4\"/><circle cx=\"8\" cy=\"11.8\" r=\".6\" fill=\"currentColor\"/>"
        + "</svg><div><b>\(esc(title))</b><span>\(esc(detail))</span></div></div>"
    }

    private static func bar(label: String, fraction: Double, trailing: String, sub: String?) -> String {
        let w = String(format: "%.1f", max(0.4, min(100, fraction * 100)))
        var out = "<div class=\"bar\"><span class=\"lbl\">\(esc(label))</span>"
        out += "<span class=\"tr\"><i class=\"fl\" style=\"width:\(w)%\"></i></span>"
        out += "<span class=\"val\">\(trailing)</span>"
        if let sub { out += "<span class=\"sub\">\(esc(sub))</span>" }
        return out + "</div>"
    }

    private static func frac(_ a: Int64, _ b: Int64) -> Double {
        b > 0 ? Double(a) / Double(b) : 0
    }

    private static func rel(_ path: String, _ root: String) -> String {
        path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    /// Inlines a bundled PNG as a data URL. A report that renders a broken image
    /// icon when forwarded is worse than one with no logo.
    private static func img(_ name: String, cls: String, alt: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let data = try? Data(contentsOf: url) else { return "" }
        let c = cls.isEmpty ? "" : " class=\"\(cls)\""
        return "<img\(c) alt=\"\(esc(alt))\" src=\"data:image/png;base64,\(data.base64EncodedString())\">"
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
