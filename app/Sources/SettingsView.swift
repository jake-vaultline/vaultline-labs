import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var tab: Tab = .workflow

    enum Tab: String, CaseIterable, Identifiable {
        case team, workflow, form
        var id: String { rawValue }
        var title: String {
            switch self {
            case .team:     return "Team Setup"
            case .workflow: return "Workflow"
            case .form:     return "Shoot Form"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Tab.allCases) { t in
                    Button(t.title) { tab = t }
                        .buttonStyle(TabButton(active: tab == t))
                }
                Spacer()
            }
            .padding(.horizontal, VL.Space.m)
            .frame(height: 46)

            Divider().overlay(VL.rule)

            ScrollView {
                VStack(alignment: .leading, spacing: VL.Space.xl) {
                    if state.isRunning {
                        VLNotice(title: "Ingest in progress", systemImage: "lock") {
                            Text("Workflow and form settings are locked until every destination has finished verification. The active card keeps the exact settings it started with.")
                                .font(VL.small).foregroundStyle(VL.inkDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    switch tab {
                    case .team:     TeamSettings()
                    case .workflow: WorkflowSettings()
                    case .form:     FormEditor()
                    }
                }
                .padding(VL.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 680, height: 520)
        .vlWindowBackground()
        .foregroundStyle(VL.ink)
        .environmentObject(state)
    }
}

// MARK: - Portable team setup

private struct TeamSettings: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: VL.Space.l) {
            VStack(alignment: .leading, spacing: VL.Space.s) {
                SectionLabel("Configured for")
                Text(state.config.effectiveTeam.teamName).font(VL.display(20))
                Text("One app binary, configured with a portable JSON package. The package contains workflow rules—not credentials, account state, or media.")
                    .font(VL.body).foregroundStyle(VL.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: VL.Space.s) {
                SectionLabel("Workflows")
                ForEach(state.config.effectiveTeam.workflows) { workflow in
                    Panel {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(workflow.name).font(VL.bodyMed)
                            Text(workflow.jobNameTemplate).font(VL.monoSm).foregroundStyle(VL.blue)
                            Text("\(workflow.parentSubpath) → \(workflow.mediaFolder)")
                                .font(VL.small).foregroundStyle(VL.inkFaint)
                        }
                    }
                }
            }

            HStack(spacing: VL.Space.s) {
                Button("Import Team Configuration…") { importConfiguration() }
                    .buttonStyle(VLPrimaryButton())
                    .disabled(state.isRunning)
                Button("Export…") { exportConfiguration() }.buttonStyle(VLButton())
            }

            VLNotice(title: "Free Vaultline setup", systemImage: "slider.horizontal.3") {
                Text("Vaultline will configure the shoot form, naming, folder structure, destinations, and project-template workflow for your team at no charge. The result is one portable configuration for this same standalone app—not a custom source fork.")
                    .font(VL.small).foregroundStyle(VL.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = state.message {
                Text(message).font(VL.small).foregroundStyle(VL.inkDim)
            }
        }
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try state.configStore.importTeamConfiguration(from: url)
            state.message = "Imported and validated \(state.config.effectiveTeam.teamName)'s configuration."
        } catch {
            state.message = "Configuration was not imported: \(error.localizedDescription)"
        }
    }

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "vaultline-ingest-team.json"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try state.configStore.exportTeamConfiguration(to: url)
            state.message = "Exported the portable team configuration."
        } catch {
            state.message = "Configuration was not exported: \(error.localizedDescription)"
        }
    }
}

private struct TabButton: ButtonStyle {
    let active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(active ? VL.bodyMed : VL.body)
            .foregroundStyle(active ? VL.ink : VL.inkDim)
            .padding(.horizontal, 13).padding(.vertical, 6)
            .background(active ? VL.slate : .clear,
                        in: RoundedRectangle(cornerRadius: VL.Radius.small))
            .contentShape(Rectangle())
    }
}

// MARK: - Workflow

private struct WorkflowSettings: View {
    @EnvironmentObject private var state: AppState

    private var locked: Bool { state.config.isManaged || state.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: VL.Space.s) {
            SectionLabel("Checksum")
            Picker("", selection: Binding(
                get: { state.config.checksum },
                set: { v in state.configStore.update { $0.checksum = v } })
            ) {
                ForEach(ChecksumAlgorithm.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden().pickerStyle(.radioGroup).disabled(locked)

            Text("xxHash64 runs at gigabytes per second, so verification isn't what's slowing your offload down. Pick MD5 or SHA-1 only if a facility requires it.")
                .font(VL.small).foregroundStyle(VL.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: VL.Space.s) {
            SectionLabel("Transfer record")
            Panel(tint: VL.slate) {
                Text("Verification is always on and there is no overwrite option. Matching files count as done; different files are flagged and left untouched.")
                    .font(VL.small).foregroundStyle(VL.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Write an ASC MHL manifest", isOn: Binding(
                get: { state.config.workflow.manifest },
                set: { v in state.configStore.update { $0.workflow.manifest = v } }))
                .toggleStyle(.checkbox).font(VL.body).disabled(locked)
        }

        VStack(alignment: .leading, spacing: VL.Space.s) {
            SectionLabel("Naming")
            if state.config.naming.fileTemplate.isEmpty {
                Text("No convention learned yet. Use Naming Setup in the main window.")
                    .font(VL.small).foregroundStyle(VL.inkFaint)
            } else {
                Text(state.config.naming.fileTemplate).font(VL.mono)
                if let learned = state.config.naming.learnedFrom {
                    Text("Learned from \(learned)"
                         + (state.config.naming.consistencyAtLearn.map { " · \(Int($0 * 100))% consistent" } ?? ""))
                        .font(VL.small).foregroundStyle(VL.inkFaint)
                }
            }

            TextField("", text: Binding(
                get: { state.config.naming.projectCode },
                set: { v in state.configStore.update { $0.naming.projectCode = v }; state.replan() }),
                prompt: Text("Project code — fills {code}").foregroundColor(VL.inkFaint))
                .textFieldStyle(VLFieldStyle())
                .disabled(locked)
                .frame(maxWidth: 280)
        }
    }
}
