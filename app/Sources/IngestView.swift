import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct IngestView: View {
    @EnvironmentObject private var state: AppState
    @State private var isTargeted = false
    @State private var showWizard = false
    @State private var showJob = false

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(showWizard: $showWizard)
            Divider().overlay(VL.rule)

            Group {
                if state.section == .drives {
                    DrivesView()
                } else if state.sourceURL == nil {
                    DropZone(isTargeted: isTargeted,
                             choose: { state.chooseSource() },
                             newJob: { showJob = true })
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: VL.Space.xl) {
                            SourceBlock()
                            if !state.renamePreview.isEmpty { RenameBlock() }
                            if state.config.form.enabled && !state.config.form.fields.isEmpty {
                                ShootForm()
                            }
                            DestinationBlock(newJob: { showJob = true })
                            if state.progress.phase != .planning { RunBlock() }
                            if state.progress.hasProblems { ProblemBlock() }
                            if !state.results.isEmpty && !state.isRunning { ResultsBlock() }
                        }
                        .padding(VL.Space.l)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if state.section == .ingest {
                Divider().overlay(VL.rule)
                ActionBar()
            }
        }
        .vlWindowBackground()
        .foregroundStyle(VL.ink)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { handleDrop($0) }
        .sheet(isPresented: $showWizard) { SetupWizard().environmentObject(state) }
        .sheet(isPresented: $showJob) { JobSheet().environmentObject(state) }
        .sheet(item: $state.passportPrompt) { prompt in
            PassportPairingSheet(prompt: prompt).environmentObject(state)
        }
        .sheet(item: $state.driveIdentityPrompt) { prompt in
            DriveIdentityReviewSheet(prompt: prompt).environmentObject(state)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first, !state.isRunning else { return false }
        p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
            else if let u = item as? URL { url = u }
            guard let url else { return }
            DispatchQueue.main.async { state.setSource(url) }
        }
        return true
    }
}

// MARK: - Title bar

/// Custom chrome: the window has no system title bar, so this is it. Keeps the
/// dark surface unbroken from edge to edge.
private struct TitleBar: View {
    @EnvironmentObject private var state: AppState
    @Binding var showWizard: Bool

    var body: some View {
        HStack(spacing: VL.Space.m) {
            // Space for the traffic lights.
            Spacer().frame(width: 68)

            // The real wordmark, not a text approximation. Ships white because
            // the app is dark only — no tinting, so the drawn weight is exact.
            Image("VaultlineWordmark")
                .resizable().scaledToFit()
                .frame(height: 17)

            // Two halves of one job: knowing what drives you have, and moving
            // media onto them safely.
            HStack(spacing: 2) {
                ForEach(AppState.Section.allCases) { s in
                    Button(s.title) { state.section = s }
                        .buttonStyle(SegmentButton(active: state.section == s))
                }
            }
            .padding(2)
            .background(VL.slate, in: RoundedRectangle(cornerRadius: VL.Radius.small + 2))

            if state.config.passport?.isConnected == true {
                VLChip(text: state.passports.pendingUploads > 0
                       ? "PASSPORTS · \(state.passports.pendingUploads) PENDING"
                       : "PASSPORTS", tint: state.passports.pendingUploads > 0 ? VL.amber : VL.blue)
                    .help("Drive Passport metadata sync is connected")
            }

            Spacer()

            Button("Naming Setup") { showWizard = true }
                .buttonStyle(VLButton())
                .help("Learn your naming convention from work you've already done")
        }
        .padding(.horizontal, VL.Space.m)
        .frame(height: 46)
        .background(VL.charcoal)
    }
}

