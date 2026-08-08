import Foundation

/// Collects the media files Pass 1 found so Pass 2 can probe them.
/// Deliberately NOT part of ScanSnapshot — the snapshot is copied and published
/// ~7×/second, and carrying a 100k-element array through that would be the one
/// thing that makes a live-updating scan stutter.
final class MediaIndex: @unchecked Sendable {
    /// Media files, for Pass 2.
    var refs: [FileEntry] = []
    /// Any file big enough to be worth a duplicate check, for Pass 3. Kept
    /// separate because duplicates aren't a media-only question — a 12 GB
    /// project cache copied three times is exactly what people want to find.
    var large: [FileEntry] = []
}

// MARK: - Engine

@MainActor
final class ScanEngine: ObservableObject {

    @Published private(set) var snapshot = ScanSnapshot()
    @Published private(set) var isScanning = false
    @Published var errorMessage: String?

    private var consumer: Task<Void, Never>?
    private var prober: Task<Void, Never>?
    private var deduper: Task<Void, Never>?
    private var index = MediaIndex()
    private var accessedURL: URL?

    /// True while any pass is running.
    var isBusy: Bool { isScanning || snapshot.probe.isRunning || snapshot.dupes.isRunning }

    func scan(_ url: URL) {
        cancel()
        errorMessage = nil

        // Sandboxed: the user-selected URL carries a security scope. Hold it open
        // across BOTH passes — releasing after Pass 1 would make every probe fail.
        let opened = url.startAccessingSecurityScopedResource()
        accessedURL = opened ? url : nil

        var seed = ScanSnapshot()
        seed.rootPath = url.path
        if let v = try? url.resourceValues(forKeys: [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey
        ]) {
            seed.volumeName = v.volumeName ?? url.lastPathComponent
            seed.volumeTotalBytes = Int64(v.volumeTotalCapacity ?? 0)
            seed.volumeFreeBytes = Int64(v.volumeAvailableCapacity ?? 0)
        } else {
            seed.volumeName = url.lastPathComponent
        }

        snapshot = seed
        isScanning = true

        index = MediaIndex()
        let idx = index
        let stream = Walker.walk(root: url, seed: seed, index: idx)

        consumer = Task { [weak self] in
            for await snap in stream {
                guard let self else { return }
                // Preserve later-pass state — Pass 1 snapshots don't know about it.
                var s = snap
                s.probe = self.snapshot.probe
                s.dupes = self.snapshot.dupes
                self.snapshot = s
            }
            guard let self, !Task.isCancelled else { return }
            self.isScanning = false
            self.consumer = nil
            self.startProbe(idx.refs)
        }
    }

    func cancel() {
        consumer?.cancel(); consumer = nil
        prober?.cancel();  prober = nil
        deduper?.cancel(); deduper = nil
        isScanning = false
        snapshot.probe.isRunning = false
        snapshot.dupes.isRunning = false
        releaseAccess()
    }

    // MARK: Pass 2

    private func startProbe(_ refs: [FileEntry]) {
        let probable = refs.filter { $0.category.isMedia }
        guard !probable.isEmpty else {
            snapshot.probe.isComplete = true
            startDuplicates()
            return
        }

        snapshot.probe.filesToProbe = probable.count
        snapshot.probe.isRunning = true

        // Biggest first: the summary percentages stabilise early, so the numbers
        // on screen are already close to final long before the pass ends.
        let ordered = probable.sorted { $0.size > $1.size }

        prober = Task { [weak self] in
            let stream = Prober.run(ordered)
            for await partial in stream {
                guard let self, !Task.isCancelled else { return }
                self.snapshot.probe = partial
            }
            guard let self else { return }
            self.snapshot.probe.isRunning = false
            self.snapshot.probe.isComplete = !Task.isCancelled
            self.prober = nil
            guard !Task.isCancelled else { self.releaseAccess(); return }
            self.startDuplicates()
        }
    }

    // MARK: Pass 3

    private func startDuplicates() {
        let candidates = index.large
        guard candidates.count > 1 else {
            snapshot.dupes.isComplete = true
            releaseAccess()
            return
        }

        snapshot.dupes.isRunning = true
        deduper = Task { [weak self] in
            let stream = DuplicateFinder.run(candidates)
            for await partial in stream {
                guard let self, !Task.isCancelled else { return }
                self.snapshot.dupes = partial
            }
            guard let self else { return }
            self.snapshot.dupes.isRunning = false
            self.deduper = nil
            self.releaseAccess()
        }
    }

    private func releaseAccess() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }
}

// MARK: - Pass 2 driver

enum Prober {

