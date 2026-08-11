import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var tab: Tab = .workflow

    enum Tab: String, CaseIterable, Identifiable {
        case workflow, form, passport, nexus, network
        var id: String { rawValue }
        var title: String {
            switch self {
            case .workflow: return "Workflow"
            case .form:     return "Shoot Form"
            case .passport: return "Drive Passports"
            case .nexus:    return "Media Nexus"
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
                    case .workflow: WorkflowSettings()
                    case .form:     FormEditor()
                    case .passport: PassportSettings()
                    case .nexus:    NexusSettings()
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
                    Text("Drive Passports is a separate hosted metadata service. It does not change Media Nexus's local-first boundary.")
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
        if locked {
            Panel {
                HStack(spacing: VL.Space.s) {
                    Image(systemName: "lock").foregroundStyle(VL.blue).font(.system(size: 12))
                    Text("These settings come from your Media Nexus and can't be edited here.")
                        .font(VL.small).foregroundStyle(VL.inkDim)
                }
            }
        }

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

// MARK: - Nexus

private struct NexusSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var url = ""
    @State private var code = ""
    @State private var busy = false

    var body: some View {
        if state.config.nexus.isPaired {
            VStack(alignment: .leading, spacing: VL.Space.s) {
                SectionLabel("Connected")
                Panel {
                    VStack(alignment: .leading, spacing: 7) {
                        row("Media Nexus", state.config.nexus.url)
                        row("This Mac", state.config.nexus.deviceName)
                        if let at = state.config.nexus.pairedAt {
                            row("Paired", at.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
                Button("Unpair") { state.unpair() }.buttonStyle(VLButton(destructiveTint: true))
                Text("Unpairing returns settings to local control. Nothing on your drives changes.")
                    .font(VL.small).foregroundStyle(VL.inkFaint)
            }
        } else {
            VStack(alignment: .leading, spacing: VL.Space.m) {
                SectionLabel("Connect")
                Text("If your team runs Vaultline, connect this Mac to your Media Nexus. It will report what you ingest and pick up your team's naming convention automatically.")
                    .font(VL.body).foregroundStyle(VL.inkDim)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: VL.Space.s) {
                    TextField("", text: $url,
                              prompt: Text("https://nexus.yourstudio.local").foregroundColor(VL.inkFaint))
                        .textFieldStyle(VLFieldStyle())
                    TextField("", text: $code,
                              prompt: Text("Pairing code").foregroundColor(VL.inkFaint))
                        .textFieldStyle(VLFieldStyle())
                        .frame(maxWidth: 200)
                }
                .frame(maxWidth: 380)

                Button(busy ? "Connecting…" : "Pair") {
                    busy = true
                    Task { await state.pair(url: url, code: code); busy = false }
                }
                .buttonStyle(VLPrimaryButton())
                .disabled(url.isEmpty || busy)

                Panel {
                    Text("Only metadata and checksums are ever sent — never your media. The app has no upload path for footage.")
                        .font(VL.small).foregroundStyle(VL.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear { url = state.config.nexus.url }
        }

        if let m = state.message {
            Text(m).font(VL.small).foregroundStyle(VL.inkFaint)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: VL.Space.m) {
            Text(k).font(VL.small).foregroundStyle(VL.inkFaint)
                .frame(width: 92, alignment: .leading)
            Text(v).font(VL.small).textSelection(.enabled)
        }
    }
}

// MARK: - Network panel

/// The app's substitute for a provable no-network entitlement (spec §2).
/// Only meaningful while it is genuinely complete — every request goes through
/// `NexusClient.send`, and `release.sh` fails the build if anything else creates
/// a URLSession.
private struct NetworkPanel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: VL.Space.s) {
            Text("Every request this app makes").font(VL.display(16))
            Text("Not a sample — all of them. There is no analytics, no telemetry, no update check and no crash reporting. The app only contacts the Drive Passport and Media Nexus addresses you entered.")
                .font(VL.small).foregroundStyle(VL.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }

        if state.nexus.log.entries.isEmpty {
            Panel(padding: VL.Space.xl) {
                VStack(spacing: VL.Space.s) {
                    Image(systemName: "network.slash")
                        .font(.system(size: 26, weight: .thin)).foregroundStyle(VL.steel)
                    Text("No network requests have been made.")
                        .font(VL.body).foregroundStyle(VL.inkDim)
                    Text(state.config.nexus.isPaired || state.config.passport?.isConnected == true
                         ? "Nothing has been sent yet this session."
                         : "No hosted services are connected, so the app has nothing to talk to.")
                        .font(VL.small).foregroundStyle(VL.inkFaint)
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 4) {
                ForEach(state.nexus.log.entries) { e in
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

// MARK: - Pairing sheet (from the install command)

struct PairingSheet: View {
    @EnvironmentObject private var state: AppState
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: VL.Space.m) {
            Text("Connect to your Media Nexus").font(VL.display(17))

            if let p = state.pendingPairing {
                Text("This Mac is being set up to connect to:")
                    .font(VL.body).foregroundStyle(VL.inkDim)

                Panel { Text(p.url).font(VL.mono).textSelection(.enabled) }

                Text("Your ingests will be reported to it, and your team's naming convention will be applied automatically. Your media stays on your drives — only metadata and checksums are sent.")
                    .font(VL.small).foregroundStyle(VL.inkDim)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Not Now") { state.pendingPairing = nil }.buttonStyle(VLButton())
                    Spacer()
                    Button(busy ? "Connecting…" : "Connect") {
                        busy = true
                        Task { await state.pair(url: p.url, code: p.code); busy = false }
                    }
                    .buttonStyle(VLPrimaryButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
                }
                .padding(.top, VL.Space.xs)
            }
        }
        .padding(VL.Space.l)
        .frame(width: 470)
        .vlWindowBackground()
        .foregroundStyle(VL.ink)
    }
}
