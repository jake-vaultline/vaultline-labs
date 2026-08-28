import Foundation

/// Local configuration for the standalone Labs utility. `team` is the portable
/// customization layer; local destinations and bookmarks stay on this Mac.
struct IngestConfig: Codable {
    var version = 1
    var naming = NamingConfig()
    var destinations: [DestinationConfig] = []
    var checksum: ChecksumAlgorithm = .xxhash64
    var workflow = WorkflowConfig()
    var form = IngestFormConfig()
    /// Optional keeps pre-VLP-415 config files decodable. `effectiveTeam`
    /// supplies the excellent standalone default until the normalized config
    /// is saved.
    var team: TeamConfiguration?
    /// Retained as a UI compatibility seam while old managed-state branches are
    /// removed. Standalone team configurations are always locally editable.
    var isManaged: Bool { false }

    var effectiveTeam: TeamConfiguration { team ?? TeamConfiguration() }

    mutating func normalizeForStandalone() {
        version = max(version, 2)
        if team == nil { team = TeamConfiguration() }
        if form.fields.isEmpty || form.fields.allSatisfy({ $0.token == nil }) {
            form = IngestFormConfig()
        }
    }
}

struct NamingConfig: Codable {
    /// e.g. `{code}_{date:yyyyMMdd}_{reel}_{seq:0000}`
    var fileTemplate = ""
    var folderTemplate = ""
    var separator = "_"
    /// Applies to the destination copies only. The source card is never touched,
    /// so a rename you dislike costs a re-ingest, never the original.
    var renameOnIngest = false
    /// Fills `{code}` — the project or client code for the current job.
    var projectCode = ""
    var learnedFrom: String?      // where the wizard inferred this from
    var consistencyAtLearn: Double?
}

struct DestinationConfig: Codable, Identifiable {
    var id: String { path }
    var path: String
    var label: String
    var isPrimary: Bool = false
}

struct WorkflowConfig: Codable {
    var manifest = true
}

// MARK: - Store

@MainActor
final class ConfigStore: ObservableObject {

    @Published private(set) var config = IngestConfig()

    private let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Vaultline Ingest", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("config.json")
    }()

    init() {
        load()
        var normalized = config
        normalized.normalizeForStandalone()
        config = normalized
        save()
    }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(IngestConfig.self, from: data)
        else { return }
        config = decoded
    }

    func update(_ change: (inout IngestConfig) -> Void) {
        var c = config
        change(&c)
        c.normalizeForStandalone()
        config = c
        save()
    }

    func exportTeamConfiguration(to destination: URL) throws {
        let package = try TeamConfigurationPackage(
            team: try config.effectiveTeam.validated(), form: config.form,
            naming: config.naming, checksum: config.checksum, workflow: config.workflow).validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(package).write(to: destination, options: .atomic)
    }

    func importTeamConfiguration(from source: URL) throws {
        let data = try Data(contentsOf: source)
        let package = try JSONDecoder().decode(TeamConfigurationPackage.self, from: data).validated()
        let team = package.team
        var c = config
        c.team = team
        c.form = package.form
        c.naming = package.naming
        c.checksum = package.checksum
        c.workflow = package.workflow
        c.normalizeForStandalone()
        config = c
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) { try? data.write(to: url, options: .atomic) }
    }
}
