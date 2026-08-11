import Foundation

/// Creates the folder tree a job lives in, before the card is even inserted.
///
/// This is where naming actually goes wrong. By the time someone is renaming
/// files, the structure has usually already been improvised — and the most
/// common improvisation is having no separation at all between what was shot
/// and what's being cut. Camera media, exports, graphics, music and project
/// files end up in one pile, and two years later nobody can tell which of six
/// similarly-named folders holds the originals.
///
/// So the default template separates them at the top: **Shoot** is
/// write-once and never touched again; **Edit** is where everything churns.
/// That one line is most of the value.
enum StructureBuilder {

    struct Template: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        var detail: String
        /// Folder paths relative to the job root. `{}` tokens are rendered with
        /// the same engine as filenames.
        var folders: [String]
    }

    // MARK: Built-in templates

    static let shootAndEdit = Template(
        name: "Shoot + Edit",
        detail: "Separates original media from everything that changes. The default, and the one most people are missing.",
        folders: [
            "01_Shoot/Camera",
            "01_Shoot/Audio",
            "01_Shoot/Photo",
            "01_Shoot/Manifests",
            "02_Edit/Project",
            "02_Edit/Proxies",
            "02_Edit/Graphics",
            "02_Edit/Music",
            "02_Edit/VO",
            "02_Edit/Exports",
            "03_Deliverables",
            "04_Documents"
        ])

    static let shootOnly = Template(
        name: "Shoot only",
        detail: "For a card that's being archived rather than cut. No edit side.",
        folders: [
            "Camera", "Audio", "Photo", "Manifests", "Documents"
        ])

    static let flat = Template(
        name: "Minimal",
        detail: "One folder per media type. For small jobs that don't need a structure.",
        folders: ["Video", "Audio", "Photo"])

    static let builtIn = [shootAndEdit, shootOnly, flat]

    // MARK: Creation

    struct Result {
        var created: [String] = []
        var alreadyExisted: [String] = []
        var jobRoot: URL
    }

    /// Creates the tree under `parent`, named from the job template.
    ///
    /// Creating a folder is the one write this app does that isn't a copy, so
    /// the same rules apply: nothing is deleted, nothing is replaced, and an
    /// existing folder is reported rather than touched.
    static func create(template: Template,
                       jobName: String,
                       in parent: URL) throws -> Result {

        let safeName = jobName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)

        let root = parent.appendingPathComponent(safeName.isEmpty ? "Untitled Job" : safeName)
        var result = Result(jobRoot: root)

        for relative in ([""] + template.folders) {
            let url = relative.isEmpty ? root : root.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path) {
                result.alreadyExisted.append(relative.isEmpty ? safeName : relative)
            } else {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                result.created.append(relative.isEmpty ? safeName : relative)
            }
        }
        return result
    }

    /// Renders a job folder name from the naming convention the wizard learned,
    /// so the tree and the files inside it agree with each other.
    static func jobName(naming: NamingConfig, jobTitle: String, date: Date = Date()) -> String {
        guard !naming.folderTemplate.isEmpty else {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd"
            return jobTitle.isEmpty ? f.string(from: date) : "\(f.string(from: date))_\(jobTitle)"
        }
        var v = NameTemplate.Values()
        v.code = naming.projectCode
        v.word = jobTitle
        v.text = jobTitle
        v.date = date
        v.originalStem = jobTitle
        return NameTemplate.render(naming.folderTemplate, values: v, index: 1)
    }

    /// Where a freshly ingested card should land inside a job created above.
    /// Camera media goes to the shoot side — never into the edit side, which is
    /// the whole point of separating them.
    static func suggestedIngestFolder(in jobRoot: URL, template: Template) -> URL {
        for candidate in ["01_Shoot/Camera", "Camera", "Video"] {
            let url = jobRoot.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return jobRoot
    }
}
