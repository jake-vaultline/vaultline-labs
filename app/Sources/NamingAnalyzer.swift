import Foundation

/// Infers a naming convention from work a team has already done.
///
/// Nobody can describe their own naming convention accurately — ask and you get
/// the aspiration, not the practice. But everyone can point at a drive. So the
/// wizard reads real names, works out the recurring shape, and shows it back with
/// their own files as examples.
///
/// The most valuable output is usually not the pattern. It's the **consistency
/// score** — "84% of your folders match this, here are the 16% that don't" —
/// because it's typically the first time anyone has measured it.
enum NamingAnalyzer {

    // MARK: Tokens

    enum TokenKind: String, Codable {
        case date, sequence, reel, code, word, mixed

        var placeholder: String {
            switch self {
            case .date:     return "date"
            case .sequence: return "seq"
            case .reel:     return "reel"
            case .code:     return "code"
            case .word:     return "word"
            case .mixed:    return "text"
            }
        }
    }

    struct Token: Codable, Hashable {
        let kind: TokenKind
        /// `yyyyMMdd` for dates, digit width for sequences, else empty.
        var detail: String = ""

        var signature: String { detail.isEmpty ? kind.rawValue : "\(kind.rawValue):\(detail)" }
        var placeholder: String {
            switch kind {
            case .date:     return "{date:\(detail)}"
            case .sequence: return "{seq:\(String(repeating: "0", count: Int(detail) ?? 3))}"
            default:        return "{\(kind.placeholder)}"
            }
        }
    }

    // MARK: Results

    struct Candidate: Identifiable {
        var id: String { signature }
        let signature: String
        let tokens: [Token]
        let separator: String
        let matches: Int
        let examples: [String]

        /// `{code}_{date:yyyyMMdd}_{reel}_{seq:0000}`
        var template: String {
            tokens.map(\.placeholder).joined(separator: separator)
        }
    }

    struct Analysis {
        let scope: String                 // "files" or "folders"
        let sampleSize: Int
        let candidates: [Candidate]
        let exceptions: [String]
        let dominantSeparator: String

        /// Share of names matching the leading pattern, 0–1.
        var consistency: Double {
            guard sampleSize > 0, let top = candidates.first else { return 0 }
            return Double(top.matches) / Double(sampleSize)
        }

        var headline: String {
            guard let top = candidates.first else { return "No recurring pattern found." }
            let pct = Int((consistency * 100).rounded())
            return "\(pct)% of \(scope) match \(top.template)"
        }
    }

    // MARK: Entry point

    static func analyze(names: [String], scope: String = "files") -> Analysis {
        let cleaned = names
            .map { stripExtension($0) }
            .filter { !$0.isEmpty && !$0.hasPrefix(".") }
        guard !cleaned.isEmpty else {
            return Analysis(scope: scope, sampleSize: 0, candidates: [],
                            exceptions: [], dominantSeparator: "_")
        }

        let separator = dominantSeparator(cleaned)

        var groups: [String: (tokens: [Token], names: [String])] = [:]
        for name in cleaned {
            let tokens = tokenize(name, separator: separator)
            guard !tokens.isEmpty else { continue }
            let sig = tokens.map(\.signature).joined(separator: "|")
            groups[sig, default: (tokens, [])].names.append(name)
        }

        let ranked = groups
            .map { sig, g in
                Candidate(signature: sig, tokens: g.tokens, separator: separator,
                          matches: g.names.count, examples: Array(g.names.prefix(4)))
            }
            .sorted { $0.matches > $1.matches }

        // Everything outside the leading pattern is worth showing — the odd ones
        // out are where the convention actually broke down.
        let topSig = ranked.first?.signature
        let exceptions = ranked
            .filter { $0.signature != topSig }
            .flatMap(\.examples)

        return Analysis(scope: scope,
                        sampleSize: cleaned.count,
                        candidates: Array(ranked.prefix(6)),
                        exceptions: Array(exceptions.prefix(25)),
                        dominantSeparator: separator)
    }

