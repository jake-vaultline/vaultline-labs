import Foundation
import Darwin

// MARK: - Model

struct IngestFile: Identifiable {
    var id: String { sourcePath }
    let sourcePath: String
    /// Path relative to the source card.
    let relativePath: String
    /// Where it lands under each destination root — after renaming and any
    /// folder template. Equals `relativePath` when renaming is off.
    var destinationRelativePath: String
    let size: Int64

    var sourceHash: String?
    var destinations: [String: DestinationState] = [:]

    var originalName: String { (relativePath as NSString).lastPathComponent }
    var newName: String { (destinationRelativePath as NSString).lastPathComponent }
    var wasRenamed: Bool { originalName != newName }
}

enum DestinationState: Equatable {
    case pending
    /// Already present and byte-identical — a re-run, not a copy.
    case alreadyVerified(hash: String)
    case verified(hash: String)
    /// Something different is already sitting there. Never overwritten.
    case conflict(String)
    case failed(String)
    case skipped(String)

    var isVerified: Bool {
        switch self {
        case .verified, .alreadyVerified: return true
        default: return false
        }
    }
    var isProblem: Bool {
        switch self {
        case .conflict, .failed: return true
        default: return false
        }
    }
}

struct Destination: Identifiable, Hashable {
    var id: String { root }
    let root: String
    let label: String
    /// Informational only — every destination is written and verified
    /// identically. A "backup" given less care than the primary would be worse
    /// than no backup.
    let isPrimary: Bool
}

enum IngestPathSafety {
    static func issue(source: URL, destinations: [Destination]) -> String? {
        let sourcePath = normalized(source.path)
        for destination in destinations {
            let path = normalized(destination.root)
            if path == sourcePath || path.hasPrefix(sourcePath + "/") {
                return "\(destination.label) is inside the source. Choose a destination outside the card or source folder."
            }
        }
        for index in destinations.indices {
            for otherIndex in destinations.indices where otherIndex > index {
                let first = normalized(destinations[index].root)
                let second = normalized(destinations[otherIndex].root)
                if first == second || first.hasPrefix(second + "/") || second.hasPrefix(first + "/") {
                    return "\(destinations[index].label) and \(destinations[otherIndex].label) overlap. Choose independent destination folders."
                }
            }
        }
        return nil
    }

    private static func normalized(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return resolved.count > 1 && resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
    }
}

enum IngestPlanSafety {
    static func issue(files: [IngestFile], destinations: [Destination] = []) -> String? {
        var seen = Set<String>()
        for file in files {
            let relative = file.destinationRelativePath.replacingOccurrences(of: "\\", with: "/")
            let components = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard !relative.hasPrefix("/"), !components.contains(".."),
                  !components.contains("."), !components.contains("") else {
                return "A planned destination path is not safe: \(file.destinationRelativePath)"
            }
            let normalized = file.destinationRelativePath
                .precomposedStringWithCanonicalMapping
                .lowercased()
            guard seen.insert(normalized).inserted else {
                return "More than one source file would land at \(file.destinationRelativePath). Adjust the rename pattern before starting."
            }
            for destination in destinations {
                let target = URL(fileURLWithPath: destination.root, isDirectory: true)
                    .appendingPathComponent(file.destinationRelativePath)
                guard DestinationPathSafety.contains(target, under: URL(
                    fileURLWithPath: destination.root, isDirectory: true)) else {
                    return "\(destination.label) contains a linked folder that would send \(file.destinationRelativePath) outside the selected destination. Remove the link or choose a different destination."
                }
            }
        }
        return nil
    }
}

enum DestinationPathSafety {
    static func contains(_ target: URL, under root: URL) -> Bool {
        let resolvedRoot = normalized(root)
        let resolvedTarget = normalized(target)
        return resolvedTarget == resolvedRoot || resolvedTarget.hasPrefix(resolvedRoot + "/")
    }