    static func run(_ files: [FileEntry]) -> AsyncStream<ProbeSummary> {
        AsyncStream { continuation in
            let work = Task.detached(priority: .utility) {
                var summary = ProbeSummary()
                summary.filesToProbe = files.count
                summary.isRunning = true

                var lastYield = Date()
                var index = 0

                // A nested function capturing the task group would be an
                // "escaping closure captures inout parameter" error, so the
                // enqueue is written inline in both places instead.
                await withTaskGroup(of: (FileEntry, ProbeResult?).self) { group in

                    // Prime the pump, then keep exactly `concurrency` in flight.
                    let priming = min(MediaProbe.concurrency, files.count)
                    for _ in 0..<priming {
                        let f = files[index]
                        index += 1
                        group.addTask {
                            let r = await MediaProbe.probe(path: f.path, category: f.category)
                            return (f, r)
                        }
                    }

                    while let (file, result) = await group.next() {
                        if Task.isCancelled { break }
                        summary.filesProbed += 1
                        apply(result, for: file, into: &summary)

                        let now = Date()
                        if now.timeIntervalSince(lastYield) >= 0.2 {
                            lastYield = now
                            continuation.yield(summary)
                        }

                        if index < files.count {
                            let f = files[index]
                            index += 1
                            group.addTask {
                                let r = await MediaProbe.probe(path: f.path, category: f.category)
                                return (f, r)
                            }
                        }
                    }
                }

                summary.isRunning = false
                summary.isComplete = !Task.isCancelled
                continuation.yield(summary)
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private static func apply(_ r: ProbeResult?, for file: FileEntry, into s: inout ProbeSummary) {
        // Even a failed probe contributes a year, from mtime.
        let fallbackYear = file.modified.map { Calendar.current.component(.year, from: $0) }

        guard let r else {
            if let y = fallbackYear { s.bytesByYear[y, default: 0] += file.size }
            return
        }

        // AVFoundation can open a container and still hand back nothing —
        // confirmed against real RED .r3d footage, which probes exactly this
        // way without RED's own decoder installed. A video with no codec, no
        // resolution and no duration didn't yield a partial answer; it
        // yielded none, and that's worth a flag rather than silent zeros.
        let extractedNothing = r.codec == nil && r.duration == 0
            && (file.category != .video || r.resolution == nil)
        if extractedNothing {
            s.unreadable.add(file.size)
        }

        if let c = r.codec       { s.bytesByCodec[c, default: 0] += file.size }
        if let res = r.resolution, file.category == .video { s.clipsByResolution[res, default: 0] += 1 }
        if let fr = r.frameRate  { s.clipsByFrameRate[fr, default: 0] += 1 }
        if r.duration > 0        { s.totalDuration += r.duration }

        if let cam = r.camera {
            s.byCamera[cam, default: CountAndBytes()].add(file.size)
        }

        if let d = r.captureDate {
            s.embeddedDateCount += 1
            s.bytesByYear[Calendar.current.component(.year, from: d), default: 0] += file.size
        } else if let y = fallbackYear {
            s.bytesByYear[y, default: 0] += file.size
        }
    }
}

// MARK: - Pass 1 walker

enum Walker {

    private static let yieldInterval: TimeInterval = 0.15
    static let largestFilesKept = 100
    static let largestFoldersKept = 25
    /// Ceiling on how many media files we hold for Pass 2. Well beyond any real
    /// drive; exists so a pathological tree can't exhaust memory.
    static let maxMediaRefs = 400_000

    static func walk(root: URL, seed: ScanSnapshot, index: MediaIndex) -> AsyncStream<ScanSnapshot> {
        AsyncStream { continuation in
            let work = Task.detached(priority: .userInitiated) {
                var acc = Accumulator(seed: seed, rootPath: root.path)
                let started = Date()

                let keys: [URLResourceKey] = [
                    .isRegularFileKey, .isDirectoryKey, .fileSizeKey,
                    .contentModificationDateKey, .isSymbolicLinkKey
                ]

                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles],
                    errorHandler: { _, _ in true }   // skip unreadable, keep going
                ) else {
                    acc.snapshot.isComplete = true
                    continuation.yield(acc.snapshot)
                    continuation.finish()
                    return
                }

                var lastYield = Date()

                for case let fileURL as URL in enumerator {
                    if Task.isCancelled {
                        acc.snapshot.wasCancelled = true
                        break
                    }

                    guard let vals = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }
                    if vals.isSymbolicLink == true { continue }

                    if vals.isDirectory == true {
                        acc.addDirectory(fileURL.path, ext: fileURL.pathExtension)
                    } else if vals.isRegularFile == true {
                        let entry = acc.addFile(
                            path: fileURL.path,
                            ext: fileURL.pathExtension,
                            size: Int64(vals.fileSize ?? 0),
                            modified: vals.contentModificationDate
                        )
                        if entry.category.isMedia, index.refs.count < maxMediaRefs {
                            index.refs.append(entry)
                        }
                        if entry.size >= DuplicateFinder.minimumSize, index.large.count < maxMediaRefs {
                            index.large.append(entry)
                        }
                    }

                    let now = Date()
                    if now.timeIntervalSince(lastYield) >= yieldInterval {
                        lastYield = now
                        acc.snapshot.elapsed = now.timeIntervalSince(started)
                        continuation.yield(acc.finalizedCopy(partial: true))
                    }
                }

                acc.snapshot.elapsed = Date().timeIntervalSince(started)
                acc.snapshot.isComplete = !acc.snapshot.wasCancelled
                continuation.yield(acc.finalizedCopy(partial: false))
                continuation.finish()
            }

            continuation.onTermination = { _ in work.cancel() }
        }
    }
}

