import Foundation
import SQLite3

final class CleanupStore {
    private let database: OpaquePointer

    init(url: URL) throws {
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path, &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard result == SQLITE_OK, let connection else {
            sqlite3_close(connection)
            throw StorageError.operationFailed
        }
        database = connection
        try execute("""
            BEGIN IMMEDIATE;
            CREATE TABLE IF NOT EXISTS quota (
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                used INTEGER NOT NULL CHECK(used >= 0)
            );
            INSERT OR IGNORE INTO quota VALUES (1, 0);
            CREATE TABLE IF NOT EXISTS pending (
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                batch_id TEXT NOT NULL,
                asset_ids TEXT NOT NULL,
                count INTEGER NOT NULL CHECK(count > 0),
                confirmed_at REAL
            );
            CREATE TABLE IF NOT EXISTS history (
                batch_id TEXT PRIMARY KEY,
                completed_at REAL NOT NULL,
                count INTEGER NOT NULL
            );
            COMMIT;
            """)
    }

    deinit {
        sqlite3_close(database)
    }

    static func openLocal() throws -> CleanupStore {
        var directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Cleanup", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return try CleanupStore(url: directory.appendingPathComponent("cleanup.sqlite"))
    }

    func remaining() throws -> Int {
        try statement("SELECT used FROM quota WHERE singleton = 1") { query in
            guard sqlite3_step(query) == SQLITE_ROW else { throw StorageError.operationFailed }
            return max(0, CleanupLimits.freeItems - Int(sqlite3_column_int64(query, 0)))
        }
    }

    func pending() throws -> PendingCleanup? {
        try statement("SELECT batch_id, confirmed_at FROM pending WHERE singleton = 1") { query in
            switch sqlite3_step(query) {
            case SQLITE_DONE:
                return nil
            case SQLITE_ROW:
                guard let id = sqlite3_column_text(query, 0) else { throw StorageError.operationFailed }
                let date = sqlite3_column_type(query, 1) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(query, 1))
                return PendingCleanup(id: String(cString: id), confirmedAt: date)
            default:
                throw StorageError.operationFailed
            }
        }
    }

    func prepare(id: String, assetIDs: [String]) throws {
        let unique = Set(assetIDs)
        guard !unique.isEmpty, unique.count == assetIDs.count,
              unique.count <= CleanupLimits.batchSize
        else { throw StorageError.operationFailed }
        let encoded = try JSONEncoder().encode(unique.sorted())
        try transaction {
            guard try remaining() >= unique.count else { throw StorageError.operationFailed }
            try statement("INSERT INTO pending VALUES (1, ?, ?, ?, NULL)") { query in
                try bind(id, to: query, at: 1)
                try bind(String(decoding: encoded, as: UTF8.self), to: query, at: 2)
                try check(sqlite3_bind_int64(query, 3, Int64(unique.count)))
                try finish(query)
            }
        }
    }

    func confirm(id: String, at date: Date) throws {
        try statement("UPDATE pending SET confirmed_at = ?, asset_ids = '[]' WHERE batch_id = ? AND confirmed_at IS NULL") { query in
            try check(sqlite3_bind_double(query, 1, date.timeIntervalSince1970))
            try bind(id, to: query, at: 2)
            try finish(query)
        }
    }

    func settle(id: String) throws {
        try transaction {
            guard let batch = try pending(), batch.id == id, let date = batch.confirmedAt else { return }
            try execute("UPDATE quota SET used = used + (SELECT count FROM pending WHERE singleton = 1) WHERE singleton = 1")
            try execute("INSERT INTO history SELECT batch_id, confirmed_at, count FROM pending WHERE singleton = 1")
            try execute("DELETE FROM pending WHERE singleton = 1")
            try pruneHistory(now: date)
        }
    }

    func discardUnconfirmed(id: String) throws {
        try statement("DELETE FROM pending WHERE batch_id = ? AND confirmed_at IS NULL") { query in
            try bind(id, to: query, at: 1)
            try finish(query)
        }
    }

    func history() throws -> [CleanupHistory] {
        try pruneHistory(now: .now)
        return try statement("SELECT batch_id, completed_at, count FROM history ORDER BY completed_at DESC, batch_id DESC") { query in
            var rows: [CleanupHistory] = []
            var result = sqlite3_step(query)
            while result == SQLITE_ROW {
                guard let id = sqlite3_column_text(query, 0) else { throw StorageError.operationFailed }
                rows.append(CleanupHistory(
                    id: String(cString: id),
                    date: Date(timeIntervalSince1970: sqlite3_column_double(query, 1)),
                    count: Int(sqlite3_column_int64(query, 2))
                ))
                result = sqlite3_step(query)
            }
            guard result == SQLITE_DONE else { throw StorageError.operationFailed }
            return rows
        }
    }

    func clearHistory() throws {
        try execute("DELETE FROM history")
    }

    private func pruneHistory(now: Date) throws {
        let cutoff = now.addingTimeInterval(-90 * 86_400).timeIntervalSince1970
        try statement("DELETE FROM history WHERE completed_at < ? OR batch_id IN (SELECT batch_id FROM history ORDER BY completed_at DESC, batch_id DESC LIMIT -1 OFFSET 50)") { query in
            try check(sqlite3_bind_double(query, 1, cutoff))
            try finish(query)
        }
    }

    private func transaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try operation()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        try check(sqlite3_exec(database, sql, nil, nil, nil))
    }

    private func statement<Value>(_ sql: String, _ operation: (OpaquePointer) throws -> Value) throws -> Value {
        var query: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &query, nil)
        defer { sqlite3_finalize(query) }
        guard result == SQLITE_OK, let query else { throw StorageError.operationFailed }
        return try operation(query)
    }

    private func bind(_ value: String, to query: OpaquePointer, at index: Int32) throws {
        try check(sqlite3_bind_text(query, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw StorageError.operationFailed }
    }

    private func finish(_ query: OpaquePointer) throws {
        guard sqlite3_step(query) == SQLITE_DONE else { throw StorageError.operationFailed }
    }

    private enum StorageError: Error {
        case operationFailed
    }
}
