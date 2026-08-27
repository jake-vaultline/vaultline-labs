import Foundation
import AppKit
import SwiftUI
import Combine

/// Ties config, the offload engine and the Nexus client together, and owns the
/// state the UI renders.
@MainActor
final class AppState: ObservableObject {

    let configStore: ConfigStore
    let nexus: NexusClient
    let passports: DrivePassportClient
    let volumes: VolumeMonitor

    private var bag = Set<AnyCancellable>()

    /// SwiftUI does **not** observe nested ObservableObjects. A view watching
    /// `AppState` sees nothing when `configStore`, `volumes`, `nexus` or the
    /// network log publishes — the drive list would sit stale, settings changes
    /// wouldn't take, the request log would never appear.
    ///
    /// Forwarding each child's `objectWillChange` is the fix. Every child must
    /// be listed here; adding one and forgetting this is a silent, confusing bug.
    init() {
        let loadedConfig = ConfigStore()
        configStore = loadedConfig
        nexus = NexusClient()
        passports = DrivePassportClient(log: nexus.log)
        volumes = VolumeMonitor(rules: loadedConfig.config.effectiveDriveScanRules)

        for child in [
            configStore.objectWillChange.eraseToAnyPublisher(),
            volumes.objectWillChange.eraseToAnyPublisher(),
            nexus.objectWillChange.eraseToAnyPublisher(),
            passports.objectWillChange.eraseToAnyPublisher(),
            nexus.log.objectWillChange.eraseToAnyPublisher()
        ] {
            child
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &bag)
        }