    private static func normalized(_ url: URL) -> String {
        // `resolvingSymlinksInPath()` does not resolve a linked ancestor when
        // the leaf does not exist yet—the exact state before a copy. Resolve
        // the nearest existing ancestor first, then append the uncreated tail.
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path { break }
            tail.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in tail { resolved.appendPathComponent(component) }
        let path = resolved.standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// Refuses an ingest before the first source byte is read when any destination
/// cannot hold its missing files. Existing paths do not need additional space:
/// the engine will hash them and either resume or report a conflict without
/// rewriting them.
enum DestinationCapacity {
    static let safetyReserve: Int64 = 512 * 1024 * 1024

    static func missingBytes(files: [IngestFile], destination: Destination,
                             fileManager: FileManager = .default) -> Int64 {
        files.reduce(into: Int64(0)) { total, file in
            let path = (destination.root as NSString)
                .appendingPathComponent(file.destinationRelativePath)
            if !fileManager.fileExists(atPath: path) { total += file.size }
        }
    }

    static func issue(files: [IngestFile], destinations: [Destination],
                      availableCapacity: (String) -> Int64? = availableBytes) -> String? {
        for destination in destinations {
            let missing = missingBytes(files: files, destination: destination)
            guard missing > 0, let available = availableCapacity(destination.root) else { continue }
            let required = missing.addingReportingOverflow(safetyReserve)
            let threshold = required.overflow ? Int64.max : required.partialValue
            guard available < threshold else { continue }
            return "\(destination.label) needs about \(formatted(threshold)) free for this ingest, but only \(formatted(available)) is available. Choose another destination or free space."
        }
        return nil
    }

    private static func availableBytes(at path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let value = attributes[.systemFreeSize] as? NSNumber else { return nil }
        return value.int64Value
    }

    private static func formatted(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct OffloadProgress {
    var totalFiles = 0
    var totalBytes: Int64 = 0
    var filesVerified = 0
    var filesAlreadyPresent = 0
    var bytesCopied = Int64(0)
    var currentFile = ""
    var phase: Phase = .planning
    var failures: [String] = []
    var conflicts: [String] = []
    var startedAt = Date()

    enum Phase: String { case planning, copying, verifying, manifest, done, failed, cancelled }

    var fraction: Double {
        totalBytes > 0 ? min(1, Double(bytesCopied) / Double(totalBytes)) : 0
    }
    var throughputMBps: Double {
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0.5 else { return 0 }
        return Double(bytesCopied) / elapsed / 1_000_000
    }
    var hasProblems: Bool { !failures.isEmpty || !conflicts.isEmpty }
}

enum OffloadError: LocalizedError {
    case unreadable(String)
    case destinationUnwritable(String)
    case sourceChanged(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let p):            return "Couldn't read \(p)."
        case .destinationUnwritable(let p): return "Can't write to \(p)."
        case .sourceChanged(let p):          return "The source changed while \(p) was being copied. No final copy was published; stop recording or writing to the source and try again."
        }
    }
}

struct SourceDiscoveryFailure: Error, Equatable {
    let relativePath: String
    let detail: String

    var operatorMessage: String {
        let item = relativePath.isEmpty ? "the source folder" : relativePath
        return "The source scan couldn't read every item. Nothing can be ingested until access to \(item) is fixed or a different source is chosen."
    }
}

enum SourcePlanningResult {
    case planned([IngestFile])
    case cancelled
    case failed(SourceDiscoveryFailure)
}

/// Owns only Vaultline-created transfer scratch space. A recognizable marker
/// proves provenance; an advisory lock distinguishes an abandoned session from
/// another running app instance. Foreign or active contents are never removed.
enum StagingArea {
    static let directoryName = ".vaultline-ingest-staging"
    static let markerName = ".vaultline-owned-v1"
    static let lockName = ".vaultline-session.lock"

    final class Session {
        let root: URL
        private let lockDescriptor: Int32
        private var cleaned = false

        init(root: URL, lockDescriptor: Int32) {
            self.root = root
            self.lockDescriptor = lockDescriptor
        }

        func cleanup() {
            guard !cleaned else { return }
            cleaned = true
            // This session directory was atomically named by this process and
            // its lock is still held. It is the only recursive delete the copy
            // engine performs.
            try? FileManager.default.removeItem(at: root)
            _ = Darwin.close(lockDescriptor)
        }

        deinit {
            if !cleaned { _ = Darwin.close(lockDescriptor) }
        }
    }

    static func cleanupAbandoned(destinationRoot: URL) throws {
        let stagingRoot = destinationRoot.appendingPathComponent(directoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: stagingRoot.path) else { return }
        try requireRealDirectory(stagingRoot, label: "the reserved staging path")

        let children = try FileManager.default.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [])
        for child in children {
            guard UUID(uuidString: child.lastPathComponent) != nil,
                  isRealDirectory(child),
                  owns(child) else { continue }

            let lockURL = child.appendingPathComponent(lockName)
            guard isRegularFileWithoutFollowingLink(lockURL) else { continue }
            let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            defer { _ = Darwin.close(descriptor) }

            // A live process holds LOCK_EX. A crash releases it, at which point
            // this exact marker-bound session is safe to reclaim.
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
            try FileManager.default.removeItem(at: child)
        }
    }

    static func begin(destinationRoot: URL, sessionID: UUID) throws -> Session {
        let stagingRoot = destinationRoot.appendingPathComponent(directoryName, isDirectory: true)
        if FileManager.default.fileExists(atPath: stagingRoot.path) {
            try requireRealDirectory(stagingRoot, label: "the reserved staging path")
        } else {
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: false)
            try requireRealDirectory(stagingRoot, label: "the reserved staging path")
        }

        let sessionRoot = stagingRoot.appendingPathComponent(
            sessionID.uuidString.lowercased(), isDirectory: true)
        guard DestinationPathSafety.contains(sessionRoot, under: destinationRoot) else {
            throw OffloadError.destinationUnwritable(stagingRoot.path)
        }
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: false)

