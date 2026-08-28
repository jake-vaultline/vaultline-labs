import Foundation

/// The bounded customization surface Vaultline configures for a media team.
/// One app binary reads this data; client workflows never require source forks,
/// account state, or a network connection.
struct TeamConfiguration: Codable, Equatable {
    var schemaVersion = 1
    var teamName = "Your team"
    var workflows: [IngestWorkflowPreset] = [.standard]

    static let currentSchemaVersion = 1

    func validated() throws -> TeamConfiguration {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw TeamConfigurationError.unsupportedVersion(schemaVersion)
        }
        guard !workflows.isEmpty else { throw TeamConfigurationError.noWorkflows }
        guard !teamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TeamConfigurationError.invalidWorkflow("The configuration is missing its team name.")
        }
        var ids = Set<String>()
        for workflow in workflows {
            guard ids.insert(workflow.id).inserted else {
                throw TeamConfigurationError.duplicateWorkflow(workflow.id)
            }
            try workflow.validate()
        }
        return self
    }
}

struct IngestWorkflowPreset: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var detail: String
    /// Optional configured volume/folder root. The operator can choose another
    /// root at ingest time without changing the workflow.
    var destinationRoot: String?
    /// Fixed path under the selected root, e.g. `01 Shoots`.
    var parentSubpath: String
    /// The job folder itself, e.g. `{date:yyMMdd}_{project}`.
    var jobNameTemplate: String
    var folders: [String]
    /// Media copies land here under the job root.
    var mediaFolder: String
    /// Optional real project template supplied by the team. The app copies it;
    /// it never fabricates an undocumented Premiere project file.
    var projectTemplatePath: String?
    /// Portable builds embed the exact client-supplied template bytes so the
    /// imported package does not depend on another machine's absolute path.
    var projectTemplateBase64: String?
    var projectFolder: String?
    var projectNameTemplate: String?

    static let standard = IngestWorkflowPreset(
        id: "standard-shoot",
        name: "Standard shoot",
        detail: "Creates a dated shoot, keeps camera originals separate from edit work, and prepares a Premiere project folder.",
        destinationRoot: nil,
        parentSubpath: "01 Shoots",
        jobNameTemplate: "{date:yyMMdd}_{project}",
        folders: [
            "01_Media/Camera", "01_Media/Audio", "01_Media/Stills",
            "02_Edit/Premiere", "02_Edit/Proxies", "02_Edit/Graphics",
            "02_Edit/Music", "02_Edit/VO", "03_Exports", "04_Documents"
        ],
        mediaFolder: "01_Media/Camera",
        projectTemplatePath: nil,
        projectTemplateBase64: nil,
        projectFolder: "02_Edit/Premiere",
        projectNameTemplate: "{date:yyMMdd}_{project}.prproj")

    func validate() throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TeamConfigurationError.invalidWorkflow("A workflow is missing its id.")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TeamConfigurationError.invalidWorkflow("Workflow \(id) is missing its name.")
        }
        guard !jobNameTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TeamConfigurationError.invalidWorkflow("\(name) is missing a job-name template.")
        }
        for path in [parentSubpath, mediaFolder] + folders + [projectFolder].compactMap({ $0 }) {
            try WorkflowPath.validateRelative(path, context: name)
        }
        let folderSet = Set(folders.map(WorkflowPath.normalized))
        guard folderSet.count == folders.count else {
            throw TeamConfigurationError.invalidWorkflow("\(name)'s folder structure contains a duplicate path.")
        }
        guard folderSet.contains(WorkflowPath.normalized(mediaFolder)) else {
            throw TeamConfigurationError.invalidWorkflow("\(name)'s media folder is not present in its folder structure.")
        }
        if let projectFolder, !folderSet.contains(WorkflowPath.normalized(projectFolder)) {
            throw TeamConfigurationError.invalidWorkflow("\(name)'s project folder is not present in its folder structure.")
        }
        if let destinationRoot, !destinationRoot.isEmpty,
           !(destinationRoot as NSString).isAbsolutePath {
            throw TeamConfigurationError.invalidWorkflow("\(name)'s suggested destination root must be an absolute path.")
        }
        let hasPathTemplate = !(projectTemplatePath?.isEmpty ?? true)
        let hasEmbeddedTemplate = !(projectTemplateBase64?.isEmpty ?? true)
        guard !(hasPathTemplate && hasEmbeddedTemplate) else {
            throw TeamConfigurationError.invalidWorkflow("\(name) must configure either a local project template path or embedded template data, not both.")
        }
        if hasPathTemplate || hasEmbeddedTemplate {
            guard projectFolder != nil, let projectNameTemplate,
                  projectNameTemplate.lowercased().hasSuffix(".prproj") else {
                throw TeamConfigurationError.invalidWorkflow("\(name)'s project template needs a project folder and a .prproj output name.")
            }
        }
        if let projectTemplatePath, !projectTemplatePath.isEmpty {
            guard URL(fileURLWithPath: projectTemplatePath).pathExtension.lowercased() == "prproj" else {
                throw TeamConfigurationError.invalidWorkflow("\(name)'s source project template must be a .prproj file.")
            }
            guard FileManager.default.fileExists(atPath: projectTemplatePath) else {
                throw TeamConfigurationError.projectTemplateMissing(projectTemplatePath)
            }
        }
        if let projectTemplateBase64, !projectTemplateBase64.isEmpty,
           Data(base64Encoded: projectTemplateBase64)?.isEmpty != false {
            throw TeamConfigurationError.invalidWorkflow("\(name)'s embedded project template is not valid non-empty base64 data.")
        }
    }
}

