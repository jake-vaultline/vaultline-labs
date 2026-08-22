import Foundation
import CryptoKit

/// A resumable, exact-content duplicate verifier.
///
/// Exact size and a first/last-chunk hash cheaply remove non-matches. Unlike
/// 0.1, a partial collision is never reported as reclaimable: every path in
/// `groups` has also passed a complete SHA-256 file hash.
enum DuplicateFinder {
    static let minimumSize: Int64 = 4 * 1024 * 1024
    static let defaultReadBudget: Int64 = 24 * 1024 * 1024 * 1024
    static let chunk = 1024 * 1024

    struct CandidateGroup {
        let size: Int64
        let files: [FileEntry]
    }

    /// Kept out of ScanSnapshot because a session may retain hundreds of
    /// thousands of paths between Continue actions.
    final class Session: @unchecked Sendable {
        fileprivate var sizeGroups: [CandidateGroup]
        fileprivate var fullHashGroups: [CandidateGroup] = []
        fileprivate var forcedFullGroups = 0
        fileprivate var summary: DuplicateSummary

        fileprivate init(files: [FileEntry]) {
            var bySize: [Int64: [FileEntry]] = [:]
            for file in files where file.size >= minimumSize {
                bySize[file.size, default: []].append(file)
            }
            sizeGroups = bySize
                .filter { $0.value.count > 1 }
                .map { CandidateGroup(size: $0.key, files: $0.value.sorted { $0.path < $1.path }) }
                .sorted {
                    let left = $0.size * Int64($0.files.count)
                    let right = $1.size * Int64($1.files.count)
                    return left == right ? $0.size < $1.size : left < right
                }
            summary = DuplicateSummary()
            summary.candidatesTotal = sizeGroups.reduce(0) { $0 + $1.files.count }
            summary.remainingCandidateFiles = summary.candidatesTotal
        }
    }

    static func makeSession(_ files: [FileEntry]) -> Session { Session(files: files) }

