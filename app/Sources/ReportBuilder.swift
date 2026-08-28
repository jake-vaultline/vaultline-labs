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
        body += duplicatesBlock(s)
        body += capacityBlock(s)
        body += typeBlock(s)
        body += codecBlock(s)
        body += frameRateBlock(s)
        body += formatBlock(s)
        body += cameraBlock(s)
        body += yearBlock(s)
        body += foldersBlock(s)
        body += filesBlock(s)
        body += attentionBlock(s)

        var out = "<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n"
        out += "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n"
        out += "<title>\(esc(s.volumeName)) Drive Report · Vaultline</title>\n"
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
        // "Verified duplicate space" wrapped onto two lines in the tile header
        // and knocked this tile's note out of line with the other three.
        if s.dupes.recoverableBytes > 0 {
            out += tile("Reclaimable", Fmt.bytes(s.dupes.recoverableBytes),
                        "\(Fmt.count(s.dupes.duplicateFileCount)) verified extra copies")
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

        // Every bar carries its own figure. A percentage alone does not tell a
        // producer whether "17% H.264" is four clips or four hundred.
        let codecs = p.topCodecs(Show.codecs).map {
            bar(label: $0.name, fraction: frac($0.bytes, p.codecBytesTotal),
                trailing: Fmt.percent($0.bytes, of: p.codecBytesTotal), sub: Fmt.bytes($0.bytes))
        }.joined()

        let res = p.topResolutions(Show.resolutions).map {
            bar(label: $0.name,
                fraction: Double($0.count) / Double(max(1, p.resolutionClipsTotal)),
                trailing: Fmt.percent($0.count, of: p.resolutionClipsTotal),
                sub: "\(Fmt.count($0.count)) \($0.count == 1 ? "clip" : "clips")")
        }.joined()

        var out = "<section class=\"cols2\">"
        if !codecs.isEmpty {
            out += "<div><h2>Codecs</h2><p class=\"lede\">Share of media storage.</p>"
                 + "<div class=\"bars\">\(codecs)</div>"
                 + more(shown: min(Show.codecs, p.bytesByCodec.count), of: p.bytesByCodec.count,
                        noun: "codec") + "</div>"
        }
        if !res.isEmpty {
            out += "<div><h2>Resolutions</h2><p class=\"lede\">Share of clips.</p>"
                 + "<div class=\"bars\">\(res)</div>"
                 + more(shown: min(Show.resolutions, p.clipsByResolution.count),
                        of: p.clipsByResolution.count, noun: "resolution") + "</div>"
        }
        return out + "</section>\n"
    }

    /// Extensions, not categories. "Video is 96%" is the shape of the drive;
    /// ".mov is 96% and .mp4 is 3%" is the thing an editor can act on. The app
    /// window has always shown this; the report did not.
    private static func formatBlock(_ s: ScanSnapshot) -> String {
        let rows = s.topExtensions(Show.extensions)
        guard rows.count > 1 else { return "" }
        let bars = rows.map {
            bar(label: ".\($0.name)", fraction: frac($0.bytes, s.bytesScanned),
                trailing: Fmt.percent($0.bytes, of: s.bytesScanned),
                sub: "\(Fmt.files($0.count)) · \(Fmt.bytes($0.bytes))")
        }.joined()
        return "<section><h2>Top formats</h2><p class=\"lede\">Share of scanned data by file "
             + "extension.</p><div class=\"bars\">\(bars)</div>"
             + more(shown: rows.count, of: s.byExtension.count, noun: "extension") + "</section>\n"
    }

    private static func frameRateBlock(_ s: ScanSnapshot) -> String {
        let rates = s.probe.topFrameRates(Show.frameRates)
        guard !rates.isEmpty else { return "" }
        let rows = rates.map {
            "<tr><td>\(esc($0.name))</td><td class=\"n\">\(Fmt.count($0.count))</td>"
            + "<td class=\"n\">\(Fmt.percent($0.count, of: s.probe.frameRateClipsTotal))</td></tr>"
        }.joined()
        return "<section><h2>Frame rates</h2><table><thead><tr><th>Rate</th>"
             + "<th class=\"n\">Clips</th><th class=\"n\">Share</th>"
             + "</tr></thead><tbody>\(rows)</tbody></table>"
             + more(shown: rates.count, of: s.probe.clipsByFrameRate.count, noun: "rate")
             + "</section>\n"
    }

    private static func cameraBlock(_ s: ScanSnapshot) -> String {
        let cams = s.probe.topCameras(Show.cameras)
        guard !cams.isEmpty else { return "" }
        let chips = cams.map {
            "<div class=\"cam\"><b>\(esc($0.name))</b>"
            + "<span>\(Fmt.files($0.count)) · \(Fmt.bytes($0.bytes))</span></div>"
        }.joined()
        return "<section><h2>Cameras detected</h2><p class=\"lede\">"
             + "Read from clip metadata, sidecars and card structure.</p>"
             + "<div class=\"cams\">\(chips)</div>"
             + more(shown: cams.count, of: s.probe.byCamera.count, noun: "camera")
             + "</section>\n"
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
            : "From file modification dates. Little of this drive's media carried an embedded capture date, so copied files may appear in the wrong year."

        return "<section><h2>Media by year</h2><p class=\"lede\">\(source)</p>"
             + "<div class=\"years\" style=\"grid-template-columns:repeat(\(years.count),1fr)\">"
             + "\(cols)</div></section>\n"
    }

    private static func foldersBlock(_ s: ScanSnapshot) -> String {
        guard !s.largestFolders.isEmpty else { return "" }
        let shown = Array(s.largestFolders.prefix(Show.largestFolders))
        let peak = s.largestFolders.first?.bytes ?? 1
        let rows = shown.map { f -> String in
            let w = Int(Double(f.bytes) / Double(max(1, peak)) * 100)
            return "<tr><td><div class=\"nm\">\(esc(f.name))</div>"
                 + "<div class=\"path\">\(esc(rel(f.path, s.rootPath)))</div>"
                 + "<div class=\"minibar\"><i style=\"width:\(w)%\"></i></div></td>"
                 + "<td class=\"n\">\(Fmt.count(f.fileCount))</td>"
                 + "<td class=\"n\">\(Fmt.bytes(f.bytes))</td></tr>"
        }.joined()
        return "<section><h2>Largest folders</h2><p class=\"lede\">Recursive size, so a folder "
             + "includes everything beneath it. Ranked from \(Fmt.count(s.foldersScanned)) folders "
             + "scanned.</p><table><thead><tr><th>Folder</th>"
             + "<th class=\"n\">Files</th><th class=\"n\">Size</th>"
             + "</tr></thead><tbody>\(rows)</tbody></table></section>\n"
    }

    private static func filesBlock(_ s: ScanSnapshot) -> String {
        guard !s.largestFiles.isEmpty else { return "" }
        let shown = Array(s.largestFiles.prefix(Show.largestFiles))
        let rows = shown.map { f -> String in
            let dir = rel((f.path as NSString).deletingLastPathComponent, s.rootPath)
            return "<tr><td><div class=\"nm\">\(esc(f.name))</div>"
                 + "<div class=\"path\">\(esc(dir))</div></td>"
                 + "<td class=\"n\">\(f.category.displayName)</td>"
                 + "<td class=\"n\">\(Fmt.bytes(f.size))</td></tr>"
        }.joined()
        let note = s.largestFiles.count > shown.count
            ? "<div class=\"more\">The full ranking of the "
              + "\(Fmt.count(s.largestFiles.count)) largest files is in the CSV export.</div>"
            : ""
        return "<section><h2>Largest files</h2><table><thead><tr><th>File</th>"
             + "<th class=\"n\">Type</th><th class=\"n\">Size</th>"
             + "</tr></thead><tbody>\(rows)</tbody></table>\(note)</section>\n"
    }

    private static func duplicatesBlock(_ s: ScanSnapshot) -> String {
        let d = s.dupes
        guard d.candidatesTotal > 0 || d.isComplete || d.isRunning || d.isPaused || d.wasCancelled else { return "" }
        let shown = Array(d.groups.prefix(Show.duplicateGroups))
        let rows = shown.map { g -> String in
            // Every copy on its own line. Run together on one line they were
            // unreadable, and this table is the one someone acts on.
            let others = g.paths.dropFirst().map {
                "<div class=\"path\">\(esc(rel($0, s.rootPath)))</div>"
            }.joined()
            return "<tr><td><div class=\"nm\">\(esc(g.name))</div>"
                 + "<div class=\"path\">\(esc(rel(g.paths[0], s.rootPath)))</div>\(others)</td>"
                 + "<td class=\"n\">\(g.paths.count)×</td>"
                 + "<td class=\"n\">\(Fmt.bytes(g.recoverable))</td></tr>"
        }.joined()

        var lede = "\(Fmt.count(d.groups.count)) exact-content \(d.groups.count == 1 ? "group" : "groups"), "
                 + "\(Fmt.bytes(d.recoverableBytes)) reclaimable. Files 4 MB and larger, every group "
                 + "matched by complete SHA-256 content hash. Verify paths before deleting anything."
        if d.isPaused || d.remainingCandidateFiles > 0 {
            lede += " \(Fmt.files(d.remainingCandidateFiles)) still require verification and are excluded from these totals."
        }
        if d.unreadableFiles > 0 || d.changedFiles > 0 {
            lede += " \(Fmt.files(d.unreadableFiles)) were unreadable and \(Fmt.files(d.changedFiles)) changed during the scan; both were excluded."
        }
        if d.wasCancelled {
            lede += " Verification was cancelled; \(Fmt.files(d.cancelledFiles)) were unfinished and excluded."
        }
        let trimmed = d.groups.count > shown.count
            ? "<div class=\"more\">Showing the \(Fmt.count(shown.count)) largest of "
              + "\(Fmt.count(d.groups.count)) groups. Every group and every path is in the "
              + "CSV export.</div>"
            : ""
        let table = rows.isEmpty
            ? "<div class=\"att\"><div class=\"it\"><div><b>No verified duplicate groups in the completed scope.</b><span>Potential and incomplete candidates are never counted as reclaimable.</span></div></div></div>"
            : "<table><thead><tr><th>File</th><th class=\"n\">Copies</th><th class=\"n\">Reclaimable</th></tr></thead><tbody>\(rows)</tbody></table>\(trimmed)"
        return "<section><h2>Verified duplicates</h2><p class=\"lede\">\(lede)</p>"
             + table + "</section>\n"
    }

    private static func attentionBlock(_ s: ScanSnapshot) -> String {
        var items: [String] = []

        if s.dupes.recoverableBytes > 0 {
            items.append(item(
                "\(Fmt.count(s.dupes.duplicateFileCount)) verified extra copies, \(Fmt.bytes(s.dupes.recoverableBytes)) reclaimable",
                "Across \(Fmt.count(s.dupes.groups.count)) exact-content groups. Check paths before deleting."))
        }
        if !s.emptyFolders.isEmpty {
            items.append(item(
                "\(Fmt.count(s.emptyFolders.count)) empty folders",
                "Left behind by moves or aborted offloads. Every path is listed in the CSV export."))
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
                "\(Fmt.bytes(s.probe.unreadable.bytes)) counted as video/audio above has no metadata behind it. Usually RAW formats like R3D or BRAW that need the camera vendor's own software installed."))
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
        out += "<div class=\"q\">Finding the duplicates is the easy half. Knowing why they keep appearing is the part that changes next quarter.</div>"
        out += "<div class=\"p\">The Media Operations Blueprint is a written read of how footage actually moves through your team, from card to archive to the search three years later, and a plan for what to change first. It starts from the workflow you already have rather than from software you would have to buy. "
        out += "<a class=\"cta\" href=\"https://www.vaultlinesolutions.com/offers/media-operations-blueprint?entry_context=duplicate-finder-report\">See the Media Operations Blueprint →</a></div>"
        out += "<div class=\"r\"><span class=\"t\">"
        out += img("report-icon-white", cls: "", alt: "")
        out += "Custom software for serious footage libraries.</span></div>"
        out += "<div class=\"r\" style=\"border:0;padding-top:8px;margin-top:2px\">"
        out += "<span class=\"s\">Generated by Vaultline Labs Drive Inspector \(appVersion)</span>"
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

    /// Names what a ranked list left out, rather than stopping silently at the
    /// limit and reading as the complete answer. Empty when nothing was cut.
    private static func more(shown: Int, of total: Int, noun: String) -> String {
        guard total > shown else { return "" }
        let rest = total - shown
        return "<div class=\"more\">\(Fmt.count(rest)) further "
             + "\(rest == 1 ? noun : noun + "s") not shown. All of them are in the CSV export.</div>"
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
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
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