private struct PassportPairingSheet: View {
    @EnvironmentObject private var state: AppState
    let prompt: AppState.PassportPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: VL.Space.m) {
            Text("Attach a Drive Tag").font(VL.display(18))
            Text("\(prompt.volumeName)'s latest snapshot is ready. Tap or scan an unpaired Drive Tag, sign in, and enter this code:")
                .font(VL.body).foregroundStyle(VL.inkDim)
                .fixedSize(horizontal: false, vertical: true)

            Panel {
                VStack(alignment: .leading, spacing: 6) {
                    Text(prompt.code)
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .tracking(5).foregroundStyle(VL.blue)
                    Text("One use · expires in five minutes")
                        .font(VL.small).foregroundStyle(VL.inkFaint)
                }
            }

            Text("The physical tag keeps its static URL forever. Reassignment happens safely on the server; the tag itself contains no drive name, serial, workspace ID, or secret.")
                .font(VL.small).foregroundStyle(VL.inkDim)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Open Workspace") {
                    if let url = URL(string: prompt.serviceURL) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(VLButton())
                Spacer()
                Button("Done") { state.passportPrompt = nil }
                    .buttonStyle(VLPrimaryButton())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(VL.Space.l)
        .frame(width: 490)
        .vlWindowBackground()
        .foregroundStyle(VL.ink)
    }
}

private struct DriveIdentityReviewSheet: View {
    @EnvironmentObject private var state: AppState
    let prompt: AppState.DriveIdentityPrompt
    @State private var resolving = false

    private var review: DrivePassportClient.DriveIdentityReview { prompt.review }