enum TeamConfigurationError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case noWorkflows
    case duplicateWorkflow(String)
    case invalidWorkflow(String)
    case unresolvedToken(String)
    case invalidPath(String)
    case projectTemplateMissing(String)
    case projectTemplateCollision(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "This configuration uses unsupported schema version \(version)."
        case .noWorkflows: return "The configuration must contain at least one ingest workflow."
        case .duplicateWorkflow(let id): return "More than one workflow uses id \(id)."
        case .invalidWorkflow(let message): return message
        case .unresolvedToken(let token): return "Fill in \(token) before creating the job."
        case .invalidPath(let path): return "The configured path is not safe: \(path)"
        case .projectTemplateMissing(let path): return "The configured project template is missing: \(path)"
        case .projectTemplateCollision(let path): return "A project file already exists and was left untouched: \(path)"
        }
    }
}

enum WorkflowPath {
    static func normalized(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init).joined(separator: "/")
    }

    static func validateRelative(_ path: String, context: String = "workflow") throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
            throw TeamConfigurationError.invalidPath("\(context): \(path)")
        }
        let components = trimmed.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
        guard !components.contains(".."), !components.contains("."),
              !components.contains(where: { $0.contains(":") }) else {
            throw TeamConfigurationError.invalidPath("\(context): \(path)")
        }
    }

    static func validateFilename(_ name: String, context: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == (trimmed as NSString).lastPathComponent,
              trimmed != ".", trimmed != "..", !trimmed.contains("\\"), !trimmed.contains(":") else {
            throw TeamConfigurationError.invalidPath("\(context): \(name)")
        }
    }
}

enum WorkflowTemplate {
    struct Values {
        var fields: [String: String] = [:]
        var date = Date()
    }

