import Foundation
import SQLite3

/// Durable, metadata-only queue for Drive Passport snapshot uploads.
///
/// The queue lives in the app sandbox's Application Support directory. It never
/// contains media, filenames, raw paths, or device credentials. Device tokens
/// remain in Keychain and are looked up only when a retry is attempted.
final class PassportOutbox {
    struct Item {
        let id: String
        let serviceURL: String
        let driveID: String
        let volumeID: String
        let payload: Data
        let idempotencyKey: String
        let attempts: Int
    }

    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL? = nil) throws {
        let resolvedURL: URL
        if let databaseURL {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            resolvedURL = databaseURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask)[0]
                .appendingPathComponent("Vaultline Ingest", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            resolvedURL = base.appendingPathComponent("passport-outbox.sqlite3")
        }
        let path = resolvedURL.path
        guard sqlite3_open_v2(path, &database,
                              SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else {
            throw failure("open")
        }
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = FULL")
        try execute("""
            CREATE TABLE IF NOT EXISTS passport_outbox (
              id TEXT PRIMARY KEY,
              service_url TEXT NOT NULL,
              drive_id TEXT NOT NULL,
              volume_id TEXT NOT NULL,
              payload BLOB NOT NULL,
              idempotency_key TEXT NOT NULL UNIQUE,
              attempts INTEGER NOT NULL DEFAULT 0,
              next_attempt_at INTEGER NOT NULL,
              created_at INTEGER NOT NULL,
              last_error TEXT
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS idx_passport_outbox_ready ON passport_outbox(next_attempt_at, created_at)")
        try execute("PRAGMA optimize")
    }

    deinit { sqlite3_close(database) }

    @discardableResult
    func enqueue(serviceURL: String, driveID: String, volumeID: String,
                 payload: Data, idempotencyKey: String) throws -> String {
        let id = UUID().uuidString
        let now = milliseconds(Date())
        let statement = try prepare("""
            INSERT OR IGNORE INTO passport_outbox
              (id, service_url, drive_id, volume_id, payload, idempotency_key,
               attempts, next_attempt_at, created_at, last_error)
            VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, NULL)
            """)
        defer { sqlite3_finalize(statement) }
        bind(id, to: statement, at: 1)
        bind(serviceURL, to: statement, at: 2)
        bind(driveID, to: statement, at: 3)
        bind(volumeID, to: statement, at: 4)
        _ = payload.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 5, bytes.baseAddress, Int32(bytes.count), transient)
        }
        bind(idempotencyKey, to: statement, at: 6)
        sqlite3_bind_int64(statement, 7, now)
        sqlite3_bind_int64(statement, 8, now)
        try stepDone(statement, operation: "enqueue")
        return try existingID(for: idempotencyKey) ?? id
    }

    func ready(limit: Int = 20) throws -> [Item] {
        let statement = try prepare("""
            SELECT id, service_url, drive_id, volume_id, payload,
                   idempotency_key, attempts
            FROM passport_outbox
            WHERE next_attempt_at <= ?
            ORDER BY created_at ASC
            LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, milliseconds(Date()))
        sqlite3_bind_int(statement, 2, Int32(limit))
        var items: [Item] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let bytes = sqlite3_column_blob(statement, 4)
            let count = Int(sqlite3_column_bytes(statement, 4))
            let payload = bytes.map { Data(bytes: $0, count: count) } ?? Data()
            items.append(Item(
                id: text(statement, 0), serviceURL: text(statement, 1),
                driveID: text(statement, 2), volumeID: text(statement, 3),
                payload: payload, idempotencyKey: text(statement, 5),
                attempts: Int(sqlite3_column_int(statement, 6))))
        }
        return items
    }

    func remove(_ id: String) throws {
        let statement = try prepare("DELETE FROM passport_outbox WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(id, to: statement, at: 1)
        try stepDone(statement, operation: "remove")
    }

    func recordFailure(_ id: String, attempts: Int, error: String) throws {
        let nextAttempts = attempts + 1
        let seconds = min(3600, Int(pow(2.0, Double(min(nextAttempts, 9)))) * 5)
        let next = milliseconds(Date().addingTimeInterval(TimeInterval(seconds)))
        let statement = try prepare("""
            UPDATE passport_outbox
            SET attempts = ?, next_attempt_at = ?, last_error = ?
            WHERE id = ?
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(nextAttempts))
        sqlite3_bind_int64(statement, 2, next)
        bind(String(error.prefix(500)), to: statement, at: 3)
        bind(id, to: statement, at: 4)
        try stepDone(statement, operation: "record failure")
    }

    func contains(_ id: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM passport_outbox WHERE id = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bind(id, to: statement, at: 1)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func attempts(for id: String) throws -> Int {
        let statement = try prepare("SELECT attempts FROM passport_outbox WHERE id = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bind(id, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    func count() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM passport_outbox")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure("count") }
        return Int(sqlite3_column_int(statement, 0))
    }

#if DEBUG
    /// Deterministic integration-test hook. Production retry timing remains the
    /// exponential backoff recorded by `recordFailure`.
    func makeAllReadyForTesting() throws {
        try execute("UPDATE passport_outbox SET next_attempt_at = 0")
    }
#endif

    private func existingID(for idempotencyKey: String) throws -> String? {
        let statement = try prepare("SELECT id FROM passport_outbox WHERE idempotency_key = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bind(idempotencyKey, to: statement, at: 1)
        return sqlite3_step(statement) == SQLITE_ROW ? text(statement, 0) : nil
    }

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
            sqlite3_free(message)
            throw PassportOutboxError.database(detail ?? "SQLite operation failed")
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure("prepare") }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer, operation: String) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(operation) }
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    private func failure(_ operation: String) -> PassportOutboxError {
        let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "database unavailable"
        return .database("Could not \(operation) Drive Passport outbox: \(detail)")
    }
}

enum PassportOutboxError: LocalizedError {
    case database(String)
    var errorDescription: String? {
        switch self { case .database(let message): return message }
    }
}