        do {
            let lockURL = sessionRoot.appendingPathComponent(lockName)
            let descriptor = Darwin.open(
                lockURL.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC,
                S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw OffloadError.destinationUnwritable(lockURL.path)
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                _ = Darwin.close(descriptor)
                throw OffloadError.destinationUnwritable(lockURL.path)
            }
            // Publish the ownership marker only after the session lock is held.
            // Cleanup can therefore never observe an owned-but-not-yet-locked
            // session and mistake a concurrent startup for abandoned work.
            let marker = markerContents(sessionName: sessionRoot.lastPathComponent)
            guard FileManager.default.createFile(
                atPath: sessionRoot.appendingPathComponent(markerName).path,
                contents: Data(marker.utf8)) else {
                _ = Darwin.close(descriptor)
                throw OffloadError.destinationUnwritable(sessionRoot.path)
            }
            return Session(root: sessionRoot, lockDescriptor: descriptor)
        } catch {
            try? FileManager.default.removeItem(at: sessionRoot)
            throw error
        }
    }

    static func markerContents(sessionName: String) -> String {
        "vaultline-ingest-staging-v1\n\(sessionName)\n"
    }

    private static func owns(_ sessionRoot: URL) -> Bool {
        let marker = sessionRoot.appendingPathComponent(markerName)
        guard isRegularFileWithoutFollowingLink(marker),
              let data = try? Data(contentsOf: marker),
              data.count <= 256,
              let text = String(data: data, encoding: .utf8) else { return false }
        return text == markerContents(sessionName: sessionRoot.lastPathComponent)
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isRegularFileWithoutFollowingLink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func requireRealDirectory(_ url: URL, label: String) throws {
        guard isRealDirectory(url) else {
            throw OffloadError.destinationUnwritable("\(label) at \(url.path)")
        }
    }
}

// MARK: - Engine

