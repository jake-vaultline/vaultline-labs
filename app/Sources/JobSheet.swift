import SwiftUI
import AppKit

/// Creates the folder tree a job lives in, before the card goes in.
///
/// Deliberately the first thing offered on an empty ingest screen rather than
/// something buried in a menu: structure that gets improvised after the media
/// has landed is the structure that goes wrong.
struct JobSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var template = StructureBuilder.shootAndEdit
    @State private var parent: URL?

    private var previewName: String {
        StructureBuilder.jobName(naming: state.config.naming, jobTitle: title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("New Job").font(VL.title)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(VLQuietButton())
            }
            .padding(.horizontal, VL.Space.l).frame(height: 46)

            Divider().overlay(VL.rule)

            ScrollView {
                VStack(alignment: .leading, spacing: VL.Space.l) {
                    naming
                    templates
                    preview
                }
                .padding(VL.Space.l)
            }

            Divider().overlay(VL.rule)

            HStack {
                Text(parent.map { "in \($0.lastPathComponent)" } ?? "Choose where it goes")
                    .font(VL.small).foregroundStyle(VL.inkFaint)
                Spacer()
                Button("Create") {
                    guard let parent else { return }
                    state.createJob(template: template, title: title, in: parent)
                    dismiss()
                }
                .buttonStyle(VLPrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(parent == nil)
                .opacity(parent == nil ? 0.45 : 1)
            }
            .padding(.horizontal, VL.Space.m).frame(height: 52)
        }
        .frame(width: 620, height: 560)
        .vlWindowBackground()
        .foregroundStyle(VL.ink)
    }

    // MARK: Blocks

    private var naming: some View {
        VStack(alignment: .leading, spacing: VL.Space.s) {
            SectionLabel("Job")
            TextField("", text: $title,
                      prompt: Text("What is it? e.g. Northstar Q3 Campaign").foregroundColor(VL.inkFaint))
                .textFieldStyle(VLFieldStyle())

            HStack(spacing: VL.Space.s) {
                Button(parent == nil ? "Choose Location…" : "Change Location…") { pick() }
                    .buttonStyle(VLButton())
                if let parent {
                    Text(parent.path).font(VL.monoSm).foregroundStyle(VL.inkFaint)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    private var templates: some View {
        VStack(alignment: .leading, spacing: VL.Space.s) {
            SectionLabel("Structure")
            ForEach(StructureBuilder.builtIn) { t in
                Button { template = t } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(t.name).font(VL.bodyMed)
                            Spacer()
                            Text("\(t.folders.count) folders")
                                .font(VL.small).foregroundStyle(VL.inkFaint)
                        }
                        Text(t.detail).font(VL.small).foregroundStyle(VL.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(VL.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(template.id == t.id ? VL.blue.opacity(0.12) : VL.slate,
                                in: RoundedRectangle(cornerRadius: VL.Radius.panel))
                    .overlay(RoundedRectangle(cornerRadius: VL.Radius.panel)
                        .strokeBorder(template.id == t.id ? VL.blue.opacity(0.75) : VL.ruleSoft,
                                      lineWidth: template.id == t.id ? 1.5 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: VL.Space.s) {
            SectionLabel("Will create")
            Panel {
                VStack(alignment: .leading, spacing: 2) {
                    Text(previewName).font(VL.mono)
                    ForEach(template.folders, id: \.self) { f in
                        Text("  " + f.replacingOccurrences(of: "/", with: " / "))
                            .font(VL.monoSm).foregroundStyle(VL.inkDim)
                    }
                    Text("Camera media from your next ingest will land in the shoot side, not the edit side. That separation is the whole point — shoot is written once, edit is where everything churns.")
                        .font(VL.small).foregroundStyle(VL.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, VL.Space.s)
                }
            }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Where should this job folder be created?"
        if panel.runModal() == .OK { parent = panel.url }
    }
}
