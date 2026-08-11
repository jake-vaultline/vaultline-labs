import Foundation

/// Renders the template strings the wizard produces —
/// `{code}_{date:yyyyMMdd}_{reel}_{seq:0000}` — into real names.
///
/// Kept separate from `NamingAnalyzer` because the analyzer's job is reading
/// and this one's job is writing, and the writing side is what touches
/// destination filenames. Anything that renames media deserves its own file and
/// its own tests.
enum NameTemplate {

    struct Values {
        var code: String = ""
        var reel: String = ""
        var word: String = ""
        var text: String = ""
        var date: Date = Date()
        /// Falls back to this when the template can't fill a slot.
        var originalStem: String = ""
    }

    /// Renders `template` for one file. `index` fills sequence tokens.
    ///
    /// An unfillable token collapses to nothing rather than leaving a literal
    /// `{code}` in a filename — but if *everything* collapses, the original stem
    /// is returned instead. A rename that produces `__0001` is worse than no
    /// rename at all.
    static func render(_ template: String, values: Values, index: Int) -> String {
        guard !template.isEmpty else { return values.originalStem }

        var out = template
        for token in tokens(in: template) {
            out = out.replacingOccurrences(of: token.raw,
                                           with: substitute(token, values: values, index: index))
        }

        // Tidy up separators left stranded by empty substitutions.
        out = out.replacingOccurrences(of: #"[_\-.]{2,}"#, with: "_", options: .regularExpression)
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_-. "))

        let meaningful = out.contains { $0.isLetter || $0.isNumber }
        return meaningful ? sanitize(out) : values.originalStem
    }

    /// Full destination-relative path: folder template (if any) + filename.
    static func destinationPath(fileTemplate: String,
                                folderTemplate: String,
                                originalRelativePath: String,
                                values: Values,
                                index: Int) -> String {
        let ext = (originalRelativePath as NSString).pathExtension
        var v = values
        v.originalStem = ((originalRelativePath as NSString).lastPathComponent as NSString)
            .deletingPathExtension

        let stem = render(fileTemplate, values: v, index: index)
        let filename = ext.isEmpty ? stem : "\(stem).\(ext)"

        // Preserve the card's own subfolder structure under any new top-level
        // folder — camera card layouts carry meaning and flattening them loses it.
        let originalDir = (originalRelativePath as NSString).deletingLastPathComponent

        var parts: [String] = []
        if !folderTemplate.isEmpty {
            let folder = render(folderTemplate, values: v, index: index)
            if !folder.isEmpty { parts.append(folder) }
        }
        if !originalDir.isEmpty { parts.append(originalDir) }
        parts.append(filename)
        return parts.joined(separator: "/")
    }

    // MARK: Parsing

    private struct Token {
        let raw: String     // "{date:yyyyMMdd}"
        let name: String    // "date"
        let detail: String  // "yyyyMMdd"
    }

    private static func tokens(in template: String) -> [Token] {
        guard let re = try? NSRegularExpression(pattern: #"\{([a-zA-Z]+)(?::([^}]+))?\}"#) else {
            return []
        }
        let ns = template as NSString
        return re.matches(in: template, range: NSRange(location: 0, length: ns.length)).map { m in
            Token(raw: ns.substring(with: m.range),
                  name: ns.substring(with: m.range(at: 1)).lowercased(),
                  detail: m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2)))
        }
    }

    private static func substitute(_ t: Token, values: Values, index: Int) -> String {
        switch t.name {
        case "date":
            let f = DateFormatter()
            f.dateFormat = t.detail.isEmpty ? "yyyyMMdd" : t.detail
            return f.string(from: values.date)
        case "seq":
            let width = max(1, t.detail.filter { $0 == "0" }.count)
            return String(format: "%0\(width)d", index)
        case "reel": return values.reel
        case "code": return values.code
        case "word": return values.word
        case "text": return values.text
        default:     return ""
        }
    }

    /// Filenames that survive every filesystem and every NLE. `/` and `:` are
    /// the dangerous ones on macOS; the rest is politeness.
    private static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return s.components(separatedBy: bad).joined(separator: "-")
    }
}
