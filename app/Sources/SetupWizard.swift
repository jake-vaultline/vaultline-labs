import SwiftUI
import AppKit

/// Learns a naming convention from work the team has already done, instead of
/// asking them to describe it. See `../spec.md` §5.
struct SetupWizard: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var analysis: NamingAnalyzer.Analysis?
    @State private var hierarchy: [NamingAnalyzer.Analysis] = []
    @State private var selected: NamingAnalyzer.Candidate?
    @State private var scanning = false
    @State private var scannedFrom = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Naming Setup").font(VL.title)
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(VLQuietButton())
            }
            .padding(.horizontal, VL.Space.l).frame(height: 46)

            Divider().overlay(VL.rule)

            ScrollView {
                VStack(alignment: .leading, spacing: VL.Space.xl) {
                    if analysis == nil { intro } else { results }
                }
                .padding(VL.Space.l)
            }

            Divider().overlay(VL.rule)

            HStack {
                if let a = analysis {
                    Text("\(F.count(a.sampleSize)) names read from \(scannedFrom)")
                        .font(VL.small).foregroundStyle(VL.inkFaint)
                }
                Spacer()
                Button("Use This Pattern") { apply() }
                    .buttonStyle(VLPrimaryButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
                    .opacity(selected == nil ? 0.45 : 1)
            }
            .padding(.horizontal, VL.Space.m).frame(height: 52)
        }
        .frame(width: 760, height: 600)
        .vlWindowBackground()
        .foregroundStyle(VL.ink)
    }

    // MARK: Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: VL.Space.m) {
            Text("Point this at work you've already done.").font(VL.display(20))
            Text("""
                 Nobody can describe their naming convention accurately — but everyone has a \
                 drive that shows it. This reads real folder and file names, works out the \
                 recurring shape, and tells you how consistently you've actually stuck to it.
                 """)
                .font(VL.body).foregroundStyle(VL.inkDim)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)

            Panel(tint: VL.slate) {
                HStack(spacing: VL.Space.s) {
                    Image(systemName: "eye").font(.system(size: 12)).foregroundStyle(VL.blue)
                    Text("Nothing is modified. It only reads names.")
                        .font(VL.small).foregroundStyle(VL.inkDim)
                }
            }
            .frame(maxWidth: 400)

            Button(scanning ? "Reading…" : "Choose a Folder to Learn From…") { scan() }
                .buttonStyle(VLPrimaryButton())
                .disabled(scanning)
                .padding(.top, VL.Space.xs)
        }
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        if let a = analysis {
            VStack(alignment: .leading, spacing: VL.Space.s) {
                Text(a.headline).font(VL.display(19))
                VLProgressBar(value: a.consistency,
                              tint: a.consistency > 0.75 ? VL.blue : VL.amber,
                              height: 8)
                Text(consistencyNote(a.consistency))
                    .font(VL.body).foregroundStyle(VL.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: VL.Space.s) {
                SectionLabel("Patterns found")
                ForEach(a.candidates) { c in
                    CandidateRow(candidate: c, total: a.sampleSize,
                                 isSelected: selected?.id == c.id) { selected = c }
                }
            }

            if !hierarchy.isEmpty {
                VStack(alignment: .leading, spacing: VL.Space.s) {
                    SectionLabel("Folder structure")
                    Panel {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(Array(hierarchy.enumerated()), id: \.offset) { _, h in
                                if let top = h.candidates.first {
                                    HStack(spacing: VL.Space.m) {
                                        Text(h.scope.capitalized).font(VL.body)
                                            .frame(width: 128, alignment: .leading)
                                        Text(top.template).font(VL.mono).foregroundStyle(VL.inkDim)
                                        Spacer()
                                        Text("\(Int(h.consistency * 100))%")
                                            .font(VL.small).foregroundStyle(VL.inkFaint).monospacedDigit()
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if !a.exceptions.isEmpty {
                VStack(alignment: .leading, spacing: VL.Space.s) {
                    SectionLabel("The ones that don't match")
                    Text("Usually the most useful thing here — this is where the convention broke.")
                        .font(VL.small).foregroundStyle(VL.inkFaint)
                    Panel {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(a.exceptions.prefix(12), id: \.self) { e in
                                Text(e).font(VL.monoSm).foregroundStyle(VL.inkDim)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
            }

            Button("Learn From a Different Folder…") { scan() }
                .buttonStyle(VLButton())
        }
    }

    private func consistencyNote(_ v: Double) -> String {
        switch v {
        case 0.9...:    return "Very consistent. Worth locking in as the standard."
        case 0.7..<0.9: return "Mostly consistent. The exceptions below are worth a look before you standardise."
        case 0.4..<0.7: return "Loosely followed. Picking one pattern here will save real time later."
        default:        return "No dominant convention. That's normal, and it's exactly the thing worth fixing first."
        }
    }

    // MARK: Actions

    private func scan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Read"
        panel.message = "Choose a folder of existing work. Nothing will be modified."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        scanning = true
        scannedFrom = url.lastPathComponent

        Task.detached {
            var names: [String] = []
            var relPaths: [String] = []
            let root = url.path

            if let e = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                while let f = e.nextObject() as? URL {
                    guard names.count < 8000 else { break }
                    guard let v = try? f.resourceValues(forKeys: [.isRegularFileKey]),
                          v.isRegularFile == true else { continue }
                    names.append(f.lastPathComponent)
                    var rel = f.path
                    if rel.hasPrefix(root) { rel = String(rel.dropFirst(root.count + 1)) }
                    relPaths.append(rel)
                }
            }

            let a = NamingAnalyzer.analyze(names: names, scope: "files")
            let h = NamingAnalyzer.analyzeHierarchy(relativePaths: relPaths)

            await MainActor.run {
                analysis = a
                hierarchy = h
                selected = a.candidates.first
                scanning = false
            }
        }
    }

    private func apply() {
        guard let c = selected, let a = analysis else { return }
        state.configStore.update { cfg in
            cfg.naming.fileTemplate = c.template
            cfg.naming.separator = c.separator
            cfg.naming.learnedFrom = scannedFrom
            cfg.naming.consistencyAtLearn = a.consistency
            if let folder = hierarchy.first?.candidates.first {
                cfg.naming.folderTemplate = folder.template
            }
        }
        dismiss()
    }
}

// MARK: - Candidate row

private struct CandidateRow: View {
    let candidate: NamingAnalyzer.Candidate
    let total: Int
    let isSelected: Bool
    let select: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(candidate.template).font(VL.mono)
                    Spacer()
                    Text("\(F.count(candidate.matches)) of \(F.count(total))")
                        .font(VL.small).foregroundStyle(VL.inkFaint).monospacedDigit()
                }
                VLProgressBar(value: total > 0 ? Double(candidate.matches) / Double(total) : 0,
                              tint: isSelected ? VL.blue : VL.steel.opacity(0.55),
                              height: 3)
                Text(candidate.examples.joined(separator: "   "))
                    .font(VL.monoSm).foregroundStyle(VL.inkFaint)
                    .lineLimit(1).truncationMode(.tail)
            }
            .padding(VL.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? VL.blue.opacity(0.12) : (hovering ? VL.slateHi : VL.slate),
                        in: RoundedRectangle(cornerRadius: VL.Radius.panel))
            .overlay(RoundedRectangle(cornerRadius: VL.Radius.panel)
                .strokeBorder(isSelected ? VL.blue.opacity(0.75) : VL.ruleSoft,
                              lineWidth: isSelected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