    var body: some View {
        VStack(alignment: .leading, spacing: VL.Space.m) {
            Text(review.resolvable ? "Is this a drive you already enrolled?" : "Drive identity needs review")
                .font(VL.display(18))
            Text(introduction)
                .font(VL.body).foregroundStyle(VL.inkDim)
                .fixedSize(horizontal: false, vertical: true)

            if review.candidates.isEmpty {
                Panel {
                    Text("No safe candidate details were returned. Nothing was merged or created.")
                        .font(VL.small).foregroundStyle(VL.inkDim)
                }
            } else {
                VStack(alignment: .leading, spacing: VL.Space.s) {
                    ForEach(review.candidates) { candidate in
                        Panel {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.displayName).font(VL.bodyMed)
                                Text("Matched on \(signalLabels(candidate.matchedIdentifiers))")
                                    .font(VL.small).foregroundStyle(VL.inkFaint)
                                if review.resolvable {
                                    Button("Same physical drive — use this passport") {
                                        resolve(.bindExisting(candidate.driveID))
                                    }
                                    .buttonStyle(VLButton())
                                    .disabled(resolving)
                                    .padding(.top, 4)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            if review.resolvable {
                Text("Choose a prior passport only if this is the same physical drive after a rename, reformat, or enclosure change. Choosing new keeps both records separate.")
                    .font(VL.small).foregroundStyle(VL.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if !review.resolvable,
                   let serviceURL = state.config.passport?.url,
                   let url = URL(string: serviceURL) {
                    Button("Open Workspace") { NSWorkspace.shared.open(url) }
                        .buttonStyle(VLButton())
                }
                Spacer()
                Button("Cancel") { state.driveIdentityPrompt = nil }
                    .buttonStyle(VLQuietButton())
                    .disabled(resolving)
                if review.resolvable {
                    Button("Create a new Drive Passport") { resolve(.createNew) }
                        .buttonStyle(VLPrimaryButton())
                        .disabled(resolving)
                }
            }
        }
        .padding(VL.Space.l)
        .frame(width: 540)
        .vlWindowBackground()
        .foregroundStyle(VL.ink)
    }

    private var introduction: String {
        if review.resolvable {
            return "\(review.volumeName) shares weaker identity signals with the drive records below. Vaultline has paused before uploading or attaching a tag."
        }
        return "\(review.volumeName) matches more than one enrolled drive on strong identifiers. Vaultline blocked the merge. Review the drive records in the workspace before trying again."
    }

    private func resolve(_ resolution: DrivePassportClient.IdentityResolution) {
        resolving = true
        Task { await state.resolveDriveIdentity(prompt, resolution: resolution) }
    }

    private func signalLabels(_ signals: [String]) -> String {
        signals.map {
            switch $0 {
            case "volume_uuid": return "filesystem identity"
            case "hardware_serial": return "hardware serial"
            case "capacity": return "capacity"
            case "vendor_model": return "vendor/model"
            case "topology": return "disk topology"
            default: return $0.replacingOccurrences(of: "_", with: " ")
            }
        }.joined(separator: ", ")
    }
}

private struct SegmentButton: ButtonStyle {
    let active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: active ? .semibold : .regular))
            .foregroundStyle(active ? VL.charcoal : VL.inkDim)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(active ? VL.softWhite : .clear,
                        in: RoundedRectangle(cornerRadius: VL.Radius.small))
            .contentShape(Rectangle())
    }
}

// MARK: - Drop zone

private struct DropZone: View {
    let isTargeted: Bool
    let choose: () -> Void
    let newJob: () -> Void

    var body: some View {
        VStack(spacing: VL.Space.m) {
            Spacer()

            // The VL mark itself — the monogram already reads as a path running
            // into a frame, which is exactly what an ingest is. No invented
            // iconography needed.
            Image("VaultlineMark")
                .resizable().scaledToFit()
                .frame(height: 46)
                .opacity(isTargeted ? 1 : 0.8)

            VStack(spacing: VL.Space.xs) {
                Text("Drop a card or folder here").font(VL.display(19))
                Text("Copied, verified, and never moved or deleted.")
                    .font(VL.body).foregroundStyle(VL.inkDim)
            }

            HStack(spacing: VL.Space.s) {
                Button("Choose Source…", action: choose).buttonStyle(VLPrimaryButton())
                Button("Create Configured Job…", action: newJob).buttonStyle(VLButton())
            }
            .padding(.top, VL.Space.xs)

            Text("Fill in the shoot details, then use the configured workflow to create the correctly named job and folder structure.")
                .font(VL.small).foregroundStyle(VL.inkFaint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? VL.blue.opacity(0.06) : .clear)
        .overlay(
            RoundedRectangle(cornerRadius: VL.Radius.panel)
                .strokeBorder(isTargeted ? VL.blue : VL.rule,
                              style: StrokeStyle(lineWidth: isTargeted ? 1.5 : 1, dash: [6, 5]))
                .padding(VL.Space.l))
        .animation(.easeOut(duration: 0.14), value: isTargeted)
    }
}

// MARK: - Source

private struct SourceBlock: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: VL.Space.s) {
            SectionLabel("Source") {
                Button("Change") { state.chooseSource() }
                    .buttonStyle(VLQuietButton())
                    .disabled(state.isRunning)
            }

            Text(state.sourceURL?.lastPathComponent ?? "")
                .font(VL.display(20))

            Text("\(F.count(state.plan.count)) files · \(F.bytes(state.plannedBytes))")
                .font(VL.body).foregroundStyle(VL.inkDim).monospacedDigit()

            if !state.config.naming.fileTemplate.isEmpty {
                Toggle(isOn: Binding(
                    get: { state.config.naming.renameOnIngest },
                    set: { v in
                        state.configStore.update { $0.naming.renameOnIngest = v }
                        state.replan()
                    })
                ) {
                    HStack(spacing: 6) {
                        Text("Rename copies to").font(VL.body).foregroundStyle(VL.inkDim)
                        Text(state.config.naming.fileTemplate)
                            .font(VL.mono).foregroundStyle(VL.ink)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(state.isRunning || state.config.isManaged)
                .padding(.top, VL.Space.xs)
            }
        }
    }
}

// MARK: - Rename preview

/// Shows what files will be called *before* anything is written. Finding out
/// about a rename afterwards is how people lose track of footage.
private struct RenameBlock: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: VL.Space.s) {
            SectionLabel("Will be renamed")
            Panel {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(state.renamePreview) { r in
                        HStack(spacing: VL.Space.s) {
                            Text(r.from).font(VL.monoSm).foregroundStyle(VL.inkDim)
                                .frame(width: 130, alignment: .leading)
                                .lineLimit(1).truncationMode(.middle)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 8)).foregroundStyle(VL.inkFaint)
                            Text(r.to).font(VL.monoSm)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Text("Copies only — the card keeps its original names.")
                        .font(.system(size: 10.5)).foregroundStyle(VL.inkFaint)
                        .padding(.top, 3)
                }
            }
        }
    }
}

// MARK: - Destinations

