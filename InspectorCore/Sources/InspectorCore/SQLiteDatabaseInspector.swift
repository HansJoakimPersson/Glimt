import Foundation
import CSQLite

/// Reads only the SQLite catalog from a local database opened strictly read-only.
public enum SQLiteDatabaseInspector {
    public static let maximumSchemaObjects = 512
    private static let maximumObjectTextBytes = 16_384
    private static let signature = Data("SQLite format 3\0".utf8)

    /// Returns table and view definitions without reading any row data.
    public static func inspect(fileAt url: URL, fileSize: Int,
                               isCancelled: @escaping () -> Bool = { false }) throws -> SecurityFormatInspection {
        guard fileSize >= signature.count else { throw SQLiteDatabaseError.incompleteInput }
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == fileSize else {
            throw SQLiteDatabaseError.incompleteInput
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw SQLiteDatabaseError.malformed }
        defer { try? handle.close() }
        guard try handle.read(upToCount: signature.count) == signature else { throw SQLiteDatabaseError.malformed }

        var database: OpaquePointer?
        let openResult = url.path.withCString { path in
            sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        }
        guard openResult == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw SQLiteDatabaseError.malformed
        }
        defer { sqlite3_close_v2(database) }

        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, Int32(maximumObjectTextBytes))
        sqlite3_limit(database, SQLITE_LIMIT_SQL_LENGTH, 4_096)
        sqlite3_busy_timeout(database, 0)

        let context = SQLiteInspectionContext(isCancelled: isCancelled)
        let opaqueContext = Unmanaged.passUnretained(context).toOpaque()
        sqlite3_progress_handler(database, 500, { pointer in
            guard let pointer else { return 0 }
            let context = Unmanaged<SQLiteInspectionContext>.fromOpaque(pointer).takeUnretainedValue()
            return context.shouldStop ? 1 : 0
        }, opaqueContext)
        defer { sqlite3_progress_handler(database, 0, nil, nil) }

        var statement: OpaquePointer?
        let query = "SELECT type, name, tbl_name, sql FROM sqlite_schema WHERE type IN ('table','view') AND substr(name,1,7) != 'sqlite_' ORDER BY type,name LIMIT 513"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw context.failure ?? SQLiteDatabaseError.malformed
        }
        defer { sqlite3_finalize(statement) }

        var objects: [StructuredValue] = []
        var retainedTextBytes = 0
        while true {
            if context.shouldStop { throw context.failure ?? SQLiteDatabaseError.cancelled }
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw context.failure ?? SQLiteDatabaseError.malformed }
            guard objects.count < maximumSchemaObjects else { throw SQLiteDatabaseError.objectLimitExceeded }

            let type = try columnText(statement, index: 0)
            let name = try columnText(statement, index: 1)
            let tableName = try columnText(statement, index: 2)
            let sql = try columnText(statement, index: 3)
            retainedTextBytes += type.utf8.count + name.utf8.count + tableName.utf8.count + sql.utf8.count
            guard retainedTextBytes <= 1_048_576 else { throw SQLiteDatabaseError.outputLimitExceeded }
            objects.append(.object([
                .init(key: "Type", value: .string(type)),
                .init(key: "Name", value: .string(name)),
                .init(key: "Table", value: .string(tableName)),
                .init(key: "SQL", value: sql.isEmpty ? .null : .string(sql))
            ]))
        }

        let count = objects.count
        let tableCount = objects.filter { object in
            guard case .object(let fields) = object,
                  let type = fields.first(where: { $0.key == "Type" })?.value,
                  case .string("table") = type else { return false }
            return true
        }.count
        let viewCount = count - tableCount
        let content = StructuredValue.object([
            .init(key: "Tables", value: .number(String(tableCount))),
            .init(key: "Views", value: .number(String(viewCount))),
            .init(key: "Schema", value: .array(objects)),
            .init(key: "Row data", value: .string("Not read"))
        ])
        let objectLabel = count == 1 ? "schema object" : "schema objects"
        return .init(formatID: .sqlite, content: content,
                     summary: "SQLite · \(count) \(objectLabel) · row data not read", diagnostics: [])
    }

    private static func columnText(_ statement: OpaquePointer, index: Int32) throws -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        let length = Int(sqlite3_column_bytes(statement, index))
        guard length <= maximumObjectTextBytes else { throw SQLiteDatabaseError.outputLimitExceeded }
        let bytes = UnsafeBufferPointer(start: pointer, count: length)
        return escaped(String(decoding: bytes, as: UTF8.self))
    }

    private static func escaped(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            if scalar.value == 0x5C { return "\\\\" }
            if CharacterSet.controlCharacters.contains(scalar) || [0x202A...0x202E, 0x2066...0x2069].contains(where: { $0.contains(scalar.value) }) {
                return String(format: "\\u{%X}", scalar.value)
            }
            return String(scalar)
        }.joined()
    }
}

enum SQLiteDatabaseError: Error {
    case malformed, incompleteInput, cancelled, objectLimitExceeded, outputLimitExceeded
}

private final class SQLiteInspectionContext {
    private let isCancelled: () -> Bool
    private(set) var failure: SQLiteDatabaseError?

    init(isCancelled: @escaping () -> Bool) { self.isCancelled = isCancelled }

    var shouldStop: Bool {
        if Task.isCancelled || isCancelled() {
            failure = .cancelled
            return true
        }
        return false
    }
}
