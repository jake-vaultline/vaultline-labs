import Foundation

/// The shoot form that travels with the footage.
///
/// Every team has a different set of things they wish had been written down at
/// the card — production, shoot day, DP, location, whether it's approved to
/// archive. So the fields are **configured by the user**, not fixed by us, and
/// the whole thing is optional.
///
/// The answers are written next to the media as a plain text sidecar. Plain
/// text on purpose: it survives every migration, opens on any machine, is
/// readable in fifty years, and gets indexed by Spotlight and by Vaultline
/// alike. A database row would be lost the day the app is uninstalled.
struct IngestFormField: Codable, Identifiable, Hashable {
    var id = UUID()
    var label: String
    var kind: Kind = .text
    var options: [String] = []
    var required = false
    /// Carries over to the next card. Most fields on a shoot day don't change
    /// between cards, and retyping them is how forms stop getting filled in.
    var sticky = true
    var defaultValue = ""
    /// Stable token used by job and project-name templates. Labels can change;
    /// tokens are the configuration contract and therefore must not.
    var token: String?
    var automaticValue: AutomaticValue?

    enum AutomaticValue: String, Codable, CaseIterable {
        case today
    }

    enum Kind: String, Codable, CaseIterable, Identifiable {
        case text, longText, choice, date, toggle
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .text:     return "Single line"
            case .longText: return "Notes"
            case .choice:   return "Pick from a list"
            case .date:     return "Date"
            case .toggle:   return "Yes / no"
            }
        }
    }

    /// What a media team usually wishes it had recorded. Offered as a starting
    /// point, entirely editable — a default that can't be changed is just a
    /// constraint wearing a friendly hat.
    static let suggested: [IngestFormField] = [
        IngestFormField(label: "Shoot date", kind: .date, required: true, token: "shootDate", automaticValue: .today),
        IngestFormField(label: "Who shot this?", kind: .text, required: true, token: "shooter"),
        IngestFormField(label: "Where was it shot?", kind: .text, token: "location"),
        IngestFormField(label: "What was shot?", kind: .text, required: true, token: "project"),
        IngestFormField(label: "Camera", kind: .text, token: "camera"),
        IngestFormField(label: "Job number", kind: .text, token: "jobNumber"),
        IngestFormField(label: "Card / reel", kind: .text, sticky: false, token: "reel"),
        IngestFormField(label: "Notes", kind: .longText, sticky: false, token: "notes")
    ]

    func resolvedDefault(on date: Date = Date()) -> String {
        switch automaticValue {
        case .today:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        case nil:
            return defaultValue
        }
    }

    func dateValue(from value: String) -> Date? {
        guard kind == .date else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#,
                            options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: trimmed)
    }

    func isValid(answer: String) -> Bool {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return !required }
        switch kind {
        case .date: return dateValue(from: trimmed) != nil
        case .choice: return options.contains(trimmed)
        case .toggle: return trimmed == "yes" || trimmed == "no"
        default: return true
        }
    }
}

struct IngestFormConfig: Codable {
    var enabled = true
    var fields: [IngestFormField] = IngestFormField.suggested
    /// Written alongside the media at each destination.
    var writeSidecar = true
    var sidecarName = "INGEST-NOTES.txt"
}

// MARK: - Sidecar

enum IngestSidecar {

    /// Writes the form answers and a factual record of the transfer.
    ///
    /// Everything below the form is written by the app, not typed by a person:
    /// what was copied, where it went, which checksum, how many files verified.
    /// A note that says "all good" is worth less than one that says 312 of 312
    /// verified with xxHash64.
    static func text(fields: [IngestFormField],
                     answers: [UUID: String],
                     sourceName: String,
                     destinations: [Destination],
                     files: [IngestFile],
                     algorithm: ChecksumAlgorithm,
                     progress: OffloadProgress) -> String {

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"

        var out = "INGEST RECORD\n"
        out += String(repeating: "=", count: 52) + "\n\n"
        out += "Source            \(sourceName)\n"
        out += "Ingested          \(df.string(from: Date()))\n"
        out += "By                \(Host.current().localizedName ?? "unknown Mac")\n"
        out += "Tool              Vaultline Ingest \(version)\n\n"

        let answered = fields.filter {
            !(answers[$0.id] ?? $0.resolvedDefault())
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !answered.isEmpty {
            out += "SHOOT\n" + String(repeating: "-", count: 52) + "\n"
            let width = answered.map(\.label.count).max() ?? 12
            for f in answered {
                let value = answers[f.id] ?? f.resolvedDefault()
                if f.kind == .longText {
                    out += "\(f.label)\n"
                    for line in value.split(separator: "\n", omittingEmptySubsequences: false) {
                        out += "  \(line)\n"
                    }
                } else {
                    out += f.label.padding(toLength: max(width + 2, 18), withPad: " ", startingAt: 0)
                    out += "\(value)\n"
                }
            }
            out += "\n"
        }

        out += "TRANSFER\n" + String(repeating: "-", count: 52) + "\n"
        out += "Files verified    \(progress.filesVerified) of \(progress.totalFiles)\n"
        if progress.filesAlreadyPresent > 0 {
            out += "Already present   \(progress.filesAlreadyPresent) (matched, not rewritten)\n"
        }
        out += "Data              \(bytes(progress.totalBytes))\n"
        out += "Checksum          \(algorithm.mhlName)\n"
        out += "Verification      read back from each destination and compared\n"
        for d in destinations {
            let n = files.filter { $0.destinations[d.root]?.isVerified == true }.count
            out += "Destination       \(d.label) — \(d.root) (\(n) verified)\n"
        }
        if !progress.conflicts.isEmpty {
            out += "\nNAME CLASHES — nothing was overwritten\n"
            for c in progress.conflicts.prefix(50) { out += "  \(c)\n" }
        }
        if !progress.failures.isEmpty {
            out += "\nDID NOT VERIFY\n"
            for f in progress.failures.prefix(50) { out += "  \(f)\n" }
        }

        out += "\nFILES\n" + String(repeating: "-", count: 52) + "\n"
        for f in files where f.sourceHash != nil {
            let renamed = f.wasRenamed ? "  (was \(f.originalName))" : ""
            out += "\(f.sourceHash ?? "")  \(f.destinationRelativePath)\(renamed)\n"
        }

        out += "\nChecksums above are \(algorithm.mhlName). A machine-readable\n"
        out += "ASC MHL manifest is alongside this file.\n"
        return out
    }

    static func write(_ text: String, to destination: Destination, name: String) throws -> URL {
        let url = URL(fileURLWithPath: destination.root).appendingPathComponent(name)
        // Never clobber an existing record — a second card into the same folder
        // must not erase the first card's notes.
        var final = url
        var n = 2
        while FileManager.default.fileExists(atPath: final.path) {
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            final = URL(fileURLWithPath: destination.root)
                .appendingPathComponent(ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)")
            n += 1
        }
        try AtomicNoReplaceWriter.write(Data(text.utf8), to: final)
        return final
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private static func bytes(_ v: Int64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file
        return f.string(fromByteCount: v)
    }
}