private struct DestinationBlock: View {
    @EnvironmentObject private var state: AppState
    let newJob: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VL.Space.s) {
            SectionLabel("Destinations") {
                HStack(spacing: VL.Space.m) {
                    Button("Create Configured Job") { newJob() }
                        .buttonStyle(VLQuietButton())
                        .disabled(state.isRunning || state.config.isManaged)
                    Button("Add") { state.addDestination() }
                        .buttonStyle(VLQuietButton())
                        .disabled(state.isRunning || state.config.isManaged)
                }
            }

            if state.config.destinations.isEmpty {
                Panel {
                    VStack(alignment: .leading, spacing: VL.Space.s) {
                        Text("Add at least one. Two is better — both are written and verified identically.")
                            .font(VL.body).foregroundStyle(VL.inkDim)
                        Text("Or create a configured job and this will point at its approved media folder for you.")
                            .font(VL.small).foregroundStyle(VL.inkFaint)
                    }
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(state.config.destinations) { d in
                        DestinationRow(destination: d)
                    }
                }
            }
        }
    }
}

private struct DestinationRow: View {
    @EnvironmentObject private var state: AppState
    let destination: DestinationConfig
    @State private var hovering = false

    var body: some View {
        HStack(spacing: VL.Space.m) {
            RoundedRectangle(cornerRadius: 2)
                .fill(destination.isPrimary ? VL.blue : VL.steel.opacity(0.5))
                .frame(width: 3, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(destination.label).font(VL.bodyMed)
                Text(destination.path).font(VL.monoSm).foregroundStyle(VL.inkFaint)
                    .lineLimit(1).truncationMode(.middle)
            }

            Spacer()

            if let summary = tally {
                VLChip(text: summary.text, tint: summary.tint)
            }

            if hovering && !state.isRunning && !state.config.isManaged {
                Button {
                    state.removeDestination(destination.path)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(VLQuietButton())
            }
        }
        .padding(.horizontal, VL.Space.m).padding(.vertical, 9)
        .background(hovering ? VL.slateHi : VL.slate,
                    in: RoundedRectangle(cornerRadius: VL.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: VL.Radius.panel)
            .strokeBorder(VL.ruleSoft, lineWidth: 1))
        .onHover { hovering = $0 }
    }

    /// Per-destination outcome once an ingest has run. Two destinations can
    /// finish differently — one clean, one with a clash — and a single overall
    /// number would hide that.
    private var tally: (text: String, tint: Color)? {
        guard !state.results.isEmpty else { return nil }
        var verified = 0, problems = 0
        for f in state.results {
            switch f.destinations[destination.path] {
            case .some(let s) where s.isVerified: verified += 1
            case .some(let s) where s.isProblem:  problems += 1
            default: break
            }
        }
        if problems > 0 { return ("\(problems) UNRESOLVED", VL.amber) }
        if verified > 0 { return ("\(verified) VERIFIED", VL.blue) }
        return nil
    }
}

// MARK: - Run

private struct RunBlock: View {
    @EnvironmentObject private var state: AppState

    private var p: OffloadProgress { state.progress }