        passports.$completedOutboxSync
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                self?.volumes.recordPassport(
                    volumeID: event.volumeID, driveID: event.driveID,
                    syncedAt: event.syncedAt,
                    state: event.tagPaired ? "paired" : "synced")
            }
            .store(in: &bag)

        configStore.$config
            .map(\.effectiveDriveScanRules)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] rules in self?.volumes.updateScanRules(rules) }
            .store(in: &bag)

        volumes.onScanCompleted = { [weak self] volume in
            guard let self, self.config.nexus.isPaired else { return }
            Task { await self.reportScannedVolume(volume) }
        }
    }

    /// Which half of the app is on screen. Drives is the standing view — the
    /// thing that's useful on a day when nothing is being ingested.
    @Published var section: Section = .drives
    enum Section: String, CaseIterable, Identifiable {
        case drives, ingest
        var id: String { rawValue }
        var title: String { self == .drives ? "Drives" : "Ingest" }
    }

    /// Answers to the configurable shoot form, keyed by field id.
    @Published var formAnswers: [UUID: String] = [:]

    /// Job folder created this session, if any — offered as a destination.
    @Published var lastJob: StructureBuilder.Result?

    @Published var sourceURL: URL?
    @Published var plan: [IngestFile] = []
    @Published var progress = OffloadProgress()
    @Published var results: [IngestFile] = []
    @Published var isRunning = false
    @Published var message: String?

    /// Set when an install command hands us pairing details via URL scheme.
    @Published var pendingPairing: (url: String, code: String)?

    struct PassportPrompt: Identifiable {
        let id = UUID()
        let volumeName: String
        let code: String
        let expiresAt: String
        let serviceURL: String
    }
    @Published var passportPrompt: PassportPrompt?

    struct DriveIdentityPrompt: Identifiable {
        let id = UUID()
        let review: DrivePassportClient.DriveIdentityReview
    }
    @Published var driveIdentityPrompt: DriveIdentityPrompt?

    private let engine = OffloadEngine()
    private var scopes = ScopeHolder()
    private var task: Task<Void, Never>?

    var config: IngestConfig { configStore.config }

    var destinations: [Destination] {
        config.destinations.map {
            Destination(root: $0.path, label: $0.label, isPrimary: $0.isPrimary)
        }
    }

    var canStart: Bool {
        sourceURL != nil && !plan.isEmpty && !destinations.isEmpty
            && !isRunning && missingRequired.isEmpty
    }

    /// Why Start is unavailable, in the user's terms. A disabled button with no
    /// explanation is the most common way an app feels broken.
    var blockedReason: String? {
        if isRunning { return nil }
        if sourceURL == nil { return "Choose a card or folder to ingest." }
        if plan.isEmpty { return "Nothing to ingest in that folder." }
        if destinations.isEmpty { return "Add at least one destination." }
        if let f = missingRequired.first {
            return missingRequired.count == 1
                ? "\(f.label) is required."
                : "\(missingRequired.count) required fields are still blank."
        }
        return nil
    }

    var plannedBytes: Int64 { plan.reduce(0) { $0 + $1.size } }

    var copyFindings: [DriveCopyFinding] {
        DriveCopyAnalyzer.findings(in: volumes.volumes)
    }

    private func reportScannedVolume(_ volume: KnownVolume) async {
        guard let snapshot = volume.snapshot else { return }
        let collections = (snapshot.collections ?? [:]).values.map { collection in
            [
                "name": collection.name,
                "relativePath": collection.relativePath,
                "fileCount": collection.fileCount,
                "totalBytes": collection.totalBytes,
                "inventoryFingerprint": collection.inventoryFingerprint,
            ] as [String: Any]
        }
        let payload: [String: Any] = [
            "volumeID": volume.id,
            "volumeUUID": volume.volumeUUID ?? NSNull(),
            "name": volume.name,
            "totalBytes": volume.totalBytes,
            "freeBytes": volume.freeBytes,
            "scannedAt": ISO8601DateFormatter().string(from: snapshot.takenAt),
            "fileCount": snapshot.fileCount,
            "collections": collections,
        ]
        do {
            try await nexus.reportVolumes(config.nexus, volumes: [payload])
        } catch {
            message = "Drive scan stayed local; Media Nexus sync failed: \(error.localizedDescription)"
        }
    }

    // MARK: Source

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose the card or folder to ingest"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setSource(url)
    }

    func setSource(_ url: URL) {
        section = .ingest
        sourceURL = url
        results = []
        progress = OffloadProgress()
        plan = OffloadEngine.plan(source: url, naming: config.naming)
        message = plan.isEmpty ? "Nothing to ingest in that folder." : nil
    }

    /// Recompute the plan when naming changes, so the preview always matches
    /// what will actually be written.
    func replan() {
        guard let url = sourceURL else { return }
        plan = OffloadEngine.plan(source: url, naming: config.naming)
    }

    /// A struct, not a labelled tuple — Swift has no key paths into tuple
    /// components, so `ForEach(…, id: \.from)` over tuples doesn't compile.
    struct RenamePreview: Identifiable {
        var id: String { from }
        let from: String
        let to: String
    }

    var renamePreview: [RenamePreview] {
        plan.filter(\.wasRenamed).prefix(6).map { RenamePreview(from: $0.originalName, to: $0.newName) }
    }

    /// Clears the last card without touching destinations or settings — the
    /// common case is another card into the same job.
    func reset() {
        sourceURL = nil
        plan = []
        results = []
        progress = OffloadProgress()
        message = nil
    }

    func addDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        panel.message = "Choose a destination for the footage"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Bookmarks.save(url)
        configStore.update { c in
            guard !c.destinations.contains(where: { $0.path == url.path }) else { return }
            c.destinations.append(DestinationConfig(
                path: url.path,
                label: url.lastPathComponent,
                isPrimary: c.destinations.isEmpty))
        }
    }

    func removeDestination(_ path: String) {
        Bookmarks.remove(path: path)
        configStore.update { $0.destinations.removeAll { $0.path == path } }
    }

    // MARK: Run

    func start() {
        guard canStart, let source = sourceURL else { return }

        // Open every destination's security scope up front and keep it open for
        // the whole offload. Losing write access mid-card is not recoverable.
        scopes.releaseAll()
        scopes = ScopeHolder()
        let available = scopes.open(paths: destinations.map(\.root))
        let usable = destinations.filter { available.contains($0.root) || FileManager.default.isWritableFile(atPath: $0.root) }

        guard !usable.isEmpty else {
            message = "Couldn't get write access to any destination. Re-add them in Settings."
            return
        }

        isRunning = true
        message = nil
        let files = plan
        let algorithm = config.checksum
        let sourceName = source.lastPathComponent

        task = Task { [weak self] in
            guard let self else { return }
            let engine = self.engine

            let (finalProgress, finished) = await engine.run(
                files: files, destinations: usable, algorithm: algorithm,
                onProgress: { p in Task { @MainActor in self.progress = p } })

            self.progress = finalProgress
            self.results = finished
            self.isRunning = false

            // Manifest last, and only over verified files.
            if self.config.workflow.manifest {
                for d in usable {
                    _ = try? MHLWriter.write(files: finished, destination: d,
                                             algorithm: algorithm, sourceName: sourceName)
                }
            }

            // The human-readable record, alongside it. Plain text on purpose —
            // it outlives this app, and it's the thing someone actually reads
            // when they find the drive in three years.
            let form = self.config.form
            let ingestContext = form.fields.compactMap { field -> NexusClient.IngestContextValue? in
                let value = (self.formAnswers[field.id] ?? field.defaultValue)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                return NexusClient.IngestContextValue(
                    fieldID: field.id, label: field.label, kind: field.kind, value: value)
            }
            if form.enabled && form.writeSidecar {
                let body = IngestSidecar.text(
                    fields: form.fields, answers: self.formAnswers,
                    sourceName: sourceName, destinations: usable, files: finished,
                    algorithm: algorithm, progress: finalProgress)
                for d in usable {
                    _ = try? IngestSidecar.write(body, to: d, name: form.sidecarName)
                }
            }

            // Non-sticky fields clear so the next card doesn't inherit the last
            // card's reel number or notes.
            for f in form.fields where !f.sticky { self.formAnswers[f.id] = "" }

            if self.config.nexus.isPaired {
                try? await self.nexus.reportIngest(self.config.nexus,
                                                   sourceName: sourceName,
                                                   files: finished,
                                                   destinations: usable,
                                                   context: form.enabled ? ingestContext : [])
            }

            self.scopes.releaseAll()
            self.message = Self.summary(finalProgress, destinations: usable.count)
        }
    }

    private static func summary(_ p: OffloadProgress, destinations: Int) -> String {
        let d = "\(destinations) destination\(destinations == 1 ? "" : "s")"
        if !p.hasProblems {
            var s = "Done — \(p.filesVerified) files verified on \(d)."
            if p.filesAlreadyPresent > 0 {
                s += " \(p.filesAlreadyPresent) were already there and matched, so nothing was rewritten."
            }
            return s
        }
        var parts: [String] = []
        if !p.conflicts.isEmpty { parts.append("\(p.conflicts.count) name clash\(p.conflicts.count == 1 ? "" : "es")") }
        if !p.failures.isEmpty  { parts.append("\(p.failures.count) failure\(p.failures.count == 1 ? "" : "s")") }
        return "Finished with \(parts.joined(separator: " and ")). Nothing was deleted or overwritten — the card is untouched."
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        scopes.releaseAll()
        message = "Stopped. Files already verified are fine; the rest were not copied."
    }

    // MARK: Form

    func answer(_ field: IngestFormField) -> Binding<String> {
        Binding(
            get: { self.formAnswers[field.id] ?? field.defaultValue },
            set: { self.formAnswers[field.id] = $0 })
    }

    /// Required fields that are still blank. Blocks Start, because a form that
    /// can be skipped silently is a form nobody fills in.
    var missingRequired: [IngestFormField] {
        guard config.form.enabled else { return [] }
        return config.form.fields.filter {
            $0.required && (formAnswers[$0.id] ?? $0.defaultValue)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: Jobs

    /// Creates a folder tree for a new job and offers its shoot folder as a
    /// destination. This is the step that happens *before* the card goes in,
    /// which is where structure normally goes wrong.
    func createJob(template: StructureBuilder.Template, title: String, in parent: URL) {
        let name = StructureBuilder.jobName(naming: config.naming, jobTitle: title)
        do {
            let result = try StructureBuilder.create(template: template, jobName: name, in: parent)
            lastJob = result

            let target = StructureBuilder.suggestedIngestFolder(in: result.jobRoot, template: template)
            Bookmarks.save(parent)
            Bookmarks.save(result.jobRoot)
            configStore.update { c in
                guard !c.destinations.contains(where: { $0.path == target.path }) else { return }
                c.destinations.insert(DestinationConfig(
                    path: target.path,
                    label: result.jobRoot.lastPathComponent,
                    isPrimary: c.destinations.isEmpty), at: 0)
            }

            let made = result.created.count
            message = made > 0
                ? "Created \(name) — \(made) folders. Camera media will land in \(target.lastPathComponent)."
                : "\(name) already existed. Nothing was changed."
        } catch {
            message = "Couldn't create the job folder: \(error.localizedDescription)"
        }
    }

    // MARK: Results

    struct FileOutcome: Identifiable {
        var id: String { file.id }
        let file: IngestFile
        let verified: Int
        let problems: Int
        var isClean: Bool { problems == 0 && verified > 0 }
    }

    var outcomes: [FileOutcome] {
        results.map { f in
            let v = f.destinations.values.filter(\.isVerified).count
            let p = f.destinations.values.filter(\.isProblem).count
            return FileOutcome(file: f, verified: v, problems: p)
        }
        // Problems first — the point of a results list is the exceptions.
        .sorted { ($0.problems > 0 ? 0 : 1, $0.file.relativePath) < ($1.problems > 0 ? 0 : 1, $1.file.relativePath) }
    }

    // MARK: Pairing

    func handleURL(_ url: URL) {
        // vaultline-ingest://pair?url=https://nexus.studio.local&code=ABC123
        guard url.scheme == "vaultline-ingest", url.host == "pair",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let items = comps.queryItems ?? []
        let nexusURL = items.first { $0.name == "url" }?.value ?? ""
        let code = items.first { $0.name == "code" }?.value ?? ""
        guard !nexusURL.isEmpty else { return }
        pendingPairing = (nexusURL, code)
    }

    func pair(url: String, code: String) async {
        do {
            let result = try await nexus.pair(urlString: url, code: code,
                                              deviceName: Host.current().localizedName ?? "Mac")
            configStore.update { c in
                c.nexus.url = url
                c.nexus.deviceName = result.deviceName
                c.nexus.pairedAt = Date()
            }
            if let remote = try? await nexus.fetchConfig(configStore.config.nexus) {
                configStore.applyFromNexus(remote)
            }
            message = "Paired with \(result.serverName). Settings are now managed by your Media Nexus."
            pendingPairing = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func unpair() {
        nexus.unpair(urlString: config.nexus.url)
        configStore.unpair()
        message = "Unpaired. Settings are yours again."
    }

    // MARK: Drive Passports

    func connectPassports(url: String, code: String) async {
        do {
            let result = try await passports.connect(
                urlString: url, code: code,
                deviceName: Host.current().localizedName ?? "Mac")
            configStore.updatePassport { p in
                p.url = url
                p.deviceName = result.deviceID
                p.connectedAt = Date()
            }
            message = "Connected to \(result.workspaceName). Scan a drive, then create its Drive Passport."
        } catch {
            message = error.localizedDescription
        }
    }

    func disconnectPassports() {
        if let p = config.passport { passports.disconnect(urlString: p.url) }
        configStore.disconnectPassport()
        message = "Drive Passports disconnected. Local drive history is unchanged."
    }

    func preparePassport(_ volume: KnownVolume, createPairing: Bool? = nil,
                         identityResolution: DrivePassportClient.IdentityResolution? = nil) async {
        guard let config = config.passport, config.isConnected else {
            message = "Connect Drive Passports in Settings first."
            return
        }
        do {
            let wantsPairing = createPairing ?? (volume.passportDriveID == nil)
            let result = try await passports.preparePassport(
                config: config, volume: volume, createPairing: wantsPairing,
                identityResolution: identityResolution)
            let syncState: String
            if !result.snapshotSynced { syncState = "pending" }
            else if result.tagPaired { syncState = "paired" }
            else if result.pairing != nil { syncState = "awaiting_tag" }
            else { syncState = "synced" }
            volumes.recordPassport(volumeID: volume.id, driveID: result.driveID,
                                   syncedAt: result.snapshotSynced ? Date() : volume.passportLastSyncedAt,
                                   state: syncState)
            if let pairing = result.pairing {
                passportPrompt = PassportPrompt(
                    volumeName: volume.name, code: pairing.code,
                    expiresAt: pairing.expiresAt, serviceURL: config.url)
            } else if result.snapshotSynced {
                message = result.tagPaired
                    ? "Drive Passport refreshed. The physical tag is attached."
                    : "Drive Passport refreshed."
            } else {
                message = "Snapshot saved locally and queued. Drive Passports will retry automatically when connectivity returns."
            }
        } catch PassportError.identityReview(let review) {
            driveIdentityPrompt = DriveIdentityPrompt(review: review)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func resolveDriveIdentity(_ prompt: DriveIdentityPrompt,
                              resolution: DrivePassportClient.IdentityResolution) async {
        guard let volume = volumes.volumes.first(where: { $0.id == prompt.review.volumeID }) else {
            driveIdentityPrompt = nil
            message = "That drive is no longer in the local registry. Reconnect it and scan again."
            return
        }
        driveIdentityPrompt = nil
        await preparePassport(volume, createPairing: true, identityResolution: resolution)
    }
}
