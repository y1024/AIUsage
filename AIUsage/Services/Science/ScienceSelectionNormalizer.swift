import Foundation
import SQLite3

/// Keeps Claude Science's persisted picker selection inside the active AIUsage
/// catalog without carrying old model rows into the catalog itself.
///
/// The migration is intentionally narrow:
/// - it only opens `operon-cli.db` files below AIUsage-owned sandbox/adopt dirs;
/// - it only rewrites stale `claude-aiusage-v1-*` transport aliases;
/// - raw/native model IDs and the real `~/.claude-science` tree are never touched.
nonisolated enum ScienceSelectionNormalizer {
    static let aliasPrefix = "claude-aiusage-v1-"
    static let persistentDefaultSelectionID = "claude-opus-4-8"

    struct Result: Sendable, Equatable {
        let databaseCount: Int
        let skippedSchemaCount: Int
        let normalizedFrameCount: Int
    }

    enum NormalizationError: LocalizedError {
        case unmanagedDataDirectory
        case database(String)

        var errorDescription: String? {
            switch self {
            case .unmanagedDataDirectory:
                return "Refused to normalize an unmanaged Claude Science data directory."
            case .database(let message):
                return "Failed to normalize the managed Claude Science selections: \(message)"
            }
        }
    }

    /// Production callers use the two fixed AIUsage roots. Tests may inject a
    /// temporary managed root without weakening the production path check.
    static func normalize(
        dataDir: String,
        currentModelIDs: Set<String>,
        managedDataDirs: Set<String> = defaultManagedDataDirs
    ) throws -> Result {
        let root = try validatedManagedRoot(dataDir, managedDataDirs: managedDataDirs)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return Result(databaseCount: 0, skippedSchemaCount: 0, normalizedFrameCount: 0)
        }

        let databaseURLs = try databaseURLs(below: root)
        let currentAliases = currentModelIDs
            .filter { $0.hasPrefix(aliasPrefix) }
            .sorted()
        var skippedSchemaCount = 0
        var normalizedFrameCount = 0

        for databaseURL in databaseURLs {
            switch try normalizeDatabase(databaseURL, currentAliases: currentAliases) {
            case .unsupportedSchema:
                skippedSchemaCount += 1
            case .normalized(let count):
                normalizedFrameCount += count
            }
        }

        return Result(
            databaseCount: databaseURLs.count,
            skippedSchemaCount: skippedSchemaCount,
            normalizedFrameCount: normalizedFrameCount
        )
    }

    private static var defaultManagedDataDirs: Set<String> {
        let home = NSHomeDirectory() as NSString
        return [
            home.appendingPathComponent(".config/aiusage/science-sandbox/home/.claude-science"),
            home.appendingPathComponent(".config/aiusage/science-adopt/home/.claude-science"),
        ]
    }

    private static func validatedManagedRoot(
        _ dataDir: String,
        managedDataDirs: Set<String>
    ) throws -> URL {
        let requestedRaw = standardizedURL(dataDir)
        let requested = requestedRaw.resolvingSymlinksInPath()
        let allowedRaw = Set(managedDataDirs.map { standardizedURL($0).path })
        let allowedResolved = Set(managedDataDirs.map {
            standardizedURL($0).resolvingSymlinksInPath().path
        })
        let real = standardizedURL(
            (NSHomeDirectory() as NSString).appendingPathComponent(".claude-science")
        ).resolvingSymlinksInPath().path

        // Require both the configured spelling and resolved destination to be
        // managed. A symlink from an AIUsage root into the real Science tree is
        // rejected even though its pre-resolution path looks valid.
        guard allowedRaw.contains(requestedRaw.path),
              allowedResolved.contains(requested.path),
              !isDataDirRootSymlink(requestedRaw),
              requested.path != real,
              !requested.path.hasPrefix(real + "/") else {
            throw NormalizationError.unmanagedDataDirectory
        }
        return requested
    }

    /// Parent relocation (for example a symlinked ~/.config) is allowed, but
    /// the allowlisted dataDir entry itself may not redirect elsewhere.
    private static func isDataDirRootSymlink(_ dataDir: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: dataDir.path) else { return false }
        return (try? dataDir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func databaseURLs(below root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var databases: [URL] = []
        for case let candidate as URL in enumerator where candidate.lastPathComponent == "operon-cli.db" {
            let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.path + "/") else {
                throw NormalizationError.unmanagedDataDirectory
            }
            databases.append(resolved)
        }
        return databases.sorted { $0.path < $1.path }
    }

    private enum DatabaseResult {
        case unsupportedSchema
        case normalized(Int)
    }

    private static func normalizeDatabase(
        _ databaseURL: URL,
        currentAliases: [String]
    ) throws -> DatabaseResult {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let database { sqlite3_close(database) }
            throw NormalizationError.database(message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 3_000)

        guard try hasSupportedSchema(database, path: databaseURL.path) else {
            return .unsupportedSchema
        }

        try execute("BEGIN IMMEDIATE", database: database, path: databaseURL.path)
        var committed = false
        defer {
            if !committed { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        }

        // Science has an AFTER UPDATE trigger which renumbers root_seq whenever
        // an UPDATE leaves root_seq unchanged. Preserve the exact original
        // values in a temporary table, deliberately make non-root root_seq
        // differ during the model UPDATE (so the trigger predicate is false),
        // then restore it. Both writes remain inside this transaction.
        try execute(
            "CREATE TEMP TABLE aiusage_selection_targets (id TEXT PRIMARY KEY, original_root_seq) WITHOUT ROWID",
            database: database,
            path: databaseURL.path
        )

        let exclusions = currentAliases.isEmpty
            ? ""
            : " AND model NOT IN (\(Array(repeating: "?", count: currentAliases.count).joined(separator: ",")))"
        let targetSQL = "INSERT INTO temp.aiusage_selection_targets (id, original_root_seq) SELECT id, root_seq FROM frames WHERE model GLOB ?\(exclusions)"
        var targetStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, targetSQL, -1, &targetStatement, nil) == SQLITE_OK,
              let targetStatement else {
            throw databaseError(database, path: databaseURL.path)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try bind(aliasPrefix + "*", at: 1, statement: targetStatement, database: database, path: databaseURL.path, transient: transient)
        for (offset, alias) in currentAliases.enumerated() {
            try bind(alias, at: Int32(offset + 2), statement: targetStatement, database: database, path: databaseURL.path, transient: transient)
        }
        guard sqlite3_step(targetStatement) == SQLITE_DONE else {
            sqlite3_finalize(targetStatement)
            throw databaseError(database, path: databaseURL.path)
        }
        sqlite3_finalize(targetStatement)
        let changed = Int(sqlite3_changes(database))

        if changed > 0 {
            var updateStatement: OpaquePointer?
            let updateSQL = """
                UPDATE frames
                SET model = ?,
                    root_seq = CASE
                        WHEN root_frame_id IS NULL THEN root_seq
                        WHEN root_seq = 0 THEN -1
                        ELSE 0
                    END
                WHERE id IN (SELECT id FROM temp.aiusage_selection_targets)
                """
            guard sqlite3_prepare_v2(database, updateSQL, -1, &updateStatement, nil) == SQLITE_OK,
                  let updateStatement else {
                throw databaseError(database, path: databaseURL.path)
            }
            try bind(persistentDefaultSelectionID, at: 1, statement: updateStatement, database: database, path: databaseURL.path, transient: transient)
            guard sqlite3_step(updateStatement) == SQLITE_DONE else {
                sqlite3_finalize(updateStatement)
                throw databaseError(database, path: databaseURL.path)
            }
            sqlite3_finalize(updateStatement)

            try execute(
                """
                UPDATE frames
                SET root_seq = (
                    SELECT original_root_seq
                    FROM temp.aiusage_selection_targets
                    WHERE aiusage_selection_targets.id = frames.id
                )
                WHERE root_frame_id IS NOT NULL
                  AND id IN (SELECT id FROM temp.aiusage_selection_targets)
                """,
                database: database,
                path: databaseURL.path
            )

            let mismatchCount = try scalarInt(
                """
                SELECT COUNT(*)
                FROM frames
                JOIN temp.aiusage_selection_targets AS targets ON targets.id = frames.id
                WHERE frames.model IS NOT ?
                   OR frames.root_seq IS NOT targets.original_root_seq
                """,
                binding: persistentDefaultSelectionID,
                database: database,
                path: databaseURL.path
            )
            guard mismatchCount == 0 else {
                throw NormalizationError.database("post-update integrity check failed")
            }
        }
        try execute("COMMIT", database: database, path: databaseURL.path)
        committed = true
        return .normalized(changed)
    }

    private static func hasSupportedSchema(
        _ database: OpaquePointer,
        path: String
    ) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(frames)", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(database, path: path)
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let name = sqlite3_column_text(statement, 1) {
                    columns.insert(String(cString: name))
                }
            case SQLITE_DONE:
                let required = Set(["id", "model", "root_frame_id", "root_seq"])
                guard required.isSubset(of: columns) else { return false }
                return try hasOnlyKnownFrameTriggers(database, path: path)
            default:
                throw databaseError(database, path: path)
            }
        }
    }

    private static func hasOnlyKnownFrameTriggers(
        _ database: OpaquePointer,
        path: String
    ) throws -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'frames' COLLATE NOCASE"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(database, path: path)
        }
        defer { sqlite3_finalize(statement) }

        let known = [
            "trg_frames_root_seq_ins": canonicalSQL(expectedInsertTriggerSQL),
            "trg_frames_root_seq_upd": canonicalSQL(expectedUpdateTriggerSQL),
        ]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let nameText = sqlite3_column_text(statement, 0),
                      let sqlText = sqlite3_column_text(statement, 1) else { return false }
                let name = String(cString: nameText)
                guard let expected = known[name],
                      canonicalSQL(String(cString: sqlText)) == expected else {
                    return false
                }
            case SQLITE_DONE:
                return true
            default:
                throw databaseError(database, path: path)
            }
        }
    }

    private static let expectedInsertTriggerSQL = """
        CREATE TRIGGER trg_frames_root_seq_ins AFTER INSERT ON frames
        WHEN NEW.root_frame_id IS NOT NULL
        BEGIN
          UPDATE frames SET root_seq = (
            SELECT COALESCE(MAX(root_seq), 0) + 1 FROM frames
            WHERE root_frame_id = NEW.root_frame_id
          ) WHERE id = NEW.id;
        END
        """

    private static let expectedUpdateTriggerSQL = """
        CREATE TRIGGER trg_frames_root_seq_upd AFTER UPDATE ON frames
        WHEN NEW.root_frame_id IS NOT NULL AND NEW.root_seq IS OLD.root_seq
        BEGIN
          UPDATE frames SET root_seq = (
            SELECT COALESCE(MAX(root_seq), 0) + 1 FROM frames
            WHERE root_frame_id = NEW.root_frame_id
          ) WHERE id = NEW.id;
        END
        """

    private static func canonicalSQL(_ sql: String) -> String {
        String(sql.lowercased().unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && scalar != "`"
                && scalar != ";"
        })
    }

    private static func execute(
        _ sql: String,
        database: OpaquePointer,
        path: String
    ) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw databaseError(database, path: path)
        }
    }

    private static func bind(
        _ value: String,
        at index: Int32,
        statement: OpaquePointer,
        database: OpaquePointer,
        path: String,
        transient: sqlite3_destructor_type
    ) throws {
        guard sqlite3_bind_text(statement, index, value, -1, transient) == SQLITE_OK else {
            throw databaseError(database, path: path)
        }
    }

    private static func scalarInt(
        _ sql: String,
        binding: String,
        database: OpaquePointer,
        path: String
    ) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(database, path: path)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try bind(binding, at: 1, statement: statement, database: database, path: path, transient: transient)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw databaseError(database, path: path)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func databaseError(_ database: OpaquePointer, path: String) -> NormalizationError {
        _ = path // Keep call sites uniform without exposing managed filesystem paths.
        return NormalizationError.database(String(cString: sqlite3_errmsg(database)))
    }

    private static func standardizedURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL
    }
}