    /// Renders arbitrary team field tokens plus `{date}` / `{date:format}`.
    /// Every referenced field must be present: silently collapsing a job number
    /// is how media lands in the wrong job.
    static func render(_ template: String, values: Values) throws -> String {
        let expression = try NSRegularExpression(pattern: #"\{([a-zA-Z][a-zA-Z0-9]*)(?::([^}]+))?\}"#)
        let ns = template as NSString
        var output = template
        for match in expression.matches(in: template, range: NSRange(location: 0, length: ns.length)).reversed() {
            let rawRange = match.range(at: 0)
            let token = ns.substring(with: match.range(at: 1))
            let detail = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
            let replacement: String
            if token.lowercased() == "date" {
                let formatter = DateFormatter()
                formatter.dateFormat = detail.isEmpty ? "yyMMdd" : detail
                replacement = formatter.string(from: values.date)
            } else {
                let value = values.fields[token]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !value.isEmpty else { throw TeamConfigurationError.unresolvedToken(token) }
                replacement = value
            }
            output = (output as NSString).replacingCharacters(in: rawRange, with: sanitizeComponent(replacement))
        }
        let unresolved = output.contains("{") || output.contains("}")
        guard !unresolved else { throw TeamConfigurationError.invalidPath(output) }
        let sanitized = sanitizeComponent(output).trimmingCharacters(in: CharacterSet(charactersIn: "_-. "))
        guard !sanitized.isEmpty, sanitized != ".", sanitized != ".." else {
            throw TeamConfigurationError.invalidPath(output)
        }
        return sanitized
    }

    static func referencedTokens(in template: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: #"\{([a-zA-Z][a-zA-Z0-9]*)(?::([^}]+))?\}"#)
        let ns = template as NSString
        let matches = expression.matches(in: template, range: NSRange(location: 0, length: ns.length))
        var remainder = template
        for match in matches.reversed() {
            remainder = (remainder as NSString).replacingCharacters(in: match.range(at: 0), with: "")
        }
        guard !remainder.contains("{"), !remainder.contains("}") else {
            throw TeamConfigurationError.invalidPath(template)
        }
        return matches.map { ns.substring(with: $0.range(at: 1)) }
    }

    private static func sanitizeComponent(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        return value.components(separatedBy: forbidden).joined(separator: "-")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}

struct ConfiguredJobPlan: Equatable {
    let workflow: IngestWorkflowPreset
    let selectedRoot: URL
    let parent: URL
    let jobName: String
    let jobRoot: URL
    let mediaRoot: URL
    let projectURL: URL?

    static func make(workflow: IngestWorkflowPreset,
                     selectedRoot: URL,
                     values: WorkflowTemplate.Values) throws -> ConfiguredJobPlan {
        try workflow.validate()
        let jobName = try WorkflowTemplate.render(workflow.jobNameTemplate, values: values)
        let parent = workflow.parentSubpath.isEmpty
            ? selectedRoot
            : selectedRoot.appendingPathComponent(WorkflowPath.normalized(workflow.parentSubpath), isDirectory: true)
        let jobRoot = parent.appendingPathComponent(jobName, isDirectory: true)
        let mediaRoot = jobRoot.appendingPathComponent(WorkflowPath.normalized(workflow.mediaFolder), isDirectory: true)
        let projectURL: URL?
        if let folder = workflow.projectFolder, let nameTemplate = workflow.projectNameTemplate {
            let rendered = try WorkflowTemplate.render(nameTemplate, values: values)
            projectURL = jobRoot.appendingPathComponent(WorkflowPath.normalized(folder), isDirectory: true)
                .appendingPathComponent(rendered, isDirectory: false)
        } else {
            projectURL = nil
        }
        return ConfiguredJobPlan(workflow: workflow, selectedRoot: selectedRoot, parent: parent,
                                 jobName: jobName, jobRoot: jobRoot, mediaRoot: mediaRoot,
                                 projectURL: projectURL)
    }
}

enum ConfiguredJobBuilder {
    struct Result {
        let plan: ConfiguredJobPlan
        var created: [String]
        var alreadyExisted: [String]
        var projectCreated: Bool
        var projectNote: String
    }

    static func create(_ plan: ConfiguredJobPlan, fileManager: FileManager = .default) throws -> Result {
        guard DestinationPathSafety.contains(plan.jobRoot, under: plan.selectedRoot) else {
            throw TeamConfigurationError.invalidPath(
                "A linked folder would create \(plan.jobName) outside the selected destination.")
        }
        for relative in plan.workflow.folders {
            let target = plan.jobRoot.appendingPathComponent(
                WorkflowPath.normalized(relative), isDirectory: true)
            guard DestinationPathSafety.contains(target, under: plan.jobRoot) else {
                throw TeamConfigurationError.invalidPath(
                    "A linked folder would create \(relative) outside the configured job.")
            }
        }

        // Preflight the only file creation before making any directories, so a
        // missing template or collision leaves the destination entirely alone.
        if let destination = plan.projectURL,
           plan.workflow.projectTemplatePath != nil || plan.workflow.projectTemplateBase64 != nil {
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw TeamConfigurationError.projectTemplateCollision(destination.path)
            }
        }
        if let sourcePath = plan.workflow.projectTemplatePath,
           !fileManager.fileExists(atPath: sourcePath) {
            throw TeamConfigurationError.projectTemplateMissing(sourcePath)
        }

        var created: [String] = []
        var existing: [String] = []
        for relative in [""] + plan.workflow.folders {
            let url = relative.isEmpty ? plan.jobRoot : plan.jobRoot.appendingPathComponent(WorkflowPath.normalized(relative), isDirectory: true)
            if fileManager.fileExists(atPath: url.path) {
                existing.append(relative.isEmpty ? plan.jobName : relative)
            } else {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                created.append(relative.isEmpty ? plan.jobName : relative)
            }
        }

        var projectCreated = false
        var projectNote = "Project folder created; no project template is configured."
        if let sourcePath = plan.workflow.projectTemplatePath,
           let destination = plan.projectURL {
            try fileManager.copyItem(at: URL(fileURLWithPath: sourcePath), to: destination)
            projectCreated = true
            projectNote = "Copied the team's project template as \(destination.lastPathComponent)."
        } else if let encoded = plan.workflow.projectTemplateBase64,
                  let data = Data(base64Encoded: encoded),
                  let destination = plan.projectURL {
            try data.write(to: destination, options: .withoutOverwriting)
            projectCreated = true
            projectNote = "Created \(destination.lastPathComponent) from the team's embedded project template."
        }
        return Result(plan: plan, created: created, alreadyExisted: existing,
                      projectCreated: projectCreated, projectNote: projectNote)
    }
}

/// Portable, credential-free configuration exchanged between Vaultline and a
/// team. It deliberately excludes account and network state.
struct TeamConfigurationPackage: Codable {
    var schemaVersion = 1
    var team: TeamConfiguration
    var form: IngestFormConfig
    var naming: NamingConfig
    var checksum: ChecksumAlgorithm
    var workflow: WorkflowConfig

