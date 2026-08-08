import SwiftUI
import AppKit

/// Built from the shared design system in `Theme.swift`, same as Vaultline
/// Ingest — the two apps ship together and should read as one company.
struct ResultsView: View {
    let snapshot: ScanSnapshot
    let isScanning: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VL.Space.xl) {
                header
                statRow
                capacity
                categoryBreakdown
                probeBreakdown
                cameras
                extensionBreakdown
                twoColumn
                duplicates
                attention
            }
            .padding(VL.Space.l)
        }
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
            VLStat(label: "Recoverable",
                   value: snapshot.dupes.recoverableBytes > 0
                       ? Fmt.bytes(snapshot.dupes.recoverableBytes)
                       : (snapshot.dupes.isRunning ? "…" : "—"),
                   note: snapshot.dupes.duplicateFileCount > 0
                       ? "\(Fmt.count(snapshot.dupes.duplicateFileCount)) likely duplicates" : "—",
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
                            ForEach(p.topCodecs(6)) { row in
                                Bar(label: row.name, detail: Fmt.bytes(row.bytes),
                                    fraction: p.codecBytesTotal > 0
                                        ? Double(row.bytes) / Double(p.codecBytesTotal) : 0,
                                    trailing: Fmt.percent(row.bytes, of: p.codecBytesTotal))
                            }
                        }
                    }
                }
                if !p.clipsByResolution.isEmpty {
                    VStack(alignment: .leading, spacing: VL.Space.s) {
                        SectionLabel("Resolutions")
                        VStack(spacing: VL.Space.s) {
                            ForEach(p.topResolutions(6)) { row in
                                Bar(label: row.name, detail: "\(Fmt.count(row.count)) clips",
                                    fraction: p.resolutionClipsTotal > 0
                                        ? Double(row.count) / Double(p.resolutionClipsTotal) : 0,
                                    trailing: Fmt.percent(row.count, of: p.resolutionClipsTotal))
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var cameras: some View {
        let cams = snapshot.probe.topCameras(8)
        if !cams.isEmpty {
            VStack(alignment: .leading, spacing: VL.Space.s) {
                SectionLabel("Cameras detected")
                HStack(alignment: .top, spacing: VL.Space.s) {
                    ForEach(Array(cams.prefix(5))) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).font(VL.bodyMed).lineLimit(1)
                            Text(Fmt.files(c.count))
                                .font(.system(size: 10.5)).foregroundStyle(VL.inkFaint).monospacedDigit()
                        }
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .background(VL.slate, in: RoundedRectangle(cornerRadius: VL.Radius.small))
                        .overlay(RoundedRectangle(cornerRadius: VL.Radius.small)
                            .strokeBorder(VL.ruleSoft, lineWidth: 1))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var extensionBreakdown: some View {
        VStack(alignment: .leading, spacing: VL.Space.s) {
            SectionLabel("Top formats")
            VStack(spacing: VL.Space.s) {
                ForEach(snapshot.topExtensions(8)) { row in
                    Bar(label: ".\(row.name)",
                        detail: "\(Fmt.files(row.count)) · \(Fmt.bytes(row.bytes))",
                        fraction: fraction(row.bytes),
                        trailing: Fmt.percent(row.bytes, of: snapshot.bytesScanned))
                }
            }
        }
    }

    private var twoColumn: some View {
        HStack(alignment: .top, spacing: VL.Space.xl) {
            VStack(alignment: .leading, spacing: VL.Space.s) {
                SectionLabel("Largest folders")
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(snapshot.largestFolders.prefix(10)) { f in
                        Row(name: f.name, detail: Fmt.files(f.fileCount),
                            value: Fmt.bytes(f.bytes), path: f.path)
                    }
                }
            }
            VStack(alignment: .leading, spacing: VL.Space.s) {
                SectionLabel("Largest files")
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(snapshot.largestFiles.prefix(10)) { f in
                        Row(name: f.name, detail: f.category.displayName, value: Fmt.bytes(f.size),
                            path: f.path)
                    }
                }
            }
        }
    }

    // MARK: Duplicates

    @ViewBuilder
    private var duplicates: some View {
        let d = snapshot.dupes
        if !d.groups.isEmpty {
            VStack(alignment: .leading, spacing: VL.Space.s) {
                SectionLabel("Potential duplicates") {
                    Text("\(Fmt.files(d.duplicateFileCount)) · \(Fmt.bytes(d.recoverableBytes)) recoverable")
                        .font(.system(size: 10.5)).foregroundStyle(VL.inkFaint).monospacedDigit()
                }
                VStack(spacing: 1) {
                    ForEach(d.groups.prefix(25)) { g in
                        DuplicateGroupRow(group: g, rootPath: snapshot.rootPath)
                    }
                }
                if d.groups.count > 25 {
                    let rest = d.groups.count - 25
                    Text("+ \(Fmt.count(rest)) more \(rest == 1 ? "group" : "groups") — see the exported report for the full list")
                        .font(VL.small).foregroundStyle(VL.inkFaint)
                }
                if d.hitReadBudget {
                    Text("This check stopped early against its read budget, so there may be more.")
                        .font(VL.small).foregroundStyle(VL.inkFaint)
                }
                Text("Matched by size and content hash. Verify before deleting anything.")
                    .font(VL.small).foregroundStyle(VL.inkDim)
            }
        }
    }

    // Duplicates has its own full section above (`duplicates`), so this is
    // only the media that AVFoundation opened and got nothing usable from —
    // confirmed real against actual RED .r3d footage, not hypothetical.
    @ViewBuilder
    private var attention: some View {
        let u = snapshot.probe.unreadable
        if u.count > 0 {
            VLNotice(title: "\(Fmt.files(u.count)) couldn't be read for codec, resolution or duration") {
                Text("\(Fmt.bytes(u.bytes)) of what's counted as video/audio above has no metadata behind it — often RAW formats like R3D or BRAW that need the camera vendor's own software installed to decode.")
                    .font(VL.small).foregroundStyle(VL.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fraction(_ v: Int64) -> Double {
        snapshot.bytesScanned > 0 ? Double(v) / Double(snapshot.bytesScanned) : 0
    }
}

// MARK: - Pieces

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