    /// Folder-depth grammar: what each level of the tree tends to be.
    /// e.g. `Project / yyyyMMdd / Camera / files`
    static func analyzeHierarchy(relativePaths: [String], maxDepth: Int = 4) -> [Analysis] {
        var byLevel: [Int: [String]] = [:]
        for path in relativePaths {
            let parts = path.split(separator: "/").map(String.init)
            // Drop the last component — that's the file, covered by analyze().
            for (i, part) in parts.dropLast().enumerated() where i < maxDepth {
                byLevel[i, default: []].append(part)
            }
        }
        return byLevel.sorted { $0.key < $1.key }.map {
            analyze(names: $0.value, scope: "level \($0.key + 1) folders")
        }
    }

    // MARK: Tokenizing

    private static let separators = ["_", "-", ".", " "]

    private static func dominantSeparator(_ names: [String]) -> String {
        var counts: [String: Int] = [:]
        for n in names {
            for s in separators { counts[s, default: 0] += n.components(separatedBy: s).count - 1 }
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? "_"
    }

    private static func tokenize(_ name: String, separator: String) -> [Token] {
        name.components(separatedBy: separator)
            .filter { !$0.isEmpty }
            .map(classify)
    }

    static func classify(_ part: String) -> Token {
        // Date first — it's the most constrained and the most useful to get right.
        if let fmt = dateFormat(part) { return Token(kind: .date, detail: fmt) }

        // Reel/camera: a letter or two followed by digits. A001, C0043, CAM2.
        if part.range(of: #"^[A-Za-z]{1,3}\d{2,5}$"#, options: .regularExpression) != nil {
            return Token(kind: .reel)
        }

        // Pure digits: a sequence. Width matters — 0007 and 7 are different rules.
        if part.allSatisfy(\.isNumber) {
            return Token(kind: .sequence, detail: String(part.count))
        }

        // All-caps short strings behave like project or client codes.
        if part.count <= 8, part.allSatisfy({ $0.isUppercase || $0.isNumber }),
           part.contains(where: \.isLetter) {
            return Token(kind: .code)
        }

        if part.allSatisfy({ $0.isLetter }) { return Token(kind: .word) }
        return Token(kind: .mixed)
    }

    /// Recognises the date shapes that actually turn up on production drives.
    private static func dateFormat(_ s: String) -> String? {
        let patterns: [(String, String)] = [
            (#"^\d{8}$"#,               "yyyyMMdd"),
            (#"^\d{4}-\d{2}-\d{2}$"#,   "yyyy-MM-dd"),
            (#"^\d{2}-\d{2}-\d{2}$"#,   "yy-MM-dd"),
            (#"^\d{4}_\d{2}_\d{2}$"#,   "yyyy_MM_dd"),
            (#"^\d{6}$"#,               "yyMMdd"),
            (#"^\d{4}\d{2}$"#,          "yyyyMM")
        ]
        for (regex, format) in patterns
        where s.range(of: regex, options: .regularExpression) != nil {
            // 8 digits could be a date or a long counter. Sanity-check the month
            // so a 6-digit shot number doesn't get filed as March.
            if format == "yyyyMMdd" || format == "yyMMdd" {
                let month = format.hasPrefix("yyyy")
                    ? Int(s.dropFirst(4).prefix(2))
                    : Int(s.dropFirst(2).prefix(2))
                guard let m = month, (1...12).contains(m) else { continue }
            }
            return format
        }
        return nil
    }

    private static func stripExtension(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    // MARK: Rendering

    /// Fills a template for a new ingest. Unknown tokens are left visible rather
    /// than silently dropped — a filename with `{code}` in it is an obvious bug;
    /// one with a segment quietly missing is not.
    static func render(_ candidate: Candidate, values: [String: String], index: Int) -> String {
        candidate.tokens.enumerated().map { i, token -> String in
            switch token.kind {
            case .date:
                let f = DateFormatter(); f.dateFormat = token.detail
                return values["date"] ?? f.string(from: Date())
            case .sequence:
                let width = Int(token.detail) ?? 3
                return String(format: "%0\(width)d", index)
            case .reel:
                return values["reel"] ?? "A001"
            default:
                return values[token.kind.placeholder] ?? values["slot\(i)"] ?? token.placeholder
            }
        }.joined(separator: candidate.separator)
    }
}
