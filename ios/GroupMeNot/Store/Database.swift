import Foundation
import OSLog
import SQLite3

/// SQLite wants to know whether it may keep a pointer we handed it. It may not:
/// Swift only guarantees our buffers live for the duration of the call.
nonisolated private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Values

/// One bindable SQLite value. Deliberately small: five storage classes is all
/// SQLite has, so anything richer belongs in the calling code, not here.
nonisolated enum SQLValue: Hashable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

nonisolated extension SQLValue {
    init(_ value: String?) { self = value.map(SQLValue.text) ?? .null }
    init(_ value: Int64?) { self = value.map(SQLValue.integer) ?? .null }
    init(_ value: Int?) { self = value.map { .integer(Int64($0)) } ?? .null }
    init(_ value: Double?) { self = value.map(SQLValue.real) ?? .null }
    init(_ value: Data?) { self = value.map(SQLValue.blob) ?? .null }
    init(_ value: Bool?) { self = value.map { .integer($0 ? 1 : 0) } ?? .null }

    /// Dates are stored as epoch seconds, matching GroupMe's own timestamps.
    init(_ value: Date?) { self = value.map { .integer(Int64($0.timeIntervalSince1970.rounded())) } ?? .null }
}

// MARK: - Errors

nonisolated struct SQLError: Error, CustomStringConvertible {
    var code: Int32
    var message: String
    /// The statement that failed, when we have it. Handy in a crash report.
    var sql: String?

    var isBusy: Bool { code & 0xFF == SQLITE_BUSY || code & 0xFF == SQLITE_LOCKED }

    var description: String {
        sql.map { "SQLite \(code): \(message) [\($0)]" } ?? "SQLite \(code): \(message)"
    }
}

// MARK: - Rows

/// A cursor onto the current row of a stepping statement.
///
/// Columns are addressed by position, not name. Every query in this module
/// spells out its `SELECT` list, so position is unambiguous and it saves a
/// string comparison per column per row.
///
/// A `Row` is only valid inside the decode closure it was handed to.
nonisolated struct Row {
    fileprivate let statement: OpaquePointer

    func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }

    func int64(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
    func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
    func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
    func bool(_ index: Int32) -> Bool { sqlite3_column_int64(statement, index) != 0 }

    func int64OrNil(_ index: Int32) -> Int64? { isNull(index) ? nil : int64(index) }
    func intOrNil(_ index: Int32) -> Int? { isNull(index) ? nil : int(index) }
    func boolOrNil(_ index: Int32) -> Bool? { isNull(index) ? nil : bool(index) }

    func string(_ index: Int32) -> String { stringOrNil(index) ?? "" }

    func stringOrNil(_ index: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: bytes)
    }

    func dataOrNil(_ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        let count = sqlite3_column_bytes(statement, index)
        guard count > 0 else { return Data() }
        return Data(bytes: bytes, count: Int(count))
    }

    /// Epoch seconds to `Date`, treating 0 and NULL alike as "no timestamp".
    func dateOrNil(_ index: Int32) -> Date? {
        guard let seconds = int64OrNil(index), seconds != 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}

// MARK: - Where the database lives