// MARK: - Accumulator

/// Mutable scan state. Kept separate from ScanSnapshot so the expensive derived
/// work (sorting largest files/folders) only runs when we publish.
private struct Accumulator {

    var snapshot: ScanSnapshot
    let rootPath: String

    private var folderBytes: [String: Int64] = [:]
    private var folderCounts: [String: Int] = [:]
    private var allDirs: Set<String> = []
    private var nonEmptyDirs: Set<String> = []
    private var largest: [FileEntry] = []
    private var smallestKept: Int64 = 0

    init(seed: ScanSnapshot, rootPath: String) {
        self.snapshot = seed
        self.rootPath = rootPath
    }

    mutating func addDirectory(_ path: String, ext: String) {
        allDirs.insert(path)
        snapshot.foldersScanned += 1

        // A project bundle counts as a project document in its own right, even
        // though we still descend into it looking for media (FCP libraries
        // frequently contain the actual footage).
        if !ext.isEmpty, MediaClassifier.isProjectBundle(extension: ext) {
            let entry = FileEntry(path: path, size: 0, modified: nil, category: .project)
            snapshot.projectFiles.append(entry)
            snapshot.byCategory[.project, default: CountAndBytes()].add(0)
        }
    }

    @discardableResult
    mutating func addFile(path: String, ext: String, size: Int64, modified: Date?) -> FileEntry {
        let category = MediaClassifier.category(forExtension: ext)
        let entry = FileEntry(path: path, size: size, modified: modified, category: category)

        snapshot.filesScanned += 1
        snapshot.bytesScanned += size
        snapshot.byCategory[category, default: CountAndBytes()].add(size)

        if !ext.isEmpty {
            snapshot.byExtension[ext.lowercased(), default: CountAndBytes()].add(size)
        }

        if category == .project, snapshot.projectFiles.count < 500 {
            snapshot.projectFiles.append(entry)
        }

        // Date range across media only — a stray render cache shouldn't widen
        // the shoot window. Pass 2 refines this with real capture dates.
        if category.isMedia, let m = modified {
            if snapshot.earliest == nil || m < snapshot.earliest! { snapshot.earliest = m }
            if snapshot.latest == nil || m > snapshot.latest! { snapshot.latest = m }
        }

        trackLargest(entry)
        attributeToAncestors(path: path, size: size)
        return entry
    }

    /// Bounded top-N. Avoids sorting the whole file list on a 500k-file drive.
    private mutating func trackLargest(_ entry: FileEntry) {
        guard largest.count < Walker.largestFilesKept || entry.size > smallestKept else { return }
        largest.append(entry)
        if largest.count > Walker.largestFilesKept * 2 {
            largest.sort { $0.size > $1.size }
            largest = Array(largest.prefix(Walker.largestFilesKept))
            smallestKept = largest.last?.size ?? 0
        }
    }

    /// Every ancestor folder up to the scan root gets credited with this file's
    /// bytes, which yields true recursive folder sizes in a single pass.
    private mutating func attributeToAncestors(path: String, size: Int64) {
        var dir = (path as NSString).deletingLastPathComponent
        while dir.hasPrefix(rootPath), dir.count >= rootPath.count {
            folderBytes[dir, default: 0] += size
            folderCounts[dir, default: 0] += 1
            nonEmptyDirs.insert(dir)
            if dir == rootPath { break }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
    }

    func finalizedCopy(partial: Bool) -> ScanSnapshot {
        var out = snapshot

        var files = largest
        files.sort { $0.size > $1.size }
        out.largestFiles = Array(files.prefix(Walker.largestFilesKept))

        // The scan root itself is always in `folderBytes` (every file's bytes
        // are credited up to and including it) and therefore always 100% —
        // a guaranteed #1 entry that says nothing and bumps a real folder out
        // of the top N. It belongs in the header stats, not this ranking.
        out.largestFolders = folderBytes
            .filter { $0.key != rootPath }
            .sorted { $0.value > $1.value }
            .prefix(Walker.largestFoldersKept)
            .map { FolderStat(path: $0.key, bytes: $0.value, fileCount: folderCounts[$0.key] ?? 0) }

        if !partial {
            out.emptyFolders = allDirs.subtracting(nonEmptyDirs).sorted()
        }
        return out
    }
}
