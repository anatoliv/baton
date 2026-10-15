import CSQLite
import Foundation

/// A value bound into, or read out of, a statement.
public enum SQLValue: Equatable, Sendable {
    case null
    case int(Int64)
    case text(String)

    public var int: Int64? { if case let .int(v) = self { v } else { nil } }
    public var text: String? { if case let .text(v) = self { v } else { nil } }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// The smallest SQLite wrapper `baton-share` needs: one connection, statements prepared per call,
/// rows as dictionaries.
///
/// **Not thread-safe by itself.** `ShareService` owns the only instance and serializes every call
/// behind its lock; the connection is also opened `FULLMUTEX` so a mistake there is a stall
/// rather than corruption. Prepared-per-call is deliberate: the service handles a few requests a
/// second at most, and a statement cache is a place for a stale binding to hide.
public final class SQLiteDatabase {
    private var handle: OpaquePointer?

    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw SQLiteError(message: "open \(path): \(message)")
        }
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit { sqlite3_close(handle) }

    /// Runs one or more statements that take no parameters (schema, pragmas).
    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw SQLiteError(message: message)
        }
    }

    /// Runs a statement and returns the number of rows it changed.
    @discardableResult
    public func run(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int {
        try withStatement(sql, parameters) { statement in
            let code = sqlite3_step(statement)
            guard code == SQLITE_DONE || code == SQLITE_ROW else { throw lastError(sql) }
            return Int(sqlite3_changes(handle))
        }
    }

    /// Runs a query and returns every row, column name to value.
    public func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [[String: SQLValue]] {
        try withStatement(sql, parameters) { statement in
            var rows: [[String: SQLValue]] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw lastError(sql) }
                var row: [String: SQLValue] = [:]
                for column in 0 ..< sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, column))
                    switch sqlite3_column_type(statement, column) {
                    case SQLITE_INTEGER:
                        row[name] = .int(sqlite3_column_int64(statement, column))
                    case SQLITE_NULL:
                        row[name] = .null
                    default:
                        row[name] = sqlite3_column_text(statement, column)
                            .map { .text(String(cString: $0)) } ?? .null
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }

    /// The first column of the first row as an integer: `COUNT(*)`, `SUM(…)`, and the like.
    public func scalar(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int64 {
        try query(sql, parameters).first?.values.first?.int ?? 0
    }

    /// Runs `body` inside a transaction, rolling back if it throws.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func withStatement<T>(_ sql: String, _ parameters: [SQLValue],
                                  _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError(sql)
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, index)
            case let .int(v): sqlite3_bind_int64(statement, index, v)
            case let .text(v): sqlite3_bind_text(statement, index, v, -1, sqliteTransient)
            }
        }
        return try body(statement)
    }

    private func lastError(_ sql: String) -> SQLiteError {
        SQLiteError(message: "\(String(cString: sqlite3_errmsg(handle))) (in: \(sql.prefix(80)))")
    }
}

/// `SQLITE_TRANSIENT`: SQLite copies the bound text before the call returns. The C macro is a
/// cast of -1 that Swift cannot import.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
