import Foundation
import AppKit
import SwiftUI
import Combine

/// Immutable evidence captured at the instant the operator starts a card.
///
/// The UI and Settings window are separate SwiftUI scenes. Without an explicit
/// snapshot, a change made while a long copy is running could make the final
/// record describe different answers or output settings than the transfer that
/// actually ran. Materializing defaults here also fixes the automatic date to
/// the start of the ingest instead of whichever day verification finishes.
struct IngestRunContext {
    let config: IngestConfig
    let answers: [UUID: String]

    init(config: IngestConfig, answers: [UUID: String], startedAt: Date = Date()) {
        self.config = config
        self.answers = Dictionary(uniqueKeysWithValues: config.form.fields.map { field in
            (field.id, answers[field.id] ?? field.resolvedDefault(on: startedAt))
        })
    }
}

/// Ties the standalone team configuration and offload engine together and owns
/// the state the UI renders. The standalone Labs utility has no Media Nexus,
/// Relay, account, telemetry, or other network client.
@MainActor
final class AppState: ObservableObject {

    let configStore: ConfigStore

    private var bag = Set<AnyCancellable>()
    private var formNamespace: String
    private var plannedNaming: NamingConfig

    /// SwiftUI does **not** observe nested ObservableObjects. A view watching
    /// `AppState` sees nothing when `configStore` publishes. Forward its changes
    /// so an imported or edited team package immediately refreshes the app.
    init() {
        let loadedConfig = ConfigStore()
        configStore = loadedConfig
        formNamespace = StickyFormAnswers.namespace(for: loadedConfig.config)
        plannedNaming = loadedConfig.config.naming
        formAnswers = StickyFormAnswers.load(config: loadedConfig.config)
        configStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
        configStore.$config
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] config in
                guard let self else { return }
                if config.naming != self.plannedNaming {
                    self.plannedNaming = config.naming
                    self.replan()
                }
                let namespace = StickyFormAnswers.namespace(for: config)
                guard namespace != self.formNamespace else { return }
                self.formNamespace = namespace
                self.formAnswers = StickyFormAnswers.load(config: config)
            }
            .store(in: &bag)
    }

    /// Answers to the configurable shoot form, keyed by field id.
    @Published var formAnswers: [UUID: String] = [:]

    /// Job folder created this session, if any — offered as a destination.
    @Published var lastConfiguredJob: ConfiguredJobBuilder.Result?

    @Published var sourceURL: URL?
    @Published var plan: [IngestFile] = []
    @Published var progress = OffloadProgress()
    @Published var results: [IngestFile] = []
    @Published private(set) var isPlanningSource = false
    @Published var isRunning = false
    @Published var message: String?

    private let engine = OffloadEngine()
    private var scopes = ScopeHolder()
    private var task: Task<Void, Never>?
    private var sourcePlanningTask: Task<Void, Never>?
    private var sourcePlanGeneration = UUID()

    var config: IngestConfig { configStore.config }

    var destinations: [Destination] {
        config.destinations.map {
            Destination(root: $0.path, label: $0.label, isPrimary: $0.isPrimary)
        }
    }

    var canStart: Bool {
        sourceURL != nil && !isPlanningSource && !plan.isEmpty && !destinations.isEmpty
            && !isRunning && missingRequired.isEmpty && invalidFields.isEmpty
            && unsafeDestinationReason == nil && unsafePlanReason == nil
    }

    /// Why Start is unavailable, in the user's terms. A disabled button with no
    /// explanation is the most common way an app feels broken.
    var blockedReason: String? {
        if isRunning { return nil }
        if sourceURL == nil { return "Choose a card or folder to ingest." }
        if isPlanningSource { return "Scanning the source…" }
        if plan.isEmpty { return "Nothing to ingest in that folder." }
        if destinations.isEmpty { return "Add at least one destination." }
        if let f = missingRequired.first {
            return missingRequired.count == 1
                ? "\(f.label) is required."
                : "\(missingRequired.count) required fields are still blank."
        }
        if let field = invalidFields.first {
            return "\(field.label) isn't valid.\(field.kind == .date ? " Use YYYY-MM-DD." : "")"
        }
        if let issue = unsafeDestinationReason { return issue }
        if let issue = unsafePlanReason { return issue }
        return nil
    }

    var plannedBytes: Int64 { plan.reduce(0) { $0 + $1.size } }

    // MARK: Source

    func chooseSource() {
        // A huge card can still be discovering files when the operator decides
        // to choose a different source. Stop that work before opening the
        // system picker; otherwise the obsolete scan needlessly competes with
        // the picker for CPU until a replacement folder is finally selected.
        let shouldResumeCurrentPlan = isPlanningSource
        if shouldResumeCurrentPlan {
            cancelSourcePlan()
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        // Camera formats such as RED's .RDC are directory packages. Treating
        // packages as folders lets an operator choose one directly instead of
        // making the system picker disable an otherwise valid source.
        panel.treatsFilePackagesAsDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose the card or folder to ingest"
        guard panel.runModal() == .OK, let url = panel.url else {
            if shouldResumeCurrentPlan, let sourceURL {
                beginSourcePlan(sourceURL)
            }
            return
        }
        setSource(url)
    }

    func setSource(_ url: URL) {
        Bookmarks.save(url)
        sourceURL = url
        results = []
        progress = OffloadProgress()
        beginSourcePlan(url)
    }

    /// Recompute the plan when naming changes, so the preview always matches
    /// what will actually be written.
    func replan() {
        guard let url = sourceURL, !isRunning else { return }
        beginSourcePlan(url)
    }

    private func beginSourcePlan(_ url: URL) {
        cancelSourcePlan()
        let generation = sourcePlanGeneration
        let naming = config.naming

        isPlanningSource = true
        plan = []
        message = nil

        sourcePlanningTask = Task { [weak self] in
            let planned = await SourcePlanner.plan(source: url, naming: naming)
            guard let self,
                  !Task.isCancelled,
                  self.sourcePlanGeneration == generation,
                  self.sourceURL?.standardizedFileURL == url.standardizedFileURL else { return }

            self.isPlanningSource = false
            self.sourcePlanningTask = nil
            guard let planned else { return }
            self.plan = planned
            self.message = planned.isEmpty ? "Nothing to ingest in that folder." : nil
        }
    }

    private func cancelSourcePlan() {
        sourcePlanningTask?.cancel()
        sourcePlanningTask = nil
        sourcePlanGeneration = UUID()
        isPlanningSource = false
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
        cancelSourcePlan()
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
        let available = scopes.open(paths: [source.path] + destinations.map(\.root))
        guard available.contains(source.path) || FileManager.default.isReadableFile(atPath: source.path) else {
            scopes.releaseAll()
            message = "Couldn't keep access to the source. Choose the card or folder again."
            return
        }
        let unavailable = destinations.filter {
            !available.contains($0.root) && !FileManager.default.isWritableFile(atPath: $0.root)
        }
        guard unavailable.isEmpty else {
            scopes.releaseAll()
            message = "No files were copied because \(unavailable.map(\.label).joined(separator: ", ")) couldn't be opened. Re-add or reconnect every destination."
            return
        }
        let usable = destinations

        if let capacityIssue = DestinationCapacity.issue(files: plan, destinations: usable) {
            scopes.releaseAll()
            message = "No files were copied. \(capacityIssue)"
            return
        }

        let run = IngestRunContext(config: config, answers: formAnswers)

        // Save the operator's configured carry-over fields before the first
        // source byte is read, so a crash or unplug during this card does not
        // erase the brief needed to resume it safely.
        StickyFormAnswers.save(run.answers, config: run.config)

        isRunning = true
        message = nil
        let files = plan
        let algorithm = run.config.checksum
        let sourceName = source.lastPathComponent

        task = Task { [weak self] in
            guard let self else { return }
            let engine = self.engine

            let (engineProgress, finished) = await engine.run(
                files: files, destinations: usable, algorithm: algorithm,
                onProgress: { p in Task { @MainActor in self.progress = p } })

            var finalProgress = engineProgress
            self.results = finished

            // Manifest last, and only over verified files. Keep the exact
            // outcome per destination so each durable text record can say
            // what actually exists beside it instead of making a blanket
            // claim about an optional output.
            var manifestReceipts: [String: IngestSidecar.ManifestReceipt] = [:]
            if run.config.workflow.manifest {
                for d in usable {
                    guard finished.contains(where: {
                        $0.destinations[d.root]?.isVerified == true
                    }) else {
                        manifestReceipts[d.root] = .notWritten("no files verified on this destination")
                        continue
                    }
                    do {
                        let url = try MHLWriter.write(
                            files: finished, destination: d,
                            algorithm: algorithm, sourceName: sourceName)
                        manifestReceipts[d.root] = .written(url.lastPathComponent)
                    } catch {
                        manifestReceipts[d.root] = .notWritten("the manifest write failed")
                        finalProgress.failures.append("Manifest → \(d.label): \(error.localizedDescription)")
                    }
                }
            } else {
                for d in usable { manifestReceipts[d.root] = .disabled }
            }

            // The human-readable record, alongside it. Plain text on purpose —
            // it outlives this app, and it's the thing someone actually reads
            // when they find the drive in three years.
            let form = run.config.form
            if form.enabled && form.writeSidecar {
                for d in usable {
                    do {
                        let body = IngestSidecar.text(
                            fields: form.fields, answers: run.answers,
                            sourceName: sourceName, destinations: usable, files: finished,
                            algorithm: algorithm, progress: finalProgress,
                            manifest: manifestReceipts[d.root]
                                ?? .notWritten("manifest outcome unavailable"))
                        _ = try IngestSidecar.write(body, to: d, name: form.sidecarName)
                    } catch {
                        finalProgress.failures.append("Ingest record → \(d.label): \(error.localizedDescription)")
                    }
                }
            }

            if !finalProgress.failures.isEmpty, finalProgress.phase == .done {
                finalProgress.phase = .failed
            }

            // Non-sticky fields clear so the next card doesn't inherit the last
            // card's reel number or notes.
            for f in self.config.form.fields where !f.sticky {
                self.formAnswers[f.id] = ""
            }

            self.scopes.releaseAll()
            self.progress = finalProgress
            self.isRunning = false
            self.task = nil
            self.message = Self.summary(finalProgress, destinations: usable.count)
        }
    }

    static func summary(_ p: OffloadProgress, destinations: Int) -> String {
        let d = "\(destinations) destination\(destinations == 1 ? "" : "s")"
        let files = F.quantity(p.filesVerified, singular: "file")
        if p.phase == .cancelled {
            let verb = p.filesVerified == 1 ? "was" : "were"
            return "Stopped safely — \(files) \(verb) fully verified on \(d). Incomplete staging was removed; re-run the card to continue."
        }
        if !p.hasProblems {
            var s = "Done — \(files) verified on \(d)."
            if p.filesAlreadyPresent > 0 {
                let verb = p.filesAlreadyPresent == 1 ? "was" : "were"
                s += " \(F.count(p.filesAlreadyPresent)) \(verb) already there and matched, so nothing was rewritten."
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
        message = "Stopping safely after the current disk operation…"
    }

    // MARK: Form

    func answer(_ field: IngestFormField) -> Binding<String> {
        Binding(
            get: { self.formAnswers[field.id] ?? field.resolvedDefault() },
            set: { self.formAnswers[field.id] = $0 })
    }

    /// Required fields that are still blank. Blocks Start, because a form that
    /// can be skipped silently is a form nobody fills in.
    var missingRequired: [IngestFormField] {
        guard config.form.enabled else { return [] }
        return config.form.fields.filter {
            $0.required && (formAnswers[$0.id] ?? $0.resolvedDefault())
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var invalidFields: [IngestFormField] {
        guard config.form.enabled else { return [] }
        return config.form.fields.filter {
            let value = formAnswers[$0.id] ?? $0.resolvedDefault()
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.isValid(answer: value)
        }
    }

    func isInvalid(_ field: IngestFormField) -> Bool {
        invalidFields.contains(where: { $0.id == field.id })
    }

    var unsafeDestinationReason: String? {
        guard let sourceURL else { return nil }
        return IngestPathSafety.issue(source: sourceURL, destinations: destinations)
    }

    var unsafePlanReason: String? {
        IngestPlanSafety.issue(files: plan, destinations: destinations)
    }

    var workflowValues: WorkflowTemplate.Values {
        var values: [String: String] = [:]
        var workflowDate = Date()
        for field in config.form.fields {
            guard let token = field.token, !token.isEmpty else { continue }
            let answer = formAnswers[field.id] ?? field.resolvedDefault()
            values[token] = answer
            if field.kind == .date, let parsed = field.dateValue(from: answer),
               token.lowercased() == "shootdate" {
                workflowDate = parsed
            }
        }
        return WorkflowTemplate.Values(fields: values, date: workflowDate)
    }

    // MARK: Jobs

    /// Creates one configured team job and makes its media landing folder the
    /// active ingest destination. Existing folders and project files are never
    /// replaced; template collisions are surfaced as a blocking error.
    func createConfiguredJob(workflow: IngestWorkflowPreset, in selectedRoot: URL) {
        // A failed second attempt must not inherit the success result from a
        // prior job and cause the sheet to dismiss as though creation worked.
        lastConfiguredJob = nil
        let jobScope = ScopeHolder()
        do {
            guard jobScope.open(paths: [selectedRoot.path]).contains(selectedRoot.path) else {
                throw TeamConfigurationError.invalidWorkflow("Choose the destination once to grant this app access.")
            }
            defer { jobScope.releaseAll() }
            let plan = try ConfiguredJobPlan.make(
                workflow: workflow, selectedRoot: selectedRoot, values: workflowValues)
            if let sourceURL, let issue = IngestPathSafety.issue(
                source: sourceURL,
                destinations: [Destination(
                    root: plan.mediaRoot.path,
                    label: "The configured job",
                    isPrimary: true)]) {
                throw TeamConfigurationError.invalidWorkflow(issue)
            }
            let result = try ConfiguredJobBuilder.create(plan)
            lastConfiguredJob = result
            Bookmarks.save(selectedRoot)
            // The destination list stores the exact media landing folder. Save
            // a bookmark for that exact path so a quit/relaunch does not turn a
            // configured job into an inaccessible stale destination.
            Bookmarks.save(plan.mediaRoot)
            configStore.update { c in
                c.destinations.removeAll()
                c.destinations.append(DestinationConfig(
                    path: plan.mediaRoot.path,
                    label: "\(workflow.name) · \(plan.jobName)",
                    isPrimary: true))
            }
            message = "Created \(plan.jobName). Media will land in \(workflow.mediaFolder). \(result.projectNote)"
        } catch {
            message = "Couldn't create the configured job: \(error.localizedDescription)"
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

}
