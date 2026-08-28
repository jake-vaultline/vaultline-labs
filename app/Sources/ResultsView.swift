import SwiftUI
import AppKit

/// Built from the shared design system in `Theme.swift`, same as Vaultline
/// Ingest — the two apps ship together and should read as one company.
struct ResultsView: View {
    let snapshot: ScanSnapshot
    let isScanning: Bool

    var body: some View {
        ScrollView { sections }
    }

    /// Section order matches `ReportBuilder.html` exactly. Someone reads the
    /// window, exports the report, and reads the same thing in the same order.
    ///
    /// Split out of `body` so it can be rendered without a scroll view, which
    /// is the only way to get a whole-window image out of `ImageRenderer`.
    var sections: some View {
        VStack(alignment: .leading, spacing: VL.Space.xl) {
            header
            statRow
            capacity
            duplicates
            categoryBreakdown
            probeBreakdown
            frameRates
            extensionBreakdown
            cameras
            mediaByYear
            twoColumn
            attention
        }
        .padding(VL.Space.l)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: VL.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: VL.Space.s) {
                Text(snapshot.volumeName.isEmpty ? "Scan" : snapshot.volumeName)
                    .font(VL.display(26))
                if snapshot.volumeTotalBytes > 0 {
                    Text(Fmt.bytes(snapshot.volumeTotalBytes))
                        .font(.system(size: 20)).foregroundStyle(VL.steel)
                }
                Spacer()
                if !snapshot.rootPath.isEmpty {
                    Button {
                        Finder.reveal(snapshot.rootPath)
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .buttonStyle(VLButton())
                    .font(VL.small)
                }
            }
            Text(subtitle)
                .font(VL.body).foregroundStyle(VL.inkDim).monospacedDigit()
        }
    }

    private var subtitle: String {
        var parts = [
            "\(Fmt.bytes(snapshot.bytesScanned)) scanned",
            "\(Fmt.count(snapshot.filesScanned)) files",
            "\(Fmt.count(snapshot.mediaFileCount)) media files"
        ]
        if !snapshot.projectFiles.isEmpty {
            parts.append("\(Fmt.count(snapshot.projectFiles.count)) project files")
        }
        if snapshot.isComplete { parts.append(String(format: "in %.1fs", snapshot.elapsed)) }
        else if snapshot.wasCancelled { parts.append("stopped early") }
        if snapshot.probe.isRunning {
            parts.append("reading media \(Int(snapshot.probe.progress * 100))%")
        }
        if snapshot.dupes.isPaused {
            parts.append("duplicate verification paused")
        } else if snapshot.dupes.wasCancelled {
            parts.append("duplicate verification cancelled")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Stats

    private var statRow: some View {
        HStack(alignment: .top, spacing: VL.Space.l) {
            VLStat(label: "Footage",
                   value: snapshot.probe.totalDuration > 0
                       ? Fmt.duration(snapshot.probe.totalDuration)
                       : (snapshot.probe.isRunning ? "…" : "—"),
                   note: "across \(Fmt.count(snapshot.byCategory[.video]?.count ?? 0)) clips")
            VLStat(label: "Date range",
                   value: Fmt.dateRange(snapshot.earliest, snapshot.latest),
                   note: snapshot.probe.usedEmbeddedDates ? "from capture dates" : "from file dates")
            VLStat(label: "Folders",
                   value: Fmt.count(snapshot.foldersScanned),
                   note: snapshot.isComplete ? "\(Fmt.count(snapshot.emptyFolders.count)) empty" : "—")
            VLStat(label: "Reclaimable",
                   value: snapshot.dupes.recoverableBytes > 0
                       ? Fmt.bytes(snapshot.dupes.recoverableBytes)
                       : (snapshot.dupes.isRunning ? "…" : "—"),
                   note: snapshot.dupes.duplicateFileCount > 0
                       ? "\(Fmt.count(snapshot.dupes.duplicateFileCount)) verified extra copies"
                       : "files 4 MB and larger",
                   tint: snapshot.dupes.recoverableBytes > 0 ? VL.amber : VL.ink)
        }
    }

    @ViewBuilder
    private var capacity: some View {
        if snapshot.volumeTotalBytes > 0 {
            let used = snapshot.volumeTotalBytes - snapshot.volumeFreeBytes
            VStack(alignment: .leading, spacing: VL.Space.xs) {
                VLProgressBar(value: Double(used) / Double(snapshot.volumeTotalBytes))
                Text("\(Fmt.bytes(used)) used · \(Fmt.bytes(snapshot.volumeFreeBytes)) free")
                    .font(VL.small).foregroundStyle(VL.inkFaint).monospacedDigit()
            }
        }
    }

    // MARK: Breakdowns

    private var categoryBreakdown: some View {
        VStack(alignment: .leading, spacing: VL.Space.s) {
            SectionLabel("What's on it")
            VStack(spacing: VL.Space.s) {
                ForEach(MediaCategory.allCases) { cat in
                    if let s = snapshot.byCategory[cat], s.count > 0 {
                        Bar(label: cat.displayName,
                            detail: "\(Fmt.files(s.count)) · \(Fmt.bytes(s.bytes))",
                            fraction: fraction(s.bytes),
                            trailing: Fmt.percent(s.bytes, of: snapshot.bytesScanned))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var probeBreakdown: some View {
        let p = snapshot.probe
        if !p.bytesByCodec.isEmpty || !p.clipsByResolution.isEmpty {
            HStack(alignment: .top, spacing: VL.Space.xl) {
                if !p.bytesByCodec.isEmpty {
                    VStack(alignment: .leading, spacing: VL.Space.s) {
                        SectionLabel("Codecs")
                        VStack(spacing: VL.Space.s) {
                            ForEach(p.topCodecs(Show.codecs)) { row in
                                Bar(label: row.name, detail: Fmt.bytes(row.bytes),
                                    fraction: p.codecBytesTotal > 0
                                        ? Double(row.bytes) / Double(p.codecBytesTotal) : 0,
                                    trailing: Fmt.percent(row.bytes, of: p.codecBytesTotal))
                            }
                        }
                        Remainder(shown: min(Show.codecs, p.bytesByCodec.count),
                                  total: p.bytesByCodec.count, noun: "codec")
                    }
                }
                if !p.clipsByResolution.isEmpty {
                    VStack(alignment: .leading, spacing: VL.Space.s) {
                        SectionLabel("Resolutions")
                        VStack(spacing: VL.Space.s) {
                            ForEach(p.topResolutions(Show.resolutions)) { row in
                                Bar(label: row.name, detail: "\(Fmt.count(row.count)) clips",
                                    fraction: p.resolutionClipsTotal > 0
                                        ? Double(row.count) / Double(p.resolutionClipsTotal) : 0,
                                    trailing: Fmt.percent(row.count, of: p.resolutionClipsTotal))
                            }
                        }
                        Remainder(shown: min(Show.resolutions, p.clipsByResolution.count),
                                  total: p.clipsByResolution.count, noun: "resolution")
                    }
                }
            }
        }
    }

    /// The report has had this section since 0.1. The window never did, so
    /// anyone reading the window saw strictly less than the file they emailed.
    @ViewBuilder
    private var frameRates: some View {
        let rates = snapshot.probe.topFrameRates(Show.frameRates)
        if !rates.isEmpty {
            VStack(alignment: .leading, spacing: VL.Space.s) {
                SectionLabel("Frame rates")
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(rates) { r in
                        Row(name: r.name,
                            detail: Fmt.percent(r.count, of: snapshot.probe.frameRateClipsTotal),
                            value: "\(Fmt.count(r.count)) \(r.count == 1 ? "clip" : "clips")")
                    }
                }
                Remainder(shown: rates.count, total: snapshot.probe.clipsByFrameRate.count,
                          noun: "rate")
            }
        }
    }

    @ViewBuilder
    private var cameras: some View {
        let cams = snapshot.probe.topCameras(Show.cameras)
        if !cams.isEmpty {
            VStack(alignment: .leading, spacing: VL.Space.s) {
                SectionLabel("Cameras detected")
                // A fixed row of five silently dropped every camera past the
                // fifth; the report listed ten of the same set.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: VL.Space.s)],
                          alignment: .leading, spacing: VL.Space.s) {
                    ForEach(cams) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).font(VL.bodyMed).lineLimit(1).truncationMode(.middle)
                            Text("\(Fmt.files(c.count)) · \(Fmt.bytes(c.bytes))")
                                .font(.system(size: 10.5)).foregroundStyle(VL.inkFaint).monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .background(VL.slate, in: RoundedRectangle(cornerRadius: VL.Radius.small))
                        .overlay(RoundedRectangle(cornerRadius: VL.Radius.small)
                            .strokeBorder(VL.ruleSoft, lineWidth: 1))
                    }
                }
                Remainder(shown: cams.count, total: snapshot.probe.byCamera.count, noun: "camera")
            }
        }
    }

    @ViewBuilder
    private var extensionBreakdown: some View {
        let rows = snapshot.topExtensions(Show.extensions)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: VL.Space.s) {
                SectionLabel("Top formats")
                VStack(spacing: VL.Space.s) {
                    ForEach(rows) { row in
                        Bar(label: ".\(row.name)",
                            detail: "\(Fmt.files(row.count)) · \(Fmt.bytes(row.bytes))",
                            fraction: fraction(row.bytes),
                            trailing: Fmt.percent(row.bytes, of: snapshot.bytesScanned))
                    }
                }
                Remainder(shown: rows.count, total: snapshot.byExtension.count,
                          noun: "extension")
            }
        }
    }

    /// Also report-only until now. The caveat line is the point of the section:
    /// on a cloned drive with no embedded dates every clip lands in the copy
    /// year, and a confidently wrong timeline is worse than no timeline.
    @ViewBuilder
    private var mediaByYear: some View {
        let years = snapshot.probe.bytesByYear.sorted { $0.key < $1.key }.suffix(Show.years)
        if years.count > 1 {
            let peak = years.map(\.value).max() ?? 1
            VStack(alignment: .leading, spacing: VL.Space.s) {
                SectionLabel("Media by year")
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(years), id: \.key) { y in
                        VStack(spacing: 4) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(VL.blue)
                                .frame(height: max(3, CGFloat(Double(y.value) / Double(peak)) * 76))
                            Text(Fmt.bytes(y.value))
                                .font(.system(size: 9)).foregroundStyle(VL.inkDim)
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Text(String(y.key))
                                .font(.system(size: 10)).foregroundStyle(VL.inkFaint).monospacedDigit()
                        }
                    }
                }
                .frame(height: 118)
                Text(snapshot.probe.usedEmbeddedDates
                     ? "From embedded capture dates."
                     : "From file modification dates. Little of this drive's media carried an embedded capture date, so copied files may appear in the wrong year.")
                    .font(VL.small).foregroundStyle(VL.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
                Remainder(shown: years.count, total: snapshot.probe.bytesByYear.count,
                          noun: "year")
            }
        }
    }

    private var twoColumn: some View {
        HStack(alignment: .top, spacing: VL.Space.xl) {
            VStack(alignment: .leading, spacing: VL.Space.s) {
                SectionLabel("Largest folders")
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(snapshot.largestFolders.prefix(Show.largestFolders)) { f in
                        Row(name: f.name, detail: Fmt.files(f.fileCount),
                            value: Fmt.bytes(f.bytes), path: f.path)
                    }
                }
            }
            VStack(alignment: .leading, spacing: VL.Space.s) {
                SectionLabel("Largest files")
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(snapshot.largestFiles.prefix(Show.largestFiles)) { f in
                        Row(name: f.name, detail: f.category.displayName, value: Fmt.bytes(f.size),
                            path: f.path)
                    }
                }
                if snapshot.largestFiles.count > Show.largestFiles {
                    Text("The full ranking of the \(Fmt.count(snapshot.largestFiles.count)) largest files is in the CSV export.")
                        .font(VL.small).foregroundStyle(VL.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Duplicates

    @ViewBuilder
    private var duplicates: some View {
        let d = snapshot.dupes
        if d.candidatesTotal > 0 || d.isComplete || d.isRunning || d.isPaused || d.wasCancelled {
            VStack(alignment: .leading, spacing: VL.Space.s) {
                SectionLabel("Verified duplicates") {
                    Text("\(Fmt.count(d.verifiedGroupCount)) groups · \(Fmt.bytes(d.recoverableBytes)) reclaimable")
                        .font(.system(size: 10.5)).foregroundStyle(VL.inkFaint).monospacedDigit()
                }
                if d.groups.isEmpty {
                    VLNotice(title: duplicateEmptyTitle(d)) {
                        Text(duplicateStatus(d))
                            .font(VL.small).foregroundStyle(VL.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    VStack(spacing: 1) {
                        ForEach(d.groups.prefix(Show.duplicateGroups)) { g in
                            DuplicateGroupRow(group: g, rootPath: snapshot.rootPath)
                        }
                    }
                }
                // This used to say "see the exported report for the full list"
                // while the report showed ten groups to the window's twenty-five.
                // Both surfaces now show the same set, and the CSV is the one
                // place that genuinely holds every group.
                if d.groups.count > Show.duplicateGroups {
                    let rest = d.groups.count - Show.duplicateGroups
                    Text("\(Fmt.count(rest)) further \(rest == 1 ? "group" : "groups") not shown. Every group and every path is in the CSV export.")
                        .font(VL.small).foregroundStyle(VL.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if d.isPaused {
                    Text("\(Fmt.files(d.remainingCandidateFiles)) still need verification. Continue after the media analysis finishes; verified totals above remain exact.")
                        .font(VL.small).foregroundStyle(VL.inkFaint)
                }
                if d.unreadableFiles > 0 || d.changedFiles > 0 {
                    Text("\(Fmt.files(d.unreadableFiles)) unreadable · \(Fmt.files(d.changedFiles)) changed during the scan and were excluded.")
                        .font(VL.small).foregroundStyle(VL.inkFaint)
                }
                if d.wasCancelled {
                    Text("Verification was cancelled. \(Fmt.files(d.cancelledFiles)) were unfinished and excluded; verified totals above remain exact.")
                        .font(VL.small).foregroundStyle(VL.inkFaint)
                }
                Text("Files 4 MB and larger · matched by complete SHA-256 content hash · verify paths before deleting anything.")
                    .font(VL.small).foregroundStyle(VL.inkDim)
            }
        }
    }

    private func duplicateEmptyTitle(_ d: DuplicateSummary) -> String {
        if d.isRunning { return "Verifying file contents…" }
        if d.isPaused { return "No verified groups yet" }
        if d.wasCancelled { return "Duplicate verification cancelled" }
        return "No verified duplicates found"
    }

    private func duplicateStatus(_ d: DuplicateSummary) -> String {
        if d.isRunning {
            return "\(Fmt.files(d.candidatesChecked)) of \(Fmt.files(d.candidatesTotal)) size-matched candidates checked; \(Fmt.bytes(d.bytesRead)) read."
        }
        if d.isPaused {
            return "\(Fmt.files(d.remainingCandidateFiles)) remain outside this verification pass. Continue to expand the exact result."
        }
        if d.wasCancelled {
            return "\(Fmt.files(d.cancelledFiles)) were unfinished and excluded. Run the scan again for a complete duplicate result."
        }
        return "The completed scan found no exact content matches among files 4 MB and larger."
    }

    // The report's "Worth a look" block, in the window. Duplicates have their
    // own full section above so they are not repeated here; everything else the
    // report raises is raised here too, in the same order and the same words.
    //
    // NOTE: "files with no verified second copy" is deliberately absent, here
    // and in the report. A single-drive scan cannot know what exists elsewhere.
    // See ReportBuilder.attentionBlock and report/report-spec.md §5.
    @ViewBuilder
    private var attention: some View {
        let p = snapshot.probe
        let proxy = p.estimatedProxyBytes
        let other = snapshot.byCategory[.other]
        let unrecognised = (other?.bytes ?? 0) > snapshot.bytesScanned / 20 ? other?.bytes ?? 0 : 0

        if !snapshot.emptyFolders.isEmpty || proxy > 0 || unrecognised > 0 || p.unreadable.count > 0 {
            VStack(alignment: .leading, spacing: VL.Space.s) {
                SectionLabel("Worth a look")
                if !snapshot.emptyFolders.isEmpty {
                    VLNotice(title: "\(Fmt.count(snapshot.emptyFolders.count)) empty folders") {
                        NoticeBody("Left behind by moves or aborted offloads. Every path is listed in the CSV export.")
                    }
                }
                if proxy > 0 {
                    VLNotice(title: "Proxies for this drive would need about \(Fmt.bytes(proxy))") {
                        NoticeBody("Rough estimate for everything 4K and above. An order of magnitude, not a quote.")
                    }
                }
                if unrecognised > 0 {
                    VLNotice(title: "\(Fmt.bytes(unrecognised)) in unrecognised file types") {
                        NoticeBody("Caches, renders, archives or formats this tool doesn't classify yet.")
                    }
                }
                if p.unreadable.count > 0 {
                    VLNotice(title: "\(Fmt.files(p.unreadable.count)) couldn't be read for codec, resolution or duration") {
                        NoticeBody("\(Fmt.bytes(p.unreadable.bytes)) of what's counted as video/audio above has no metadata behind it. Usually RAW formats like R3D or BRAW that need the camera vendor's own software installed to decode.")
                    }
                }
            }
        }
    }

    private func fraction(_ v: Int64) -> Double {
        snapshot.bytesScanned > 0 ? Double(v) / Double(snapshot.bytesScanned) : 0
    }
}

// MARK: - Pieces

/// The body line of a "Worth a look" notice. Same treatment every time, so the
/// four of them read as one list rather than four ad hoc panels.
private struct NoticeBody: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(VL.small).foregroundStyle(VL.inkDim)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Says what a ranked list left out. The report prints the same sentence, from
/// `ReportBuilder.more(shown:of:noun:)`.
private struct Remainder: View {
    let shown: Int
    let total: Int
    let noun: String

    var body: some View {
        if total > shown {
            let rest = total - shown
            Text("\(Fmt.count(rest)) further \(rest == 1 ? noun : noun + "s") not shown. All of them are in the CSV export.")
                .font(VL.small).foregroundStyle(VL.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Bar: View {
    let label: String
    let detail: String
    let fraction: Double
    let trailing: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(VL.bodyMed)
                Spacer()
                Text(trailing).font(VL.body).monospacedDigit().foregroundStyle(VL.inkDim)
            }
            VLProgressBar(value: fraction, height: 5)
            Text(detail).font(.system(size: 10.5)).foregroundStyle(VL.inkFaint).monospacedDigit()
        }
    }
}

private struct Row: View {
    let name: String
    let detail: String
    let value: String
    var path: String? = nil

    @State private var hovering = false

    var body: some View {
        HStack(spacing: VL.Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.system(size: 10)).foregroundStyle(VL.inkFaint)
            }
            Spacer()
            if let path, hovering {
                RevealButton(path: path)
            }
            Text(value).font(.system(size: 12)).monospacedDigit().foregroundStyle(VL.inkDim)
        }
        .onHover { hovering = $0 }
    }
}

/// Small "reveal in Finder" affordance, used anywhere a row names a real path.
private struct RevealButton: View {
    let path: String
    var body: some View {
        Button { Finder.reveal(path) } label: {
            Image(systemName: "arrow.forward.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(VL.inkFaint)
        .help("Reveal in Finder")
    }
}

private struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    let rootPath: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: VL.Space.s) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(VL.inkFaint)
                        .frame(width: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Text("\(group.paths.count)× · \(Fmt.bytes(group.size)) each")
                            .font(.system(size: 10)).foregroundStyle(VL.inkFaint)
                    }
                    Spacer()
                    Text(Fmt.bytes(group.recoverable))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(VL.amber)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(group.paths, id: \.self) { p in
                        HStack(spacing: VL.Space.s) {
                            Text(rel(p)).font(.system(size: 10.5)).foregroundStyle(VL.inkDim)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            RevealButton(path: p)
                        }
                    }
                }
                .padding(.leading, 18)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider().overlay(VL.ruleSoft) }
    }

    private func rel(_ path: String) -> String {
        path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
    }
}

/// Reveals a path in Finder. The app is sandboxed and read-only, so this is the
/// only "open" affordance it needs — Finder does everything past this point.
enum Finder {
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