    /// Continue for a bounded amount of I/O. A single group may exceed the
    /// budget so one very large duplicate can never cause a no-progress loop.
    static func run(
        _ session: Session,
        readBudget: Int64 = defaultReadBudget
    ) -> AsyncStream<DuplicateSummary> {
        AsyncStream { continuation in
            let work = Task.detached(priority: .utility) {
                var used: Int64 = 0
                session.summary.isRunning = true
                session.summary.isPaused = false
                session.summary.wasCancelled = false

                guard session.summary.candidatesTotal > 0 else {
                    session.summary.isRunning = false
                    session.summary.isComplete = true
                    continuation.yield(session.summary)
                    continuation.finish()
                    return
                }
                continuation.yield(session.summary)

                var lastYield = Date()
                while !Task.isCancelled {
                    if let group = session.fullHashGroups.first {
                        let estimated = group.size * Int64(group.files.count)
                        if session.forcedFullGroups == 0 && used > 0
                            && used + estimated > max(1, readBudget) { break }
                        session.fullHashGroups.removeFirst()
                        used += verifyFullGroup(group, summary: &session.summary)
                        session.forcedFullGroups = max(0, session.forcedFullGroups - 1)
                    } else if let group = session.sizeGroups.first {
                        let estimated = partialReadSize(group)
                        if used > 0 && used + estimated > max(1, readBudget) { break }
                        session.sizeGroups.removeFirst()
                        used += filterPartialGroup(group, session: session)
                    } else {
                        break
                    }

                    session.summary.remainingCandidateFiles = remainingFiles(session)
                    if Date().timeIntervalSince(lastYield) >= 0.2 {
                        lastYield = Date()
                        continuation.yield(sorted(session.summary))
                    }
                }

                session.summary.isRunning = false
                if Task.isCancelled {
                    let excluded = max(
                        session.summary.remainingCandidateFiles,
                        max(remainingFiles(session), session.summary.candidatesTotal - session.summary.candidatesChecked)
                    )
                    session.summary.cancelledFiles = max(session.summary.cancelledFiles, excluded)
                    session.summary.remainingCandidateFiles = 0
                    session.summary.isComplete = false
                    session.summary.isPaused = false
                    session.summary.wasCancelled = true
                } else if session.summary.remainingCandidateFiles > 0 {
                    session.summary.remainingCandidateFiles = remainingFiles(session)
                    session.summary.isComplete = false
                    session.summary.isPaused = true
                } else {
                    session.summary.remainingCandidateFiles = remainingFiles(session)
                    session.summary.isComplete = true
                    session.summary.isPaused = false
                }
                continuation.yield(sorted(session.summary))
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private static func filterPartialGroup(_ group: CandidateGroup, session: Session) -> Int64 {
        var byPartial: [String: [FileEntry]] = [:]
        var bytes: Int64 = 0
        for file in group.files {
            if Task.isCancelled { break }
            switch hash(file, mode: .partial) {
            case let .success(digest, read):
                byPartial[digest, default: []].append(file)
                bytes += read
            case .unreadable:
                session.summary.unreadableFiles += 1
            case .changed:
                session.summary.changedFiles += 1
            case .cancelled:
                break
            }
            session.summary.candidatesChecked += 1
        }
        session.summary.bytesRead += bytes
        let collisions = byPartial
            .filter { $0.value.count > 1 }
            .map { CandidateGroup(size: group.size, files: $0.value) }
            .sorted { ($0.files.first?.path ?? "") < ($1.files.first?.path ?? "") }
        // A partial collision is still pending until its complete-file hash
        // finishes, so it must not advance the verified-candidate progress.
        session.summary.candidatesChecked -= collisions.reduce(0) { $0 + $1.files.count }
        session.fullHashGroups.append(contentsOf: collisions)
        session.forcedFullGroups += collisions.count
        return bytes
    }

    private static func verifyFullGroup(_ group: CandidateGroup, summary: inout DuplicateSummary) -> Int64 {
        var byFull: [String: [String]] = [:]
        var bytes: Int64 = 0
        for file in group.files {
            if Task.isCancelled { break }
            switch hash(file, mode: .full) {
            case let .success(digest, read):
                byFull[digest, default: []].append(file.path)
                bytes += read
                summary.candidatesChecked += 1
            case .unreadable:
                summary.unreadableFiles += 1
                summary.candidatesChecked += 1
            case .changed:
                summary.changedFiles += 1
                summary.candidatesChecked += 1
            case .cancelled:
                break
            }
        }
        summary.bytesRead += bytes
        for paths in byFull.values where paths.count > 1 {
            summary.groups.append(DuplicateGroup(size: group.size, paths: paths.sorted()))
        }
        return bytes
    }

    private static func remainingFiles(_ session: Session) -> Int {
        session.sizeGroups.reduce(0) { $0 + $1.files.count }
            + session.fullHashGroups.reduce(0) { $0 + $1.files.count }
    }

    private static func partialReadSize(_ group: CandidateGroup) -> Int64 {
        min(group.size, Int64(chunk * 2)) * Int64(group.files.count)
    }

    private static func sorted(_ summary: DuplicateSummary) -> DuplicateSummary {
        var out = summary
        out.groups.sort {
            if $0.recoverable == $1.recoverable { return $0.name < $1.name }
            return $0.recoverable > $1.recoverable
        }
        return out
    }

    private enum HashMode { case partial, full }
    private enum HashResult {
        case success(String, Int64)
        case unreadable
        case changed
        case cancelled
    }

    private struct Fingerprint: Equatable {
        let size: Int64
        let modified: Date?
    }

    private static func fingerprint(_ path: String) -> Fingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return Fingerprint(size: size.int64Value, modified: attributes[.modificationDate] as? Date)
    }

    private static func matchesEntry(_ fingerprint: Fingerprint, _ file: FileEntry) -> Bool {
        guard fingerprint.size == file.size else { return false }
        guard let expected = file.modified, let actual = fingerprint.modified else { return true }
        // Filesystems and URLResourceValues do not promise identical subsecond
        // precision across enumeration and a later lookup. The before/after
        // fingerprint comparison below remains exact for in-flight changes.
        return abs(expected.timeIntervalSince(actual)) < 1.0
    }

    private static func hash(_ file: FileEntry, mode: HashMode) -> HashResult {
        guard let before = fingerprint(file.path), matchesEntry(before, file) else { return .changed }
        guard let handle = FileHandle(forReadingAtPath: file.path) else { return .unreadable }
        defer { try? handle.close() }

        var hasher = SHA256()
        var bytesRead: Int64 = 0
        switch mode {
        case .partial:
            withUnsafeBytes(of: file.size.littleEndian) { hasher.update(bufferPointer: $0) }
            guard let head = try? handle.read(upToCount: chunk) else { return .unreadable }
            hasher.update(data: head)
            bytesRead += Int64(head.count)
            if file.size > Int64(chunk * 2) {
                guard (try? handle.seek(toOffset: UInt64(file.size) - UInt64(chunk))) != nil,
                      let tail = try? handle.read(upToCount: chunk) else { return .unreadable }
                hasher.update(data: tail)
                bytesRead += Int64(tail.count)
            }
        case .full:
            while true {
                if Task.isCancelled { return .cancelled }
                let data: Data
                do {
                    guard let next = try handle.read(upToCount: chunk * 4) else { break }
                    data = next
                } catch { return .unreadable }
                if data.isEmpty { break }
                hasher.update(data: data)
                bytesRead += Int64(data.count)
            }
        }

        guard let after = fingerprint(file.path), before == after else { return .changed }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return .success(digest, bytesRead)
    }
}
