import SwiftUI
import AppKit

/// Preview and create a job from the team's portable workflow configuration.
/// The ingest form supplies naming tokens; the operator only chooses the
/// workflow and destination root.
struct JobSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var workflowID = ""
    @State private var selectedRoot: URL?

    private var workflows: [IngestWorkflowPreset] { state.config.effectiveTeam.workflows }
    private var workflow: IngestWorkflowPreset? {
        workflows.first { $0.id == workflowID } ?? workflows.first
    }
    private var plan: Result<ConfiguredJobPlan, Error> {
        guard let workflow, let selectedRoot else {
            return .failure(TeamConfigurationError.invalidWorkflow("Choose a workflow and destination."))
        }
        return Result { try ConfiguredJobPlan.make(
            workflow: workflow, selectedRoot: selectedRoot, values: state.workflowValues) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Create Ingest Job").font(VL.title)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(VLQuietButton())
            }
            .padding(.horizontal, VL.Space.l).frame(height: 46)

            Divider().overlay(VL.rule)

            ScrollView {
                VStack(alignment: .leading, spacing: VL.Space.l) {
                    if state.config.form.enabled && !state.config.form.fields.isEmpty {
                        ShootForm()
                    }

                    VStack(alignment: .leading, spacing: VL.Space.s) {
                        SectionLabel("Team workflow")
                        ForEach(workflows) { item in
                            Button { workflowID = item.id; useConfiguredRoot(item) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).font(VL.bodyMed)
                                    Text(item.detail).font(VL.small).foregroundStyle(VL.inkDim)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(VL.Space.m)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(workflow?.id == item.id ? VL.blue.opacity(0.12) : VL.slate,
                                            in: RoundedRectangle(cornerRadius: VL.Radius.panel))
                                .overlay(RoundedRectangle(cornerRadius: VL.Radius.panel)
                                    .strokeBorder(workflow?.id == item.id ? VL.blue.opacity(0.75) : VL.ruleSoft))
                            }.buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: VL.Space.s) {
                        SectionLabel("Destination")
                        HStack(spacing: VL.Space.s) {
                            Button(selectedRoot == nil ? "Choose Drive or Folder…" : "Change…") { pickRoot() }
                                .buttonStyle(VLButton())
                            if let selectedRoot {
                                Text(selectedRoot.path).font(VL.monoSm).foregroundStyle(VL.inkFaint)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        if selectedRoot == nil, let suggested = workflow?.destinationRoot {
                            Text("Configured destination: \(suggested). Choose it once so macOS can grant access.")
                                .font(VL.small).foregroundStyle(VL.inkFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    preview
                }
                .padding(VL.Space.l)
            }

            Divider().overlay(VL.rule)
            HStack {
                Text("Nothing existing is overwritten.")
                    .font(VL.small).foregroundStyle(VL.inkFaint)
                Spacer()
                Button("Create Job") {
                    guard let workflow, let selectedRoot else { return }
                    state.createConfiguredJob(workflow: workflow, in: selectedRoot)
                    if state.lastConfiguredJob != nil { dismiss() }
                }
                .buttonStyle(VLPrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
                .opacity(canCreate ? 1 : 0.45)
            }
            .padding(.horizontal, VL.Space.m).frame(height: 52)
        }
        .frame(width: 680, height: 650)
        .vlWindowBackground().foregroundStyle(VL.ink)
        .onAppear {
            if workflowID.isEmpty { workflowID = workflows.first?.id ?? "" }
            if let workflow { useConfiguredRoot(workflow) }
        }
    }

    private var canCreate: Bool {
        guard state.missingRequired.isEmpty, state.invalidFields.isEmpty, selectedRoot != nil else { return false }
        if case .success = plan { return true }
        return false
    }

    @ViewBuilder private var preview: some View {
        VStack(alignment: .leading, spacing: VL.Space.s) {
            SectionLabel("Preview")
            Panel {
                switch plan {
                case .success(let plan):
                    VStack(alignment: .leading, spacing: 3) {
                        Text(plan.parent.path).font(VL.monoSm).foregroundStyle(VL.inkFaint)
                        Text(plan.jobName).font(VL.mono)
                        ForEach(plan.workflow.folders, id: \.self) { folder in
                            HStack(spacing: 6) {
                                Text("  " + folder.replacingOccurrences(of: "/", with: " / "))
                                    .font(VL.monoSm).foregroundStyle(
                                        WorkflowPath.normalized(folder) == WorkflowPath.normalized(plan.workflow.mediaFolder)
                                        ? VL.blue : VL.inkDim)
                                if WorkflowPath.normalized(folder) == WorkflowPath.normalized(plan.workflow.mediaFolder) {
                                    Text("MEDIA LANDS HERE").font(.system(size: 8, weight: .semibold)).foregroundStyle(VL.blue)
                                }
                            }
                        }
                        if let project = plan.projectURL {
                            Text("Project: \(project.lastPathComponent)")
                                .font(VL.small).foregroundStyle(VL.inkFaint).padding(.top, 6)
                            Text(plan.workflow.projectTemplatePath == nil && plan.workflow.projectTemplateBase64 == nil
                                 ? "The project folder is created. No fake Premiere file is generated until Vaultline configures a real team template."
                                 : "The team's real project template will be copied under this name.")
                                .font(VL.small).foregroundStyle(VL.inkDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .failure(let error):
                    Text(error.localizedDescription).font(VL.small).foregroundStyle(VL.amber)
                }
            }
        }
    }

    private func useConfiguredRoot(_ workflow: IngestWorkflowPreset) {
        guard let path = workflow.destinationRoot, Bookmarks.has(path: path) else { return }
        selectedRoot = URL(fileURLWithPath: path, isDirectory: true)
    }

    private func pickRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Choose the drive or folder where this team's configured parent folder should live."
        if panel.runModal() == .OK, let url = panel.url {
            Bookmarks.save(url)
            selectedRoot = url
        }
    }
}