/// A database file, as a `Sendable` value.
///
/// The handle itself is not sendable and never crosses an isolation boundary;
/// each store actor opens its own connection from one of these. WAL lets those
/// connections read concurrently and take turns writing, which is exactly the
/// access pattern an offline-first client has.
nonisolated struct DatabaseFile: Hashable, Sendable {
    /// The path handed to `sqlite3_open_v2`. A URI when `isURI` is set.
    var path: String
    var isURI: Bool = false

    /// The default on-device location, `Application Support/GroupMeNot/<name>`.
    static func applicationSupport(named name: String = "groupmenot.sqlite") throws -> DatabaseFile {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("GroupMeNot", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var directory = base
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        try? directory.setResourceValues(resource)
        return DatabaseFile(path: base.appendingPathComponent(name).path)
    }

    /// A shared-cache in-memory database. Every connection opened with the same
    /// `name` sees the same data, which on-disk semantics need and plain
    /// `:memory:` does not give. For tests.
    static func inMemory(named name: String = "groupmenot") -> DatabaseFile {
        DatabaseFile(path: "file:\(name)?mode=memory&cache=shared", isURI: true)
    }

    /// A fresh file in a unique temporary directory. For tests that want real
    /// WAL behaviour rather than the shared-cache approximation.
    static func temporary() throws -> DatabaseFile {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GroupMeNot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return DatabaseFile(path: directory.appendingPathComponent("store.sqlite").path)
    }

    /// Opens a connection and brings it up to the current schema version.
    func open() throws -> Database {
        let database = try Database(self)
        try Schema.migrate(database)
        return database
    }
}

// MARK: - The connection

/// A single SQLite connection.
///
/// This is the only type in the app that touches the C API. It is not
/// `Sendable`: own one per actor, and let WAL sort out the rest.
nonisolated final class Database {
    private let handle: OpaquePointer
    private let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "db")

    /// Prepared statements, keyed by their SQL. Reusing a statement skips the
    /// parse and plan, which for a batched upsert is most of the work.
    private var cache: [String: OpaquePointer] = [:]
    private var transactionDepth = 0

    let file: DatabaseFile

    init(_ file: DatabaseFile) throws {
        self.file = file
        var handle: OpaquePointer?
        // FULLMUTEX because Swift concurrency moves an actor between threads
        // freely. The mutex is uncontended in that case, so it costs nothing
        // and removes a whole class of "worked until it didn't".
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if file.isURI { flags |= SQLITE_OPEN_URI }
        let code = sqlite3_open_v2(file.path, &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLError(code: code, message: message, sql: nil)
        }
        self.handle = handle

        sqlite3_extended_result_codes(handle, 1)
        // Wait rather than fail when another connection holds the write lock.
        // Five seconds is far longer than any write this app performs.
        sqlite3_busy_timeout(handle, 5_000)

        do {
            try execute("PRAGMA foreign_keys = ON")
            // WAL: readers never block the writer, and the writer never blocks
            // readers. The UI reads on every keystroke; sync writes constantly.
            try setJournalModeWAL()
            // With WAL, NORMAL only risks losing the last transactions on power
            // loss, never corruption. The server is the durable copy anyway.
            try execute("PRAGMA synchronous = NORMAL")
            try execute("PRAGMA temp_store = MEMORY")
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
    }

    deinit {
        for statement in cache.values { sqlite3_finalize(statement) }
        sqlite3_close_v2(handle)
    }

    /// `PRAGMA journal_mode` returns a row, so it cannot go through `exec`
    /// cleanly, and it can report `SQLITE_BUSY` if another connection is mid
    /// write. Retry briefly rather than refusing to open.
    private func setJournalModeWAL() throws {
        // An in-memory database cannot use WAL and says so; that is not a fault.
        guard !file.isURI || !file.path.contains("mode=memory") else { return }
        for attempt in 0..<5 {
            do {
                let mode = try queryOne("PRAGMA journal_mode = WAL") { $0.string(0) }
                if mode?.lowercased() == "wal" { return }
                log.warning("journal_mode is \(mode ?? "unknown", privacy: .public), not wal")
                return
            } catch let error as SQLError where error.isBusy && attempt < 4 {
                usleep(20_000)
            }
        }
    }

    // MARK: Statements

    /// Runs one or more statements with no bindings and no results. Used for
    /// schema DDL and pragmas.
    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard code == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorMessage)
            throw SQLError(code: code, message: message, sql: sql)
        }
        sqlite3_free(errorMessage)
    }

    /// Runs a single statement that returns no rows.
    func run(_ sql: String, _ bindings: [SQLValue] = []) throws {
        let statement = try prepared(sql)
        defer { reset(statement) }
        try bind(bindings, to: statement, sql: sql)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            throw SQLError(code: code, message: lastErrorMessage, sql: sql)
        }
    }

    /// Runs a query and decodes every row.
    ///
    /// `decode` runs while the statement is still stepping, so it must not
    /// re-enter the database with the same SQL.
    func query<T>(_ sql: String, _ bindings: [SQLValue] = [], _ decode: (Row) throws -> T) throws -> [T] {
        let statement = try prepared(sql)
        defer { reset(statement) }
        try bind(bindings, to: statement, sql: sql)

        var results: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                results.append(try decode(Row(statement: statement)))
            } else if code == SQLITE_DONE {
                return results
            } else {
                throw SQLError(code: code, message: lastErrorMessage, sql: sql)
            }
        }
    }

    /// Runs a query and decodes at most the first row.
    func queryOne<T>(_ sql: String, _ bindings: [SQLValue] = [], _ decode: (Row) throws -> T) throws -> T? {
        let statement = try prepared(sql)
        defer { reset(statement) }
        try bind(bindings, to: statement, sql: sql)

        let code = sqlite3_step(statement)
        switch code {
        case SQLITE_ROW: return try decode(Row(statement: statement))
        case SQLITE_DONE: return nil
        default: throw SQLError(code: code, message: lastErrorMessage, sql: sql)
        }
    }

    /// Rows changed by the most recent statement.
    var changes: Int { Int(sqlite3_changes(handle)) }

    // MARK: Transactions

    /// Runs `body` inside a transaction, committing on return and rolling back
    /// on any thrown error. Nesting is handled with savepoints, so a store can
    /// call another store's transactional helper without thinking about it.
    ///
    /// The outermost transaction is `IMMEDIATE`: it takes the write lock up
    /// front, so contention surfaces as a `busy_timeout` wait at `BEGIN`
    /// instead of a failed upgrade halfway through.
    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T {
        let savepoint = "sp\(transactionDepth)"
        if transactionDepth == 0 {
            try execute("BEGIN IMMEDIATE")
        } else {
            try execute("SAVEPOINT \(savepoint)")
        }
        transactionDepth += 1

        do {
            let value = try body()
            transactionDepth -= 1
            if transactionDepth == 0 {
                try execute("COMMIT")
            } else {
                try execute("RELEASE \(savepoint)")
            }
            return value
        } catch {
            transactionDepth -= 1
            if transactionDepth == 0 {
                try? execute("ROLLBACK")
            } else {
                try? execute("ROLLBACK TO \(savepoint)")
                try? execute("RELEASE \(savepoint)")
            }
            throw error
        }
    }

    // MARK: Maintenance

    /// Truncates the WAL and reclaims free pages. Worth doing when the app
    /// backgrounds, never on a path the UI is waiting on.
    func compact() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try execute("PRAGMA incremental_vacuum")
    }

    // MARK: Internals

    private var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let cached = cache[sql] { return cached }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v3(
            handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil
        )
        guard code == SQLITE_OK, let statement else {
            throw SQLError(code: code, message: lastErrorMessage, sql: sql)
        }
        cache[sql] = statement
        return statement
    }

    /// A statement holds read locks and pins WAL frames until it is reset, so
    /// every exit path resets. `clear_bindings` stops a stale value from
    /// silently surviving into the next use of a cached statement.
    private func reset(_ statement: OpaquePointer) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    private func bind(_ values: [SQLValue], to statement: OpaquePointer, sql: String) throws {
        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard values.count == expected else {
            throw SQLError(
                code: SQLITE_MISUSE,
                message: "expected \(expected) bindings, got \(values.count)",
                sql: sql
            )
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null:
                code = sqlite3_bind_null(statement, index)
            case .integer(let number):
                code = sqlite3_bind_int64(statement, index, number)
            case .real(let number):
                code = sqlite3_bind_double(statement, index, number)
            case .text(let string):
                code = sqlite3_bind_text(statement, index, string, -1, sqliteTransient)
            case .blob(let data):
                code = data.isEmpty
                    ? sqlite3_bind_zeroblob(statement, index, 0)
                    : data.withUnsafeBytes {
                        sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), sqliteTransient)
                    }
            }
            guard code == SQLITE_OK else {
                throw SQLError(code: code, message: lastErrorMessage, sql: sql)
            }
        }
    }
}
