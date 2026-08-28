import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var tab: Tab = .workflow

    enum Tab: String, CaseIterable, Identifiable {
        case team, workflow, form, driveScans, passport, network
        var id: String { rawValue }
        var title: String {
            switch self {
            case .team:     return "Team Setup"
            case .workflow: return "Workflow"
            case .form:     return "Shoot Form"
            case .driveScans: return "Drive Scans"
            case .passport: return "Drive Passports"
            case .network:  return "Network"
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
                    switch tab {
                    case .team:     TeamSettings()
                    case .workflow: WorkflowSettings()
                    case .form:     FormEditor()
                    case .driveScans: DriveScanSettings()
                    case .passport: PassportSettings()
                    case .network:  NetworkPanel()
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
                Button("Export…") { exportConfiguration() }.buttonStyle(VLButton())
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

// MARK: - Drive scans

private struct DriveScanSettings: View {
    @EnvironmentObject private var state: AppState

    private var locked: Bool { state.config.isManaged }
    private var rules: DriveScanRules { state.config.effectiveDriveScanRules }

    var body: some View {
        if locked {
            Panel {
                HStack(spacing: VL.Space.s) {
                    Image(systemName: "lock").foregroundStyle(VL.blue).font(.system(size: 12))
                    Text("These scan rules are locked by the imported team configuration.")
                        .font(VL.small).foregroundStyle(VL.inkDim)
                }
            }
        }

        VStack(alignment: .leading, spacing: VL.Space.s) {
            SectionLabel("Folders to track")
            Text("Enter a regular expression that matches the complete folder name carrying your job or asset identity.")
                .font(VL.body).foregroundStyle(VL.inkDim)
                .fixedSize(horizontal: false, vertical: true)

            TextField("", text: Binding(
                get: { rules.folderNamePattern },
                set: { value in state.configStore.update {
                    var next = $0.effectiveDriveScanRules
                    next.folderNamePattern = value
                    $0.driveScanRules = next
                } }),
                prompt: Text("Example: ^JOB-[0-9]{4}$").foregroundColor(VL.inkFaint))
                .textFieldStyle(VLFieldStyle())
                .font(VL.mono)
                .disabled(locked)
                .frame(maxWidth: 420)

            if !rules.patternIsValid {
                Text("That regular expression isn't valid. Scans will track no folders until it is fixed.")
                    .font(VL.small).foregroundStyle(VL.amber)
            } else if rules.trimmedPattern.isEmpty {
                Text("No pattern set — each top-level folder is treated as a tracked collection.")
                    .font(VL.small).foregroundStyle(VL.inkFaint)
            }
        }

        VStack(alignment: .leading, spacing: VL.Space.s) {
            SectionLabel("When a drive is connected")
            Toggle("Scan matching folders automatically", isOn: Binding(
                get: { rules.automaticOnMount },
                set: { value in state.configStore.update {
                    var next = $0.effectiveDriveScanRules
                    next.automaticOnMount = value
                    $0.driveScanRules = next
                } }))
                .toggleStyle(.checkbox).font(VL.body).disabled(locked || !rules.patternIsValid)

            Panel(tint: VL.slate) {
                Text("Automatic scanning is opt-in because it reads directory metadata from every matching drive. It never moves, replaces, or deletes media.")
                    .font(VL.small).foregroundStyle(VL.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Drive Passports

private struct PassportSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var url = ""
    @State private var code = ""
    @State private var busy = false

    var body: some View {
        if let passport = state.config.passport, passport.isConnected {
            VStack(alignment: .leading, spacing: VL.Space.s) {
                SectionLabel("Connected")
                Panel {
                    VStack(alignment: .leading, spacing: 7) {
                        row("Workspace", passport.url)
                        row("This Mac", passport.deviceName)
                        if let at = passport.connectedAt {
                            row("Connected", at.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
                Button("Disconnect") { state.disconnectPassports() }
                    .buttonStyle(VLButton(destructiveTint: true))
                Text("Disconnecting stops hosted metadata sync. Your local snapshots and ingest settings are unchanged.")
                    .font(VL.small).foregroundStyle(VL.inkFaint)
            }
        } else {
            VStack(alignment: .leading, spacing: VL.Space.m) {
                SectionLabel("Connect")
                Text("Connect this Mac to a Drive Passport workspace. Only bounded drive identity signals and snapshot aggregates are sent — never media, filenames, hidden files, or raw local paths.")
                    .font(VL.body).foregroundStyle(VL.inkDim)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: VL.Space.s) {
                    TextField("", text: $url,
                              prompt: Text("https://your-drive-passports-site").foregroundColor(VL.inkFaint))
                        .textFieldStyle(VLFieldStyle())
                    TextField("", text: $code,
                              prompt: Text("One-time desktop code").foregroundColor(VL.inkFaint))
                        .textFieldStyle(VLFieldStyle())
                        .frame(maxWidth: 230)
                }
                .frame(maxWidth: 430)

                Button(busy ? "Connecting…" : "Connect") {
                    busy = true
                    Task { await state.connectPassports(url: url, code: code); busy = false }
                }
                .buttonStyle(VLPrimaryButton())
                .disabled(url.isEmpty || code.count != 6 || busy)

                Panel {
                    Text("Drive Passports is a separate optional metadata service. It does not change Ingest's standalone offload workflow.")
                        .font(VL.small).foregroundStyle(VL.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear { url = state.config.passport?.url ?? "" }
        }

        if let m = state.message { Text(m).font(VL.small).foregroundStyle(VL.inkFaint) }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: VL.Space.m) {
            Text(key).font(VL.small).foregroundStyle(VL.inkFaint)
                .frame(width: 92, alignment: .leading)
            Text(value).font(VL.small).textSelection(.enabled)
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

    private var locked: Bool { state.config.isManaged }

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
            SectionLabel("If a different file is already there")
            Picker("", selection: Binding(
                get: { state.config.workflow.onCollision },
                set: { v in state.configStore.update { $0.workflow.onCollision = v } })
            ) {
                ForEach(WorkflowConfig.CollisionPolicy.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden().pickerStyle(.radioGroup).disabled(locked)

            Panel(tint: VL.slate) {
                Text("There is no overwrite option — nothing this app does can replace or delete existing media. A file that's already there and byte-identical isn't a clash at all: it counts as done, so re-running an interrupted card picks up where it stopped.")
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

// MARK: - Network panel

/// The app's substitute for a provable no-network entitlement (spec §2).
/// Only meaningful while it is genuinely complete — every request goes through
/// `DrivePassportClient`, and `release.sh` fails the build if anything else
/// creates a URLSession.
private struct NetworkPanel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: VL.Space.s) {
            Text("Every request this app makes").font(VL.display(16))
            Text("Not a sample — all of them. There is no analytics, telemetry, update check, crash reporting, or Media Nexus connection. The optional Drive Passport service is the only active network feature.")
                .font(VL.small).foregroundStyle(VL.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }

        if state.networkLog.entries.isEmpty {
            Panel(padding: VL.Space.xl) {
                VStack(spacing: VL.Space.s) {
                    Image(systemName: "network.slash")
                        .font(.system(size: 26, weight: .thin)).foregroundStyle(VL.steel)
                    Text("No network requests have been made.")
                        .font(VL.body).foregroundStyle(VL.inkDim)
                    Text(state.config.passport?.isConnected == true
                         ? "Nothing has been sent yet this session."
                         : "No hosted services are connected, so the app has nothing to talk to.")
                        .font(VL.small).foregroundStyle(VL.inkFaint)
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 4) {
                ForEach(state.networkLog.entries) { e in
                    HStack(alignment: .top, spacing: VL.Space.m) {
                        Rectangle()
                            .fill(e.error != nil ? VL.amber : VL.blue)
                            .frame(width: 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.summary).font(VL.monoSm)
                            Text("\(e.at.formatted(date: .omitted, time: .standard)) · ↑\(F.bytes(Int64(e.bytesOut))) ↓\(F.bytes(Int64(e.bytesIn)))"
                                 + (e.error.map { " · \($0)" } ?? ""))
                                .font(.system(size: 10)).foregroundStyle(VL.inkFaint)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 5).padding(.horizontal, VL.Space.s)
                    .background(VL.slate, in: RoundedRectangle(cornerRadius: VL.Radius.small))
                }
            }
        }
    }
}