    private var tint: Color {
        switch p.phase {
        case .failed: return VL.amber
        case .done:   return VL.blue
        default:      return VL.blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VL.Space.m) {
            SectionLabel(p.phase == .done ? "Complete" : p.phase.rawValue)

            VLProgressBar(value: p.phase == .done ? 1 : p.fraction, tint: tint)

            HStack(alignment: .top, spacing: VL.Space.l) {
                VLStat(label: "Verified",
                       value: "\(F.count(p.filesVerified))",
                       note: "of \(F.count(p.totalFiles)) files")
                VLStat(label: "Copied",
                       value: F.bytes(p.bytesCopied),
                       note: "of \(F.bytes(p.totalBytes))")
                VLStat(label: "Rate",
                       value: F.rate(p.throughputMBps),
                       note: p.phase == .done ? "average" : F.eta(p))
                VLStat(label: "Already there",
                       value: "\(F.count(p.filesAlreadyPresent))",
                       note: p.filesAlreadyPresent > 0 ? "matched, not rewritten" : "—",
                       tint: p.filesAlreadyPresent > 0 ? VL.ink : VL.inkFaint)
            }

            if !p.currentFile.isEmpty {
                Text(p.currentFile)
                    .font(VL.mono).foregroundStyle(VL.inkDim)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

// MARK: - Problems

private struct ProblemBlock: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: VL.Space.m) {
            if !state.progress.conflicts.isEmpty {
                VLNotice(title: "\(state.progress.conflicts.count) name clash\(state.progress.conflicts.count == 1 ? "" : "es")") {
                    Text("Something different was already at these paths. It was left exactly as it was.")
                        .font(VL.small).foregroundStyle(VL.inkDim)
                    ForEach(state.progress.conflicts.prefix(8), id: \.self) { c in
                        Text(c).font(VL.monoSm).foregroundStyle(VL.inkDim)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            if !state.progress.failures.isEmpty {
                VLNotice(title: "\(state.progress.failures.count) file\(state.progress.failures.count == 1 ? "" : "s") did not verify",
                         systemImage: "xmark.octagon") {
                    ForEach(state.progress.failures.prefix(8), id: \.self) { f in
                        Text(f).font(VL.monoSm).foregroundStyle(VL.inkDim)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Text("The card is untouched. Re-running skips everything already verified.")
                        .font(VL.small).foregroundStyle(VL.inkDim).padding(.top, 2)
                }
            }
        }
    }
}

// MARK: - Per-file results

/// Problems first. The point of a results list isn't the 309 files that worked.
private struct ResultsBlock: View {
    @EnvironmentObject private var state: AppState
    @State private var showAll = false

    private var outcomes: [AppState.FileOutcome] { state.outcomes }
    private var problems: [AppState.FileOutcome] { outcomes.filter { $0.problems > 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: VL.Space.s) {
            SectionLabel("Files") {
                Button(showAll ? "Show problems only" : "Show all \(F.count(outcomes.count))") {
                    showAll.toggle()
                }
                .buttonStyle(VLQuietButton())
            }

            if !showAll && problems.isEmpty {
                Panel {
                    HStack(spacing: VL.Space.s) {
                        Image(systemName: "checkmark.circle").foregroundStyle(VL.blue)
                            .font(.system(size: 12))
                        Text("Every file verified on every destination.")
                            .font(VL.body).foregroundStyle(VL.inkDim)
                    }
                }
            } else {
                VStack(spacing: 2) {
                    ForEach((showAll ? outcomes : problems).prefix(200)) { o in
                        HStack(spacing: VL.Space.s) {
                            Circle()
                                .fill(o.isClean ? VL.blue.opacity(0.75) : VL.amber)
                                .frame(width: 5, height: 5)
                            Text(o.file.destinationRelativePath)
                                .font(VL.monoSm)
                                .lineLimit(1).truncationMode(.middle)
                            if o.file.wasRenamed {
                                Text("was \(o.file.originalName)")
                                    .font(.system(size: 9.5)).foregroundStyle(VL.inkFaint)
                            }
                            Spacer()
                            Text(F.bytes(o.file.size))
                                .font(.system(size: 10)).foregroundStyle(VL.inkFaint).monospacedDigit()
                            Text("\(o.verified)/\(o.verified + o.problems)")
                                .font(.system(size: 10)).monospacedDigit()
                                .foregroundStyle(o.isClean ? VL.inkFaint : VL.amber)
                                .frame(width: 30, alignment: .trailing)
                        }
                        .padding(.horizontal, VL.Space.s).padding(.vertical, 4)
                        .background(o.isClean ? Color.clear : VL.amber.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
    }
}

// MARK: - Action bar

private struct ActionBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: VL.Space.m) {
            // A disabled button with no explanation is the most common way an
            // app feels broken. Say what's missing.
            if let blocked = state.blockedReason, state.progress.phase == .planning {
                HStack(spacing: 6) {
                    Circle().fill(VL.amber).frame(width: 4, height: 4)
                    Text(blocked).font(VL.small).foregroundStyle(VL.inkDim)
                }
            } else if let m = state.message {
                Text(m).font(VL.small).foregroundStyle(VL.inkDim)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: VL.Space.m)

            if state.isRunning {
                Button("Stop") { state.cancel() }.buttonStyle(VLButton(destructiveTint: true))
            } else {
                if state.sourceURL != nil && state.progress.phase != .planning {
                    Button("New Card") { state.reset() }.buttonStyle(VLButton())
                }
                Button("Start Ingest") { state.start() }
                    .buttonStyle(VLPrimaryButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.canStart)
                    .opacity(state.canStart ? 1 : 0.45)
            }
        }
        .padding(.horizontal, VL.Space.m)
        .frame(height: 52)
        .background(VL.charcoal)
    }
}
