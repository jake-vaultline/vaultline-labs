import Foundation

// MARK: - Categories

enum MediaCategory: String, CaseIterable, Identifiable {
    case video, photo, audio, project, sidecar, other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .video:   return "Video"
        case .photo:   return "Photo"
        case .audio:   return "Audio"
        case .project: return "Project files"
        case .sidecar: return "Sidecars"
        case .other:   return "Other"
        }
    }

    /// Categories that count toward the headline "media files" number.
    var isMedia: Bool {
        switch self {
        case .video, .photo, .audio: return true
        default: return false
        }
    }
}

// MARK: - Entries

struct FileEntry: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let size: Int64
    let modified: Date?
    let category: MediaCategory

    var name: String { (path as NSString).lastPathComponent }

    static func == (a: FileEntry, b: FileEntry) -> Bool { a.path == b.path }
    func hash(into h: inout Hasher) { h.combine(path) }
}

struct FolderStat: Identifiable {
    var id: String { path }
    let path: String
    let bytes: Int64
    let fileCount: Int

    var name: String { (path as NSString).lastPathComponent }
}

struct CountAndBytes {
    var count: Int = 0
    var bytes: Int64 = 0

    mutating func add(_ size: Int64) {
        count += 1
        bytes += size
    }
}

// MARK: - Snapshot

/// An immutable point-in-time view of a scan. The engine republishes a fresh
/// snapshot on a throttle so SwiftUI can render live without per-file churn.
struct ScanSnapshot {
    var rootPath: String = ""
    var volumeName: String = ""
    var volumeTotalBytes: Int64 = 0
    var volumeFreeBytes: Int64 = 0

    var filesScanned: Int = 0
    var bytesScanned: Int64 = 0
    var foldersScanned: Int = 0

    var byCategory: [MediaCategory: CountAndBytes] = [:]
    var byExtension: [String: CountAndBytes] = [:]

    var earliest: Date?
    var latest: Date?

    var largestFiles: [FileEntry] = []
    var largestFolders: [FolderStat] = []
    var emptyFolders: [String] = []
    var projectFiles: [FileEntry] = []

    var isComplete: Bool = false
    var wasCancelled: Bool = false
    var elapsed: TimeInterval = 0

    // ── Pass 2 ────────────────────────────────────────────────
    var probe = ProbeSummary()

    // ── Pass 3 ────────────────────────────────────────────────
    var dupes = DuplicateSummary()

    var mediaFileCount: Int {
        MediaCategory.allCases
            .filter(\.isMedia)
            .reduce(0) { $0 + (byCategory[$1]?.count ?? 0) }
    }

    var mediaBytes: Int64 {
        MediaCategory.allCases
            .filter(\.isMedia)
            .reduce(0) { $0 + (byCategory[$1]?.bytes ?? 0) }
    }

    /// Extensions sorted by bytes, largest first.
    func topExtensions(_ limit: Int) -> [StatRow] {
        byExtension
            .sorted { $0.value.bytes > $1.value.bytes }
            .prefix(limit)
            .map { StatRow(name: $0.key, count: $0.value.count, bytes: $0.value.bytes) }
    }
}

// MARK: - Pass 3

struct DuplicateGroup: Identifiable {
    var id: String { paths.first ?? UUID().uuidString }
    let size: Int64
    let paths: [String]

    /// Bytes you'd get back keeping one copy.
    var recoverable: Int64 { size * Int64(max(0, paths.count - 1)) }
    var name: String { (paths.first.map { ($0 as NSString).lastPathComponent }) ?? "—" }
}

struct DuplicateSummary {
    var isRunning = false
    var isComplete = false
    var candidatesChecked = 0
    var candidatesTotal = 0
    var groups: [DuplicateGroup] = []

    /// True when the scan stopped early against its read budget. The report must
    /// say so — "218 duplicates" reads as complete unless you say it isn't.
    var hitReadBudget = false

    var duplicateFileCount: Int { groups.reduce(0) { $0 + $1.paths.count - 1 } }
    var recoverableBytes: Int64 { groups.reduce(0) { $0 + $1.recoverable } }
    var progress: Double {
        candidatesTotal > 0 ? Double(candidatesChecked) / Double(candidatesTotal) : 0
    }
}

// MARK: - Ranked row

/// A named row in any ranked breakdown — extensions, codecs, resolutions,
/// frame rates, cameras.
///
/// This is a struct rather than a labelled tuple on purpose: Swift has no key
/// paths into tuple components, so `ForEach(rows, id: \.name)` does not compile
/// over `[(name: String, bytes: Int64)]`. Every ranked list here feeds a ForEach
/// somewhere, so they all return this.
struct StatRow: Identifiable, Hashable {
    var id: String { name }
    let name: String
    var count: Int = 0
    var bytes: Int64 = 0
}

// MARK: - Pass 2 aggregates