/// Copies media off a card and proves it arrived intact.
///
/// The rules in `../spec.md` §3 live here, not in the UI:
///
/// - **Copy, never move.** There is no move path in this file.
/// - **Never delete operator data.** Only marker-bound, lock-proven temporary
///   transfer sessions created by this app can be reclaimed.
/// - **Never overwrite.** A destination that already holds *different* content
///   is reported as a conflict and left completely alone.
/// - **Verified means read back and matched**, not "the write returned".
///
/// One source read, fanned out to every destination.
///
/// ### Resume falls out of the collision rule
///
/// A file already at the destination is hashed and compared instead of being
/// overwritten. Identical → it's marked verified and nothing is written; that's
/// a re-run of an interrupted card. Different → conflict, untouched. The same
/// rule gives you safety and resume, with no dialog and no state file to go
/// stale.
actor OffloadEngine {

    private let bufferSize: Int

    init(bufferSize: Int = 4 * 1024 * 1024) {
        self.bufferSize = max(1, bufferSize)
    }

    func run(files: [IngestFile],
             destinations: [Destination],
             algorithm: ChecksumAlgorithm,
             onProgress: @escaping @Sendable (OffloadProgress) -> Void) async -> (OffloadProgress, [IngestFile]) {

        var progress = OffloadProgress()
        progress.totalFiles = files.count
        progress.totalBytes = files.reduce(0) { $0 + $1.size }
        progress.phase = .copying
        onProgress(progress)

        // Reclaim only marker-bound, unlocked sessions from an earlier crash.
        // Foreign contents and another running app instance remain untouched.
        for destination in destinations {
            do {
                try StagingArea.cleanupAbandoned(destinationRoot: URL(
                    fileURLWithPath: destination.root, isDirectory: true))
            } catch {
                let detail = "Couldn't clear an incomplete prior transfer at \(destination.label): \(error.localizedDescription)"
                progress.failures.append(detail)
                progress.phase = .failed
                let results = files.map { sourceFile in
                    var file = sourceFile
                    file.destinations[destination.root] = .failed(detail)
                    return file
                }
                onProgress(progress)
                return (progress, results)
            }
        }

        var results: [IngestFile] = []

        for var file in files {
            if Task.isCancelled {
                progress.phase = .cancelled
                progress.currentFile = ""
                onProgress(progress)
                return (progress, results)
            }

            progress.currentFile = file.originalName
            onProgress(progress)

            var toWrite: [Destination] = []
            var existing: [Destination] = []

            do {
                // ── Triage each destination before writing anything ────────
                for d in destinations {
                    let path = destinationPath(for: file, in: d)
                    if FileManager.default.fileExists(atPath: path) {
                        // Different size is a conflict without reading a byte.
                        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                        let onDisk = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
                        if onDisk == file.size {
                            existing.append(d)
                        } else {
                            file.destinations[d.root] = .conflict("a different file of that name is already there")
                        }
                    } else {
                        toWrite.append(d)
                    }
                }

                // Nothing left to do and nothing to check — every destination
                // conflicts. Record it and move on without touching the source.
                if toWrite.isEmpty && existing.isEmpty {
                    for d in destinations where file.destinations[d.root]?.isProblem == true {
                        progress.conflicts.append("\(file.relativePath) → \(d.label)")
                    }
                    results.append(file)
                    onProgress(progress)
                    continue
                }

                // ── One source read: hash it, write the copies that are due ──
                let copied = try await copyFanOut(
                    file: file, destinations: toWrite, algorithm: algorithm,
                    onBytes: { delta in
                        progress.bytesCopied += delta
                        onProgress(progress)
                    })
                let sourceHash = copied.sourceHash
                file.sourceHash = sourceHash
                for (root, state) in copied.states { file.destinations[root] = state }

                // ── Verify by reading back ────────────────────────────────
                progress.phase = .verifying
                onProgress(progress)

                for d in toWrite {
                    guard file.destinations[d.root] == nil else { continue }
                    file.destinations[d.root] = .failed("the destination copy was not finalized")
                }

                // ── Existing files: identical means already done ──────────
                for d in existing {
                    let path = destinationPath(for: file, in: d)
                    let hash = try await hashFile(at: path, algorithm: algorithm)
                    if hash == sourceHash {
                        file.destinations[d.root] = .alreadyVerified(hash: hash)
                        progress.filesAlreadyPresent += 1
                    } else {
                        file.destinations[d.root] = .conflict("a different file of that name is already there")
                    }
                }

                if file.destinations.count == destinations.count,
                   file.destinations.values.allSatisfy(\.isVerified) {
                    progress.filesVerified += 1
                }
                progress.phase = .copying

            } catch is CancellationError {
                for d in destinations where file.destinations[d.root] == nil {
                    file.destinations[d.root] = .skipped("stopped before verification")
                }
                results.append(file)
                progress.phase = .cancelled
                progress.currentFile = ""
                onProgress(progress)
                return (progress, results)
            } catch {
                // One bad file doesn't abandon the card. Record it, keep going,
                // and report exactly what didn't make it.
                for d in destinations where file.destinations[d.root] == nil {
                    file.destinations[d.root] = .failed(error.localizedDescription)
                }
            }

            for (root, state) in file.destinations where state.isProblem {
                let label = destinations.first { $0.root == root }?.label ?? root
                let line = "\(file.relativePath) → \(label)"
                if case .conflict = state { progress.conflicts.append(line) }
                else { progress.failures.append(line) }
            }

            results.append(file)
            onProgress(progress)
        }

        progress.phase = progress.hasProblems ? .failed : .done
        progress.currentFile = ""
        onProgress(progress)
        return (progress, results)
    }

    // MARK: Copy

    private struct FanOutResult {
        let sourceHash: String
        let states: [String: DestinationState]
    }

    private struct StagedDestination {
        let destination: Destination
        let finalURL: URL
        let stagingURL: URL
        let handle: FileHandle
    }

    /// Writes to an app-owned hidden staging area on each destination, then
    /// reads those bytes back before an atomic same-volume move into the final
    /// path. Cancellation or a failed destination therefore never leaves a
    /// partial file at the operator's intended media path.
    private func copyFanOut(file: IngestFile,
                            destinations: [Destination],
                            algorithm: ChecksumAlgorithm,
                            onBytes: (Int64) -> Void) async throws -> FanOutResult {

        guard let input = FileHandle(forReadingAtPath: file.sourcePath) else {
            throw OffloadError.unreadable(file.sourcePath)
        }
        defer { try? input.close() }
        let sourceAttributes = try? FileManager.default.attributesOfItem(atPath: file.sourcePath)

        let sessionID = UUID()
        var staged: [StagedDestination] = []
        var sessions: [StagingArea.Session] = []
        defer {
            for item in staged { try? item.handle.close() }
            for session in sessions { session.cleanup() }
        }

        // Open every staging file before reading the source, so an unavailable
        // destination fails without touching any final media path.
        for d in destinations {
            let finalURL = URL(fileURLWithPath: destinationPath(for: file, in: d))
            let session = try StagingArea.begin(
                destinationRoot: URL(fileURLWithPath: d.root, isDirectory: true),
                sessionID: sessionID)
            sessions.append(session)
            let stagingURL = session.root.appendingPathComponent(
                file.destinationRelativePath, isDirectory: false)
            try FileManager.default.createDirectory(
                at: stagingURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: stagingURL.path, contents: nil),
                  let handle = FileHandle(forWritingAtPath: stagingURL.path) else {
                throw OffloadError.destinationUnwritable(finalURL.path)
            }
            staged.append(StagedDestination(
                destination: d, finalURL: finalURL, stagingURL: stagingURL,
                handle: handle))
        }

        var hasher = StreamingHasher(algorithm)
        var sourceBytesRead = Int64(0)

        while true {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: bufferSize), !chunk.isEmpty else { break }
            sourceBytesRead += Int64(chunk.count)
            hasher.update(chunk)
            for item in staged { try item.handle.write(contentsOf: chunk) }
            if !staged.isEmpty { onBytes(Int64(chunk.count)) }
            await Task.yield()
        }
        try Task.checkCancellation()

        // A selected folder can still be written by a camera, recorder, or
        // another process. Never certify a transient partial view as a complete
        // source file: size drift or a modification-time change invalidates the
        // staged copies before anything reaches its final media path.
        let finalSourceAttributes = try? FileManager.default.attributesOfItem(atPath: file.sourcePath)
        let finalSourceSize = (finalSourceAttributes?[.size] as? NSNumber)?.int64Value
        let originalModificationDate = sourceAttributes?[.modificationDate] as? Date
        let finalModificationDate = finalSourceAttributes?[.modificationDate] as? Date
        guard sourceBytesRead == file.size,
              finalSourceSize == file.size,
              originalModificationDate == finalModificationDate else {
            throw OffloadError.sourceChanged(file.relativePath)
        }

        // Force to disk before claiming anything about it. Verifying a file
        // still sitting in the page cache proves nothing about the drive.
        for item in staged {
            try item.handle.synchronize()
            try item.handle.close()
            // Camera timestamps are operational metadata. Preserve the source
            // dates on the destination copy instead of making every clip look
            // as though it was created at ingest time. Some filesystems do not
            // support creation dates, so modification time is the mandatory
            // portable value and creation time is best-effort.
            if let modified = sourceAttributes?[.modificationDate] {
                try FileManager.default.setAttributes(
                    [.modificationDate: modified], ofItemAtPath: item.stagingURL.path)
            }
            if let created = sourceAttributes?[.creationDate] {
                try? FileManager.default.setAttributes(
                    [.creationDate: created], ofItemAtPath: item.stagingURL.path)
            }
        }

        let sourceHash = hasher.hexDigest()
        var states: [String: DestinationState] = [:]

        for item in staged {
            try Task.checkCancellation()
            let stagedHash = try await hashFile(at: item.stagingURL.path, algorithm: algorithm)
            guard stagedHash == sourceHash else {
                states[item.destination.root] = .failed("checksum mismatch in the staged copy")
                continue
            }

            if FileManager.default.fileExists(atPath: item.finalURL.path) {
                let existingHash = try await hashFile(at: item.finalURL.path, algorithm: algorithm)
                states[item.destination.root] = existingHash == sourceHash
                    ? .alreadyVerified(hash: existingHash)
                    : .conflict("a different file of that name appeared during the copy")
                continue
            }

            do {
                guard DestinationPathSafety.contains(
                    item.finalURL,
                    under: URL(fileURLWithPath: item.destination.root, isDirectory: true)) else {
                    states[item.destination.root] = .failed(
                        "a linked folder would publish this file outside the selected destination")
                    continue
                }
                try FileManager.default.createDirectory(
                    at: item.finalURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: item.stagingURL, to: item.finalURL)
                let finalHash = try await hashFile(at: item.finalURL.path, algorithm: algorithm)
                states[item.destination.root] = finalHash == sourceHash
                    ? .verified(hash: finalHash)
                    : .failed("checksum mismatch — the final copy does not match the source")
            } catch {
                states[item.destination.root] = .failed(error.localizedDescription)
            }
        }

        return FanOutResult(sourceHash: sourceHash, states: states)
    }

    // MARK: Verify

    private func hashFile(at path: String, algorithm: ChecksumAlgorithm) async throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw OffloadError.unreadable(path)
        }
        defer { try? handle.close() }

        var hasher = StreamingHasher(algorithm)
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: bufferSize), !chunk.isEmpty else { break }
            hasher.update(chunk)
            await Task.yield()
        }
        return hasher.hexDigest()
    }

    private nonisolated func destinationPath(for file: IngestFile, in d: Destination) -> String {
        (d.root as NSString).appendingPathComponent(file.destinationRelativePath)
    }

    // MARK: Planning

    /// Walks a card, applies the naming convention, and produces the work list.
    ///
    /// Naming is resolved here, once, up front — so the UI can show people
    /// exactly what their files will be called *before* anything is written.
    /// Discovering a rename after the fact is how people lose track of footage.
    nonisolated static func plan(source: URL, naming: NamingConfig) throws -> [IngestFile] {
        switch planCancellable(source: source, naming: naming, shouldContinue: { true }) {
        case .planned(let files): return files
        case .cancelled: throw CancellationError()
        case .failed(let failure): throw failure
        }
    }

    /// The same deterministic planner with a cooperative cancellation seam.
    /// Large cards can contain tens of thousands of filesystem entries; the
    /// app runs this off the main actor and abandons obsolete scans when the
    /// operator changes cards or naming rules.
    nonisolated static func planCancellable(
        source: URL,
        naming: NamingConfig,
        shouldContinue: () -> Bool
    ) -> SourcePlanningResult {
        let skippedFiles: Set<String> = [".ds_store", "thumbs.db"]
        let skippedDirectories: Set<String> = [
            ".spotlight-v100", ".fseventsd", ".trashes", ".temporaryitems"
        ]
        // Resolve the selected root before walking it because Foundation may
        // canonicalize `/var` to `/private/var`. Every returned URL is then
        // proven to remain under that root before it becomes an output path.
        let root = source.standardizedFileURL.resolvingSymlinksInPath()
        var raw: [(path: String, rel: String, size: Int64)] = []
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        var pendingDirectories = [root]
        while let directory = pendingDirectories.popLast() {
            guard shouldContinue() else { return .cancelled }
            let children: [URL]
            do {
                // Unlike FileManager's recursive enumerator, this explicit walk
                // cannot silently swallow a directory-read error. Hidden camera
                // metadata is included; only the named OS debris below is skipped.
                children = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: keys,
                    options: [])
            } catch {
                return .failed(failure(for: directory, root: root, error: error))
            }
            for url in children {
                guard shouldContinue() else { return .cancelled }
                let relative: String
                do {
                    relative = try relativePath(of: url, under: root)
                } catch let failure as SourceDiscoveryFailure {
                    return .failed(failure)
                } catch {
                    return .failed(SourceDiscoveryFailure(
                        relativePath: url.lastPathComponent, detail: error.localizedDescription))
                }
                let v: URLResourceValues
                do {
                    v = try url.resourceValues(forKeys: Set(keys))
                } catch {
                    return .failed(failure(for: url, root: root, error: error))
                }
                let lowerName = url.lastPathComponent.lowercased()
                if v.isSymbolicLink == true { continue }
                if v.isDirectory == true {
                    if !skippedDirectories.contains(lowerName) {
                        pendingDirectories.append(url)
                    }
                    continue
                }
                guard v.isRegularFile == true else { continue }
                // AppleDouble sidecars are Finder metadata, not camera assets.
                // macOS creates them as `._*` files on ExFAT/FAT volumes, including
                // beside otherwise valuable hidden camera metadata.
                if skippedFiles.contains(lowerName) || lowerName.hasPrefix("._") { continue }

                raw.append((url.path, relative, Int64(v.fileSize ?? 0)))
            }
        }

        // Stable order so sequence numbers are reproducible across re-runs —
        // otherwise resuming an interrupted card would rename everything.
        guard shouldContinue() else { return .cancelled }
        raw.sort { $0.rel < $1.rel }

        let renaming = naming.renameOnIngest && !naming.fileTemplate.isEmpty
        var values = NameTemplate.Values()
        values.code = naming.projectCode
        values.reel = source.lastPathComponent

        var planned: [IngestFile] = []
        planned.reserveCapacity(raw.count)
        for (i, f) in raw.enumerated() {
            guard shouldContinue() else { return .cancelled }
            let dest = renaming
                ? NameTemplate.destinationPath(fileTemplate: naming.fileTemplate,
                                               folderTemplate: naming.folderTemplate,
                                               originalRelativePath: f.rel,
                                               values: values,
                                               index: i + 1)
                : f.rel
            planned.append(IngestFile(sourcePath: f.path,
                                      relativePath: f.rel,
                                      destinationRelativePath: dest,
                                      size: f.size))
        }
        return .planned(planned)
    }

    private nonisolated static func relativePath(of url: URL, under root: URL) throws -> String {
        let path = url.standardizedFileURL.path
        let prefix = root.path == "/" ? "/" : root.path + "/"
        guard path.hasPrefix(prefix) else {
            throw SourceDiscoveryFailure(
                relativePath: url.lastPathComponent,
                detail: "The source enumerator returned an item outside the selected source.")
        }
        return String(path.dropFirst(prefix.count))
    }

    private nonisolated static func failure(
        for url: URL, root: URL, error: Error
    ) -> SourceDiscoveryFailure {
        let relative = (try? relativePath(of: url, under: root)) ?? url.lastPathComponent
        return SourceDiscoveryFailure(relativePath: relative, detail: error.localizedDescription)
    }
}

/// Runs card discovery outside the UI actor while propagating cancellation to
/// the detached filesystem walk. A failed result blocks ingest; a partial plan
/// is never published as though it represented the complete source.
enum SourcePlanner {
    static func plan(source: URL, naming: NamingConfig) async -> SourcePlanningResult {
        let worker = Task.detached(priority: .userInitiated) {
            OffloadEngine.planCancellable(
                source: source,
                naming: naming,
                shouldContinue: { !Task.isCancelled })
        }
        return await withTaskCancellationHandler(
            operation: { await worker.value },
            onCancel: { worker.cancel() })
    }
}
