import SwiftUI

/// The standing view — what's useful on a day nobody is ingesting anything.
///
/// Every drive this Mac has seen, when it was last plugged in, and what changed
/// since the time before. Nothing else answers that, and it costs a free user
/// nothing to leave running.
///
/// **Local only, and the UI says so.** This is not a team picture: one copy of
/// the app cannot see another's drives because there is no peer discovery or
/// shared Media Nexus state in this standalone utility.
struct DrivesView: View {
    @EnvironmentObject private var state: AppState

    private var monitor: VolumeMonitor { state.volumes }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VL.Space.xl) {
                if monitor.volumes.isEmpty {
                    emptyState
                } else {
                    copyHealth
                    mounted
                    seen
                    scopeNote
                }
            }
            .padding(VL.Space.l)
        }
    }

    // MARK: Sections

    private var mountedVolumes: [KnownVolume] { monitor.volumes.filter(\.isMounted) }
    private var pastVolumes: [KnownVolume] { monitor.volumes.filter { !$0.isMounted } }

    @ViewBuilder
    private var copyHealth: some View {
        if !state.copyFindings.isEmpty {
            VStack(alignment: .leading, spacing: VL.Space.s) {
                SectionLabel("Copy health")
                ForEach(state.copyFindings.prefix(12)) { finding in
                    CopyFindingRow(finding: finding)
                }
            }
        }
    }

    @ViewBuilder
    private var mounted: some View {
        VStack(alignment: .leading, spacing: VL.Space.s) {
            SectionLabel("Connected now") {
                Button("Refresh") { monitor.refreshMounted() }.buttonStyle(VLQuietButton())
            }
            if mountedVolumes.isEmpty {
                Panel { Text("No drives connected.").font(VL.body).foregroundStyle(VL.inkDim) }
            } else {
                ForEach(mountedVolumes) { v in DriveCard(volume: v) }
            }
        }
    }

    @ViewBuilder
    private var seen: some View {
        if !pastVolumes.isEmpty {
            VStack(alignment: .leading, spacing: VL.Space.s) {
                SectionLabel("Seen before")
                ForEach(pastVolumes) { v in DriveCard(volume: v) }
            }
        }
    }

    private var scopeNote: some View {
        Panel {
            HStack(alignment: .top, spacing: VL.Space.s) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 12)).foregroundStyle(VL.blue).padding(.top, 1)
                Text("This local registry shows only what has been plugged into this Mac. The standalone Ingest app never reports scans to Media Nexus or Relay.")
                    .font(VL.small).foregroundStyle(VL.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: VL.Space.m) {
            Image("VaultlineMark").resizable().scaledToFit().frame(height: 40).opacity(0.5)
            Text("No drives seen yet").font(VL.display(18))
            Text("Plug one in and it'll appear here. Scan it once and this app will tell you what changed the next time you connect it.")
                .font(VL.body).foregroundStyle(VL.inkDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

private struct CopyFindingRow: View {
    let finding: DriveCopyFinding

    var body: some View {
        Panel(tint: tint) {
            HStack(alignment: .top, spacing: VL.Space.s) {
                Image(systemName: icon)
                    .font(.system(size: 12)).foregroundStyle(iconTint).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(finding.name).font(VL.bodyMed)
                    Text(summary).font(VL.small).foregroundStyle(VL.inkDim)
                    Text(copyList).font(VL.monoSm).foregroundStyle(VL.inkFaint)
                        .lineLimit(2).truncationMode(.middle)
                }
                Spacer()
            }
        }
    }

    private var summary: String {
        switch finding.health {
        case .singleCopy:
            return "Only one indexed copy. Add or locate another before treating it as backed up."
        case .discrepancy:
            return "Copies disagree on file paths or sizes. Inspect them before the next backup."
        case .matchingCopies:
            return "\(finding.copies.count) indexed copies have matching paths and sizes."
        }
    }

    private var copyList: String {
        finding.copies.map {
            "\($0.volumeName) · \(F.count($0.fileCount)) files · \(F.bytes($0.totalBytes))"
        }.joined(separator: "   ")
    }

    private var icon: String {
        switch finding.health {
        case .singleCopy: return "externaldrive.badge.exclamationmark"
        case .discrepancy: return "arrow.triangle.branch"
        case .matchingCopies: return "checkmark.circle"
        }
    }

    private var iconTint: Color {
        finding.health == .matchingCopies ? VL.blue : VL.amber
    }

    private var tint: Color {
        finding.health == .matchingCopies ? VL.slate : VL.amber.opacity(0.07)
    }
}

// MARK: - Drive card

private struct DriveCard: View {
    @EnvironmentObject private var state: AppState
    let volume: KnownVolume
    @State private var expanded = false

    private var scanning: Bool { state.volumes.scanning.contains(volume.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: VL.Space.m) {
            header

            if volume.totalBytes > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    VLProgressBar(value: usedFraction, tint: usedFraction > 0.9 ? VL.amber : VL.blue, height: 5)
                    Text("\(F.bytes(volume.totalBytes - volume.freeBytes)) used of \(F.bytes(volume.totalBytes)) · \(F.bytes(volume.freeBytes)) free")
                        .font(VL.small).foregroundStyle(VL.inkFaint).monospacedDigit()
                }
            }

            if let change = volume.lastChange {
                changeRow(change)
            } else if volume.snapshot != nil {
                Text("Scanned \(relative(volume.snapshot!.takenAt)) · \(F.count(volume.snapshot!.fileCount)) files. Plug it in again and this will show what changed.")
                    .font(VL.small).foregroundStyle(VL.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if expanded, let change = volume.lastChange, !change.foldersChanged.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("FOLDERS THAT CHANGED").font(VL.micro).tracking(0.7).foregroundStyle(VL.inkFaint)
                    ForEach(change.foldersChanged.prefix(14), id: \.self) { f in
                        Text(f).font(VL.monoSm).foregroundStyle(VL.inkDim)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if change.foldersChanged.count > 14 {
                        Text("+ \(change.foldersChanged.count - 14) more")
                            .font(VL.monoSm).foregroundStyle(VL.inkFaint)
                    }
                }
                .padding(.top, 2)
            }

            actions
        }
        .padding(VL.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VL.slate, in: RoundedRectangle(cornerRadius: VL.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: VL.Radius.panel)
            .strokeBorder(VL.ruleSoft, lineWidth: 1))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: VL.Space.s) {
            Circle()
                .fill(volume.isMounted ? VL.blue : VL.steel.opacity(0.4))
                .frame(width: 6, height: 6)
                .padding(.trailing, 2)
            Text(volume.name).font(VL.display(16))
            if volume.isRemovable { VLChip(text: "REMOVABLE") }
            if let state = volume.passportSyncState {
                VLChip(text: passportStateLabel(state),
                       tint: state == "pending" || state == "awaiting_tag" ? VL.amber : VL.blue)
            }
            Spacer()
            Text(volume.isMounted
                 ? volume.lastPath
                 : "last seen \(relative(volume.lastSeen)) · \(volume.sightings)×")
                .font(VL.monoSm).foregroundStyle(VL.inkFaint)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func changeRow(_ change: VolumeChange) -> some View {
        HStack(alignment: .top, spacing: VL.Space.s) {
            Image(systemName: change.isEmpty ? "equal.circle" : "arrow.triangle.branch")
                .font(.system(size: 12))
                .foregroundStyle(change.isEmpty ? VL.steel : VL.amber)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.summary).font(VL.bodyMed)
                Text("Since \(relative(change.previousAt))"
                     + (change.foldersChanged.isEmpty ? "" : " · \(change.foldersChanged.count) folders affected"))
                    .font(VL.small).foregroundStyle(VL.inkFaint)
            }
            Spacer()
            if !change.foldersChanged.isEmpty {
                Button(expanded ? "Hide" : "Details") { expanded.toggle() }
                    .buttonStyle(VLQuietButton())
            }
        }
        .padding(VL.Space.s)
        .background(change.isEmpty ? Color.clear : VL.amber.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: VL.Radius.small))
    }

    private var actions: some View {
        HStack(spacing: VL.Space.s) {
            if volume.isMounted {
                Button(scanning ? "Scanning…" : (volume.snapshot == nil ? "Scan" : "Rescan")) {
                    state.volumes.scan(volume)
                }
                .buttonStyle(VLButton())
                .disabled(scanning)

                Button("Ingest From This") {
                    state.setSource(URL(fileURLWithPath: volume.lastPath))
                }
                .buttonStyle(VLButton())

                if volume.snapshot != nil {
                    Button(volume.passportDriveID == nil ? "Create Drive Passport" : "Refresh Passport") {
                        Task { await state.preparePassport(volume) }
                    }
                    .buttonStyle(VLPrimaryButton())
                    .disabled(state.config.passport?.isConnected != true || scanning)
                    .help(state.config.passport?.isConnected == true
                          ? "Upload this bounded snapshot and create a five-minute tag pairing code"
                          : "Connect Drive Passports in Settings first")

                    if volume.passportDriveID != nil && volume.passportSyncState == "awaiting_tag" {
                        Button("New Pairing Code") {
                            Task { await state.preparePassport(volume, createPairing: true) }
                        }
                        .buttonStyle(VLButton())
                        .disabled(state.config.passport?.isConnected != true || scanning)
                    }
                }
            } else {
                Button("Forget") { state.volumes.forget(volume.id) }
                    .buttonStyle(VLQuietButton())
            }
            Spacer()
        }
    }

    private var usedFraction: Double {
        volume.totalBytes > 0
            ? Double(volume.totalBytes - volume.freeBytes) / Double(volume.totalBytes) : 0
    }

    private func passportStateLabel(_ state: String) -> String {
        switch state {
        case "pending": return "SYNC PENDING"
        case "awaiting_tag": return "TAG NOT ATTACHED"
        case "paired": return "TAG PAIRED"
        default: return "PASSPORT SYNCED"
        }
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }
}
