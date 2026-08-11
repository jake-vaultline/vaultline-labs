import Foundation

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
    case alreadyVerified
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

    var errorDescription: String? {
        switch self {
        case .unreadable(let p):            return "Couldn't read \(p)."
        case .destinationUnwritable(let p): return "Can't write to \(p)."
        }
    }
}

// MARK: - Engine

/// Copies media off a card and proves it arrived intact.
///
/// The rules in `../spec.md` §3 live here, not in the UI:
///
/// - **Copy, never move.** There is no move path in this file.
/// - **Never delete.** There is no delete path either.
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

    private let bufferSize = 4 * 1024 * 1024

    func run(files: [IngestFile],
             destinations: [Destination],
             algorithm: ChecksumAlgorithm,
             onProgress: @escaping @Sendable (OffloadProgress) -> Void) async -> (OffloadProgress, [IngestFile]) {

        var progress = OffloadProgress()
        progress.totalFiles = files.count
        progress.totalBytes = files.reduce(0) { $0 + $1.size }
        progress.phase = .copying
        onProgress(progress)

        var results: [IngestFile] = []

        for var file in files {
            if Task.isCancelled {
                progress.phase = .cancelled
                onProgress(progress)
                return (progress, results)
            }

            progress.currentFile = file.originalName
            onProgress(progress)

            do {
                // ── Triage each destination before writing anything ────────
                var toWrite: [Destination] = []
                var existing: [Destination] = []

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
                let sourceHash = try copyFanOut(
                    file: file, destinations: toWrite, algorithm: algorithm,
                    onBytes: { delta in
                        progress.bytesCopied += delta
                        onProgress(progress)
                    })
                file.sourceHash = sourceHash

                // ── Verify by reading back ────────────────────────────────
                progress.phase = .verifying
                onProgress(progress)

                for d in toWrite {
                    let path = destinationPath(for: file, in: d)
                    let hash = try hashFile(at: path, algorithm: algorithm)
                    file.destinations[d.root] = hash == sourceHash
                        ? .verified(hash: hash)
                        : .failed("checksum mismatch — the copy does not match the source")
                }

                // ── Existing files: identical means already done ──────────
                for d in existing {
                    let path = destinationPath(for: file, in: d)
                    let hash = try hashFile(at: path, algorithm: algorithm)
                    if hash == sourceHash {
                        file.destinations[d.root] = .alreadyVerified
                        progress.filesAlreadyPresent += 1
                    } else {
                        file.destinations[d.root] = .conflict("a different file of that name is already there")
                    }
                }

                for (root, st) in file.destinations where st.isProblem {
                    let label = destinations.first { $0.root == root }?.label ?? root
                    let line = "\(file.relativePath) → \(label)"
                    if case .conflict = st { progress.conflicts.append(line) }
                    else { progress.failures.append(line) }
                }

                if !file.destinations.isEmpty,
                   file.destinations.values.allSatisfy(\.isVerified) {
                    progress.filesVerified += 1
                }
                progress.phase = .copying

            } catch {
                // One bad file doesn't abandon the card. Record it, keep going,
                // and report exactly what didn't make it.
                progress.failures.append("\(file.relativePath) — \(error.localizedDescription)")
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

    private func copyFanOut(file: IngestFile,
                            destinations: [Destination],
                            algorithm: ChecksumAlgorithm,
                            onBytes: (Int64) -> Void) throws -> String {

        guard let input = FileHandle(forReadingAtPath: file.sourcePath) else {
            throw OffloadError.unreadable(file.sourcePath)
        }
        defer { try? input.close() }

        // Open every destination before writing a byte, so a read-only volume
        // fails the file before it half-lands somewhere else.
        var handles: [FileHandle] = []
        for d in destinations {
            let path = destinationPath(for: file, in: d)
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: path, contents: nil),
                  let h = FileHandle(forWritingAtPath: path) else {
                throw OffloadError.destinationUnwritable(path)
            }
            handles.append(h)
        }
        defer { for h in handles { try? h.close() } }

        var hasher = StreamingHasher(algorithm)

        while true {
            guard let chunk = try input.read(upToCount: bufferSize), !chunk.isEmpty else { break }
            hasher.update(chunk)
            for h in handles { try h.write(contentsOf: chunk) }
            onBytes(Int64(chunk.count))
            if Task.isCancelled { break }
        }

        // Force to disk before claiming anything about it. Verifying a file
        // still sitting in the page cache proves nothing about the drive.
        for h in handles { try h.synchronize() }

        return hasher.hexDigest()
    }

    // MARK: Verify

    private func hashFile(at path: String, algorithm: ChecksumAlgorithm) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw OffloadError.unreadable(path)
        }
        defer { try? handle.close() }

        var hasher = StreamingHasher(algorithm)
        while true {
            guard let chunk = try handle.read(upToCount: bufferSize), !chunk.isEmpty else { break }
            hasher.update(chunk)
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
    nonisolated static func plan(source: URL, naming: NamingConfig) -> [IngestFile] {
        let skip: Set<String> = [".ds_store", "thumbs.db", ".spotlight-v100", ".fseventsd"]
        let root = source.path
        var raw: [(path: String, rel: String, size: Int64)] = []

        guard let e = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  v.isRegularFile == true else { continue }
            if skip.contains(url.lastPathComponent.lowercased()) { continue }

            var rel = url.path
            if rel.hasPrefix(root) { rel = String(rel.dropFirst(root.count)) }
            rel = rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
            raw.append((url.path, rel, Int64(v.fileSize ?? 0)))
        }

        // Stable order so sequence numbers are reproducible across re-runs —
        // otherwise resuming an interrupted card would rename everything.
        raw.sort { $0.rel < $1.rel }

        let renaming = naming.renameOnIngest && !naming.fileTemplate.isEmpty
        var values = NameTemplate.Values()
        values.code = naming.projectCode
        values.reel = source.lastPathComponent

        return raw.enumerated().map { i, f in
            let dest = renaming
                ? NameTemplate.destinationPath(fileTemplate: naming.fileTemplate,
                                               folderTemplate: naming.folderTemplate,
                                               originalRelativePath: f.rel,
                                               values: values,
                                               index: i + 1)
                : f.rel
            return IngestFile(sourcePath: f.path,
                              relativePath: f.rel,
                              destinationRelativePath: dest,
                              size: f.size)
        }
    }
}
