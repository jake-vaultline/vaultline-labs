import Foundation

/// The app's configuration — identical in shape whether the user typed it or a
/// Media Nexus sent it.
///
/// That sameness is the point. Unpaired, the user owns this file. Paired, the
/// server's copy wins and this becomes a read-only cache, so a studio can push
/// one naming convention to twelve workstations instead of twelve editors each
/// inventing their own. It's the client-config idea from the build process,
/// applied at the edge.
struct IngestConfig: Codable {

    enum Source: String, Codable { case local, nexus }

    var version = 1
    var source: Source = .local

    var naming = NamingConfig()
    var destinations: [DestinationConfig] = []
    var checksum: ChecksumAlgorithm = .xxhash64
    var workflow = WorkflowConfig()
    var form = IngestFormConfig()
    /// Optional for backward compatibility with config files written before
    /// drive scan rules existed. The effective value is deliberately local and
    /// conservative: scan manually unless the user or Media Nexus opts in.
    var driveScanRules: DriveScanRules?
    var nexus = NexusConfig()
    /// Separate hosted metadata projection for Drive Passports. Optional so
    /// existing config.json files written before Drive Tags continue to decode.
    var passport: PassportConfig?

    /// True when the config came from a server and the UI should say so rather
    /// than letting someone edit a field that will silently revert.
    var isManaged: Bool { source == .nexus }

    var effectiveDriveScanRules: DriveScanRules { driveScanRules ?? DriveScanRules() }
}

/// Rules for the Relay half of the app. A pattern scopes collection tracking to
/// folders that carry a team's asset identity (for example `^JOB-[0-9]{4}$`).
/// It is a regular expression over the folder name, not its machine-specific
/// absolute path.
struct DriveScanRules: Codable, Equatable {
    var folderNamePattern = ""
    var automaticOnMount = false

    var trimmedPattern: String {
        folderNamePattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var patternIsValid: Bool {
        trimmedPattern.isEmpty || (try? NSRegularExpression(
            pattern: trimmedPattern, options: [.caseInsensitive])) != nil
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
    var verify = true
    var manifest = true
    var onCollision: CollisionPolicy = .report
    var createStructure = true

    enum CollisionPolicy: String, Codable, CaseIterable, Identifiable {
        case report, skipQuietly
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .report:       return "Flag it prominently and continue"
            case .skipQuietly:  return "Note it in the report and continue"
            }
        }
        // Deliberately no `.overwrite`. See spec §3 — there is no case where
        // silently replacing existing media is the right default, and offering
        // it as an option is how it ends up switched on before a night shoot.
        //
        // Note both options continue rather than stopping. A destination file
        // that is byte-identical isn't a collision at all — it's a resumed
        // card — and the engine tells the difference by hashing, so the only
        // thing left to decide is how loudly to report a genuine clash.
    }
}

struct NexusConfig: Codable {
    var url = ""
    var deviceName = ""
    var pairedAt: Date?
    /// Stored in the Keychain, never in the JSON. This field is transient.
    var isPaired: Bool { pairedAt != nil && !url.isEmpty }

    enum CodingKeys: String, CodingKey { case url, deviceName, pairedAt }
}

struct PassportConfig: Codable {
    var url = ""
    var deviceName = ""
    var connectedAt: Date?
    var isConnected: Bool { connectedAt != nil && !url.isEmpty }

    enum CodingKeys: String, CodingKey { case url, deviceName, connectedAt }
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

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(IngestConfig.self, from: data)
        else { return }
        config = decoded
    }

    func update(_ change: (inout IngestConfig) -> Void) {
        guard !config.isManaged else { return }   // server owns it while paired
        var c = config
        change(&c)
        config = c
        save()
    }

    /// Applied when a paired Nexus sends config down. Bypasses the managed guard
    /// because this *is* the server writing.
    func applyFromNexus(_ incoming: IngestConfig) {
        var c = incoming
        c.source = .nexus
        c.nexus = config.nexus          // keep local pairing details
        c.passport = config.passport    // separate hosted system; Nexus does not own it
        config = c
        save()
    }

    /// Passport connectivity remains locally controlled even when Media Nexus
    /// manages the ingest workflow configuration.
    func updatePassport(_ change: (inout PassportConfig) -> Void) {
        var c = config
        var p = c.passport ?? PassportConfig()
        change(&p)
        c.passport = p
        config = c
        save()
    }

    func disconnectPassport() {
        var c = config
        c.passport = nil
        config = c
        save()
    }

    func unpair() {
        var c = config
        c.source = .local
        c.nexus = NexusConfig()
        config = c
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) { try? data.write(to: url, options: .atomic) }
    }
}
