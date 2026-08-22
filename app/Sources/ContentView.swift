import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @EnvironmentObject private var engine: ScanEngine
    @State private var isTargeted = false
    @State private var exporting = false
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().overlay(VL.rule)

            Group {
                if engine.snapshot.filesScanned == 0 && !engine.isScanning {
                    DropZone(isTargeted: isTargeted, choose: chooseFolder)
                } else {
                    ResultsView(snapshot: engine.snapshot, isScanning: engine.isScanning)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if engine.snapshot.filesScanned > 0 {
                Divider().overlay(VL.rule)
                actionBar
            }
        }
        .vlWindowBackground()
        .foregroundStyle(VL.ink)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { handleDrop($0) }
        .alert("Couldn't scan that", isPresented: .constant(engine.errorMessage != nil)) {
            Button("OK") { engine.errorMessage = nil }
        } message: { Text(engine.errorMessage ?? "") }
        .alert("Export failed", isPresented: .constant(exportError != nil)) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    // MARK: Chrome

    private var titleBar: some View {
        HStack(spacing: VL.Space.m) {
            Spacer().frame(width: 68)
            HStack(spacing: 10) {
                Image("VaultlineMark")
                    .resizable().scaledToFit()
                    .frame(height: 20)
                Rectangle().fill(VL.rule).frame(width: 1, height: 15)
                Text("Drive Inspector").font(VL.title).foregroundStyle(VL.ink)
            }
            Spacer()
            if engine.isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, VL.Space.m)
        .frame(height: 46)
        .background(VL.charcoal)
    }

    private var actionBar: some View {
        HStack(spacing: VL.Space.m) {
            if engine.isBusy {
                Button("Stop") { engine.cancel() }.buttonStyle(VLButton(destructiveTint: true))
                Text(busyLabel).font(VL.small).foregroundStyle(VL.inkDim).monospacedDigit()
            } else {
                if engine.canContinueDuplicates {
                    Button("Continue duplicate verification") { engine.continueDuplicates() }
                        .buttonStyle(VLPrimaryButton())
                }
                Button("Scan Another…", action: chooseFolder).buttonStyle(VLButton())
            }

            Spacer()

            if exporting { ProgressView().controlSize(.small) }

            // The report is what actually travels — see report/report-spec.md.
            Menu("Export Report") {
                ForEach(Exporter.Format.allCases) { fmt in
                    Button(fmt.label) { export(fmt) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(engine.snapshot.filesScanned == 0 || exporting)
            .help(engine.snapshot.probe.isComplete
                  ? "Save the full report"
                  : "Media is still being read — the report will note what was covered")
        }
        .padding(.horizontal, VL.Space.m)
        .frame(height: 52)
        .background(VL.charcoal)
    }

    private var busyLabel: String {
        let d = engine.snapshot.dupes
        if d.isRunning {
            return "Verifying duplicates — \(Fmt.count(d.candidatesChecked)) of \(Fmt.count(d.candidatesTotal)) candidates · \(Fmt.bytes(d.bytesRead)) read"
        }
        let p = engine.snapshot.probe
        if p.isRunning {
            return "Reading media — \(Fmt.count(p.filesProbed)) of \(Fmt.count(p.filesToProbe))"
        }
        return "Scanning…"
    }

    // MARK: Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a drive or folder to inspect."
        if panel.runModal() == .OK, let url = panel.url { engine.scan(url) }
    }

    private func export(_ fmt: Exporter.Format) {
        exporting = true
        Task {
            do { try await Exporter.export(engine.snapshot, as: fmt) }
            catch { exportError = error.localizedDescription }
            exporting = false
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else if let u = item as? URL { url = u }
            guard let url else { return }
            DispatchQueue.main.async { engine.scan(url) }
        }
        return true
    }
}

// MARK: - Drop zone

private struct DropZone: View {
    let isTargeted: Bool
    let choose: () -> Void

    var body: some View {
        VStack(spacing: VL.Space.m) {
            Spacer()

            Image("VaultlineMark")
                .resizable().scaledToFit()
                .frame(height: 46)
                .opacity(isTargeted ? 1 : 0.8)

            VStack(spacing: VL.Space.xs) {
                Text("Drop a drive or folder here").font(VL.display(19))
                Text("Everything is scanned on this Mac. Nothing is uploaded.")
                    .font(VL.body).foregroundStyle(VL.inkDim)
            }

            Button("Choose Folder…", action: choose)
                .buttonStyle(VLPrimaryButton())
                .padding(.top, VL.Space.xs)

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