    func validated() throws -> TeamConfigurationPackage {
        guard schemaVersion == TeamConfiguration.currentSchemaVersion else {
            throw TeamConfigurationError.unsupportedVersion(schemaVersion)
        }
        let validatedTeam = try team.validated()
        var tokens = Set<String>()
        var fieldIDs = Set<UUID>()
        for field in form.fields {
            guard fieldIDs.insert(field.id).inserted else {
                throw TeamConfigurationError.invalidWorkflow("More than one form field uses id \(field.id.uuidString).")
            }
            guard !field.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TeamConfigurationError.invalidWorkflow("A form field is missing its label.")
            }
            if field.kind == .choice {
                let choices = field.options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard choices == field.options, !choices.isEmpty, !choices.contains(""),
                      Set(choices).count == choices.count else {
                    throw TeamConfigurationError.invalidWorkflow("\(field.label) needs a non-empty list of unique choices.")
                }
            }
            if !field.defaultValue.isEmpty, !field.isValid(answer: field.defaultValue) {
                throw TeamConfigurationError.invalidWorkflow("\(field.label)'s default value is not valid for its field type.")
            }
            guard let token = field.token else { continue }
            guard token.range(of: #"^[A-Za-z][A-Za-z0-9]*$"#, options: .regularExpression) != nil,
                  token.lowercased() != "date" else {
                throw TeamConfigurationError.invalidWorkflow("\(field.label) has an invalid or reserved template token: \(token)")
            }
            guard tokens.insert(token).inserted else {
                throw TeamConfigurationError.invalidWorkflow("More than one form field uses the template token \(token).")
            }
        }
        for preset in validatedTeam.workflows {
            let templates = [preset.jobNameTemplate, preset.projectNameTemplate].compactMap { $0 }
            for template in templates {
                for token in try WorkflowTemplate.referencedTokens(in: template)
                where token.lowercased() != "date" && !tokens.contains(token) {
                    throw TeamConfigurationError.invalidWorkflow("\(preset.name) references form token \(token), but no form field provides it.")
                }
                if !form.enabled,
                   try WorkflowTemplate.referencedTokens(in: template).contains(where: { $0.lowercased() != "date" }) {
                    throw TeamConfigurationError.invalidWorkflow("\(preset.name) needs form values, so the ingest form cannot be disabled.")
                }
            }
        }
        if form.writeSidecar {
            try WorkflowPath.validateFilename(form.sidecarName, context: "ingest record filename")
        }
        var result = self
        result.team = validatedTeam
        return result
    }
}