/// Everything Pass 2 (AVFoundation / ImageIO) contributes. Kept in one struct so
/// the report generator has a single source and the UI can show "probing…" state
/// without threading extra flags around.
struct ProbeSummary {
    var filesProbed: Int = 0
    var filesToProbe: Int = 0
    var isRunning: Bool = false
    var isComplete: Bool = false

    /// Total runtime of every video/audio asset that reported a duration.
    var totalDuration: TimeInterval = 0

    var bytesByCodec: [String: Int64] = [:]
    var clipsByResolution: [String: Int] = [:]
    var clipsByFrameRate: [String: Int] = [:]
    var byCamera: [String: CountAndBytes] = [:]

    /// Video/audio files AVFoundation opened but extracted nothing usable
    /// from — no codec, no resolution, no duration. This is real, not
    /// theoretical: a genuine RED KOMODO .r3d file probes exactly this way on
    /// a Mac without RED's own decoder installed. It's silent otherwise —
    /// the file still counts as "Video" by extension and its bytes still
    /// count toward the total, so codecs/resolutions quietly stop adding up
    /// to that total with no explanation unless this is tracked and shown.
    var unreadable = CountAndBytes()

    /// Capture dates read from embedded metadata, bucketed by year.
    /// Preferred over filesystem mtime — see `usedEmbeddedDates`.
    var bytesByYear: [Int: Int64] = [:]
    var embeddedDateCount: Int = 0

    /// True when a meaningful share of media carried a real capture date. When
    /// false the year chart is built from mtime and MUST say so — a cloned drive
    /// reports every clip as this year, and a confidently wrong timeline is worse
    /// than none.
    var usedEmbeddedDates: Bool {
        filesProbed > 0 && Double(embeddedDateCount) / Double(filesProbed) > 0.5
    }

    var progress: Double {
        filesToProbe > 0 ? Double(filesProbed) / Double(filesToProbe) : 0
    }

    func topCodecs(_ limit: Int) -> [StatRow] {
        bytesByCodec.sorted { $0.value > $1.value }.prefix(limit)
            .map { StatRow(name: $0.key, bytes: $0.value) }
    }
    func topResolutions(_ limit: Int) -> [StatRow] {
        clipsByResolution.sorted { $0.value > $1.value }.prefix(limit)
            .map { StatRow(name: $0.key, count: $0.value) }
    }
    func topFrameRates(_ limit: Int) -> [StatRow] {
        clipsByFrameRate.sorted { $0.value > $1.value }.prefix(limit)
            .map { StatRow(name: $0.key, count: $0.value) }
    }
    func topCameras(_ limit: Int) -> [StatRow] {
        byCamera.sorted { $0.value.bytes > $1.value.bytes }.prefix(limit)
            .map { StatRow(name: $0.key, count: $0.value.count, bytes: $0.value.bytes) }
    }

    var codecBytesTotal: Int64 { bytesByCodec.values.reduce(0, +) }
    var resolutionClipsTotal: Int { clipsByResolution.values.reduce(0, +) }
    var frameRateClipsTotal: Int { clipsByFrameRate.values.reduce(0, +) }

    /// Rough proxy footprint for everything 4K and above, at a ProRes Proxy-ish
    /// bitrate. An estimate, and the report labels it as one.
    var estimatedProxyBytes: Int64 {
        let hiRes = ["8K", "6K", "5K", "4K"].reduce(0) { $0 + (clipsByResolution[$1] ?? 0) }
        guard resolutionClipsTotal > 0, totalDuration > 0 else { return 0 }
        let share = Double(hiRes) / Double(resolutionClipsTotal)
        let megabitsPerSecond = 45.0
        return Int64(totalDuration * share * megabitsPerSecond * 1_000_000 / 8)
    }
}

// MARK: - Formatting

enum Fmt {
    static func bytes(_ v: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useGB, .useTB, .useMB, .useKB]
        return f.string(fromByteCount: v)
    }

    static func count(_ v: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// "1 file" vs "12 files" — the singular case is common enough (a lone
    /// duplicate copy, one file left in an otherwise-empty camera bucket)
    /// that "1 files" reads as broken rather than just informal.
    static func files(_ v: Int) -> String {
        "\(count(v)) \(v == 1 ? "file" : "files")"
    }

    static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return "0%" }
        return String(format: "%.0f%%", Double(part) / Double(whole) * 100)
    }

    static func duration(_ s: TimeInterval) -> String {
        guard s > 0 else { return "—" }
        let h = Int(s) / 3600
        if h >= 1 { return "\(count(h)) h" }
        return "\(Int(s) / 60) min"
    }

    static func percent(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "0%" }
        return String(format: "%.0f%%", Double(part) / Double(whole) * 100)
    }

    static func dateRange(_ a: Date?, _ b: Date?) -> String {
        guard let a, let b else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return "\(f.string(from: a)) → \(f.string(from: b))"
    }
}
