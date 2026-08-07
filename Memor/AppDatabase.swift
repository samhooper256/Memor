//
//  AppDatabase.swift
//  Memor
//
//  Created by Codex on 4/1/26.
//

import Foundation
import GRDB

struct AppDatabase {
    nonisolated private struct InstanceSearchTypeFieldInfo: FetchableRecord, Decodable {
        let typeID: Int64
        let typeName: String
        let fieldIndex: Int
        let fieldDisplayIndex: Int
        var isPrimary: Bool = false

        enum CodingKeys: String, CodingKey {
            case typeID, typeName, fieldIndex, fieldDisplayIndex, isPrimary
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            typeID = try c.decode(Int64.self, forKey: .typeID)
            typeName = try c.decode(String.self, forKey: .typeName)
            fieldIndex = try c.decode(Int.self, forKey: .fieldIndex)
            fieldDisplayIndex = try c.decode(Int.self, forKey: .fieldDisplayIndex)
            isPrimary = (try? c.decodeIfPresent(Bool.self, forKey: .isPrimary)) ?? false
        }
    }

    nonisolated struct InstanceSearchTypeInfo {
        let typeID: Int64
        let typeName: String
        let displayFieldIndex: Int
        let allFieldIndices: [Int]
    }

    private struct InstanceSearchQuery {
        let expression: SearchExpression?
    }

    nonisolated struct QuerySearchQuery {
        let expression: SearchExpression?
    }

    private struct MapElementSearchQuery {
        let expression: SearchExpression?
    }

    nonisolated indirect enum SearchExpression: Hashable {
        case literal(String)
        case collection(String)
        case collectionID(Int64)
        case type(String)
        case typeID(Int64)
        case id(Int64)
        case queryType(typeName: String, queryTypeName: String)
        case queryTypeID(typeID: Int64, queryTypeName: String)
        case office(String)
        case noQueries
        case new
        case and(SearchExpression, SearchExpression)
        case or(SearchExpression, SearchExpression)
        case not(SearchExpression)
    }

    // What kind of row a search condition is evaluated against. Only `qt:`
    // compiles differently per context; every other component is row-kind-agnostic.
    nonisolated enum SearchConditionContext {
        case instances       // rows are instances of the scanned type table
        case standardQueries // rows are `query` rows joined to the scanned type
        case personQueries   // rows are person_query rows (srsAlias "pq")
    }

    private struct CollectionInstanceTypeInfo: FetchableRecord, Decodable {
        let typeID: Int64
        let fieldIndex: Int
    }

    private struct CollectionInstanceValueRow: FetchableRecord, Decodable {
        let id: Int64
        let displayValue: String
    }

    private struct InstanceSearchRow: FetchableRecord, Decodable {
        let id: Int64
        let displayValue: String
    }

    private struct QuerySearchRow: FetchableRecord, Decodable {
        let instanceID: Int64
        let queryTypeID: Int64
        let displayValue: String
        let queryTypeName: String
    }

    private struct GraphInstanceRow: FetchableRecord, Decodable {
        let instanceID: Int64
        let displayValue: String
        let allFieldValues: String
    }

    private static let instanceLinkRegex: NSRegularExpression = {
        // Matches href="id:NUMBER" to extract linked instance IDs
        try! NSRegularExpression(pattern: #"href="id:(\d+)""#, options: .caseInsensitive)
    }()

    private struct TypeInstancesDisplayFieldInfo: FetchableRecord, Decodable {
        let fieldIndex: Int
        let name: String
    }

    private struct TypeInstancesValueRow: FetchableRecord, Decodable {
        let id: Int64
        let displayValue: String
    }

    private struct TypeInstancesMembershipRow: FetchableRecord, Decodable {
        let instanceID: Int64
        let queryTypeID: Int64
    }

    private struct ImageFileAccessRecord: FetchableRecord, Decodable {
        let id: Int64
        let path: String
        let bookmarkData: Data
    }

    private struct ImageFolderAccessRecord: FetchableRecord, Decodable {
        let id: Int64
        let path: String
        let bookmarkData: Data
    }

    private struct StudyTypeSummary {
        let typeInfo: InstanceSearchTypeInfo
        let totalCount: Int
        let newCount: Int
        let seenCount: Int
        let minimumSeenDueTimestamp: Int64?
    }

    struct PersonStudySummary {
        let totalCount: Int
        let newCount: Int
        let minimumSeenDueTimestamp: Int64?
        var seenCount: Int { totalCount - newCount }
    }

    private enum StudySelectionPool {
        case standard(StudyTypeSummary)
        case pointMap(PointMapStudySummary)
        case boundaryMap(BoundaryMapStudySummary)
        case person(PersonStudySummary)

        var totalCount: Int {
            switch self {
            case .standard(let s): return s.totalCount
            case .pointMap(let s): return s.totalCount
            case .boundaryMap(let s): return s.totalCount
            case .person(let s): return s.totalCount
            }
        }
        var newCount: Int {
            switch self {
            case .standard(let s): return s.newCount
            case .pointMap(let s): return s.newCount
            case .boundaryMap(let s): return s.newCount
            case .person(let s): return s.newCount
            }
        }
        var seenCount: Int {
            switch self {
            case .standard(let s): return s.seenCount
            case .pointMap(let s): return s.seenCount
            case .boundaryMap(let s): return s.seenCount
            case .person(let s): return s.seenCount
            }
        }
        var minimumSeenDueTimestamp: Int64? {
            switch self {
            case .standard(let s): return s.minimumSeenDueTimestamp
            case .pointMap(let s): return s.minimumSeenDueTimestamp
            case .boundaryMap(let s): return s.minimumSeenDueTimestamp
            case .person(let s): return s.minimumSeenDueTimestamp
            }
        }
    }

    private struct StudyTypeSummaryRow: FetchableRecord, Decodable {
        let totalCount: Int
        let newCount: Int
        let minimumSeenDueTimestamp: Int64?
    }

    private struct StudyQueryRow: FetchableRecord, Decodable {
        let instanceID: Int64
        let queryTypeID: Int64
        let interval: Int64
        let maxInterval: Int64?
        let lastAnsweredTimestamp: Int64?
        let queryState: Int
        let queryTypeName: String
        let questionHTML: String
        let answerHTML: String
        let typeCSS: String
    }

    private final class GlobalQueryHTMLCache {
        private let lock = NSLock()
        private var value: String?

        func get() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ newValue: String) {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }

    private final class ImageFolderAccessController {
        private let lock = NSLock()
        private var activeFolderURLsByPath: [String: URL] = [:]

        deinit {
            lock.lock()
            let urls = Array(activeFolderURLsByPath.values)
            activeFolderURLsByPath.removeAll()
            lock.unlock()

            for url in urls {
                url.stopAccessingSecurityScopedResource()
            }
        }

        func replaceAccess(forPath path: String, with url: URL) {
            let standardizedPath = Self.standardizedPath(for: url)

            lock.lock()
            let previousURL = activeFolderURLsByPath.removeValue(forKey: path)
            activeFolderURLsByPath[standardizedPath] = url
            lock.unlock()

            if let previousURL, previousURL != url {
                previousURL.stopAccessingSecurityScopedResource()
            }
        }

        func removeAccess(forPath path: String) {
            lock.lock()
            let previousURL = activeFolderURLsByPath.removeValue(forKey: path)
            lock.unlock()

            previousURL?.stopAccessingSecurityScopedResource()
        }

        /// A retained scoped URL whose standardized path equals `targetPath`, or whose
        /// directory is an ancestor of it (i.e. a granted folder containing the file).
        /// Used to re-assert access immediately before reading a local image.
        func scopedURL(coveringPath targetPath: String) -> URL? {
            lock.lock()
            defer { lock.unlock() }

            if let exact = activeFolderURLsByPath[targetPath] {
                return exact
            }
            for (path, url) in activeFolderURLsByPath {
                let prefix = path.hasSuffix("/") ? path : path + "/"
                if targetPath.hasPrefix(prefix) {
                    return url
                }
            }
            return nil
        }

        private static func standardizedPath(for url: URL) -> String {
            url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        }
    }

    let dbQueue: DatabaseQueue
    /// Absolute filesystem path of the SQLite database file (shown in Settings → Data Storage).
    let databaseFilePath: String
    private let globalQueryHTMLCache = GlobalQueryHTMLCache()
    private let globalQueryCSSCache = GlobalQueryHTMLCache()
    private let imageFolderAccessController = ImageFolderAccessController()
    private let grantedFolderAccessController = ImageFolderAccessController()

    /// Process-wide reference used by `LocalImageURLSchemeHandler` to re-assert security scopes
    /// around local-image reads. There is exactly one `AppDatabase` per process; the scheme
    /// handler is created in several views with no `AppDatabase` of their own, so a shared
    /// reference avoids threading it through every `QueryHTMLView` call site. `AppDatabase` is a
    /// struct whose state lives in shared reference-type members (`dbQueue`, the access
    /// controllers), so this stored copy drives the same underlying objects.
    static var shared: AppDatabase?

    init(fileManager: FileManager = .default) throws {
        let databaseURL = try Self.makeDatabaseURL(fileManager: fileManager)
        let databasePath = databaseURL.path(percentEncoded: false)
        databaseFilePath = databasePath
        let isNewDatabase = !fileManager.fileExists(atPath: databasePath)
        var configuration = Configuration()

        configuration.prepareDatabase { db in
            if isNewDatabase {
                try db.execute(sql: "PRAGMA page_size = 4096")
                try db.execute(sql: "PRAGMA encoding = 'UTF-8'")
                try db.execute(sql: "PRAGMA auto_vacuum = NONE")
            }

            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }

        dbQueue = try DatabaseQueue(path: databasePath, configuration: configuration)
        try Self.createSchema(in: dbQueue, isNewDatabase: isNewDatabase)
        // Folder scopes must be started before file scopes, so stale per-file
        // bookmarks (which may live inside a granted folder) can be re-resolved
        // under the active parent scope.
        try restoreImageFolderAccess()
        try restoreImageFileAccess()

        Self.shared = self
    }

    private static func makeDatabaseURL(fileManager: FileManager) throws -> URL {
        let applicationSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = applicationSupportURL.appendingPathComponent("Memor", isDirectory: true)

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        return directoryURL.appendingPathComponent("Memor.sqlite", isDirectory: false)
    }


    private func restoreImageFileAccess() throws {
        let records = try dbQueue.read { db in
            try ImageFileAccessRecord.fetchAll(
                db,
                sql: """
                    SELECT
                        id,
                        path,
                        bookmark_data AS bookmarkData
                    FROM image_file
                    ORDER BY id
                    """
            )
        }

        var staleBookmarkUpdates: [(id: Int64, path: String, bookmarkData: Data)] = []

        for record in records {
            do {
                var isStale = false
                let resolvedURL = try URL(
                    resolvingBookmarkData: record.bookmarkData,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                guard resolvedURL.startAccessingSecurityScopedResource() else {
                    print("Failed to start security-scoped access for image file: \(record.path)")
                    continue
                }

                imageFolderAccessController.replaceAccess(forPath: record.path, with: resolvedURL)

                if isStale {
                    let updatedBookmarkData = try resolvedURL.bookmarkData(
                        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    staleBookmarkUpdates.append((
                        id: record.id,
                        path: resolvedURL.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false),
                        bookmarkData: updatedBookmarkData
                    ))
                }
            } catch {
                print("Failed to restore image file access for \(record.path): \(error)")
            }
        }

        guard !staleBookmarkUpdates.isEmpty else { return }

        try dbQueue.write { db in
            for update in staleBookmarkUpdates {
                do {
                    try db.execute(
                        sql: """
                            UPDATE image_file
                            SET path = ?, bookmark_data = ?
                            WHERE id = ?
                            """,
                        arguments: [update.path, update.bookmarkData, update.id]
                    )
                } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                    // A rename on disk can make a stale bookmark resolve to a path
                    // another row already holds, violating path's UNIQUE constraint.
                    // The surviving row already covers the file, so this bookmark
                    // is redundant — drop it.
                    try db.execute(
                        sql: "DELETE FROM image_file WHERE id = ?",
                        arguments: [update.id]
                    )
                    print("Deleted stale image file bookmark for \(update.path); another bookmark already covers that path")
                } catch {
                    // Keep the old row rather than failing app launch; the stale
                    // bookmark still resolves.
                    print("Failed to refresh stale image file bookmark for \(update.path): \(error)")
                }
            }
        }
    }

    private func restoreImageFolderAccess() throws {
        let records = try dbQueue.read { db in
            try ImageFolderAccessRecord.fetchAll(
                db,
                sql: """
                    SELECT
                        id,
                        path,
                        bookmark_data AS bookmarkData
                    FROM image_folder
                    ORDER BY id
                    """
            )
        }

        var staleBookmarkUpdates: [(id: Int64, path: String, bookmarkData: Data)] = []

        for record in records {
            do {
                var isStale = false
                let resolvedURL = try URL(
                    resolvingBookmarkData: record.bookmarkData,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                guard resolvedURL.startAccessingSecurityScopedResource() else {
                    print("Failed to start security-scoped access for image folder: \(record.path)")
                    continue
                }

                grantedFolderAccessController.replaceAccess(forPath: record.path, with: resolvedURL)

                if isStale {
                    let updatedBookmarkData = try resolvedURL.bookmarkData(
                        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    staleBookmarkUpdates.append((
                        id: record.id,
                        path: resolvedURL.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false),
                        bookmarkData: updatedBookmarkData
                    ))
                }
            } catch {
                print("Failed to restore image folder access for \(record.path): \(error)")
            }
        }

        guard !staleBookmarkUpdates.isEmpty else { return }

        try dbQueue.write { db in
            for update in staleBookmarkUpdates {
                do {
                    try db.execute(
                        sql: """
                            UPDATE image_folder
                            SET path = ?, bookmark_data = ?
                            WHERE id = ?
                            """,
                        arguments: [update.path, update.bookmarkData, update.id]
                    )
                } catch {
                    // Same UNIQUE-collision hazard as image_file above; a failed
                    // refresh must not abort launch.
                    print("Failed to refresh stale image folder bookmark for \(update.path): \(error)")
                }
            }
        }
    }

    func fetchTypes() throws -> [FlashcardType] {
        try dbQueue.read { db in
            try FlashcardType.fetchAll(
                db,
                sql: """
                    SELECT
                        "type".id,
                        "type".name,
                        COALESCE("type".description, '') AS description,
                        "type".css,
                        CASE WHEN COALESCE("type".is_builtin, 0) = 0 THEN 0 ELSE 1 END AS isBuiltin,
                        COUNT(instance_id_type_id.instance_id) AS instanceCount
                    FROM "type"
                    LEFT JOIN instance_id_type_id
                        ON instance_id_type_id.type_id = "type".id
                    GROUP BY "type".id, "type".name, "type".description, "type".css, "type".is_builtin
                    ORDER BY name COLLATE NOCASE, id
                    """
            )
        }
    }

    func fetchTypesOrderedByID() throws -> [FlashcardType] {
        try dbQueue.read { db in
            try FlashcardType.fetchAll(
                db,
                sql: """
                    SELECT
                        "type".id,
                        "type".name,
                        COALESCE("type".description, '') AS description,
                        "type".css,
                        CASE WHEN COALESCE("type".is_builtin, 0) = 0 THEN 0 ELSE 1 END AS isBuiltin,
                        COUNT(instance_id_type_id.instance_id) AS instanceCount
                    FROM "type"
                    LEFT JOIN instance_id_type_id
                        ON instance_id_type_id.type_id = "type".id
                    GROUP BY "type".id, "type".name, "type".description, "type".css, "type".is_builtin
                    ORDER BY id
                    """
            )
        }
    }

    func fetchType(typeID: Int64) throws -> FlashcardType? {
        try dbQueue.read { db in
            try FlashcardType.fetchOne(
                db,
                sql: """
                    SELECT
                        "type".id,
                        "type".name,
                        COALESCE("type".description, '') AS description,
                        "type".css,
                        CASE WHEN COALESCE("type".is_builtin, 0) = 0 THEN 0 ELSE 1 END AS isBuiltin,
                        COUNT(instance_id_type_id.instance_id) AS instanceCount
                    FROM "type"
                    LEFT JOIN instance_id_type_id
                        ON instance_id_type_id.type_id = "type".id
                    WHERE "type".id = ?
                    GROUP BY "type".id, "type".name, "type".description, "type".css, "type".is_builtin
                    """,
                arguments: [typeID]
            )
        }
    }

    func fetchTypeID(instanceID: Int64) throws -> Int64? {
        try dbQueue.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT type_id FROM instance_id_type_id WHERE instance_id = ?",
                arguments: [instanceID]
            )
        }
    }

    func fetchCollections() throws -> [Collection] {
        try dbQueue.read { db in
            try Collection.fetchAll(
                db,
                sql: """
                    SELECT
                        collection.id,
                        collection.name,
                        COALESCE(collection.description, '') AS description,
                        collection.visible_before_answer AS visibleBeforeAnswer,
                        COUNT(instance_id_collection_id.instance_id) AS instanceCount
                    FROM collection
                    LEFT JOIN instance_id_collection_id
                        ON instance_id_collection_id.collection_id = collection.id
                    GROUP BY collection.id, collection.name, collection.description, collection.visible_before_answer
                    ORDER BY collection.name COLLATE NOCASE, collection.id
                    """
            )
        }
    }

    func fetchStacks() throws -> [Stack] {
        try dbQueue.read { db in
            try Stack.fetchAll(
                db,
                sql: """
                    SELECT
                        id,
                        name,
                        search,
                        COALESCE(description, '') AS description,
                        is_pinned AS isPinned,
                        0 AS blueQueryCount,
                        0 AS redQueryCount,
                        0 AS greenQueryCount,
                        0 AS magentaQueryCount
                    FROM stack
                    ORDER BY is_pinned DESC, name COLLATE NOCASE, id
                    """
            )
        }
    }

    func createStack(name: String, search: String) throws -> Stack {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO stack (name, search)
                    VALUES (?, ?)
                    """,
                arguments: [name, search]
            )

            return Stack(
                id: db.lastInsertedRowID,
                name: name,
                search: search,
                description: "",
                isPinned: false,
                blueQueryCount: 0,
                redQueryCount: 0,
                greenQueryCount: 0,
                magentaQueryCount: 0
            )
        }
    }

    func grantImageFileAccess(fileURL: URL) throws {
        let standardizedPath = fileURL.standardizedFileURL.resolvingSymlinksInPath()
            .path(percentEncoded: false)

        // Hold the panel's fresh security-scope grant across bookmark creation. (Create the
        // bookmark from the ORIGINAL panel URL — standardizing first drops the grant; see 12f3f79.)
        let didStartAccess = fileURL.startAccessingSecurityScopedResource()

        // Best-effort: mint and persist a security-scoped bookmark so the image still renders
        // after relaunch. This can fail with NSCocoaErrorDomain Code=256 "Failed to retrieve
        // app-scope key" — the sandbox sometimes can't vend the per-app key used to sign
        // app-scoped bookmarks (notably under ad-hoc-signed debug builds, and after long
        // idle/sleep). When it fails we must NOT block the insert: fall back to retaining the
        // panel's live grant for this session so the image inserts and renders now, and let
        // persistence be retried the next time access is granted.
        do {
            let bookmarkData = try fileURL.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            try dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO image_file (path, bookmark_data)
                        VALUES (?, ?)
                        ON CONFLICT(path) DO UPDATE SET
                            bookmark_data = excluded.bookmark_data
                        """,
                    arguments: [standardizedPath, bookmarkData]
                )
            }

            var isStale = false
            let resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if resolvedURL.startAccessingSecurityScopedResource() {
                // The controller now owns the resolved scope; release the panel grant.
                if didStartAccess { fileURL.stopAccessingSecurityScopedResource() }
                imageFolderAccessController.replaceAccess(forPath: standardizedPath, with: resolvedURL)
                return
            }
            // Resolution didn't yield an active scope — fall through to retain the panel grant.
        } catch {
            print("Failed to persist image bookmark (using session-only access): \(error)")
            // Fall through to the session-only grant below.
        }

        // Fallback: keep the panel's live grant for this session so the image is usable now.
        // The controller takes ownership of the started scope (it stops it on replacement /
        // deinit), so we must not stop it here.
        guard didStartAccess else {
            throw DatabaseError(message: "Failed to start security-scoped access for the selected image.")
        }
        imageFolderAccessController.replaceAccess(forPath: standardizedPath, with: fileURL)
    }

    /// Reads a local image file, re-asserting the security scope around the read instead of
    /// relying on a scope started long ago at launch (which can lapse after sleep/idle and break
    /// rendering of already-inserted images). Tries the retained per-file / granted-folder scope
    /// first; on a permission failure it re-resolves the stored bookmark (refreshing it if stale)
    /// and retries once.
    func readSecurityScopedFile(at fileURL: URL) throws -> Data {
        let targetPath = fileURL.standardizedFileURL.resolvingSymlinksInPath()
            .path(percentEncoded: false)

        // 1. Re-assert a retained scope (per-file, else containing granted folder) for the read.
        if let scopedURL = imageFolderAccessController.scopedURL(coveringPath: targetPath)
            ?? grantedFolderAccessController.scopedURL(coveringPath: targetPath) {
            let didStart = scopedURL.startAccessingSecurityScopedResource()
            defer { if didStart { scopedURL.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: fileURL) {
                return data
            }
        }

        // 2. Re-resolve the stored bookmark (per-file row, else any covering folder row), refresh
        //    it if stale, and retry the read under the freshly-resolved scope.
        if let data = try? readByReResolvingBookmark(targetPath: targetPath) {
            return data
        }

        // 3. Last resort: read directly (covers draft previews and files needing no scope).
        return try Data(contentsOf: fileURL)
    }

    private func readByReResolvingBookmark(targetPath: String) throws -> Data? {
        struct BookmarkRow: FetchableRecord, Decodable {
            let id: Int64
            let path: String
            let bookmarkData: Data
        }

        // Per-file bookmark whose path matches exactly, then any folder bookmark that contains it.
        let fileRow = try dbQueue.read { db in
            try BookmarkRow.fetchOne(
                db,
                sql: "SELECT id, path, bookmark_data AS bookmarkData FROM image_file WHERE path = ?",
                arguments: [targetPath]
            )
        }
        let folderRows = try dbQueue.read { db in
            try BookmarkRow.fetchAll(
                db,
                sql: "SELECT id, path, bookmark_data AS bookmarkData FROM image_folder ORDER BY id"
            )
        }

        var candidates: [(table: String, row: BookmarkRow)] = []
        if let fileRow {
            candidates.append(("image_file", fileRow))
        }
        for row in folderRows {
            let prefix = row.path.hasSuffix("/") ? row.path : row.path + "/"
            if targetPath == row.path || targetPath.hasPrefix(prefix) {
                candidates.append(("image_folder", row))
            }
        }

        for candidate in candidates {
            do {
                var isStale = false
                let resolvedURL = try URL(
                    resolvingBookmarkData: candidate.row.bookmarkData,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                let didStart = resolvedURL.startAccessingSecurityScopedResource()
                defer { if didStart { resolvedURL.stopAccessingSecurityScopedResource() } }

                let fileURL = URL(fileURLWithPath: targetPath)
                let data = try Data(contentsOf: fileURL)

                if isStale {
                    try? refreshStaleBookmark(table: candidate.table, id: candidate.row.id, url: resolvedURL)
                }
                return data
            } catch {
                continue
            }
        }
        return nil
    }

    private func refreshStaleBookmark(table: String, id: Int64, url: URL) throws {
        let updatedBookmarkData = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let updatedPath = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE \(table) SET path = ?, bookmark_data = ? WHERE id = ?",
                arguments: [updatedPath, updatedBookmarkData, id]
            )
        }
    }

    func grantImageFolderAccess(folderURL: URL) throws -> ImageFolderAccess {
        // Same reasoning as grantImageFileAccess: create the bookmark from the ORIGINAL panel URL
        // (which carries the fresh grant) rather than a derived/standardized URL that drops it.
        let didStartAccess = folderURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { folderURL.stopAccessingSecurityScopedResource() } }

        let bookmarkData = try folderURL.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let standardizedPath = folderURL.standardizedFileURL.resolvingSymlinksInPath()
            .path(percentEncoded: false)

        let insertedID: Int64 = try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO image_folder (path, bookmark_data)
                    VALUES (?, ?)
                    ON CONFLICT(path) DO UPDATE SET
                        bookmark_data = excluded.bookmark_data
                    """,
                arguments: [standardizedPath, bookmarkData]
            )
            let id = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM image_folder WHERE path = ?",
                arguments: [standardizedPath]
            )
            return id ?? db.lastInsertedRowID
        }

        var isStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard resolvedURL.startAccessingSecurityScopedResource() else {
            throw DatabaseError(message: "Failed to start security-scoped access for the selected folder.")
        }

        grantedFolderAccessController.replaceAccess(forPath: standardizedPath, with: resolvedURL)

        return ImageFolderAccess(id: insertedID, path: standardizedPath)
    }

    func revokeImageFolderAccess(id: Int64) throws {
        let removedPath: String? = try dbQueue.write { db in
            let path = try String.fetchOne(
                db,
                sql: "SELECT path FROM image_folder WHERE id = ?",
                arguments: [id]
            )
            try db.execute(
                sql: "DELETE FROM image_folder WHERE id = ?",
                arguments: [id]
            )
            return path
        }
        if let removedPath {
            grantedFolderAccessController.removeAccess(forPath: removedPath)
        }
    }

    func fetchImageFolderAccesses() throws -> [ImageFolderAccess] {
        try dbQueue.read { db in
            try ImageFolderAccess.fetchAll(
                db,
                sql: """
                    SELECT id, path
                    FROM image_folder
                    ORDER BY path COLLATE NOCASE
                    """
            )
        }
    }

    private static func standardizedPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }

    func updateStackName(id: Int64, name: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE stack SET name = ? WHERE id = ?
                    """,
                arguments: [name, id]
            )
        }
    }

    func updateStackSearch(id: Int64, search: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE stack SET search = ? WHERE id = ?
                    """,
                arguments: [search, id]
            )
        }
    }

    func updateStackDescription(id: Int64, description: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE stack SET description = ? WHERE id = ?
                    """,
                arguments: [description, id]
            )
        }
    }

    func setStackPinned(id: Int64, isPinned: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE stack SET is_pinned = ? WHERE id = ?
                    """,
                arguments: [isPinned ? 1 : 0, id]
            )
        }
    }

    func deleteStack(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    DELETE FROM stack
                    WHERE id = ?
                    """,
                arguments: [id]
            )
        }
    }

    func fetchStacksLastUpdatedTimestamp() throws -> Date {
        try dbQueue.read { db in
            guard let timestampString = try String.fetchOne(
                db,
                sql: """
                    SELECT value
                    FROM globals
                    WHERE name = ?
                    """,
                arguments: ["stacks_last_updated_timestamp"]
            ), let timestamp = TimeInterval(timestampString) else {
                throw DatabaseError(message: "Missing globals row for stacks_last_updated_timestamp.")
            }

            return Date(timeIntervalSince1970: timestamp)
        }
    }

    // A collection or type name may not start with a digit, so the
    // `col:`/`collection:`/`type:`/`qt:` search components can treat a
    // leading-digit argument as an ID without ambiguity.
    nonisolated static func nameStartsWithDigit(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        return first.isNumber
    }

    func createCollection(name: String) throws -> Collection {
        if Self.nameStartsWithDigit(name) {
            throw DatabaseError(message: "A collection name cannot start with a digit.")
        }
        return try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO collection (name)
                    VALUES (?)
                    """,
                arguments: [name]
            )

            return Collection(id: db.lastInsertedRowID, name: name, description: "", visibleBeforeAnswer: true, instanceCount: 0)
        }
    }

    func updateCollectionDescription(id: Int64, description: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE collection SET description = ? WHERE id = ?
                    """,
                arguments: [description, id]
            )
        }
    }

    func renameCollection(id: Int64, to newName: String) throws {
        if Self.nameStartsWithDigit(newName) {
            throw DatabaseError(message: "A collection name cannot start with a digit.")
        }
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE collection SET name = ? WHERE id = ?
                    """,
                arguments: [newName, id]
            )
        }
    }

    func updateCollectionVisibleBeforeAnswer(id: Int64, visibleBeforeAnswer: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE collection SET visible_before_answer = ? WHERE id = ?
                    """,
                arguments: [visibleBeforeAnswer ? 1 : 0, id]
            )
        }
    }

    func fetchVisibleBeforeAnswerCollectionNames(instanceID: Int64) throws -> [String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT collection.name
                    FROM collection
                    JOIN instance_id_collection_id
                        ON instance_id_collection_id.collection_id = collection.id
                    WHERE instance_id_collection_id.instance_id = ?
                    AND collection.visible_before_answer = 1
                    ORDER BY collection.name COLLATE NOCASE
                    """,
                arguments: [instanceID]
            )
            return rows.map { $0["name"] as String }
        }
    }

    func fetchAllCollectionNames(instanceID: Int64) throws -> [String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT collection.name
                    FROM collection
                    JOIN instance_id_collection_id
                        ON instance_id_collection_id.collection_id = collection.id
                    WHERE instance_id_collection_id.instance_id = ?
                    ORDER BY collection.name COLLATE NOCASE
                    """,
                arguments: [instanceID]
            )
            return rows.map { $0["name"] as String }
        }
    }

    func deleteCollection(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    DELETE FROM collection
                    WHERE id = ?
                    """,
                arguments: [id]
            )
        }
    }

    func fetchCollectionInstances(collectionID: Int64) throws -> [CollectionInstanceSummary] {
        try dbQueue.read { db in
            let typeInfos = try CollectionInstanceTypeInfo.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT
                        instance_id_type_id.type_id AS typeID,
                        field.field_index AS fieldIndex
                    FROM instance_id_collection_id
                    JOIN instance_id_type_id
                        ON instance_id_type_id.instance_id = instance_id_collection_id.instance_id
                    JOIN field
                        ON field.type_id = instance_id_type_id.type_id
                        AND field.id = (
                            SELECT f2.id FROM field f2
                            WHERE f2.type_id = instance_id_type_id.type_id
                            ORDER BY f2.is_primary DESC, f2.field_display_index ASC, f2.id
                            LIMIT 1
                        )
                    WHERE instance_id_collection_id.collection_id = ?
                    ORDER BY instance_id_type_id.type_id
                    """,
                arguments: [collectionID]
            )

            var instances: [CollectionInstanceSummary] = []

            for typeInfo in typeInfos {
                let tableName = "\"type\(typeInfo.typeID)\""
                let displayColumnName = "\"field\(typeInfo.fieldIndex)\""
                let rows = try CollectionInstanceValueRow.fetchAll(
                    db,
                    sql: """
                        SELECT
                            \(tableName).id,
                            COALESCE(\(tableName).\(displayColumnName), '') AS displayValue
                        FROM \(tableName)
                        JOIN instance_id_collection_id
                            ON instance_id_collection_id.instance_id = \(tableName).id
                        WHERE instance_id_collection_id.collection_id = ?
                        """,
                    arguments: [collectionID]
                )

                instances.append(contentsOf: rows.map { row in
                    CollectionInstanceSummary(id: row.id, displayValue: row.displayValue)
                })
            }

            return instances.sorted { lhs, rhs in
                let comparison = lhs.displayValue.localizedCaseInsensitiveCompare(rhs.displayValue)
                if comparison == .orderedSame {
                    return lhs.id < rhs.id
                }
                return comparison == .orderedAscending
            }
        }
    }

    func fetchInstanceIDs(inCollectionID collectionID: Int64) throws -> Set<Int64> {
        try dbQueue.read { db in
            let instanceIDs = try Int64.fetchAll(
                db,
                sql: """
                    SELECT instance_id
                    FROM instance_id_collection_id
                    WHERE collection_id = ?
                    """,
                arguments: [collectionID]
            )
            return Set(instanceIDs)
        }
    }

    func addInstance(_ instanceID: Int64, toCollectionID collectionID: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO instance_id_collection_id (instance_id, collection_id)
                    SELECT ?, ?
                    WHERE NOT EXISTS (
                        SELECT 1
                        FROM instance_id_collection_id
                        WHERE instance_id = ? AND collection_id = ?
                    )
                    """,
                arguments: [instanceID, collectionID, instanceID, collectionID]
            )
        }
    }

    func removeInstance(_ instanceID: Int64, fromCollectionID collectionID: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    DELETE FROM instance_id_collection_id
                    WHERE instance_id = ? AND collection_id = ?
                    """,
                arguments: [instanceID, collectionID]
            )
        }
    }

    // Batch variants (one transaction for a whole Search selection). Instances
    // already in the collection are skipped — the join table has no unique
    // constraint, so membership is guarded per insert like addInstance's.
    func addInstances(_ instanceIDs: [Int64], toCollectionID collectionID: Int64) throws {
        guard !instanceIDs.isEmpty else { return }
        try dbQueue.write { db in
            for instanceID in instanceIDs {
                try db.execute(
                    sql: """
                        INSERT INTO instance_id_collection_id (instance_id, collection_id)
                        SELECT ?, ?
                        WHERE NOT EXISTS (
                            SELECT 1
                            FROM instance_id_collection_id
                            WHERE instance_id = ? AND collection_id = ?
                        )
                        """,
                    arguments: [instanceID, collectionID, instanceID, collectionID]
                )
            }
        }
    }

    func removeInstances(_ instanceIDs: [Int64], fromCollectionID collectionID: Int64) throws {
        guard !instanceIDs.isEmpty else { return }
        try dbQueue.write { db in
            let placeholders = instanceIDs.map { _ in "?" }.joined(separator: ", ")
            var arguments: [DatabaseValueConvertible] = [collectionID]
            arguments.append(contentsOf: instanceIDs)
            try db.execute(
                sql: """
                    DELETE FROM instance_id_collection_id
                    WHERE collection_id = ? AND instance_id IN (\(placeholders))
                    """,
                arguments: StatementArguments(arguments)
            )
        }
    }

    func fetchCollectionChecklistItems(forTypeID typeID: Int64) throws -> [CollectionChecklistItem] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        collection.id,
                        collection.name,
                        CASE WHEN pinned_collection.collection_id IS NOT NULL THEN 1 ELSE 0 END AS isPinned
                    FROM collection
                    LEFT JOIN pinned_collection
                        ON pinned_collection.collection_id = collection.id
                        AND pinned_collection.type_id = ?
                    ORDER BY collection.name COLLATE NOCASE, collection.id
                    """,
                arguments: [typeID]
            )
            return rows.map { row in
                CollectionChecklistItem(
                    id: row["id"],
                    name: row["name"],
                    isPinned: row["isPinned"] as Int64 != 0
                )
            }
        }
    }

    func fetchCollectionIDs(forInstanceID instanceID: Int64) throws -> Set<Int64> {
        try dbQueue.read { db in
            let ids = try Int64.fetchAll(
                db,
                sql: """
                    SELECT collection_id
                    FROM instance_id_collection_id
                    WHERE instance_id = ?
                    """,
                arguments: [instanceID]
            )
            return Set(ids)
        }
    }

    func setInstanceCollections(instanceID: Int64, collectionIDs: Set<Int64>) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    DELETE FROM instance_id_collection_id
                    WHERE instance_id = ?
                    """,
                arguments: [instanceID]
            )
            for collectionID in collectionIDs.sorted() {
                try db.execute(
                    sql: """
                        INSERT INTO instance_id_collection_id (instance_id, collection_id)
                        VALUES (?, ?)
                        """,
                    arguments: [instanceID, collectionID]
                )
            }
        }
    }

    func setPinnedCollection(typeID: Int64, collectionID: Int64, isPinned: Bool) throws {
        try dbQueue.write { db in
            if isPinned {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO pinned_collection (type_id, collection_id)
                        VALUES (?, ?)
                        """,
                    arguments: [typeID, collectionID]
                )
            } else {
                try db.execute(
                    sql: """
                        DELETE FROM pinned_collection
                        WHERE type_id = ? AND collection_id = ?
                        """,
                    arguments: [typeID, collectionID]
                )
            }
        }
    }

    func fetchStickyFieldIDs(forTypeID typeID: Int64) throws -> Set<Int64> {
        try dbQueue.read { db in
            let ids = try Int64.fetchAll(
                db,
                sql: "SELECT field_id FROM sticky_field WHERE type_id = ?",
                arguments: [typeID]
            )
            return Set(ids)
        }
    }

    func setStickyField(typeID: Int64, fieldID: Int64, isSticky: Bool) throws {
        try dbQueue.write { db in
            if isSticky {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO sticky_field (type_id, field_id)
                        VALUES (?, ?)
                        """,
                    arguments: [typeID, fieldID]
                )
            } else {
                try db.execute(
                    sql: """
                        DELETE FROM sticky_field
                        WHERE type_id = ? AND field_id = ?
                        """,
                    arguments: [typeID, fieldID]
                )
            }
        }
    }

    func fetchCollapsedFieldIDs(forTypeID typeID: Int64) throws -> Set<Int64> {
        try dbQueue.read { db in
            let ids = try Int64.fetchAll(
                db,
                sql: "SELECT field_id FROM collapsed_field WHERE type_id = ?",
                arguments: [typeID]
            )
            return Set(ids)
        }
    }

    func setCollapsedField(typeID: Int64, fieldID: Int64, isCollapsed: Bool) throws {
        try dbQueue.write { db in
            if isCollapsed {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO collapsed_field (type_id, field_id)
                        VALUES (?, ?)
                        """,
                    arguments: [typeID, fieldID]
                )
            } else {
                try db.execute(
                    sql: """
                        DELETE FROM collapsed_field
                        WHERE type_id = ? AND field_id = ?
                        """,
                    arguments: [typeID, fieldID]
                )
            }
        }
    }

    func fetchTypeQueryDefaults(forTypeID typeID: Int64) throws -> [Int64: Bool] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT query_type_id, is_enabled FROM type_query_default WHERE type_id = ?",
                arguments: [typeID]
            )
            var out: [Int64: Bool] = [:]
            for row in rows {
                let id = row["query_type_id"] as Int64? ?? 0
                let enabled = ((row["is_enabled"] as Int64?) ?? 0) != 0
                out[id] = enabled
            }
            return out
        }
    }

    func setTypeQueryDefault(typeID: Int64, queryTypeID: Int64, isEnabled: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO type_query_default (type_id, query_type_id, is_enabled)
                    VALUES (?, ?, ?)
                    ON CONFLICT(type_id, query_type_id) DO UPDATE SET is_enabled = excluded.is_enabled
                    """,
                arguments: [typeID, queryTypeID, isEnabled ? 1 : 0]
            )
        }
    }

    func resolveTypeQueryDefaultSelection(
        forTypeID typeID: Int64,
        availableQueryTypeIDs: [Int64]
    ) throws -> Set<Int64> {
        let saved = try fetchTypeQueryDefaults(forTypeID: typeID)
        var result = Set<Int64>()
        for queryTypeID in availableQueryTypeIDs {
            if let savedEnabled = saved[queryTypeID] {
                if savedEnabled { result.insert(queryTypeID) }
            } else {
                result.insert(queryTypeID)
            }
        }
        return result
    }

    func deleteInstance(instanceID: Int64) throws {
        try dbQueue.write { db in
            guard let typeID = try Int64.fetchOne(
                db,
                sql: """
                    SELECT type_id
                    FROM instance_id_type_id
                    WHERE instance_id = ?
                    """,
                arguments: [instanceID]
            ) else {
                throw DatabaseError(message: "Instance not found.")
            }

            let pointMapTypeID = try Int64.fetchOne(
                db,
                sql: """
                    SELECT id FROM "type" WHERE name = ? AND is_builtin = 1
                    """,
                arguments: [POINTMAP_TYPE_NAME]
            )
            let isPointMap = (typeID == pointMapTypeID)

            let boundaryMapTypeID = try Int64.fetchOne(
                db,
                sql: """
                    SELECT id FROM "type" WHERE name = ? AND is_builtin = 1
                    """,
                arguments: [BOUNDARYMAP_TYPE_NAME]
            )
            let isBoundaryMap = (typeID == boundaryMapTypeID)

            // Deleting a Person first converts every reference to them on other
            // people into a bare-name entry (preserving structure + SRS), and —
            // when the reset-on-connection-change option is on — resets the
            // affected enabled queries.
            let personTypeID = try? Self.fetchPersonTypeID(db: db)
            if typeID == personTypeID {
                let changes = try Self.deletePersonRelations(db: db, instanceID: instanceID)
                let resetFlag = try String.fetchOne(
                    db,
                    sql: "SELECT value FROM globals WHERE name = ?",
                    arguments: [PERSON_RESET_QUERIES_GLOBAL_KEY]
                ) == "1"
                if resetFlag {
                    try Self.resetPersonQueriesForRelationshipChanges(db: db, changes: changes)
                }
            }

            try db.execute(
                sql: """
                    DELETE FROM instance_id_collection_id
                    WHERE instance_id = ?
                    """,
                arguments: [instanceID]
            )

            try db.execute(
                sql: """
                    DELETE FROM instance_id_type_id
                    WHERE instance_id = ?
                    """,
                arguments: [instanceID]
            )

            if !isPointMap && !isBoundaryMap {
                try db.execute(
                    sql: """
                        DELETE FROM "type\(typeID)"
                        WHERE id = ?
                        """,
                    arguments: [instanceID]
                )
            }
            // For PointMap and BoundaryMap, cascade from instance_id_type_id → *_instance handles cleanup.
        }
    }

    func searchInstances(query: String) throws -> [InstanceSearchSection] {
        let parsedQuery = try parseInstanceSearchQuery(query)

        return try dbQueue.read { db in
            try validateCollectionSearchComponents(
                Self.collectionNames(in: parsedQuery.expression),
                db: db
            )
            try validateOfficeSearchComponents(
                Self.officeNames(in: parsedQuery.expression),
                db: db
            )

            let typeInfos = try fetchInstanceSearchTypeInfos(db: db)
            var sections: [InstanceSearchSection] = []

            for typeInfo in typeInfos {
                let rows = try fetchInstanceSearchRows(
                    db: db,
                    typeInfo: typeInfo,
                    parsedQuery: parsedQuery
                )

                if !rows.isEmpty {
                    sections.append(
                        InstanceSearchSection(
                            typeID: typeInfo.typeID,
                            typeName: typeInfo.typeName,
                            instances: rows
                        )
                    )
                }
            }

            let pointMapRows = try fetchPointMapInstanceSearchRows(
                db: db,
                expression: parsedQuery.expression
            )
            if !pointMapRows.isEmpty {
                let pointMapTypeID = try Self.fetchPointMapTypeID(db: db)
                sections.append(
                    InstanceSearchSection(
                        typeID: pointMapTypeID,
                        typeName: POINTMAP_TYPE_NAME,
                        instances: pointMapRows
                    )
                )
            }

            let boundaryMapRows = try fetchBoundaryMapInstanceSearchRows(
                db: db,
                expression: parsedQuery.expression
            )
            if !boundaryMapRows.isEmpty {
                let boundaryMapTypeID = try Self.fetchBoundaryMapTypeID(db: db)
                sections.append(
                    InstanceSearchSection(
                        typeID: boundaryMapTypeID,
                        typeName: BOUNDARYMAP_TYPE_NAME,
                        instances: boundaryMapRows
                    )
                )
            }

            return sections
        }
    }

    private func fetchPointMapInstanceSearchRows(
        db: Database,
        expression: SearchExpression?
    ) throws -> [InstanceSearchResult] {
        let searchConditions = makePointMapSearchConditions(
            expression: expression,
            pointAlias: "pp",
            instanceAlias: "pi",
            directionalAlias: nil,
            includePointName: false
        )
        let whereClause = searchConditions.sql.isEmpty ? "" : "\nWHERE \(searchConditions.sql)"

        let rows = try PointMapInstanceSearchRow.fetchAll(
            db,
            sql: """
                SELECT
                    pi.instance_id AS instanceID,
                    COALESCE(pi.title, '') AS title
                FROM pointmap_instance AS pi\(whereClause)
                ORDER BY pi.title COLLATE NOCASE, pi.instance_id
                """,
            arguments: searchConditions.arguments
        )

        return rows.map { row in
            InstanceSearchResult(id: row.instanceID, displayValue: row.title)
        }
    }

    func fetchGraphData(query: String) throws -> GraphData {
        let parsedQuery = try parseInstanceSearchQuery(query)

        return try dbQueue.read { db in
            try validateCollectionSearchComponents(
                Self.collectionNames(in: parsedQuery.expression),
                db: db
            )
            try validateOfficeSearchComponents(
                Self.officeNames(in: parsedQuery.expression),
                db: db
            )

            let typeInfos = try fetchInstanceSearchTypeInfos(db: db)
            var allNodes: [GraphNode] = []
            var allNodeIDSet: Set<Int64> = []
            var rawEdges: [(from: Int64, to: Int64)] = []

            for typeInfo in typeInfos {
                let rows = try fetchGraphInstanceRows(
                    db: db,
                    typeInfo: typeInfo,
                    parsedQuery: parsedQuery
                )
                for row in rows {
                    allNodes.append(GraphNode(instanceID: row.instanceID, label: row.displayValue))
                    allNodeIDSet.insert(row.instanceID)
                    for linkedID in parseInstanceLinks(from: row.allFieldValues) {
                        rawEdges.append((from: row.instanceID, to: linkedID))
                    }
                }
            }

            // Filter edges to in-set nodes only, then deduplicate per direction
            var edgeSet: Set<String> = []
            var edges: [GraphEdge] = []
            for edge in rawEdges {
                guard allNodeIDSet.contains(edge.to) else { continue }
                guard edgeSet.insert("\(edge.from)-\(edge.to)").inserted else { continue }
                edges.append(GraphEdge(fromInstanceID: edge.from, toInstanceID: edge.to))
            }

            let nodesWithInbound = Set(edges.map(\.toInstanceID))
            let sourceNodeIDs = allNodeIDSet.subtracting(nodesWithInbound)

            return GraphData(nodes: allNodes, sourceNodeIDs: sourceNodeIDs, edges: edges)
        }
    }

    func searchQueries(query: String) throws -> [QuerySearchSection] {
        let parsedQuery = try parseQuerySearchQuery(query)

        return try dbQueue.read { db in
            try validateCollectionSearchComponents(
                Self.collectionNames(in: parsedQuery.expression),
                db: db
            )
            try validateOfficeSearchComponents(
                Self.officeNames(in: parsedQuery.expression),
                db: db
            )

            let typeInfos = try fetchInstanceSearchTypeInfos(db: db)
            var sections: [QuerySearchSection] = []

            let personTypeID = try? Self.fetchPersonTypeID(db: db)
            for typeInfo in typeInfos {
                var rows = try fetchQuerySearchRows(
                    db: db,
                    typeInfo: typeInfo,
                    parsedQuery: parsedQuery
                )

                // Built-in Person relationship queries merge into the same
                // section (section ids are type ids, so a second Person section
                // would collide).
                if typeInfo.typeID == personTypeID {
                    rows += try fetchPersonQuerySearchRows(
                        db: db,
                        typeInfo: typeInfo,
                        parsedQuery: parsedQuery
                    )
                    rows.sort { lhs, rhs in
                        let byName = lhs.displayValue.localizedCaseInsensitiveCompare(rhs.displayValue)
                        if byName != .orderedSame { return byName == .orderedAscending }
                        if lhs.instanceID != rhs.instanceID { return lhs.instanceID < rhs.instanceID }
                        // User-defined query types before built-ins.
                        if (lhs.personKind == nil) != (rhs.personKind == nil) { return lhs.personKind == nil }
                        return lhs.id < rhs.id
                    }
                }

                if !rows.isEmpty {
                    sections.append(
                        QuerySearchSection(
                            typeID: typeInfo.typeID,
                            typeName: typeInfo.typeName,
                            queries: rows
                        )
                    )
                }
            }

            let pointMapRows = try fetchPointMapQuerySearchRows(
                db: db,
                expression: parsedQuery.expression
            )
            if !pointMapRows.isEmpty {
                let pointMapTypeID = try Self.fetchPointMapTypeID(db: db)
                sections.append(
                    QuerySearchSection(
                        typeID: pointMapTypeID,
                        typeName: POINTMAP_TYPE_NAME,
                        queries: pointMapRows
                    )
                )
            }

            let boundaryMapRows = try fetchBoundaryMapQuerySearchRows(
                db: db,
                expression: parsedQuery.expression
            )
            if !boundaryMapRows.isEmpty {
                let boundaryMapTypeID = try Self.fetchBoundaryMapTypeID(db: db)
                sections.append(
                    QuerySearchSection(
                        typeID: boundaryMapTypeID,
                        typeName: BOUNDARYMAP_TYPE_NAME,
                        queries: boundaryMapRows
                    )
                )
            }

            return sections
        }
    }

    /// Searches PointMap points and BoundaryMap boundaries (the map "elements"
    /// themselves, not their per-direction queries). Uses the restricted
    /// map-element search language (quotes, parentheses, OR/NOT, `literal:`,
    /// plain strings only).
    func searchMapElements(query: String) throws -> [MapElementSearchSection] {
        let parsedQuery = try parseMapElementSearchQuery(query)

        return try dbQueue.read { db in
            var sections: [MapElementSearchSection] = []

            // Points
            let pointConditions = makePointMapSearchConditions(
                expression: parsedQuery.expression,
                pointAlias: "pp",
                instanceAlias: "pi",
                directionalAlias: nil,
                includePointName: true
            )
            let pointWhere = pointConditions.sql.isEmpty ? "" : "\nWHERE \(pointConditions.sql)"
            struct PointRow: FetchableRecord, Decodable {
                let instanceID: Int64
                let pointID: Int64
                let pointName: String
                let title: String
            }
            let pointRows = try PointRow.fetchAll(
                db,
                sql: """
                    SELECT
                        pp.instance_id AS instanceID,
                        pp.id AS pointID,
                        COALESCE(pp.name, '') AS pointName,
                        COALESCE(pi.title, '') AS title
                    FROM pointmap_point AS pp
                    JOIN pointmap_instance AS pi
                        ON pi.instance_id = pp.instance_id\(pointWhere)
                    ORDER BY pi.title COLLATE NOCASE, pp.name COLLATE NOCASE, pp.id
                    """,
                arguments: pointConditions.arguments
            )
            if !pointRows.isEmpty {
                let pointMapTypeID = try Self.fetchPointMapTypeID(db: db)
                sections.append(
                    MapElementSearchSection(
                        typeID: pointMapTypeID,
                        typeName: POINTMAP_TYPE_NAME,
                        elements: pointRows.map {
                            MapElementSearchResult(
                                instanceID: $0.instanceID,
                                elementID: $0.pointID,
                                displayValue: $0.title,
                                elementName: $0.pointName,
                                kind: .point
                            )
                        }
                    )
                )
            }

            // Boundaries
            let boundaryConditions = makeBoundaryMapSearchConditions(
                expression: parsedQuery.expression,
                attachmentAlias: "bq",
                instanceAlias: "bi",
                boundaryAlias: "b",
                directionalAlias: nil,
                includeBoundaryName: true
            )
            let boundaryWhere = boundaryConditions.sql.isEmpty ? "" : "\nWHERE \(boundaryConditions.sql)"
            struct BoundaryRow: FetchableRecord, Decodable {
                let instanceID: Int64
                let attachmentID: Int64
                let boundaryName: String
                let title: String
            }
            let boundaryRows = try BoundaryRow.fetchAll(
                db,
                sql: """
                    SELECT
                        bq.instance_id AS instanceID,
                        bq.id AS attachmentID,
                        COALESCE(b.name, '') AS boundaryName,
                        COALESCE(bi.title, '') AS title
                    FROM boundarymap_attachment AS bq
                    JOIN boundarymap_instance AS bi
                        ON bi.instance_id = bq.instance_id
                    JOIN boundary AS b
                        ON b.id = bq.boundary_id\(boundaryWhere)
                    ORDER BY bi.title COLLATE NOCASE, b.name COLLATE NOCASE, bq.id
                    """,
                arguments: boundaryConditions.arguments
            )
            if !boundaryRows.isEmpty {
                let boundaryMapTypeID = try Self.fetchBoundaryMapTypeID(db: db)
                sections.append(
                    MapElementSearchSection(
                        typeID: boundaryMapTypeID,
                        typeName: BOUNDARYMAP_TYPE_NAME,
                        elements: boundaryRows.map {
                            MapElementSearchResult(
                                instanceID: $0.instanceID,
                                elementID: $0.attachmentID,
                                displayValue: $0.title,
                                elementName: $0.boundaryName,
                                kind: .boundary
                            )
                        }
                    )
                )
            }

            return sections
        }
    }

    private func fetchPointMapQuerySearchRows(
        db: Database,
        expression: SearchExpression?
    ) throws -> [QuerySearchResult] {
        let searchConditions = makePointMapSearchConditions(
            expression: expression,
            pointAlias: "pp",
            instanceAlias: "pi",
            directionalAlias: "pp",
            includePointName: true
        )
        let whereClause = searchConditions.sql.isEmpty ? "" : "\nWHERE \(searchConditions.sql)"

        struct Row: FetchableRecord, Decodable {
            let instanceID: Int64
            let pointID: Int64
            let pointName: String
            let title: String
            let isReverse: Bool
        }

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT
                    pp.instance_id AS instanceID,
                    pp.id AS pointID,
                    COALESCE(pp.name, '') AS pointName,
                    COALESCE(pi.title, '') AS title,
                    pp.is_reverse AS isReverse
                FROM \(Self.pointMapDirectionalFrom) AS pp
                JOIN pointmap_instance AS pi
                    ON pi.instance_id = pp.instance_id\(whereClause)
                ORDER BY pi.title COLLATE NOCASE, pp.name COLLATE NOCASE, pp.id, pp.is_reverse
                """,
            arguments: searchConditions.arguments
        )

        return rows.map { row in
            QuerySearchResult(
                instanceID: row.instanceID,
                queryTypeID: row.pointID,
                displayValue: row.title,
                queryTypeName: row.pointName + (row.isReverse ? " (Reverse)" : " (Forward)"),
                isReverse: row.isReverse
            )
        }
    }

    func resetQueryDueDates(query: String) throws {
        let parsedQuery = try parseQuerySearchQuery(query)

        try dbQueue.write { db in
            try validateCollectionSearchComponents(
                Self.collectionNames(in: parsedQuery.expression),
                db: db
            )
            try validateOfficeSearchComponents(
                Self.officeNames(in: parsedQuery.expression),
                db: db
            )

            let typeInfos = try fetchInstanceSearchTypeInfos(db: db)
            let personTypeID = try? Self.fetchPersonTypeID(db: db)
            for typeInfo in typeInfos {
                let tableName = "\"type\(typeInfo.typeID)\""
                let tableAlias = "instance_table"
                let searchConditions = makeQuerySearchConditions(
                    tableAlias: tableAlias,
                    typeName: typeInfo.typeName,
                    typeID: typeInfo.typeID,
                    fieldIndices: typeInfo.allFieldIndices,
                    expression: parsedQuery.expression
                )
                let whereClause = searchConditions.sql.isEmpty ? "1" : searchConditions.sql

                try db.execute(
                    sql: """
                        UPDATE query
                        SET query_state = 0,
                            last_answered_timestamp = NULL,
                            interval = 0
                        WHERE EXISTS (
                            SELECT 1
                            FROM \(tableName) AS \(tableAlias)
                            WHERE query.instance_id = \(tableAlias).id
                                AND \(whereClause)
                        )
                        """,
                    arguments: searchConditions.arguments
                )

                if typeInfo.typeID == personTypeID {
                    let personConditions = makeQuerySearchConditions(
                        tableAlias: tableAlias,
                        typeName: typeInfo.typeName,
                        typeID: typeInfo.typeID,
                        fieldIndices: typeInfo.allFieldIndices,
                        expression: parsedQuery.expression,
                        srsAlias: "pq"
                    )
                    let personWhere = personConditions.sql.isEmpty ? "1" : personConditions.sql
                    try db.execute(
                        sql: """
                            UPDATE person_query
                            SET query_state = 0,
                                last_answered_timestamp = NULL,
                                interval = 0
                            WHERE id IN (
                                SELECT pq.id
                                FROM \(Self.personQueryJoinFrom(personTypeID: typeInfo.typeID))
                                WHERE \(personWhere)
                            )
                            """,
                        arguments: personConditions.arguments
                    )
                }
            }

            let pointMapConditions = makePointMapSearchConditions(
                expression: parsedQuery.expression,
                pointAlias: "pp",
                instanceAlias: "pi",
                directionalAlias: "pointmap_query",
                includePointName: true
            )
            let pointMapWhere = pointMapConditions.sql.isEmpty ? "1" : pointMapConditions.sql
            try db.execute(
                sql: """
                    UPDATE pointmap_query
                    SET query_state = 0,
                        last_answered_timestamp = NULL,
                        interval = 0
                    WHERE EXISTS (
                        SELECT 1
                        FROM pointmap_point AS pp
                        JOIN pointmap_instance AS pi
                            ON pi.instance_id = pp.instance_id
                        WHERE pp.id = pointmap_query.point_id
                            AND \(pointMapWhere)
                    )
                    """,
                arguments: pointMapConditions.arguments
            )

            let boundaryMapConditions = makeBoundaryMapSearchConditions(
                expression: parsedQuery.expression,
                attachmentAlias: "bq",
                instanceAlias: "bi",
                boundaryAlias: "b",
                directionalAlias: "boundarymap_query",
                includeBoundaryName: true
            )
            let boundaryMapWhere = boundaryMapConditions.sql.isEmpty ? "1" : boundaryMapConditions.sql
            try db.execute(
                sql: """
                    UPDATE boundarymap_query
                    SET query_state = 0,
                        last_answered_timestamp = NULL,
                        interval = 0
                    WHERE EXISTS (
                        SELECT 1
                        FROM boundarymap_attachment AS bq
                        JOIN boundarymap_instance AS bi
                            ON bi.instance_id = bq.instance_id
                        JOIN boundary AS b
                            ON b.id = bq.boundary_id
                        WHERE bq.id = boundarymap_query.attachment_id
                            AND \(boundaryMapWhere)
                    )
                    """,
                arguments: boundaryMapConditions.arguments
            )
        }
    }

    func resetQueryDueDates(instanceIDAndQueryTypeIDPairs: [(instanceID: Int64, queryTypeID: Int64)]) throws {
        guard !instanceIDAndQueryTypeIDPairs.isEmpty else { return }

        try dbQueue.write { db in
            for pair in instanceIDAndQueryTypeIDPairs {
                try db.execute(
                    sql: """
                        UPDATE query
                        SET query_state = 0,
                            last_answered_timestamp = NULL,
                            interval = 0
                        WHERE instance_id = ? AND query_type_id = ?
                        """,
                    arguments: [pair.instanceID, pair.queryTypeID]
                )
                try db.execute(
                    sql: """
                        UPDATE pointmap_query
                        SET query_state = 0,
                            last_answered_timestamp = NULL,
                            interval = 0
                        WHERE point_id IN (
                            SELECT id FROM pointmap_point WHERE id = ? AND instance_id = ?
                        )
                        """,
                    arguments: [pair.queryTypeID, pair.instanceID]
                )
                try db.execute(
                    sql: """
                        UPDATE boundarymap_query
                        SET query_state = 0,
                            last_answered_timestamp = NULL,
                            interval = 0
                        WHERE attachment_id IN (
                            SELECT id FROM boundarymap_attachment WHERE id = ? AND instance_id = ?
                        )
                        """,
                    arguments: [pair.queryTypeID, pair.instanceID]
                )
            }
        }
    }

    /// Disables the given queries by removing their per-instance query rows. This
    /// never deletes instances — only the `query` / `pointmap_query` /
    /// `boundarymap_query` rows that make a query active. For map types, the
    /// `queryTypeID` is a point/attachment id, so both directions are disabled.
    func disableQueries(instanceIDAndQueryTypeIDPairs: [(instanceID: Int64, queryTypeID: Int64)]) throws {
        guard !instanceIDAndQueryTypeIDPairs.isEmpty else { return }

        try dbQueue.write { db in
            for pair in instanceIDAndQueryTypeIDPairs {
                try db.execute(
                    sql: "DELETE FROM query WHERE instance_id = ? AND query_type_id = ?",
                    arguments: [pair.instanceID, pair.queryTypeID]
                )
                try db.execute(
                    sql: """
                        DELETE FROM pointmap_query
                        WHERE point_id IN (
                            SELECT id FROM pointmap_point WHERE id = ? AND instance_id = ?
                        )
                        """,
                    arguments: [pair.queryTypeID, pair.instanceID]
                )
                try db.execute(
                    sql: """
                        DELETE FROM boundarymap_query
                        WHERE attachment_id IN (
                            SELECT id FROM boundarymap_attachment WHERE id = ? AND instance_id = ?
                        )
                        """,
                    arguments: [pair.queryTypeID, pair.instanceID]
                )
            }
        }
    }

    /// Resets due dates for specific query targets, honoring direction for map
    /// queries (a single Forward/Reverse direction), unlike the pair-based
    /// variant which resets both directions of a point/boundary.
    func resetQueryDueDates(targets: [QueryTarget]) throws {
        guard !targets.isEmpty else { return }
        try dbQueue.write { db in
            for target in targets {
                switch target.kind {
                case .standard:
                    try db.execute(
                        sql: """
                            UPDATE query
                            SET query_state = 0, last_answered_timestamp = NULL, interval = 0
                            WHERE instance_id = ? AND query_type_id = ?
                            """,
                        arguments: [target.instanceID, target.queryTypeID]
                    )
                case .point:
                    try db.execute(
                        sql: """
                            UPDATE pointmap_query
                            SET query_state = 0, last_answered_timestamp = NULL, interval = 0
                            WHERE is_reverse = ? AND point_id IN (
                                SELECT id FROM pointmap_point WHERE id = ? AND instance_id = ?
                            )
                            """,
                        arguments: [target.isReverse ? 1 : 0, target.queryTypeID, target.instanceID]
                    )
                case .boundary:
                    try db.execute(
                        sql: """
                            UPDATE boundarymap_query
                            SET query_state = 0, last_answered_timestamp = NULL, interval = 0
                            WHERE is_reverse = ? AND attachment_id IN (
                                SELECT id FROM boundarymap_attachment WHERE id = ? AND instance_id = ?
                            )
                            """,
                        arguments: [target.isReverse ? 1 : 0, target.queryTypeID, target.instanceID]
                    )
                case .person:
                    guard let personKind = target.personKind else { continue }
                    try db.execute(
                        sql: """
                            UPDATE person_query
                            SET query_state = 0, last_answered_timestamp = NULL, interval = 0
                            WHERE instance_id = ? AND kind = ? AND partnership_id IS ? AND office_id IS ?
                            """,
                        arguments: [target.instanceID, personKind.rawValue, target.personPartnershipID, target.personOfficeID]
                    )
                }
            }
        }
    }

    /// Disables specific query targets by removing their backing query rows,
    /// honoring direction for map queries. Never deletes instances.
    func disableQueries(targets: [QueryTarget]) throws {
        guard !targets.isEmpty else { return }
        try dbQueue.write { db in
            for target in targets {
                switch target.kind {
                case .standard:
                    try db.execute(
                        sql: "DELETE FROM query WHERE instance_id = ? AND query_type_id = ?",
                        arguments: [target.instanceID, target.queryTypeID]
                    )
                case .point:
                    try db.execute(
                        sql: """
                            DELETE FROM pointmap_query
                            WHERE is_reverse = ? AND point_id IN (
                                SELECT id FROM pointmap_point WHERE id = ? AND instance_id = ?
                            )
                            """,
                        arguments: [target.isReverse ? 1 : 0, target.queryTypeID, target.instanceID]
                    )
                case .boundary:
                    try db.execute(
                        sql: """
                            DELETE FROM boundarymap_query
                            WHERE is_reverse = ? AND attachment_id IN (
                                SELECT id FROM boundarymap_attachment WHERE id = ? AND instance_id = ?
                            )
                            """,
                        arguments: [target.isReverse ? 1 : 0, target.queryTypeID, target.instanceID]
                    )
                case .person:
                    guard let personKind = target.personKind else { continue }
                    try db.execute(
                        sql: """
                            DELETE FROM person_query
                            WHERE instance_id = ? AND kind = ? AND partnership_id IS ? AND office_id IS ?
                            """,
                        arguments: [target.instanceID, personKind.rawValue, target.personPartnershipID, target.personOfficeID]
                    )
                }
            }
        }
    }

    func fetchStudyQueryBuckets(forStackSearch stackSearch: String) throws -> StudyQueryBuckets {
        let parsedQuery = try parseQuerySearchQuery(stackSearch)
        let startOfTomorrowTimestamp = TimeZoneSettings.shared.startOfTomorrowTimestamp()

        return try dbQueue.read { db in
            try validateCollectionSearchComponents(Self.collectionNames(in: parsedQuery.expression), db: db)
            try validateOfficeSearchComponents(Self.officeNames(in: parsedQuery.expression), db: db)

            let typeInfos = try fetchInstanceSearchTypeInfos(db: db)
            var blueQueries: [StudyQuery] = []
            var redQueries: [StudyQuery] = []
            var greenQueries: [StudyQuery] = []

            for typeInfo in typeInfos {
                blueQueries += try fetchStudyQueries(
                    db: db,
                    typeInfo: typeInfo,
                    parsedQuery: parsedQuery,
                    whereSQL: "query.interval = 0",
                    additionalArguments: StatementArguments()
                )
                redQueries += try fetchStudyQueries(
                    db: db,
                    typeInfo: typeInfo,
                    parsedQuery: parsedQuery,
                    whereSQL: "query.interval != 0 AND query.interval <= \(QUERY_STARTER_DELAY_GOOD)",
                    additionalArguments: StatementArguments()
                )
                greenQueries += try fetchStudyQueries(
                    db: db,
                    typeInfo: typeInfo,
                    parsedQuery: parsedQuery,
                    whereSQL: """
                        query.interval > \(QUERY_STARTER_DELAY_GOOD)
                        AND query.last_answered_timestamp + query.interval < ?
                        """,
                    additionalArguments: [startOfTomorrowTimestamp]
                )
            }

            blueQueries += try fetchPersonStudyQueries(
                db: db,
                parsedQuery: parsedQuery,
                whereSQL: "pq.interval = 0",
                additionalArguments: StatementArguments()
            )
            redQueries += try fetchPersonStudyQueries(
                db: db,
                parsedQuery: parsedQuery,
                whereSQL: "pq.interval != 0 AND pq.interval <= \(QUERY_STARTER_DELAY_GOOD)",
                additionalArguments: StatementArguments()
            )
            greenQueries += try fetchPersonStudyQueries(
                db: db,
                parsedQuery: parsedQuery,
                whereSQL: """
                    pq.interval > \(QUERY_STARTER_DELAY_GOOD)
                    AND pq.last_answered_timestamp + pq.interval < ?
                    """,
                additionalArguments: [startOfTomorrowTimestamp]
            )

            blueQueries += try fetchPointMapStudyQueries(
                db: db,
                parsedQuery: parsedQuery,
                whereSQL: "pp.interval = 0",
                additionalArguments: StatementArguments()
            )
            redQueries += try fetchPointMapStudyQueries(
                db: db,
                parsedQuery: parsedQuery,
                whereSQL: "pp.interval != 0 AND pp.interval <= \(QUERY_STARTER_DELAY_GOOD)",
                additionalArguments: StatementArguments()
            )
            greenQueries += try fetchPointMapStudyQueries(
                db: db,
                parsedQuery: parsedQuery,
                whereSQL: """
                    pp.interval > \(QUERY_STARTER_DELAY_GOOD)
                    AND pp.last_answered_timestamp + pp.interval < ?
                    """,
                additionalArguments: [startOfTomorrowTimestamp]
            )

            blueQueries += try fetchBoundaryMapStudyQueries(
                db: db,
                parsedQuery: parsedQuery,
                whereSQL: "bq.interval = 0",
                additionalArguments: StatementArguments()
            )
            redQueries += try fetchBoundaryMapStudyQueries(
                db: db,
                parsedQuery: parsedQuery,
                whereSQL: "bq.interval != 0 AND bq.interval <= \(QUERY_STARTER_DELAY_GOOD)",
                additionalArguments: StatementArguments()
            )
            greenQueries += try fetchBoundaryMapStudyQueries(
                db: db,
                parsedQuery: parsedQuery,
                whereSQL: """
                    bq.interval > \(QUERY_STARTER_DELAY_GOOD)
                    AND bq.last_answered_timestamp + bq.interval < ?
                    """,
                additionalArguments: [startOfTomorrowTimestamp]
            )

            return StudyQueryBuckets(
                blueQueries: blueQueries,
                redQueries: redQueries,
                greenQueries: greenQueries
            )
        }
    }

    func selectNextStudyQuery(forStackSearch stackSearch: String, nowTimestamp: Int64) throws -> StudySelectionResult {
        let parsedQuery = try parseQuerySearchQuery(stackSearch)

        return try dbQueue.read { db in
            try validateCollectionSearchComponents(Self.collectionNames(in: parsedQuery.expression), db: db)
            try validateOfficeSearchComponents(Self.officeNames(in: parsedQuery.expression), db: db)

            let typeInfos = try fetchInstanceSearchTypeInfos(db: db)
            var pools: [StudySelectionPool] = try typeInfos.compactMap { typeInfo in
                let summary = try fetchStudyTypeSummary(
                    db: db,
                    typeInfo: typeInfo,
                    parsedQuery: parsedQuery
                )
                return summary.totalCount > 0 ? .standard(summary) : nil
            }
            if let personSummary = try fetchPersonStudySummary(db: db, parsedQuery: parsedQuery),
               personSummary.totalCount > 0 {
                pools.append(.person(personSummary))
            }
            let pointMapSummary = try fetchPointMapStudySummary(db: db, parsedQuery: parsedQuery)
            if pointMapSummary.totalCount > 0 {
                pools.append(.pointMap(pointMapSummary))
            }
            let boundaryMapSummary = try fetchBoundaryMapStudySummary(db: db, parsedQuery: parsedQuery)
            if boundaryMapSummary.totalCount > 0 {
                pools.append(.boundaryMap(boundaryMapSummary))
            }

            let totalCount = pools.reduce(0) { $0 + $1.totalCount }
            let totalNewCount = pools.reduce(0) { $0 + $1.newCount }
            let totalSeenCount = pools.reduce(0) { $0 + $1.seenCount }

            guard totalCount > 0 else {
                return .completed
            }

            let shouldChooseNewQuery: Bool
            if totalNewCount == 0 {
                shouldChooseNewQuery = false
            } else if totalSeenCount == 0 {
                shouldChooseNewQuery = true
            } else {
                shouldChooseNewQuery = Double.random(in: 0..<1) < (Double(totalNewCount) / Double(totalCount))
            }

            if shouldChooseNewQuery {
                return try selectRandomNewStudyQuery(
                    db: db,
                    pools: pools,
                    totalNewCount: totalNewCount,
                    parsedQuery: parsedQuery
                )
            }

            guard let minimumSeenDueTimestamp = pools.compactMap(\.minimumSeenDueTimestamp).min() else {
                if totalNewCount > 0 {
                    return try selectRandomNewStudyQuery(
                        db: db,
                        pools: pools,
                        totalNewCount: totalNewCount,
                        parsedQuery: parsedQuery
                    )
                }
                return .completed
            }

            guard minimumSeenDueTimestamp <= nowTimestamp else {
                if totalNewCount > 0 {
                    return try selectRandomNewStudyQuery(
                        db: db,
                        pools: pools,
                        totalNewCount: totalNewCount,
                        parsedQuery: parsedQuery
                    )
                }
                return .completed
            }

            let tiedPools = pools.filter { $0.minimumSeenDueTimestamp == minimumSeenDueTimestamp }
            let tieCountByPool: [(StudySelectionPool, Int)] = try tiedPools.map { pool in
                switch pool {
                case .standard(let summary):
                    let count = try fetchStudyQueryCount(
                        db: db,
                        typeInfo: summary.typeInfo,
                        parsedQuery: parsedQuery,
                        whereSQL: "query.interval != 0 AND query.last_answered_timestamp + query.interval = ?",
                        additionalArguments: [minimumSeenDueTimestamp]
                    )
                    return (pool, count)
                case .pointMap:
                    let count = try fetchPointMapStudyQueryCount(
                        db: db,
                        parsedQuery: parsedQuery,
                        whereSQL: "pp.interval != 0 AND pp.last_answered_timestamp + pp.interval = ?",
                        additionalArguments: [minimumSeenDueTimestamp]
                    )
                    return (pool, count)
                case .boundaryMap:
                    let count = try fetchBoundaryMapStudyQueryCount(
                        db: db,
                        parsedQuery: parsedQuery,
                        whereSQL: "bq.interval != 0 AND bq.last_answered_timestamp + bq.interval = ?",
                        additionalArguments: [minimumSeenDueTimestamp]
                    )
                    return (pool, count)
                case .person:
                    let count = try fetchPersonStudyQueryCount(
                        db: db,
                        parsedQuery: parsedQuery,
                        whereSQL: "pq.interval != 0 AND pq.last_answered_timestamp + pq.interval = ?",
                        additionalArguments: [minimumSeenDueTimestamp]
                    )
                    return (pool, count)
                }
            }

            let totalTieCount = tieCountByPool.reduce(0) { $0 + $1.1 }
            guard totalTieCount > 0 else {
                return .completed
            }

            var randomIndex = Int.random(in: 0..<totalTieCount)
            var selectedPool = tieCountByPool[0].0
            for (pool, tieCount) in tieCountByPool where tieCount > 0 {
                if randomIndex < tieCount {
                    selectedPool = pool
                    break
                }
                randomIndex -= tieCount
            }

            switch selectedPool {
            case .standard(let summary):
                let queryRow = try fetchRandomStudyQueryRow(
                    db: db,
                    typeInfo: summary.typeInfo,
                    parsedQuery: parsedQuery,
                    whereSQL: "query.interval != 0 AND query.last_answered_timestamp + query.interval = ?",
                    additionalArguments: [minimumSeenDueTimestamp]
                )
                return .query(try makeStudyQuery(db: db, typeInfo: summary.typeInfo, queryRow: queryRow))
            case .pointMap:
                let query = try fetchRandomPointMapStudyQuery(
                    db: db,
                    parsedQuery: parsedQuery,
                    whereSQL: "pp.interval != 0 AND pp.last_answered_timestamp + pp.interval = ?",
                    additionalArguments: [minimumSeenDueTimestamp]
                )
                return .query(query)
            case .boundaryMap:
                let query = try fetchRandomBoundaryMapStudyQuery(
                    db: db,
                    parsedQuery: parsedQuery,
                    whereSQL: "bq.interval != 0 AND bq.last_answered_timestamp + bq.interval = ?",
                    additionalArguments: [minimumSeenDueTimestamp]
                )
                return .query(query)
            case .person:
                let query = try fetchRandomPersonStudyQuery(
                    db: db,
                    parsedQuery: parsedQuery,
                    whereSQL: "pq.interval != 0 AND pq.last_answered_timestamp + pq.interval = ?",
                    additionalArguments: [minimumSeenDueTimestamp]
                )
                return .query(query)
            }
        }
    }

    private func selectRandomNewStudyQuery(
        db: Database,
        pools: [StudySelectionPool],
        totalNewCount: Int,
        parsedQuery: QuerySearchQuery
    ) throws -> StudySelectionResult {
        guard totalNewCount > 0 else {
            throw DatabaseError(message: "No study query matched the requested criteria.")
        }

        var randomIndex = Int.random(in: 0..<totalNewCount)
        var selectedPool: StudySelectionPool?
        for pool in pools where pool.newCount > 0 {
            if randomIndex < pool.newCount {
                selectedPool = pool
                break
            }
            randomIndex -= pool.newCount
        }
        guard let selectedPool else {
            throw DatabaseError(message: "Failed to choose a study query.")
        }

        switch selectedPool {
        case .standard(let summary):
            let queryRow = try fetchRandomStudyQueryRow(
                db: db,
                typeInfo: summary.typeInfo,
                parsedQuery: parsedQuery,
                whereSQL: "query.interval = 0",
                additionalArguments: StatementArguments()
            )
            return .query(try makeStudyQuery(db: db, typeInfo: summary.typeInfo, queryRow: queryRow))
        case .pointMap:
            let query = try fetchRandomPointMapStudyQuery(
                db: db,
                parsedQuery: parsedQuery,
                whereSQL: "pp.interval = 0",
                additionalArguments: StatementArguments()
            )
            return .query(query)
        case .boundaryMap:
            let query = try fetchRandomBoundaryMapStudyQuery(
                db: db,
                parsedQuery: parsedQuery,
                whereSQL: "bq.interval = 0",
                additionalArguments: StatementArguments()
            )
            return .query(query)
        case .person:
            let query = try fetchRandomPersonStudyQuery(
                db: db,
                parsedQuery: parsedQuery,
                whereSQL: "pq.interval = 0",
                additionalArguments: StatementArguments()
            )
            return .query(query)
        }
    }

    @discardableResult
    func applyStudyResponse(
        instanceID: Int64,
        queryTypeID: Int64,
        rating: StudyResponseRating,
        answeredAtTimestamp: Int64,
        overrideInterval: Int64? = nil
    ) throws -> StudyResponseOutcome {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT interval, query_state
                    FROM query
                    WHERE instance_id = ? AND query_type_id = ?
                    """,
                arguments: [instanceID, queryTypeID]
            ) else {
                throw DatabaseError(message: "Study query not found.")
            }

            let currentInterval = row["interval"] as Int64? ?? 0
            let currentState = QueryState(rawValue: row["query_state"] as Int? ?? 0) ?? .zero
            let outcome = studyResponseOutcome(
                currentState: currentState,
                currentInterval: currentInterval,
                rating: rating
            )
            let updatedInterval = overrideInterval ?? outcome.newInterval

            try db.execute(
                sql: """
                    UPDATE query
                    SET query_state = ?,
                        last_answered_timestamp = ?,
                        interval = ?
                    WHERE instance_id = ? AND query_type_id = ?
                    """,
                arguments: [
                    outcome.newState.rawValue,
                    answeredAtTimestamp,
                    updatedInterval,
                    instanceID,
                    queryTypeID
                ]
            )
            return StudyResponseOutcome(newState: outcome.newState, newInterval: updatedInterval)
        }
    }

    func fetchQueryState(instanceID: Int64, queryTypeID: Int64) throws -> QueryState {
        try dbQueue.read { db in
            let raw = try Int.fetchOne(
                db,
                sql: "SELECT query_state FROM query WHERE instance_id = ? AND query_type_id = ?",
                arguments: [instanceID, queryTypeID]
            ) ?? 0
            return QueryState(rawValue: raw) ?? .zero
        }
    }

    func fetchQueryIntervals(forInstanceID instanceID: Int64) throws -> [Int64: Int64] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT query_type_id, interval FROM query WHERE instance_id = ?",
                arguments: [instanceID]
            )
            var result: [Int64: Int64] = [:]
            for row in rows {
                guard let queryTypeID = row["query_type_id"] as Int64?,
                      let interval = row["interval"] as Int64? else { continue }
                result[queryTypeID] = interval
            }
            return result
        }
    }

    func fetchQuerySRSInfo(forInstanceID instanceID: Int64) throws -> [QuerySRSInfo] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT query_type_id, interval, query_state, last_answered_timestamp, max_interval
                    FROM query
                    WHERE instance_id = ?
                    ORDER BY query_type_id
                    """,
                arguments: [instanceID]
            )
            return rows.map { row in
                QuerySRSInfo(
                    queryTypeID: row["query_type_id"] as Int64? ?? 0,
                    interval: row["interval"] as Int64? ?? 0,
                    queryState: QueryState(rawValue: row["query_state"] as Int? ?? 0) ?? .zero,
                    lastAnsweredTimestamp: row["last_answered_timestamp"] as Int64?,
                    maxInterval: row["max_interval"] as Int64?
                )
            }
        }
    }

    func revertStudyResponse(
        instanceID: Int64,
        queryTypeID: Int64,
        originalInterval: Int64,
        originalLastAnsweredTimestamp: Int64?,
        originalQueryState: QueryState
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE query
                    SET query_state = ?,
                        last_answered_timestamp = ?,
                        interval = ?
                    WHERE instance_id = ? AND query_type_id = ?
                    """,
                arguments: [
                    originalQueryState.rawValue,
                    originalLastAnsweredTimestamp,
                    originalInterval,
                    instanceID,
                    queryTypeID
                ]
            )
        }
    }

    func fetchFields(forTypeID typeID: Int64) throws -> [TypeField] {
        try dbQueue.read { db in
            try TypeField.fetchAll(
                db,
                sql: """
                    SELECT
                        id,
                        type_id AS typeID,
                        name,
                        field_index AS fieldIndex,
                        field_display_index AS fieldDisplayIndex,
                        COALESCE(is_primary, 0) AS isPrimary,
                        field_type AS fieldType,
                        COALESCE(is_protected, 0) AS isProtected
                    FROM field
                    WHERE type_id = ?
                    ORDER BY field_index, id
                    """,
                arguments: [typeID]
            )
        }
    }

    func fetchFieldsForDisplay(forTypeID typeID: Int64) throws -> [TypeField] {
        try dbQueue.read { db in
            try TypeField.fetchAll(
                db,
                sql: """
                    SELECT
                        id,
                        type_id AS typeID,
                        name,
                        field_index AS fieldIndex,
                        field_display_index AS fieldDisplayIndex,
                        COALESCE(is_primary, 0) AS isPrimary,
                        field_type AS fieldType,
                        COALESCE(is_protected, 0) AS isProtected
                    FROM field
                    WHERE type_id = ?
                    ORDER BY field_display_index, id
                    """,
                arguments: [typeID]
            )
        }
    }

    func fetchQueryTypes(forTypeID typeID: Int64) throws -> [QueryType] {
        try dbQueue.read { db in
            try QueryType.fetchAll(
                db,
                sql: """
                    SELECT
                        id,
                        type_id AS typeID,
                        name,
                        question_html AS questionHTML,
                        answer_html AS answerHTML
                    FROM query_type
                    WHERE type_id = ?
                    ORDER BY name COLLATE NOCASE, id
                    """,
                arguments: [typeID]
            )
        }
    }

    func fetchTypeInstancesPageData(
        forTypeID typeID: Int64,
        searchQuery: String = ""
    ) throws -> TypeInstancesPageData {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedQuery: InstanceSearchQuery? = trimmedQuery.isEmpty
            ? nil
            : try parseInstanceSearchQuery(searchQuery)

        return try dbQueue.read { db in
            if let parsedQuery {
                try validateCollectionSearchComponents(
                    Self.collectionNames(in: parsedQuery.expression),
                    db: db
                )
                try validateOfficeSearchComponents(
                    Self.officeNames(in: parsedQuery.expression),
                    db: db
                )
            }

            let pointMapTypeID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM \"type\" WHERE name = ? AND is_builtin = 1",
                arguments: [POINTMAP_TYPE_NAME]
            )
            if let pointMapTypeID, pointMapTypeID == typeID {
                return try fetchPointMapTypeInstancesPageData(db: db, expression: parsedQuery?.expression)
            }

            let boundaryMapTypeID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM \"type\" WHERE name = ? AND is_builtin = 1",
                arguments: [BOUNDARYMAP_TYPE_NAME]
            )
            if let boundaryMapTypeID, boundaryMapTypeID == typeID {
                return try fetchBoundaryMapTypeInstancesPageData(db: db, expression: parsedQuery?.expression)
            }

            guard let displayFieldInfo = try TypeInstancesDisplayFieldInfo.fetchOne(
                db,
                sql: """
                    SELECT
                        field_index AS fieldIndex,
                        name
                    FROM field
                    WHERE type_id = ?
                    ORDER BY is_primary DESC, field_display_index ASC, id
                    LIMIT 1
                    """,
                arguments: [typeID]
            ) else {
                throw DatabaseError(message: "Type is missing a field with display_index = 1.")
            }

            let queryTypes = try QueryType.fetchAll(
                db,
                sql: """
                    SELECT
                        id,
                        type_id AS typeID,
                        name,
                        question_html AS questionHTML,
                        answer_html AS answerHTML
                    FROM query_type
                    WHERE type_id = ?
                    ORDER BY name COLLATE NOCASE, id
                    """,
                arguments: [typeID]
            )

            let tableName = "\"type\(typeID)\""
            let tableAlias = "instance_table"
            let displayColumnName = "\"field\(displayFieldInfo.fieldIndex)\""

            var whereClause = ""
            var instanceArguments = StatementArguments()
            if let parsedQuery {
                let typeInfos = try fetchInstanceSearchTypeInfos(db: db)
                guard let typeInfo = typeInfos.first(where: { $0.typeID == typeID }) else {
                    throw DatabaseError(message: "Type not found.")
                }
                let conditions = makeInstanceSearchConditions(
                    tableAlias: tableAlias,
                    typeName: typeInfo.typeName,
                    typeID: typeInfo.typeID,
                    fieldIndices: typeInfo.allFieldIndices,
                    expression: parsedQuery.expression
                )
                if !conditions.sql.isEmpty {
                    whereClause = "\nWHERE \(conditions.sql)"
                    instanceArguments = conditions.arguments
                }
            }

            let instanceRows = try TypeInstancesValueRow.fetchAll(
                db,
                sql: """
                    SELECT
                        \(tableAlias).id,
                        COALESCE(\(tableAlias).\(displayColumnName), '') AS displayValue
                    FROM \(tableName) AS \(tableAlias)\(whereClause)
                    ORDER BY \(tableAlias).\(displayColumnName) COLLATE NOCASE, \(tableAlias).id
                    """,
                arguments: instanceArguments
            )

            let membershipRows = try TypeInstancesMembershipRow.fetchAll(
                db,
                sql: """
                    SELECT
                        query.instance_id AS instanceID,
                        query.query_type_id AS queryTypeID
                    FROM query
                    JOIN query_type
                        ON query_type.id = query.query_type_id
                    WHERE query_type.type_id = ?
                    ORDER BY query.instance_id, query.query_type_id
                    """,
                arguments: [typeID]
            )

            var enabledQueryTypeIDsByInstanceID: [Int64: Set<Int64>] = [:]
            for membershipRow in membershipRows {
                enabledQueryTypeIDsByInstanceID[membershipRow.instanceID, default: []].insert(membershipRow.queryTypeID)
            }

            let rows = instanceRows.map { row in
                TypeInstancesPageRow(
                    id: row.id,
                    displayValue: row.displayValue,
                    enabledQueryTypeIDs: enabledQueryTypeIDsByInstanceID[row.id] ?? []
                )
            }

            return TypeInstancesPageData(
                displayFieldName: displayFieldInfo.name,
                queryTypes: queryTypes,
                rows: rows
            )
        }
    }

    private func fetchPointMapTypeInstancesPageData(
        db: Database,
        expression: SearchExpression? = nil
    ) throws -> TypeInstancesPageData {
        struct PointMapInstancesRow: FetchableRecord, Decodable {
            let instanceID: Int64
            let title: String
            let pointCount: Int
        }

        let searchConditions = makePointMapSearchConditions(
            expression: expression,
            pointAlias: "pp",
            instanceAlias: "pi",
            directionalAlias: nil,
            includePointName: false
        )
        let whereClause = searchConditions.sql.isEmpty ? "" : "\nWHERE \(searchConditions.sql)"

        let rows = try PointMapInstancesRow.fetchAll(
            db,
            sql: """
                SELECT
                    pi.instance_id AS instanceID,
                    COALESCE(pi.title, '') AS title,
                    (SELECT COUNT(*) FROM pointmap_point AS pp WHERE pp.instance_id = pi.instance_id) AS pointCount
                FROM pointmap_instance AS pi\(whereClause)
                ORDER BY pi.title COLLATE NOCASE, pi.instance_id
                """,
            arguments: searchConditions.arguments
        )

        let pageRows = rows.map { row in
            let label = "\(row.title) (\(row.pointCount) \(row.pointCount == 1 ? "query" : "queries"))"
            return TypeInstancesPageRow(
                id: row.instanceID,
                displayValue: label,
                enabledQueryTypeIDs: []
            )
        }

        return TypeInstancesPageData(
            displayFieldName: "Name",
            queryTypes: [],
            rows: pageRows
        )
    }

    func setQueryEnabled(_ isEnabled: Bool, instanceID: Int64, queryTypeID: Int64) throws {
        try dbQueue.write { db in
            if isEnabled {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO query (instance_id, query_type_id)
                        VALUES (?, ?)
                        """,
                    arguments: [instanceID, queryTypeID]
                )
            } else {
                try db.execute(
                    sql: """
                        DELETE FROM query
                        WHERE instance_id = ? AND query_type_id = ?
                        """,
                    arguments: [instanceID, queryTypeID]
                )
            }
        }
    }

    func fetchInstanceEditorData(instanceID: Int64) throws -> InstanceEditorData {
        try dbQueue.read { db in
            guard let typeID = try Int64.fetchOne(
                db,
                sql: """
                    SELECT type_id
                    FROM instance_id_type_id
                    WHERE instance_id = ?
                    """,
                arguments: [instanceID]
            ) else {
                throw DatabaseError(message: "Instance not found.")
            }

            let fields = try TypeField.fetchAll(
                db,
                sql: """
                    SELECT
                        id,
                        type_id AS typeID,
                        name,
                        field_index AS fieldIndex,
                        field_display_index AS fieldDisplayIndex
                    FROM field
                    WHERE type_id = ?
                    ORDER BY field_index, id
                    """,
                arguments: [typeID]
            )

            let tableName = "\"type\(typeID)\""
            let selectColumns = fields.map { field in
                "\"field\(field.fieldIndex)\" AS \"field_\(field.id)\""
            }.joined(separator: ", ")

            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT \(selectColumns)
                    FROM \(tableName)
                    WHERE id = ?
                    """,
                arguments: [instanceID]
            )

            let fieldValuesByFieldID = Dictionary(uniqueKeysWithValues: fields.map { field in
                let columnName = "field_\(field.id)"
                return (field.id, row?[columnName] as String? ?? "")
            })

            let enabledQueryTypeIDs = Set(try Int64.fetchAll(
                db,
                sql: """
                    SELECT query.query_type_id
                    FROM query
                    JOIN query_type
                        ON query_type.id = query.query_type_id
                    WHERE query.instance_id = ? AND query_type.type_id = ?
                    ORDER BY query.query_type_id
                    """,
                arguments: [instanceID, typeID]
            ))

            let maxIntervalRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT max_interval
                    FROM query
                    WHERE instance_id = ?
                    """,
                arguments: [instanceID]
            )
            let maxIntervalValues = Set(maxIntervalRows.map { $0["max_interval"] as Int64? })
            let maxInterval: Int64? = maxIntervalValues.count == 1 ? maxIntervalValues.first ?? nil : nil

            return InstanceEditorData(
                instanceID: instanceID,
                typeID: typeID,
                fieldValuesByFieldID: fieldValuesByFieldID,
                enabledQueryTypeIDs: enabledQueryTypeIDs,
                maxInterval: maxInterval
            )
        }
    }

    func fetchQueryPreview(instanceID: Int64, queryTypeID: Int64) throws -> StudyQuery {
        try dbQueue.read { db in
            if let pointMapPreview = try fetchPointMapQueryPreview(db: db, instanceID: instanceID, pointID: queryTypeID) {
                return pointMapPreview
            }
            if let boundaryMapPreview = try fetchBoundaryMapQueryPreview(db: db, instanceID: instanceID, attachmentID: queryTypeID) {
                return boundaryMapPreview
            }
            return try fetchQueryPreview(db: db, instanceID: instanceID, queryTypeID: queryTypeID)
        }
    }

    func fetchFirstQueryPreview(instanceID: Int64) throws -> StudyQuery {
        try dbQueue.read { db in
            if let pointMapPreview = try fetchPointMapQueryPreview(db: db, instanceID: instanceID, pointID: nil) {
                return pointMapPreview
            }
            if let boundaryMapPreview = try fetchBoundaryMapQueryPreview(db: db, instanceID: instanceID, attachmentID: nil) {
                return boundaryMapPreview
            }

            guard let typeID = try Int64.fetchOne(
                db,
                sql: """
                    SELECT type_id
                    FROM instance_id_type_id
                    WHERE instance_id = ?
                    """,
                arguments: [instanceID]
            ) else {
                throw DatabaseError(message: "Instance not found.")
            }

            guard let queryTypeID = try Int64.fetchOne(
                db,
                sql: """
                    SELECT id
                    FROM query_type
                    WHERE type_id = ?
                    ORDER BY id
                    LIMIT 1
                    """,
                arguments: [typeID]
            ) else {
                throw DatabaseError(message: "No query types exist for this instance's type.")
            }

            return try fetchQueryPreview(db: db, instanceID: instanceID, queryTypeID: queryTypeID)
        }
    }

    private func fetchPointMapQueryPreview(db: Database, instanceID: Int64, pointID: Int64?) throws -> StudyQuery? {
        struct PointMapInstanceRow: FetchableRecord, Decodable {
            let title: String
            let defaultCenterLat: Double
            let defaultCenterLng: Double
            let defaultZoom: Double
            let showAllPointsInQuestion: Bool
            let pointSize: PointMapPointSize
        }
        guard let instanceRow = try PointMapInstanceRow.fetchOne(
            db,
            sql: """
                SELECT
                    COALESCE(title, '') AS title,
                    default_center_lat AS defaultCenterLat,
                    default_center_lng AS defaultCenterLng,
                    default_zoom AS defaultZoom,
                    show_all_points_in_question AS showAllPointsInQuestion,
                    COALESCE(point_size, 'medium') AS pointSize
                FROM pointmap_instance
                WHERE instance_id = ?
                """,
            arguments: [instanceID]
        ) else {
            return nil
        }

        let pointRows = try GRDB.Row.fetchAll(
            db,
            sql: """
                SELECT id, name, hint, latitude, longitude
                FROM pointmap_point
                WHERE instance_id = ?
                ORDER BY id
                """,
            arguments: [instanceID]
        )
        let points = pointRows.map { pr in
            PointMapPoint(
                id: pr["id"] as Int64? ?? 0,
                instanceID: instanceID,
                name: pr["name"] as String? ?? "",
                latitude: pr["latitude"] as Double? ?? 0,
                longitude: pr["longitude"] as Double? ?? 0,
                hint: pr["hint"] as String? ?? ""
            )
        }

        let boundaries = try Self.fetchBoundaryGeometries(db: db, instanceID: instanceID)

        let highlightedPoint: PointMapPoint?
        if let pointID {
            guard let match = points.first(where: { $0.id == pointID }) else { return nil }
            highlightedPoint = match
        } else {
            highlightedPoint = nil
        }

        let payload = PointMapStudyPayload(
            pointID: highlightedPoint?.id ?? 0,
            pointName: highlightedPoint?.name ?? "",
            instanceTitle: instanceRow.title,
            points: points,
            defaultCenterLat: instanceRow.defaultCenterLat,
            defaultCenterLng: instanceRow.defaultCenterLng,
            defaultZoom: instanceRow.defaultZoom,
            showAllPointsInQuestion: instanceRow.showAllPointsInQuestion,
            showHighlight: highlightedPoint != nil,
            boundaries: boundaries,
            hint: highlightedPoint?.hint ?? "",
            pointSize: instanceRow.pointSize
        )
        return StudyQuery(
            instanceID: instanceID,
            queryTypeID: highlightedPoint?.id ?? 0,
            interval: 0,
            maxInterval: nil,
            lastAnsweredTimestamp: nil,
            queryState: .zero,
            typeName: POINTMAP_TYPE_NAME,
            queryTypeName: instanceRow.title,
            questionHTML: "",
            answerHTML: "",
            typeCSS: "",
            fieldValuesByName: [:],
            kind: .pointMap,
            pointMapPayload: payload
        )
    }

    private func fetchQueryPreview(db: Database, instanceID: Int64, queryTypeID: Int64) throws -> StudyQuery {
        guard let typeID = try Int64.fetchOne(
            db,
            sql: """
                SELECT type_id
                FROM instance_id_type_id
                WHERE instance_id = ?
                """,
            arguments: [instanceID]
        ) else {
            throw DatabaseError(message: "Instance not found.")
        }

        let typeInfos = try fetchInstanceSearchTypeInfos(db: db)
        guard let typeInfo = typeInfos.first(where: { $0.typeID == typeID }) else {
            throw DatabaseError(message: "Type not found for instance.")
        }

        guard let queryRow = try StudyQueryRow.fetchOne(
            db,
            sql: """
                SELECT
                    ? AS instanceID,
                    query_type.id AS queryTypeID,
                    0 AS interval,
                    NULL AS maxInterval,
                    NULL AS lastAnsweredTimestamp,
                    0 AS queryState,
                    query_type.name AS queryTypeName,
                    query_type.question_html AS questionHTML,
                    query_type.answer_html AS answerHTML,
                    "type".css AS typeCSS
                FROM query_type
                JOIN "type"
                    ON "type".id = query_type.type_id
                WHERE query_type.id = ?
                    AND query_type.type_id = ?
                """,
            arguments: [instanceID, queryTypeID, typeID]
        ) else {
            throw DatabaseError(message: "Query type not found for instance type.")
        }

        return try makeStudyQuery(db: db, typeInfo: typeInfo, queryRow: queryRow)
    }

    /// Builds a preview `StudyQuery` for a query type from its type alone, without
    /// requiring a persisted instance. Used by the Add Instance window, where the
    /// "instance" being previewed doesn't exist in the database yet. Field values
    /// are left empty here and supplied by the caller via `StudyQuery.withFieldValues`.
    func fetchQueryTypePreview(
        typeID: Int64,
        queryTypeID: Int64
    ) throws -> StudyQuery {
        try dbQueue.read { db in
            let typeInfos = try fetchInstanceSearchTypeInfos(db: db)
            guard let typeInfo = typeInfos.first(where: { $0.typeID == typeID }) else {
                throw DatabaseError(message: "Type not found.")
            }

            guard let queryRow = try StudyQueryRow.fetchOne(
                db,
                sql: """
                    SELECT
                        0 AS instanceID,
                        query_type.id AS queryTypeID,
                        0 AS interval,
                        NULL AS maxInterval,
                        NULL AS lastAnsweredTimestamp,
                        0 AS queryState,
                        query_type.name AS queryTypeName,
                        query_type.question_html AS questionHTML,
                        query_type.answer_html AS answerHTML,
                        "type".css AS typeCSS
                    FROM query_type
                    JOIN "type"
                        ON "type".id = query_type.type_id
                    WHERE query_type.id = ?
                        AND query_type.type_id = ?
                    """,
                arguments: [queryTypeID, typeID]
            ) else {
                throw DatabaseError(message: "Query type not found for type.")
            }

            // Carry the type's boolean field names so the draft preview renders
            // {{Bool}} / {{Bool:bit}} correctly once the caller supplies values
            // via withFieldValues.
            let booleanFieldNames = Set(try String.fetchAll(
                db,
                sql: "SELECT name FROM field WHERE type_id = ? AND field_type = 'boolean'",
                arguments: [typeID]
            ))

            return StudyQuery(
                instanceID: 0,
                queryTypeID: queryRow.queryTypeID,
                interval: queryRow.interval,
                maxInterval: queryRow.maxInterval,
                lastAnsweredTimestamp: queryRow.lastAnsweredTimestamp,
                queryState: QueryState(rawValue: queryRow.queryState) ?? .zero,
                typeName: typeInfo.typeName,
                queryTypeName: queryRow.queryTypeName,
                questionHTML: queryRow.questionHTML,
                answerHTML: queryRow.answerHTML,
                typeCSS: queryRow.typeCSS,
                fieldValuesByName: [:],
                booleanFieldNames: booleanFieldNames
            )
        }
    }

    func createType(name: String) throws -> FlashcardType {
        try dbQueue.write { db in
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw DatabaseError(message: "Type name cannot be empty.")
            }
            if Self.nameStartsWithDigit(trimmedName) {
                throw DatabaseError(message: "A type name cannot start with a digit.")
            }
            if try String.fetchOne(
                db,
                sql: "SELECT name FROM \"type\" WHERE name = ?",
                arguments: [trimmedName]
            ) != nil {
                throw DatabaseError(message: "A type named \"\(trimmedName)\" already exists.")
            }

            try db.execute(
                sql: """
                    INSERT INTO "type" (name, css)
                    VALUES (?, ?)
                    """,
                arguments: [trimmedName, ""]
            )
            let typeID = db.lastInsertedRowID

            try db.execute(
                sql: """
                    INSERT INTO field (type_id, name, field_index, field_display_index)
                    VALUES (?, ?, ?, ?), (?, ?, ?, ?)
                    """,
                arguments: [typeID, "Front", 1, 1, typeID, "Back", 2, 2]
            )
            try db.execute(
                sql: """
                    CREATE TABLE "type\(typeID)" (
                        id INTEGER PRIMARY KEY,
                        field1 TEXT,
                        field2 TEXT,
                        FOREIGN KEY (id) REFERENCES instance_id_type_id(instance_id) ON DELETE CASCADE
                    ) STRICT
                    """
            )

            return FlashcardType(id: typeID, name: trimmedName, description: "", css: "", isBuiltin: false, instanceCount: 0)
        }
    }

    /// Creates a new user type that copies the source type's description, CSS,
    /// fields (names, order, primary flag, kinds — same field_index layout, so
    /// the dynamic table's columns line up), query types (question/answer HTML
    /// verbatim) and their per-type enablement defaults. Instances are NOT
    /// copied. Only the name differs, validated like createType.
    func duplicateType(sourceTypeID: Int64, name: String) throws -> FlashcardType {
        try dbQueue.write { db in
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw DatabaseError(message: "Type name cannot be empty.")
            }
            if Self.nameStartsWithDigit(trimmedName) {
                throw DatabaseError(message: "A type name cannot start with a digit.")
            }
            if try String.fetchOne(
                db,
                sql: "SELECT name FROM \"type\" WHERE name = ?",
                arguments: [trimmedName]
            ) != nil {
                throw DatabaseError(message: "A type named \"\(trimmedName)\" already exists.")
            }
            guard let source = try Row.fetchOne(
                db,
                sql: """
                    SELECT description, css, COALESCE(is_builtin, 0) AS is_builtin
                    FROM "type"
                    WHERE id = ?
                    """,
                arguments: [sourceTypeID]
            ) else {
                throw DatabaseError(message: "Source type not found.")
            }
            if ((source["is_builtin"] as Int64?) ?? 0) != 0 {
                throw DatabaseError(message: "Built-in types cannot be duplicated.")
            }
            let description = source["description"] as String? ?? ""
            let css = source["css"] as String? ?? ""

            try db.execute(
                sql: """
                    INSERT INTO "type" (name, description, css)
                    VALUES (?, ?, ?)
                    """,
                arguments: [trimmedName, description, css]
            )
            let newTypeID = db.lastInsertedRowID

            let fieldRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        name,
                        field_index,
                        field_display_index,
                        COALESCE(is_primary, 0) AS is_primary,
                        field_type
                    FROM field
                    WHERE type_id = ?
                    ORDER BY field_index
                    """,
                arguments: [sourceTypeID]
            )
            var columnDefinitions: [String] = []
            for row in fieldRows {
                let fieldIndex = row["field_index"] as Int64? ?? 0
                let fieldType = row["field_type"] as String? ?? FieldKind.text.rawValue
                try db.execute(
                    sql: """
                        INSERT INTO field (type_id, name, field_index, field_display_index, is_primary, field_type)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        newTypeID,
                        row["name"] as String? ?? "",
                        fieldIndex,
                        row["field_display_index"] as Int64? ?? fieldIndex,
                        row["is_primary"] as Int64? ?? 0,
                        fieldType
                    ]
                )
                // Same column shapes as addField: booleans backfill '0'.
                let columnDefinition = fieldType == FieldKind.boolean.rawValue
                    ? "TEXT NOT NULL DEFAULT '0'"
                    : "TEXT DEFAULT ''"
                columnDefinitions.append("\"field\(fieldIndex)\" \(columnDefinition),")
            }
            try db.execute(
                sql: """
                    CREATE TABLE "type\(newTypeID)" (
                        id INTEGER PRIMARY KEY,
                        \(columnDefinitions.joined(separator: "\n    "))
                        FOREIGN KEY (id) REFERENCES instance_id_type_id(instance_id) ON DELETE CASCADE
                    ) STRICT
                    """
            )

            let queryTypeRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, question_html, answer_html
                    FROM query_type
                    WHERE type_id = ?
                    ORDER BY id
                    """,
                arguments: [sourceTypeID]
            )
            var newQueryTypeIDsBySourceID: [Int64: Int64] = [:]
            for row in queryTypeRows {
                try db.execute(
                    sql: """
                        INSERT INTO query_type (type_id, name, question_html, answer_html)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        newTypeID,
                        row["name"] as String?,
                        row["question_html"] as String?,
                        row["answer_html"] as String?
                    ]
                )
                newQueryTypeIDsBySourceID[row["id"] as Int64? ?? 0] = db.lastInsertedRowID
            }

            // The per-type "enabled by default on new instances" flags belong
            // to the query types, so they ride along (mapped to the new ids).
            let defaultRows = try Row.fetchAll(
                db,
                sql: "SELECT query_type_id, is_enabled FROM type_query_default WHERE type_id = ?",
                arguments: [sourceTypeID]
            )
            for row in defaultRows {
                guard let newQueryTypeID = newQueryTypeIDsBySourceID[row["query_type_id"] as Int64? ?? 0] else { continue }
                try db.execute(
                    sql: """
                        INSERT INTO type_query_default (type_id, query_type_id, is_enabled)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [newTypeID, newQueryTypeID, row["is_enabled"] as Int64? ?? 0]
                )
            }

            return FlashcardType(
                id: newTypeID,
                name: trimmedName,
                description: description,
                css: css,
                isBuiltin: false,
                instanceCount: 0
            )
        }
    }

    func createQueryType(forTypeID typeID: Int64, name: String) throws -> QueryType {
        try dbQueue.write { db in
            let fieldsForDisplay = try TypeField.fetchAll(
                db,
                sql: """
                    SELECT
                        id,
                        type_id AS typeID,
                        name,
                        field_index AS fieldIndex,
                        field_display_index AS fieldDisplayIndex,
                        COALESCE(is_primary, 0) AS isPrimary
                    FROM field
                    WHERE type_id = ?
                    ORDER BY field_display_index, id
                    """,
                arguments: [typeID]
            )

            guard let primaryDisplayField = fieldsForDisplay.sorted(by: Self.primaryFieldOrdering).first else {
                throw DatabaseError(message: "Type has no fields.")
            }

            let questionHTML = "<div class=\"\(primaryDisplayField.name)\">{{\(primaryDisplayField.name)}}</div>"
            let answerLines = fieldsForDisplay
                .filter { $0.id != primaryDisplayField.id }
                .map { "<div class=\"\($0.name)\">{{\($0.name)}}</div>" }
                .joined(separator: "\n")
            let answerHTML = uniteQuestionAndAnswerWithDefaultSeparator(
                questionHTML: "{{#QuestionContent}}",
                answerHTML: answerLines
            )

            try db.execute(
                sql: """
                    INSERT INTO query_type (type_id, name, question_html, answer_html)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [typeID, name, questionHTML, answerHTML]
            )

            return QueryType(
                id: db.lastInsertedRowID,
                typeID: typeID,
                name: name,
                questionHTML: questionHTML,
                answerHTML: answerHTML
            )
        }
    }

    /// Creates a new (non-link) query type that copies the source query type's
    /// question/answer HTML verbatim, under the same type.
    func duplicateQueryType(sourceQueryTypeID: Int64, name: String) throws -> QueryType {
        try dbQueue.write { db in
            guard let source = try QueryType.fetchOne(
                db,
                sql: """
                    SELECT
                        id,
                        type_id AS typeID,
                        name,
                        question_html AS questionHTML,
                        answer_html AS answerHTML
                    FROM query_type
                    WHERE id = ?
                    """,
                arguments: [sourceQueryTypeID]
            ) else {
                throw DatabaseError(message: "Source query type not found.")
            }

            try db.execute(
                sql: """
                    INSERT INTO query_type (type_id, name, question_html, answer_html)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [source.typeID, name, source.questionHTML, source.answerHTML]
            )

            return QueryType(
                id: db.lastInsertedRowID,
                typeID: source.typeID,
                name: name,
                questionHTML: source.questionHTML,
                answerHTML: source.answerHTML
            )
        }
    }

    func deleteType(typeID: Int64) throws {
        try dbQueue.write { db in
            let isBuiltin = try Bool.fetchOne(
                db,
                sql: "SELECT COALESCE(is_builtin, 0) FROM \"type\" WHERE id = ?",
                arguments: [typeID]
            ) ?? false
            if isBuiltin {
                throw DatabaseError(message: "Built-in types cannot be deleted.")
            }
            try db.execute(
                sql: """
                    DELETE FROM query_type
                    WHERE type_id = ?
                    """,
                arguments: [typeID]
            )

            try db.execute(
                sql: """
                    DELETE FROM instance_id_type_id
                    WHERE type_id = ?
                    """,
                arguments: [typeID]
            )

            try db.execute(
                sql: """
                    DELETE FROM field
                    WHERE type_id = ?
                    """,
                arguments: [typeID]
            )

            try db.execute(
                sql: """
                    DROP TABLE IF EXISTS "type\(typeID)"
                    """
            )

            try db.execute(
                sql: """
                    DELETE FROM "type"
                    WHERE id = ?
                    """,
                arguments: [typeID]
            )
        }
    }

    func makeInstance(
        forTypeID typeID: Int64,
        fieldValuesByFieldID: [Int64: String],
        queryTypeIDs: Set<Int64>
    ) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO instance_id_type_id (type_id)
                    VALUES (?)
                    """,
                arguments: [typeID]
            )
            let instanceID = db.lastInsertedRowID

            let fields = try TypeField.fetchAll(
                db,
                sql: """
                    SELECT
                        id,
                        type_id AS typeID,
                        name,
                        field_index AS fieldIndex,
                        field_display_index AS fieldDisplayIndex,
                        field_type AS fieldType
                    FROM field
                    WHERE type_id = ?
                    ORDER BY field_index, id
                    """,
                arguments: [typeID]
            )

            let fieldColumnNames = fields.map { field in
                "field\(field.fieldIndex)"
            }
            let allColumnNames = ["id"] + fieldColumnNames
            let placeholders = Array(repeating: "?", count: allColumnNames.count).joined(separator: ", ")
            let tableName = "\"type\(typeID)\""
            let insertSQL = """
                INSERT INTO \(tableName) (\(allColumnNames.joined(separator: ", ")))
                VALUES (\(placeholders))
                """

            var arguments: [DatabaseValue] = []
            arguments.append(instanceID.databaseValue)
            arguments.append(contentsOf: fields.map { field in
                Self.normalizedFieldValue(fieldValuesByFieldID[field.id] ?? "", kind: field.fieldType).databaseValue
            })
            try db.execute(sql: insertSQL, arguments: StatementArguments(arguments)!)

            for queryTypeID in queryTypeIDs.sorted() {
                try db.execute(
                    sql: """
                        INSERT INTO query (instance_id, query_type_id)
                        VALUES (?, ?)
                        """,
                    arguments: [instanceID, queryTypeID]
                )
            }

            return instanceID
        }
    }

    func setMaxInterval(forInstanceID instanceID: Int64, maxInterval: Int64?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE query SET max_interval = ? WHERE instance_id = ?",
                arguments: [maxInterval, instanceID]
            )
        }
    }

    func updateInstance(
        instanceID: Int64,
        fieldValuesByFieldID: [Int64: String],
        queryTypeIDs: Set<Int64>
    ) throws {
        try dbQueue.write { db in
            guard let typeID = try Int64.fetchOne(
                db,
                sql: """
                    SELECT type_id
                    FROM instance_id_type_id
                    WHERE instance_id = ?
                    """,
                arguments: [instanceID]
            ) else {
                throw DatabaseError(message: "Instance not found.")
            }

            let fields = try TypeField.fetchAll(
                db,
                sql: """
                    SELECT
                        id,
                        type_id AS typeID,
                        name,
                        field_index AS fieldIndex,
                        field_display_index AS fieldDisplayIndex,
                        field_type AS fieldType
                    FROM field
                    WHERE type_id = ?
                    ORDER BY field_index, id
                    """,
                arguments: [typeID]
            )

            let assignments = fields.map { field in
                "\"field\(field.fieldIndex)\" = ?"
            }.joined(separator: ", ")
            let arguments = StatementArguments(
                fields.map { field in
                    Self.normalizedFieldValue(fieldValuesByFieldID[field.id] ?? "", kind: field.fieldType)
                } + [String(instanceID)]
            )
            try db.execute(
                sql: """
                    UPDATE "type\(typeID)"
                    SET \(assignments)
                    WHERE id = ?
                    """,
                arguments: arguments
            )

            let existingQueryTypeIDs = Set(try Int64.fetchAll(
                db,
                sql: """
                    SELECT query.query_type_id
                    FROM query
                    JOIN query_type
                        ON query_type.id = query.query_type_id
                    WHERE query.instance_id = ? AND query_type.type_id = ?
                    ORDER BY query.query_type_id
                    """,
                arguments: [instanceID, typeID]
            ))

            let queryTypeIDsToAdd = queryTypeIDs.subtracting(existingQueryTypeIDs)
            let queryTypeIDsToRemove = existingQueryTypeIDs.subtracting(queryTypeIDs)

            for queryTypeID in queryTypeIDsToAdd.sorted() {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO query (instance_id, query_type_id)
                        VALUES (?, ?)
                        """,
                    arguments: [instanceID, queryTypeID]
                )
            }

            for queryTypeID in queryTypeIDsToRemove.sorted() {
                try db.execute(
                    sql: """
                        DELETE FROM query
                        WHERE instance_id = ? AND query_type_id = ?
                        """,
                    arguments: [instanceID, queryTypeID]
                )
            }

        }
    }

    // MARK: - Change Type

    /// For a set of instances, returns how many of them have each query type enabled
    /// (i.e. have a `query` row for it). Used to drive the tri-state source query-type
    /// checkboxes in the Change Type window.
    func fetchQueryTypeEnableCounts(instanceIDs: [Int64]) throws -> [Int64: Int] {
        guard !instanceIDs.isEmpty else { return [:] }
        return try dbQueue.read { db in
            let placeholders = Array(repeating: "?", count: instanceIDs.count).joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT query_type_id AS queryTypeID, COUNT(*) AS cnt
                    FROM query
                    WHERE instance_id IN (\(placeholders))
                    GROUP BY query_type_id
                    """,
                arguments: StatementArguments(instanceIDs.map { $0.databaseValue })
            )
            var result: [Int64: Int] = [:]
            for row in rows {
                result[row["queryTypeID"] as Int64] = Int(row["cnt"] as Int64)
            }
            return result
        }
    }

    /// Converts every instance in `instanceIDs` (all currently of `sourceTypeID`) to
    /// `destTypeID`, preserving each instance's ID. Field values are migrated according to
    /// `fieldMapping` (destFieldID -> sourceFieldID?, nil = leave blank). The converted
    /// instances get exactly `enabledDestQueryTypeIDs` enabled (SRS state reset), except
    /// that a destination query type appearing in `queryDataSources`
    /// (destQueryTypeID -> sourceQueryTypeID) copies the instance's SRS data
    /// (`query_state`, `last_answered_timestamp`, `interval`, `max_interval`) from its
    /// query for the named source query type — instances without that source query
    /// enabled still get a clean new query. When `removeFromCollections` is true the
    /// instances are removed from all collections.
    ///
    /// Supports Object->Object and Object->Person conversions only.
    func changeInstanceType(
        instanceIDs: [Int64],
        sourceTypeID: Int64,
        destTypeID: Int64,
        fieldMapping: [Int64: Int64?],
        enabledDestQueryTypeIDs: Set<Int64>,
        queryDataSources: [Int64: Int64],
        removeFromCollections: Bool
    ) throws {
        guard sourceTypeID != destTypeID else {
            throw DatabaseError(message: "Source and destination types must differ.")
        }
        guard !instanceIDs.isEmpty else { return }

        try dbQueue.write { db in
            if let personTypeID = try? Self.fetchPersonTypeID(db: db) {
                if sourceTypeID == personTypeID {
                    throw DatabaseError(message: "Person instances cannot be converted to another type.")
                }
                if destTypeID == personTypeID {
                    let sexFieldIDs = try Int64.fetchAll(
                        db,
                        sql: "SELECT id FROM field WHERE type_id = ? AND field_type = 'sex'",
                        arguments: [personTypeID]
                    )
                    for sexFieldID in sexFieldIDs where fieldMapping[sexFieldID] != nil {
                        throw DatabaseError(message: "The Sex field cannot be mapped during conversion; converted people start as Male.")
                    }
                }
            }
            func fetchFields(_ typeID: Int64) throws -> [TypeField] {
                try TypeField.fetchAll(
                    db,
                    sql: """
                        SELECT
                            id,
                            type_id AS typeID,
                            name,
                            field_index AS fieldIndex,
                            field_display_index AS fieldDisplayIndex,
                            COALESCE(is_primary, 0) AS isPrimary,
                            field_type AS fieldType
                        FROM field
                        WHERE type_id = ?
                        ORDER BY field_index, id
                        """,
                    arguments: [typeID]
                )
            }

            let sourceFields = try fetchFields(sourceTypeID)
            let destFields = try fetchFields(destTypeID)
            let sourceFieldByID = Dictionary(uniqueKeysWithValues: sourceFields.map { ($0.id, $0) })

            // Validate the mapping references real fields.
            for (destFieldID, sourceFieldID) in fieldMapping {
                guard destFields.contains(where: { $0.id == destFieldID }) else {
                    throw DatabaseError(message: "Unknown destination field in mapping.")
                }
                if let sourceFieldID, sourceFieldByID[sourceFieldID] == nil {
                    throw DatabaseError(message: "Unknown source field in mapping.")
                }
            }
            // Validate the chosen query types belong to the destination type.
            let validDestQueryTypeIDs = try Set(Int64.fetchAll(
                db,
                sql: "SELECT id FROM query_type WHERE type_id = ?",
                arguments: [destTypeID]
            ))
            for queryTypeID in enabledDestQueryTypeIDs where !validDestQueryTypeIDs.contains(queryTypeID) {
                throw DatabaseError(message: "Query type does not belong to the destination type.")
            }
            // Validate the copy-data mapping: dest keys and source values must each
            // belong to their respective types.
            let sourceQueryTypeIDs = try Set(Int64.fetchAll(
                db,
                sql: "SELECT id FROM query_type WHERE type_id = ?",
                arguments: [sourceTypeID]
            ))
            for (destQueryTypeID, sourceQueryTypeID) in queryDataSources {
                guard validDestQueryTypeIDs.contains(destQueryTypeID) else {
                    throw DatabaseError(message: "Copy-data destination query type does not belong to the destination type.")
                }
                guard sourceQueryTypeIDs.contains(sourceQueryTypeID) else {
                    throw DatabaseError(message: "Copy-data source query type does not belong to the source type.")
                }
            }

            let destColumnNames = ["id"] + destFields.map { "field\($0.fieldIndex)" }
            let destPlaceholders = Array(repeating: "?", count: destColumnNames.count).joined(separator: ", ")
            let destInsertSQL = """
                INSERT INTO "type\(destTypeID)" (\(destColumnNames.joined(separator: ", ")))
                VALUES (\(destPlaceholders))
                """

            let sourceSelectColumns = sourceFields.map { field in
                "\"field\(field.fieldIndex)\" AS \"field_\(field.id)\""
            }.joined(separator: ", ")

            for instanceID in instanceIDs {
                // Confirm the instance exists and is currently of the source type.
                guard let currentTypeID = try Int64.fetchOne(
                    db,
                    sql: "SELECT type_id FROM instance_id_type_id WHERE instance_id = ?",
                    arguments: [instanceID]
                ) else {
                    throw DatabaseError(message: "Instance \(instanceID) not found.")
                }
                guard currentTypeID == sourceTypeID else {
                    throw DatabaseError(message: "Instance \(instanceID) is not of the expected source type.")
                }

                // 1. Read source field values keyed by source field id.
                var sourceValuesByFieldID: [Int64: String] = [:]
                if !sourceFields.isEmpty {
                    let row = try Row.fetchOne(
                        db,
                        sql: """
                            SELECT \(sourceSelectColumns)
                            FROM "type\(sourceTypeID)"
                            WHERE id = ?
                            """,
                        arguments: [instanceID]
                    )
                    for field in sourceFields {
                        sourceValuesByFieldID[field.id] = row?["field_\(field.id)"] as String? ?? ""
                    }
                }

                // 2. Compute destination values via the mapping.
                var insertArguments: [DatabaseValue] = [instanceID.databaseValue]
                for field in destFields {
                    let mappedSourceID = fieldMapping[field.id] ?? nil
                    let rawValue = mappedSourceID.flatMap { sourceValuesByFieldID[$0] } ?? ""
                    insertArguments.append(Self.normalizedFieldValue(rawValue, kind: field.fieldType).databaseValue)
                }

                // 3. Repoint the instance to the destination type.
                try db.execute(
                    sql: "UPDATE instance_id_type_id SET type_id = ? WHERE instance_id = ?",
                    arguments: [destTypeID, instanceID]
                )

                // 4. Insert the destination row (same instance id preserved).
                try db.execute(sql: destInsertSQL, arguments: StatementArguments(insertArguments)!)

                // 5. Remove the old source-type row.
                try db.execute(
                    sql: "DELETE FROM \"type\(sourceTypeID)\" WHERE id = ?",
                    arguments: [instanceID]
                )

                // 6. Reset queries to exactly the selected destination query types,
                //    copying SRS data where a "Copy Data From" source query exists on
                //    this instance (read before the delete wipes it).
                var copiedSRSByDestQueryTypeID: [Int64: Row] = [:]
                for queryTypeID in enabledDestQueryTypeIDs {
                    guard let sourceQueryTypeID = queryDataSources[queryTypeID] else { continue }
                    if let srsRow = try Row.fetchOne(
                        db,
                        sql: """
                            SELECT query_state, last_answered_timestamp, interval, max_interval
                            FROM query
                            WHERE instance_id = ? AND query_type_id = ?
                            """,
                        arguments: [instanceID, sourceQueryTypeID]
                    ) {
                        copiedSRSByDestQueryTypeID[queryTypeID] = srsRow
                    }
                }
                try db.execute(
                    sql: "DELETE FROM query WHERE instance_id = ?",
                    arguments: [instanceID]
                )
                for queryTypeID in enabledDestQueryTypeIDs.sorted() {
                    if let srsRow = copiedSRSByDestQueryTypeID[queryTypeID] {
                        try db.execute(
                            sql: """
                                INSERT INTO query
                                    (instance_id, query_type_id, query_state, last_answered_timestamp, interval, max_interval)
                                VALUES (?, ?, ?, ?, ?, ?)
                                """,
                            arguments: [
                                instanceID,
                                queryTypeID,
                                srsRow["query_state"] as Int64,
                                srsRow["last_answered_timestamp"] as Int64?,
                                srsRow["interval"] as Int64,
                                srsRow["max_interval"] as Int64?,
                            ]
                        )
                    } else {
                        try db.execute(
                            sql: "INSERT INTO query (instance_id, query_type_id) VALUES (?, ?)",
                            arguments: [instanceID, queryTypeID]
                        )
                    }
                }

                // 7. Optionally drop collection memberships.
                if removeFromCollections {
                    try db.execute(
                        sql: "DELETE FROM instance_id_collection_id WHERE instance_id = ?",
                        arguments: [instanceID]
                    )
                }
            }
        }
    }

    // MARK: - PointMap

    struct PointMapPointDraft: Hashable {
        var name: String
        var latitude: Double
        var longitude: Double
        var forwardEnabled: Bool = true
        var reverseEnabled: Bool = false
        var hint: String = ""
    }

    struct BoundaryMapBoundaryDraft: Hashable {
        var boundaryID: Int64
        var forwardEnabled: Bool = true
        var reverseEnabled: Bool = false
    }

    func fetchPointMapTypeID() throws -> Int64 {
        try dbQueue.read { db in
            try Self.fetchPointMapTypeID(db: db)
        }
    }

    private static func fetchPointMapTypeID(db: Database) throws -> Int64 {
        guard let typeID = try Int64.fetchOne(
            db,
            sql: """
                SELECT id FROM "type" WHERE name = ? AND is_builtin = 1
                """,
            arguments: [POINTMAP_TYPE_NAME]
        ) else {
            throw DatabaseError(message: "PointMap type is missing.")
        }
        return typeID
    }

    func makePointMapInstance(
        title: String,
        description: String,
        defaultCenterLat: Double,
        defaultCenterLng: Double,
        defaultZoom: Double,
        showAllPointsInQuestion: Bool,
        pointSize: PointMapPointSize,
        points: [PointMapPointDraft],
        boundaryIDs: [Int64]
    ) throws -> Int64 {
        try dbQueue.write { db in
            let pointMapTypeID = try Self.fetchPointMapTypeID(db: db)

            try db.execute(
                sql: """
                    INSERT INTO instance_id_type_id (type_id)
                    VALUES (?)
                    """,
                arguments: [pointMapTypeID]
            )
            let instanceID = db.lastInsertedRowID

            try db.execute(
                sql: """
                    INSERT INTO pointmap_instance (instance_id, title, description, default_center_lat, default_center_lng, default_zoom, show_all_points_in_question, point_size)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [instanceID, title, description, defaultCenterLat, defaultCenterLng, defaultZoom, showAllPointsInQuestion ? 1 : 0, pointSize.rawValue]
            )

            for point in points {
                try db.execute(
                    sql: """
                        INSERT INTO pointmap_point (instance_id, name, hint, latitude, longitude)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [instanceID, point.name, point.hint, point.latitude, point.longitude]
                )
                let pointID = db.lastInsertedRowID
                try Self.setMapQueryEnabled(db: db, table: "pointmap_query", parentColumn: "point_id", parentID: pointID, isReverse: false, enabled: point.forwardEnabled)
                try Self.setMapQueryEnabled(db: db, table: "pointmap_query", parentColumn: "point_id", parentID: pointID, isReverse: true, enabled: point.reverseEnabled)
            }

            try Self.setBoundaries(db: db, instanceID: instanceID, boundaryIDs: boundaryIDs)

            return instanceID
        }
    }

    // Adds a single point (query) to an existing PointMap instance. Returns the
    // new point's id. Throws if `instanceID` is not a PointMap instance.
    func addPointMapPoint(
        instanceID: Int64,
        name: String,
        latitude: Double,
        longitude: Double,
        forwardEnabled: Bool,
        reverseEnabled: Bool,
        hint: String = ""
    ) throws -> Int64 {
        try dbQueue.write { db in
            let isPointMapInstance = try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM pointmap_instance WHERE instance_id = ?",
                arguments: [instanceID]
            ) != nil
            guard isPointMapInstance else {
                throw DatabaseError(message: "No PointMap instance with id \(instanceID).")
            }

            try db.execute(
                sql: """
                    INSERT INTO pointmap_point (instance_id, name, hint, latitude, longitude)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [instanceID, name, hint, latitude, longitude]
            )
            let pointID = db.lastInsertedRowID
            try Self.setMapQueryEnabled(db: db, table: "pointmap_query", parentColumn: "point_id", parentID: pointID, isReverse: false, enabled: forwardEnabled)
            try Self.setMapQueryEnabled(db: db, table: "pointmap_query", parentColumn: "point_id", parentID: pointID, isReverse: true, enabled: reverseEnabled)
            return pointID
        }
    }

    func updatePointMapInstance(
        instanceID: Int64,
        title: String,
        description: String,
        defaultCenterLat: Double,
        defaultCenterLng: Double,
        defaultZoom: Double,
        showAllPointsInQuestion: Bool,
        pointSize: PointMapPointSize,
        existingPoints: [PointMapPoint],
        newPoints: [PointMapPointDraft],
        boundaryIDs: [Int64]
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE pointmap_instance
                    SET title = ?,
                        description = ?,
                        default_center_lat = ?,
                        default_center_lng = ?,
                        default_zoom = ?,
                        show_all_points_in_question = ?,
                        point_size = ?
                    WHERE instance_id = ?
                    """,
                arguments: [title, description, defaultCenterLat, defaultCenterLng, defaultZoom, showAllPointsInQuestion ? 1 : 0, pointSize.rawValue, instanceID]
            )

            let existingIDs = Set(existingPoints.map(\.id))
            let currentIDs = try Set(Int64.fetchAll(
                db,
                sql: "SELECT id FROM pointmap_point WHERE instance_id = ?",
                arguments: [instanceID]
            ))

            // Delete removed points
            let removedIDs = currentIDs.subtracting(existingIDs)
            for removedID in removedIDs {
                try db.execute(
                    sql: "DELETE FROM pointmap_point WHERE id = ?",
                    arguments: [removedID]
                )
            }

            // Update existing points (name/lat/lng may have changed in the editor),
            // then reconcile their queries: enabling a direction inserts its query
            // row, disabling deletes it (discarding that direction's SRS progress);
            // a direction left enabled keeps its progress.
            for point in existingPoints {
                try db.execute(
                    sql: """
                        UPDATE pointmap_point
                        SET name = ?, hint = ?, latitude = ?, longitude = ?
                        WHERE id = ?
                        """,
                    arguments: [point.name, point.hint, point.latitude, point.longitude, point.id]
                )
                try Self.setMapQueryEnabled(db: db, table: "pointmap_query", parentColumn: "point_id", parentID: point.id, isReverse: false, enabled: point.forwardEnabled)
                try Self.setMapQueryEnabled(db: db, table: "pointmap_query", parentColumn: "point_id", parentID: point.id, isReverse: true, enabled: point.reverseEnabled)
            }

            // Insert brand-new points
            for point in newPoints {
                try db.execute(
                    sql: """
                        INSERT INTO pointmap_point (instance_id, name, hint, latitude, longitude)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [instanceID, point.name, point.hint, point.latitude, point.longitude]
                )
                let pointID = db.lastInsertedRowID
                try Self.setMapQueryEnabled(db: db, table: "pointmap_query", parentColumn: "point_id", parentID: pointID, isReverse: false, enabled: point.forwardEnabled)
                try Self.setMapQueryEnabled(db: db, table: "pointmap_query", parentColumn: "point_id", parentID: pointID, isReverse: true, enabled: point.reverseEnabled)
            }

            try Self.setBoundaries(db: db, instanceID: instanceID, boundaryIDs: boundaryIDs)
        }
    }

    func fetchPointMapInstance(instanceID: Int64) throws -> PointMapInstanceWithPoints? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT title, description, default_center_lat, default_center_lng, default_zoom, show_all_points_in_question, point_size
                    FROM pointmap_instance
                    WHERE instance_id = ?
                    """,
                arguments: [instanceID]
            ) else {
                return nil
            }

            let instance = PointMapInstance(
                instanceID: instanceID,
                title: row["title"] as String? ?? "",
                description: row["description"] as String? ?? "",
                defaultCenterLat: row["default_center_lat"] as Double? ?? 0,
                defaultCenterLng: row["default_center_lng"] as Double? ?? 0,
                defaultZoom: row["default_zoom"] as Double? ?? 2,
                showAllPointsInQuestion: ((row["show_all_points_in_question"] as Int64?) ?? 1) != 0,
                pointSize: PointMapPointSize(rawValue: row["point_size"] as String? ?? "medium") ?? .medium
            )

            let pointRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT p.id AS id, p.name AS name, p.hint AS hint, p.latitude AS latitude, p.longitude AS longitude,
                           (qf.id IS NOT NULL) AS forward_enabled, (qr.id IS NOT NULL) AS reverse_enabled,
                           COALESCE(qf.interval, 0) AS interval, COALESCE(qr.interval, 0) AS reverse_interval
                    FROM pointmap_point AS p
                    LEFT JOIN pointmap_query AS qf ON qf.point_id = p.id AND qf.is_reverse = 0
                    LEFT JOIN pointmap_query AS qr ON qr.point_id = p.id AND qr.is_reverse = 1
                    WHERE p.instance_id = ?
                    ORDER BY p.id
                    """,
                arguments: [instanceID]
            )
            let points = pointRows.map { row in
                PointMapPoint(
                    id: row["id"] as Int64? ?? 0,
                    instanceID: instanceID,
                    name: row["name"] as String? ?? "",
                    latitude: row["latitude"] as Double? ?? 0,
                    longitude: row["longitude"] as Double? ?? 0,
                    forwardEnabled: ((row["forward_enabled"] as Int64?) ?? 1) != 0,
                    reverseEnabled: ((row["reverse_enabled"] as Int64?) ?? 0) != 0,
                    forwardInterval: (row["interval"] as Int64?) ?? 0,
                    reverseInterval: (row["reverse_interval"] as Int64?) ?? 0,
                    hint: row["hint"] as String? ?? ""
                )
            }

            let boundaryIDs = try Self.fetchBoundaryIDs(db: db, instanceID: instanceID)

            return PointMapInstanceWithPoints(
                instance: instance,
                points: points,
                boundaryIDs: boundaryIDs
            )
        }
    }

    func fetchPointMapInstanceTitle(instanceID: Int64) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT title FROM pointmap_instance WHERE instance_id = ?",
                arguments: [instanceID]
            )
        }
    }

    // Every PointMap instance (id + title), for the editor's move-points picker.
    func fetchPointMapInstanceList() throws -> [PointMapInstanceListItem] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT instance_id, title
                    FROM pointmap_instance
                    ORDER BY title COLLATE NOCASE, instance_id
                    """
            ).map { row in
                PointMapInstanceListItem(
                    id: row["instance_id"] as Int64? ?? 0,
                    title: row["title"] as String? ?? ""
                )
            }
        }
    }

    // Moves points to another PointMap instance. Existing points are re-parented
    // in place — their pointmap_query rows follow via point_id, so per-query SRS
    // state (interval, last_answered_timestamp, query_state) is preserved — with
    // the caller's drafted name/hint/coordinates and enabled directions applied,
    // exactly what saving the source editor would have written. New (unsaved)
    // draft points are inserted directly into the target. One transaction;
    // throws if the target isn't a PointMap instance.
    func movePointMapPoints(
        existingPoints: [PointMapPoint],
        newPoints: [PointMapPointDraft],
        toInstanceID: Int64
    ) throws {
        guard !existingPoints.isEmpty || !newPoints.isEmpty else { return }
        try dbQueue.write { db in
            let isPointMapInstance = try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM pointmap_instance WHERE instance_id = ?",
                arguments: [toInstanceID]
            ) != nil
            guard isPointMapInstance else {
                throw DatabaseError(message: "No PointMap instance with id \(toInstanceID).")
            }

            for point in existingPoints {
                try db.execute(
                    sql: """
                        UPDATE pointmap_point
                        SET instance_id = ?, name = ?, hint = ?, latitude = ?, longitude = ?
                        WHERE id = ?
                        """,
                    arguments: [toInstanceID, point.name, point.hint, point.latitude, point.longitude, point.id]
                )
                try Self.setMapQueryEnabled(db: db, table: "pointmap_query", parentColumn: "point_id", parentID: point.id, isReverse: false, enabled: point.forwardEnabled)
                try Self.setMapQueryEnabled(db: db, table: "pointmap_query", parentColumn: "point_id", parentID: point.id, isReverse: true, enabled: point.reverseEnabled)
            }

            for point in newPoints {
                try db.execute(
                    sql: """
                        INSERT INTO pointmap_point (instance_id, name, hint, latitude, longitude)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [toInstanceID, point.name, point.hint, point.latitude, point.longitude]
                )
                let pointID = db.lastInsertedRowID
                try Self.setMapQueryEnabled(db: db, table: "pointmap_query", parentColumn: "point_id", parentID: pointID, isReverse: false, enabled: point.forwardEnabled)
                try Self.setMapQueryEnabled(db: db, table: "pointmap_query", parentColumn: "point_id", parentID: pointID, isReverse: true, enabled: point.reverseEnabled)
            }
        }
    }

    // A map query's existence == that direction being enabled. Enabling inserts the
    // (parent, direction) row if missing (OR IGNORE preserves progress on a row that
    // already exists); disabling deletes it, discarding that direction's SRS
    // progress. Table/column names are code constants, safe to interpolate.
    static func setMapQueryEnabled(
        db: Database,
        table: String,
        parentColumn: String,
        parentID: Int64,
        isReverse: Bool,
        enabled: Bool
    ) throws {
        if enabled {
            try db.execute(
                sql: "INSERT OR IGNORE INTO \(table) (\(parentColumn), is_reverse) VALUES (?, ?)",
                arguments: [parentID, isReverse ? 1 : 0]
            )
        } else {
            try db.execute(
                sql: "DELETE FROM \(table) WHERE \(parentColumn) = ? AND is_reverse = ?",
                arguments: [parentID, isReverse ? 1 : 0]
            )
        }
    }

    @discardableResult
    func applyPointMapStudyResponse(
        pointID: Int64,
        rating: StudyResponseRating,
        answeredAtTimestamp: Int64,
        overrideInterval: Int64? = nil,
        isReverse: Bool = false
    ) throws -> StudyResponseOutcome {
        let direction = isReverse ? 1 : 0
        return try dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT interval, query_state FROM pointmap_query WHERE point_id = ? AND is_reverse = ?",
                arguments: [pointID, direction]
            ) else {
                throw DatabaseError(message: "PointMap query not found.")
            }

            let currentInterval = row["interval"] as Int64? ?? 0
            let currentState = QueryState(rawValue: row["query_state"] as Int? ?? 0) ?? .zero
            let outcome = studyResponseOutcome(
                currentState: currentState,
                currentInterval: currentInterval,
                rating: rating
            )
            let updatedInterval = overrideInterval ?? outcome.newInterval

            try db.execute(
                sql: """
                    UPDATE pointmap_query
                    SET query_state = ?, last_answered_timestamp = ?, interval = ?
                    WHERE point_id = ? AND is_reverse = ?
                    """,
                arguments: [outcome.newState.rawValue, answeredAtTimestamp, updatedInterval, pointID, direction]
            )
            return StudyResponseOutcome(newState: outcome.newState, newInterval: updatedInterval)
        }
    }

    func revertPointMapStudyResponse(
        pointID: Int64,
        originalInterval: Int64,
        originalLastAnsweredTimestamp: Int64?,
        originalQueryState: QueryState,
        isReverse: Bool = false
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE pointmap_query
                    SET query_state = ?, last_answered_timestamp = ?, interval = ?
                    WHERE point_id = ? AND is_reverse = ?
                    """,
                arguments: [
                    originalQueryState.rawValue,
                    originalLastAnsweredTimestamp,
                    originalInterval,
                    pointID,
                    isReverse ? 1 : 0
                ]
            )
        }
    }

    func resetPointMapPointDueDates(pointIDs: [Int64]) throws {
        guard !pointIDs.isEmpty else { return }
        try dbQueue.write { db in
            for pointID in pointIDs {
                try db.execute(
                    sql: """
                        UPDATE pointmap_query
                        SET query_state = 0,
                            last_answered_timestamp = NULL,
                            interval = 0
                        WHERE point_id = ?
                        """,
                    arguments: [pointID]
                )
            }
        }
    }

    // Resets one direction's SRS state across many points at once and returns the
    // number of query rows actually reset. A pointmap_query row exists only for an
    // enabled direction, so the count reflects how many of the selected points have
    // that direction enabled. Used by the points list's "Reset Queries" submenu.
    @discardableResult
    func resetPointMapPointDueDates(pointIDs: [Int64], isReverse: Bool) throws -> Int {
        guard !pointIDs.isEmpty else { return 0 }
        return try dbQueue.write { db in
            let placeholders = pointIDs.map { _ in "?" }.joined(separator: ", ")
            var arguments: [DatabaseValueConvertible] = [isReverse ? 1 : 0]
            arguments.append(contentsOf: pointIDs)
            try db.execute(
                sql: """
                    UPDATE pointmap_query
                    SET query_state = 0,
                        last_answered_timestamp = NULL,
                        interval = 0
                    WHERE is_reverse = ? AND point_id IN (\(placeholders))
                    """,
                arguments: StatementArguments(arguments)
            )
            return try Int.fetchOne(db, sql: "SELECT changes()") ?? 0
        }
    }

    // Resets just one direction's SRS state for a single point (used by the point
    // edit popup's per-query reset buttons).
    func resetPointMapPointDueDate(pointID: Int64, isReverse: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE pointmap_query
                    SET query_state = 0,
                        last_answered_timestamp = NULL,
                        interval = 0
                    WHERE point_id = ? AND is_reverse = ?
                    """,
                arguments: [pointID, isReverse ? 1 : 0]
            )
        }
    }

    // MARK: - BoundaryMap

    func fetchBoundaryMapTypeID() throws -> Int64 {
        try dbQueue.read { db in
            try Self.fetchBoundaryMapTypeID(db: db)
        }
    }

    private static func fetchBoundaryMapTypeID(db: Database) throws -> Int64 {
        guard let typeID = try Int64.fetchOne(
            db,
            sql: """
                SELECT id FROM "type" WHERE name = ? AND is_builtin = 1
                """,
            arguments: [BOUNDARYMAP_TYPE_NAME]
        ) else {
            throw DatabaseError(message: "BoundaryMap type is missing.")
        }
        return typeID
    }

    // Resets one direction's SRS state across many attachments at once and
    // returns the number of query rows actually reset (a boundarymap_query row
    // exists only for an enabled direction). Mirrors
    // resetPointMapPointDueDates(pointIDs:isReverse:) for the boundaries
    // list's "Reset Queries" submenu.
    @discardableResult
    func resetBoundaryMapAttachmentDueDates(attachmentIDs: [Int64], isReverse: Bool) throws -> Int {
        guard !attachmentIDs.isEmpty else { return 0 }
        return try dbQueue.write { db in
            let placeholders = attachmentIDs.map { _ in "?" }.joined(separator: ", ")
            var arguments: [DatabaseValueConvertible] = [isReverse ? 1 : 0]
            arguments.append(contentsOf: attachmentIDs)
            try db.execute(
                sql: """
                    UPDATE boundarymap_query
                    SET query_state = 0,
                        last_answered_timestamp = NULL,
                        interval = 0
                    WHERE is_reverse = ? AND attachment_id IN (\(placeholders))
                    """,
                arguments: StatementArguments(arguments)
            )
            return try Int.fetchOne(db, sql: "SELECT changes()") ?? 0
        }
    }

    func makeBoundaryMapInstance(
        title: String,
        description: String,
        defaultCenterLat: Double,
        defaultCenterLng: Double,
        defaultZoom: Double,
        showAllBoundariesInQuestion: Bool,
        boundaries: [BoundaryMapBoundaryDraft]
    ) throws -> Int64 {
        try dbQueue.write { db in
            let boundaryMapTypeID = try Self.fetchBoundaryMapTypeID(db: db)

            try db.execute(
                sql: """
                    INSERT INTO instance_id_type_id (type_id)
                    VALUES (?)
                    """,
                arguments: [boundaryMapTypeID]
            )
            let instanceID = db.lastInsertedRowID

            try db.execute(
                sql: """
                    INSERT INTO boundarymap_instance (instance_id, title, description, default_center_lat, default_center_lng, default_zoom, show_all_boundaries_in_question)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [instanceID, title, description, defaultCenterLat, defaultCenterLng, defaultZoom, showAllBoundariesInQuestion ? 1 : 0]
            )

            for boundary in boundaries {
                try db.execute(
                    sql: """
                        INSERT INTO boundarymap_attachment (instance_id, boundary_id)
                        VALUES (?, ?)
                        """,
                    arguments: [instanceID, boundary.boundaryID]
                )
                let attachmentID = db.lastInsertedRowID
                try Self.setMapQueryEnabled(db: db, table: "boundarymap_query", parentColumn: "attachment_id", parentID: attachmentID, isReverse: false, enabled: boundary.forwardEnabled)
                try Self.setMapQueryEnabled(db: db, table: "boundarymap_query", parentColumn: "attachment_id", parentID: attachmentID, isReverse: true, enabled: boundary.reverseEnabled)
            }

            return instanceID
        }
    }

    func updateBoundaryMapInstance(
        instanceID: Int64,
        title: String,
        description: String,
        defaultCenterLat: Double,
        defaultCenterLng: Double,
        defaultZoom: Double,
        showAllBoundariesInQuestion: Bool,
        existingAttachments: [BoundaryMapAttachedBoundary],
        newBoundaries: [BoundaryMapBoundaryDraft]
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE boundarymap_instance
                    SET title = ?,
                        description = ?,
                        default_center_lat = ?,
                        default_center_lng = ?,
                        default_zoom = ?,
                        show_all_boundaries_in_question = ?
                    WHERE instance_id = ?
                    """,
                arguments: [title, description, defaultCenterLat, defaultCenterLng, defaultZoom, showAllBoundariesInQuestion ? 1 : 0, instanceID]
            )

            let keepIDs = Set(existingAttachments.map(\.id))
            let currentIDs = try Set(Int64.fetchAll(
                db,
                sql: "SELECT id FROM boundarymap_attachment WHERE instance_id = ?",
                arguments: [instanceID]
            ))

            // Deleting an attachment cascades to its query rows.
            let removedIDs = currentIDs.subtracting(keepIDs)
            for removedID in removedIDs {
                try db.execute(
                    sql: "DELETE FROM boundarymap_attachment WHERE id = ?",
                    arguments: [removedID]
                )
            }

            // Reconcile kept attachments' queries: enabling a direction inserts its
            // query row, disabling deletes it (discarding that direction's progress);
            // a direction left enabled keeps its progress.
            for attachment in existingAttachments {
                try Self.setMapQueryEnabled(db: db, table: "boundarymap_query", parentColumn: "attachment_id", parentID: attachment.id, isReverse: false, enabled: attachment.forwardEnabled)
                try Self.setMapQueryEnabled(db: db, table: "boundarymap_query", parentColumn: "attachment_id", parentID: attachment.id, isReverse: true, enabled: attachment.reverseEnabled)
            }

            for boundary in newBoundaries {
                try db.execute(
                    sql: """
                        INSERT INTO boundarymap_attachment (instance_id, boundary_id)
                        VALUES (?, ?)
                        """,
                    arguments: [instanceID, boundary.boundaryID]
                )
                let attachmentID = db.lastInsertedRowID
                try Self.setMapQueryEnabled(db: db, table: "boundarymap_query", parentColumn: "attachment_id", parentID: attachmentID, isReverse: false, enabled: boundary.forwardEnabled)
                try Self.setMapQueryEnabled(db: db, table: "boundarymap_query", parentColumn: "attachment_id", parentID: attachmentID, isReverse: true, enabled: boundary.reverseEnabled)
            }
        }
    }

    func fetchBoundaryMapInstance(instanceID: Int64) throws -> BoundaryMapInstanceWithBoundaries? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT title, description, default_center_lat, default_center_lng, default_zoom, show_all_boundaries_in_question
                    FROM boundarymap_instance
                    WHERE instance_id = ?
                    """,
                arguments: [instanceID]
            ) else {
                return nil
            }

            let instance = BoundaryMapInstance(
                instanceID: instanceID,
                title: row["title"] as String? ?? "",
                description: row["description"] as String? ?? "",
                defaultCenterLat: row["default_center_lat"] as Double? ?? 0,
                defaultCenterLng: row["default_center_lng"] as Double? ?? 0,
                defaultZoom: row["default_zoom"] as Double? ?? 2,
                showAllBoundariesInQuestion: ((row["show_all_boundaries_in_question"] as Int64?) ?? 1) != 0
            )

            let attachmentRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT a.id AS id, a.boundary_id AS boundaryID, b.name AS name,
                           (qf.id IS NOT NULL) AS forwardEnabled, (qr.id IS NOT NULL) AS reverseEnabled
                    FROM boundarymap_attachment AS a
                    JOIN boundary AS b ON b.id = a.boundary_id
                    LEFT JOIN boundarymap_query AS qf ON qf.attachment_id = a.id AND qf.is_reverse = 0
                    LEFT JOIN boundarymap_query AS qr ON qr.attachment_id = a.id AND qr.is_reverse = 1
                    WHERE a.instance_id = ?
                    ORDER BY b.name COLLATE NOCASE, a.id
                    """,
                arguments: [instanceID]
            )
            let attachments = attachmentRows.map { row in
                BoundaryMapAttachedBoundary(
                    id: row["id"] as Int64? ?? 0,
                    instanceID: instanceID,
                    boundaryID: row["boundaryID"] as Int64? ?? 0,
                    name: row["name"] as String? ?? "",
                    forwardEnabled: ((row["forwardEnabled"] as Int64?) ?? 1) != 0,
                    reverseEnabled: ((row["reverseEnabled"] as Int64?) ?? 0) != 0
                )
            }

            return BoundaryMapInstanceWithBoundaries(
                instance: instance,
                attachments: attachments
            )
        }
    }

    func fetchBoundaryMapInstanceTitle(instanceID: Int64) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT title FROM boundarymap_instance WHERE instance_id = ?",
                arguments: [instanceID]
            )
        }
    }

    @discardableResult
    func applyBoundaryMapStudyResponse(
        attachmentID: Int64,
        rating: StudyResponseRating,
        answeredAtTimestamp: Int64,
        overrideInterval: Int64? = nil,
        isReverse: Bool = false
    ) throws -> StudyResponseOutcome {
        let direction = isReverse ? 1 : 0
        return try dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT interval, query_state FROM boundarymap_query WHERE attachment_id = ? AND is_reverse = ?",
                arguments: [attachmentID, direction]
            ) else {
                throw DatabaseError(message: "BoundaryMap query not found.")
            }

            let currentInterval = row["interval"] as Int64? ?? 0
            let currentState = QueryState(rawValue: row["query_state"] as Int? ?? 0) ?? .zero
            let outcome = studyResponseOutcome(
                currentState: currentState,
                currentInterval: currentInterval,
                rating: rating
            )
            let updatedInterval = overrideInterval ?? outcome.newInterval

            try db.execute(
                sql: """
                    UPDATE boundarymap_query
                    SET query_state = ?, last_answered_timestamp = ?, interval = ?
                    WHERE attachment_id = ? AND is_reverse = ?
                    """,
                arguments: [outcome.newState.rawValue, answeredAtTimestamp, updatedInterval, attachmentID, direction]
            )
            return StudyResponseOutcome(newState: outcome.newState, newInterval: updatedInterval)
        }
    }

    func revertBoundaryMapStudyResponse(
        attachmentID: Int64,
        originalInterval: Int64,
        originalLastAnsweredTimestamp: Int64?,
        originalQueryState: QueryState,
        isReverse: Bool = false
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE boundarymap_query
                    SET query_state = ?, last_answered_timestamp = ?, interval = ?
                    WHERE attachment_id = ? AND is_reverse = ?
                    """,
                arguments: [
                    originalQueryState.rawValue,
                    originalLastAnsweredTimestamp,
                    originalInterval,
                    attachmentID,
                    isReverse ? 1 : 0
                ]
            )
        }
    }

    func resetBoundaryMapDueDates(attachmentIDs: [Int64]) throws {
        guard !attachmentIDs.isEmpty else { return }
        try dbQueue.write { db in
            for attachmentID in attachmentIDs {
                try db.execute(
                    sql: """
                        UPDATE boundarymap_query
                        SET query_state = 0,
                            last_answered_timestamp = NULL,
                            interval = 0
                        WHERE attachment_id = ?
                        """,
                    arguments: [attachmentID]
                )
            }
        }
    }

    // Canonical on-disk value for a field. Text fields store their value verbatim;
    // boolean fields are stored as the strings "0"/"1", so any truthy input
    // ("1"/"true", case-insensitive) becomes "1" and everything else "0". This is
    // the single chokepoint for both the editor and MCP writes.
    static func normalizedFieldValue(_ value: String, kind: FieldKind) -> String {
        switch kind {
        case .text:
            return value
        case .boolean:
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return (v == "1" || v == "true") ? "1" : "0"
        case .sex:
            // Required with default Male: anything that isn't exactly "female"
            // (case-insensitive) normalizes to "Male", so the field is never empty.
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return v == "female" ? "Female" : "Male"
        }
    }

    func addField(toTypeID typeID: Int64, name: String, fieldType: FieldKind = .text) throws -> TypeField {
        try dbQueue.write { db in
            guard fieldType != .sex else {
                throw DatabaseError(message: "Sex fields are built into the Person type and cannot be created.")
            }
            let nextFieldIndex = (try Int.fetchOne(
                db,
                sql: """
                    SELECT MAX(field_index)
                    FROM field
                    WHERE type_id = ?
                    """,
                arguments: [typeID]
            ) ?? 0) + 1

            try db.execute(
                sql: """
                    INSERT INTO field (type_id, name, field_index, field_display_index, field_type)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [typeID, name, nextFieldIndex, nextFieldIndex, fieldType.rawValue]
            )
            let fieldID = db.lastInsertedRowID

            // Boolean fields are stored as the text "0"/"1" so the rest of the
            // value pipeline (read/write/search) treats them like any text column;
            // NOT NULL DEFAULT '0' backfills false into existing rows.
            let columnDefinition = fieldType == .boolean ? "TEXT NOT NULL DEFAULT '0'" : "TEXT DEFAULT ''"
            try db.execute(
                sql: """
                    ALTER TABLE "type\(typeID)"
                    ADD COLUMN "field\(nextFieldIndex)" \(columnDefinition)
                    """
            )

            return TypeField(
                id: fieldID,
                typeID: typeID,
                name: name,
                fieldIndex: nextFieldIndex,
                fieldDisplayIndex: nextFieldIndex,
                fieldType: fieldType
            )
        }
    }

    func deleteField(fieldID: Int64, fromTypeID typeID: Int64) throws {
        try dbQueue.write { db in
            guard let field = try TypeField.fetchOne(
                db,
                sql: """
                    SELECT
                        id,
                        type_id AS typeID,
                        name,
                        field_index AS fieldIndex,
                        field_display_index AS fieldDisplayIndex,
                        COALESCE(is_primary, 0) AS isPrimary,
                        field_type AS fieldType,
                        COALESCE(is_protected, 0) AS isProtected
                    FROM field
                    WHERE id = ? AND type_id = ?
                    """,
                arguments: [fieldID, typeID]
            ) else {
                throw DatabaseError(message: "Field not found.")
            }

            if field.isProtected {
                throw DatabaseError(message: "This field is built into the Person type and cannot be deleted.")
            }
            if field.isPrimary {
                throw DatabaseError(message: "Cannot delete the primary field. Mark another text field as primary first.")
            }
            // Only text fields count toward the minimum: every type must keep at
            // least one text field (it supplies the instance display value).
            // Boolean fields can always be deleted.
            if field.fieldType == .text {
                let textFieldCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM field WHERE type_id = ? AND field_type = 'text'",
                    arguments: [typeID]
                ) ?? 0
                if textFieldCount <= 1 {
                    throw DatabaseError(message: "A type must have at least one text field.")
                }
            }

            try db.execute(
                sql: """
                    ALTER TABLE "type\(typeID)"
                    DROP COLUMN "field\(field.fieldIndex)"
                    """
            )

            try db.execute(
                sql: """
                    DELETE FROM field
                    WHERE id = ? AND type_id = ?
                    """,
                arguments: [fieldID, typeID]
            )

            try db.execute(
                sql: """
                    UPDATE field
                    SET field_display_index = field_display_index - 1
                    WHERE type_id = ? AND field_display_index > ?
                    """,
                arguments: [typeID, field.fieldDisplayIndex]
            )
        }
    }

    func renameField(fieldID: Int64, fromTypeID typeID: Int64, to newName: String) throws {
        try dbQueue.write { db in
            let isProtected = try Bool.fetchOne(
                db,
                sql: "SELECT COALESCE(is_protected, 0) FROM field WHERE id = ? AND type_id = ?",
                arguments: [fieldID, typeID]
            ) ?? false
            if isProtected {
                throw DatabaseError(message: "This field is built into the Person type and cannot be renamed.")
            }
            try db.execute(
                sql: """
                    UPDATE field
                    SET name = ?
                    WHERE id = ? AND type_id = ?
                    """,
                arguments: [newName, fieldID, typeID]
            )
        }
    }

    // MARK: - Primary / display fields

    // In-memory equivalent of the "primary field" ordering used in SQL
    // (is_primary DESC, field_display_index ASC, id). The first element of a list
    // sorted with this is the type's primary/display field.
    nonisolated static func primaryFieldOrdering(_ a: TypeField, _ b: TypeField) -> Bool {
        if a.isPrimary != b.isPrimary { return a.isPrimary }
        if a.fieldDisplayIndex != b.fieldDisplayIndex { return a.fieldDisplayIndex < b.fieldDisplayIndex }
        return a.id < b.id
    }

    // Marks `fieldID` as the type's primary text field. Independent of display
    // order: primary is tracked solely by is_primary, while field_display_index
    // controls the (separately re-orderable) display order.
    func setPrimaryField(fieldID: Int64, forTypeID typeID: Int64) throws {
        try dbQueue.write { db in
            // The primary field supplies node display chips/summaries, so it must
            // be a text field — a boolean primary would render as "0"/"1".
            let fieldTypeRaw = try String.fetchOne(
                db,
                sql: "SELECT field_type FROM field WHERE id = ? AND type_id = ?",
                arguments: [fieldID, typeID]
            )
            if fieldTypeRaw == FieldKind.boolean.rawValue || fieldTypeRaw == FieldKind.sex.rawValue {
                throw DatabaseError(message: "Only a text field can be the primary field.")
            }
            try db.execute(
                sql: "UPDATE field SET is_primary = 0 WHERE type_id = ?",
                arguments: [typeID]
            )
            try db.execute(
                sql: "UPDATE field SET is_primary = 1 WHERE id = ? AND type_id = ?",
                arguments: [fieldID, typeID]
            )
        }
    }

    // Persists a new display order for a type's text fields. `orderedFieldIDs`
    // must list every field of the type in the desired top-to-bottom order;
    // field_display_index is renumbered 1...N to match.
    func setFieldDisplayOrder(typeID: Int64, orderedFieldIDs: [Int64]) throws {
        try dbQueue.write { db in
            for (index, fieldID) in orderedFieldIDs.enumerated() {
                try db.execute(
                    sql: "UPDATE field SET field_display_index = ? WHERE id = ? AND type_id = ?",
                    arguments: [index + 1, fieldID, typeID]
                )
            }
        }
    }

    // An instance's display value: its primary/first display field's raw text.
    nonisolated static func fetchInstanceDisplayValue(db: Database, instanceID: Int64) throws -> String {
        guard let typeID = try Int64.fetchOne(
            db,
            sql: "SELECT type_id FROM instance_id_type_id WHERE instance_id = ?",
            arguments: [instanceID]
        ) else {
            return ""
        }
        guard let fieldIndex = try Int.fetchOne(
            db,
            sql: "SELECT field_index FROM field WHERE type_id = ? ORDER BY is_primary DESC, field_display_index ASC, id LIMIT 1",
            arguments: [typeID]
        ) else {
            return ""
        }
        let value = try String.fetchOne(
            db,
            sql: "SELECT COALESCE(\"field\(fieldIndex)\", '') FROM \"type\(typeID)\" WHERE id = ?",
            arguments: [instanceID]
        )
        return value ?? ""
    }

    func renameType(typeID: Int64, to newName: String) throws {
        if Self.nameStartsWithDigit(newName) {
            throw DatabaseError(message: "A type name cannot start with a digit.")
        }
        try dbQueue.write { db in
            let isBuiltin = try Bool.fetchOne(
                db,
                sql: "SELECT COALESCE(is_builtin, 0) FROM \"type\" WHERE id = ?",
                arguments: [typeID]
            ) ?? false
            if isBuiltin {
                throw DatabaseError(message: "Built-in types cannot be renamed.")
            }
            try db.execute(
                sql: """
                    UPDATE "type"
                    SET name = ?
                    WHERE id = ?
                    """,
                arguments: [newName, typeID]
            )
        }
    }

    func renameQueryType(queryTypeID: Int64, to newName: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE query_type
                    SET name = ?
                    WHERE id = ?
                    """,
                arguments: [newName, queryTypeID]
            )
        }
    }

    func deleteQueryType(queryTypeID: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    DELETE FROM query_type
                    WHERE id = ?
                    """,
                arguments: [queryTypeID]
            )
        }
    }

    func updateQuestionHTML(forQueryTypeID queryTypeID: Int64, questionHTML: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE query_type
                    SET question_html = ?
                    WHERE id = ?
                    """,
                arguments: [questionHTML, queryTypeID]
            )
        }
    }

    func updateAnswerHTML(forQueryTypeID queryTypeID: Int64, answerHTML: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE query_type
                    SET answer_html = ?
                    WHERE id = ?
                    """,
                arguments: [answerHTML, queryTypeID]
            )
        }
    }

    func updateTypeCSS(typeID: Int64, css: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE "type"
                    SET css = ?
                    WHERE id = ?
                    """,
                arguments: [css, typeID]
            )
        }
    }

    func updateTypeDescription(typeID: Int64, description: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE "type"
                    SET description = ?
                    WHERE id = ?
                    """,
                arguments: [description, typeID]
            )
        }
    }

    func fetchGlobalQueryHTML() throws -> String {
        if let cachedValue = globalQueryHTMLCache.get() {
            return cachedValue
        }

        let globalQueryHTML = try dbQueue.read { db in
            guard let value = try String.fetchOne(
                db,
                sql: """
                    SELECT value
                    FROM globals
                    WHERE name = ?
                    """,
                arguments: ["global_query_html"]
            ) else {
                throw DatabaseError(message: "Missing globals row for global_query_html.")
            }

            return value
        }

        globalQueryHTMLCache.set(globalQueryHTML)
        return globalQueryHTML
    }

    func fetchGlobalQueryCSS() throws -> String {
        if let cachedValue = globalQueryCSSCache.get() {
            return cachedValue
        }

        let globalQueryCSS = try dbQueue.read { db in
            guard let value = try String.fetchOne(
                db,
                sql: """
                    SELECT value
                    FROM globals
                    WHERE name = ?
                    """,
                arguments: ["global_query_css"]
            ) else {
                throw DatabaseError(message: "Missing globals row for global_query_css.")
            }

            return value
        }

        globalQueryCSSCache.set(globalQueryCSS)
        return globalQueryCSS
    }

    func updateGlobalQueryHTML(_ globalQueryHTML: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE globals
                    SET value = ?
                    WHERE name = ?
                    """,
                arguments: [globalQueryHTML, "global_query_html"]
            )
        }

        globalQueryHTMLCache.set(globalQueryHTML)
    }

    func updateGlobalQueryCSS(_ globalQueryCSS: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE globals
                    SET value = ?
                    WHERE name = ?
                    """,
                arguments: [globalQueryCSS, "global_query_css"]
            )
        }

        globalQueryCSSCache.set(globalQueryCSS)
    }

    nonisolated func fetchInstanceSearchTypeInfos(db: Database) throws -> [InstanceSearchTypeInfo] {
        let rows = try InstanceSearchTypeFieldInfo.fetchAll(
            db,
            sql: """
                SELECT
                    "type".id AS typeID,
                    "type".name AS typeName,
                    field.field_index AS fieldIndex,
                    field.field_display_index AS fieldDisplayIndex,
                    COALESCE(field.is_primary, 0) AS isPrimary
                FROM "type"
                JOIN field
                    ON field.type_id = "type".id
                ORDER BY "type".id, field.field_index
                """
        )

        var groupedRowsByTypeID: [Int64: [InstanceSearchTypeFieldInfo]] = [:]
        var orderedTypeIDs: [Int64] = []

        for row in rows {
            if groupedRowsByTypeID[row.typeID] == nil {
                orderedTypeIDs.append(row.typeID)
            }
            groupedRowsByTypeID[row.typeID, default: []].append(row)
        }

        return orderedTypeIDs.compactMap { typeID in
            guard let rows = groupedRowsByTypeID[typeID],
                  let displayFieldIndex = rows.sorted(by: { lhs, rhs in
                      if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
                      return lhs.fieldDisplayIndex < rhs.fieldDisplayIndex
                  }).first?.fieldIndex else {
                return nil
            }

            return InstanceSearchTypeInfo(
                typeID: typeID,
                typeName: rows[0].typeName,
                displayFieldIndex: displayFieldIndex,
                allFieldIndices: rows.map(\.fieldIndex)
            )
        }
    }

    private func fetchInstanceSearchRows(
        db: Database,
        typeInfo: InstanceSearchTypeInfo,
        parsedQuery: InstanceSearchQuery
    ) throws -> [InstanceSearchResult] {
        let tableName = "\"type\(typeInfo.typeID)\""
        let tableAlias = "instance_table"
        let displayColumnName = "\"field\(typeInfo.displayFieldIndex)\""
        let searchConditions = makeInstanceSearchConditions(
            tableAlias: tableAlias,
            typeName: typeInfo.typeName,
            typeID: typeInfo.typeID,
            fieldIndices: typeInfo.allFieldIndices,
            expression: parsedQuery.expression
        )
        let whereClause = searchConditions.sql.isEmpty ? "" : "\nWHERE \(searchConditions.sql)"

        let rows = try InstanceSearchRow.fetchAll(
            db,
            sql: """
                SELECT
                    \(tableAlias).id,
                    COALESCE(\(tableAlias).\(displayColumnName), '') AS displayValue
                FROM \(tableName) AS \(tableAlias)\(whereClause)
                ORDER BY \(tableAlias).\(displayColumnName) COLLATE NOCASE, \(tableAlias).id
                """,
            arguments: searchConditions.arguments
        )

        return rows.map { row in
            InstanceSearchResult(id: row.id, displayValue: row.displayValue)
        }
    }

    private func fetchGraphInstanceRows(
        db: Database,
        typeInfo: InstanceSearchTypeInfo,
        parsedQuery: InstanceSearchQuery
    ) throws -> [GraphInstanceRow] {
        let tableName = "\"type\(typeInfo.typeID)\""
        let tableAlias = "instance_table"
        let displayColumnName = "\"field\(typeInfo.displayFieldIndex)\""
        let searchConditions = makeInstanceSearchConditions(
            tableAlias: tableAlias,
            typeName: typeInfo.typeName,
            typeID: typeInfo.typeID,
            fieldIndices: typeInfo.allFieldIndices,
            expression: parsedQuery.expression
        )
        let whereClause = searchConditions.sql.isEmpty ? "" : "\nWHERE \(searchConditions.sql)"

        // Concatenate all field columns to scan for id: links
        let allFieldsConcat = typeInfo.allFieldIndices
            .map { "COALESCE(\(tableAlias).\"field\($0)\", '')" }
            .joined(separator: " || ' ' || ")
        let concatExpr = allFieldsConcat.isEmpty ? "''" : allFieldsConcat

        return try GraphInstanceRow.fetchAll(
            db,
            sql: """
                SELECT
                    \(tableAlias).id AS instanceID,
                    COALESCE(\(tableAlias).\(displayColumnName), '') AS displayValue,
                    \(concatExpr) AS allFieldValues
                FROM \(tableName) AS \(tableAlias)\(whereClause)
                """,
            arguments: searchConditions.arguments
        )
    }

    private func parseInstanceLinks(from html: String) -> [Int64] {
        let nsString = html as NSString
        let range = NSRange(location: 0, length: nsString.length)
        return Self.instanceLinkRegex.matches(in: html, range: range).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let captureRange = match.range(at: 1)
            guard captureRange.location != NSNotFound else { return nil }
            return Int64(nsString.substring(with: captureRange))
        }
    }

    private func fetchQuerySearchRows(
        db: Database,
        typeInfo: InstanceSearchTypeInfo,
        parsedQuery: QuerySearchQuery
    ) throws -> [QuerySearchResult] {
        let tableName = "\"type\(typeInfo.typeID)\""
        let tableAlias = "instance_table"
        let displayColumnName = "\"field\(typeInfo.displayFieldIndex)\""
        let searchConditions = makeQuerySearchConditions(
            tableAlias: tableAlias,
            typeName: typeInfo.typeName,
            typeID: typeInfo.typeID,
            fieldIndices: typeInfo.allFieldIndices,
            expression: parsedQuery.expression
        )
        let whereClause = searchConditions.sql.isEmpty ? "" : "\nWHERE \(searchConditions.sql)"

        let rows = try QuerySearchRow.fetchAll(
            db,
            sql: """
                SELECT
                    query.instance_id AS instanceID,
                    query.query_type_id AS queryTypeID,
                    COALESCE(\(tableAlias).\(displayColumnName), '') AS displayValue,
                    query_type.name AS queryTypeName
                FROM \(tableName) AS \(tableAlias)
                JOIN query
                    ON query.instance_id = \(tableAlias).id
                JOIN query_type
                    ON query_type.id = query.query_type_id\(whereClause)
                ORDER BY \(tableAlias).\(displayColumnName) COLLATE NOCASE, query.query_type_id, query.instance_id
                """,
            arguments: searchConditions.arguments
        )

        return rows.map { row in
            QuerySearchResult(
                instanceID: row.instanceID,
                queryTypeID: row.queryTypeID,
                displayValue: row.displayValue,
                queryTypeName: row.queryTypeName
            )
        }
    }

    private func fetchStudyTypeSummary(
        db: Database,
        typeInfo: InstanceSearchTypeInfo,
        parsedQuery: QuerySearchQuery
    ) throws -> StudyTypeSummary {
        let tableName = "\"type\(typeInfo.typeID)\""
        let tableAlias = "instance_table"
        let searchConditions = makeQuerySearchConditions(
            tableAlias: tableAlias,
            typeName: typeInfo.typeName,
            typeID: typeInfo.typeID,
            fieldIndices: typeInfo.allFieldIndices,
            expression: parsedQuery.expression
        )
        let whereClause = searchConditions.sql.isEmpty ? "" : "\nWHERE \(searchConditions.sql)"

        let row = try StudyTypeSummaryRow.fetchOne(
            db,
            sql: """
                SELECT
                    COUNT(*) AS totalCount,
                    COALESCE(SUM(CASE WHEN query.interval = 0 THEN 1 ELSE 0 END), 0) AS newCount,
                    MIN(CASE WHEN query.interval != 0 THEN query.last_answered_timestamp + query.interval END) AS minimumSeenDueTimestamp
                FROM \(tableName) AS \(tableAlias)
                JOIN query
                    ON query.instance_id = \(tableAlias).id\(whereClause)
                """,
            arguments: searchConditions.arguments
        ) ?? StudyTypeSummaryRow(totalCount: 0, newCount: 0, minimumSeenDueTimestamp: nil)

        return StudyTypeSummary(
            typeInfo: typeInfo,
            totalCount: row.totalCount,
            newCount: row.newCount,
            seenCount: row.totalCount - row.newCount,
            minimumSeenDueTimestamp: row.minimumSeenDueTimestamp
        )
    }

    private func fetchStudyQueryCount(
        db: Database,
        typeInfo: InstanceSearchTypeInfo,
        parsedQuery: QuerySearchQuery,
        whereSQL: String,
        additionalArguments: StatementArguments
    ) throws -> Int {
        let tableName = "\"type\(typeInfo.typeID)\""
        let tableAlias = "instance_table"
        let searchConditions = makeQuerySearchConditions(
            tableAlias: tableAlias,
            typeName: typeInfo.typeName,
            typeID: typeInfo.typeID,
            fieldIndices: typeInfo.allFieldIndices,
            expression: parsedQuery.expression
        )
        var arguments = searchConditions.arguments
        arguments += additionalArguments
        let searchSQL = searchConditions.sql.isEmpty ? whereSQL : "(\(searchConditions.sql)) AND (\(whereSQL))"

        return try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM \(tableName) AS \(tableAlias)
                JOIN query
                    ON query.instance_id = \(tableAlias).id
                WHERE \(searchSQL)
                """,
            arguments: arguments
        ) ?? 0
    }

    private func fetchRandomStudyQueryRow(
        db: Database,
        typeInfo: InstanceSearchTypeInfo,
        parsedQuery: QuerySearchQuery,
        whereSQL: String,
        additionalArguments: StatementArguments
    ) throws -> StudyQueryRow {
        let matchingCount = try fetchStudyQueryCount(
            db: db,
            typeInfo: typeInfo,
            parsedQuery: parsedQuery,
            whereSQL: whereSQL,
            additionalArguments: additionalArguments
        )
        guard matchingCount > 0 else {
            throw DatabaseError(message: "No study query matched the requested criteria.")
        }

        let tableName = "\"type\(typeInfo.typeID)\""
        let tableAlias = "instance_table"
        let searchConditions = makeQuerySearchConditions(
            tableAlias: tableAlias,
            typeName: typeInfo.typeName,
            typeID: typeInfo.typeID,
            fieldIndices: typeInfo.allFieldIndices,
            expression: parsedQuery.expression
        )
        var arguments = searchConditions.arguments
        arguments += additionalArguments
        let searchSQL = searchConditions.sql.isEmpty ? whereSQL : "(\(searchConditions.sql)) AND (\(whereSQL))"
        arguments += [Int.random(in: 0..<matchingCount)]

        guard let queryRow = try StudyQueryRow.fetchOne(
            db,
            sql: """
                SELECT
                    query.instance_id AS instanceID,
                    query.query_type_id AS queryTypeID,
                    query.interval AS interval,
                    query.max_interval AS maxInterval,
                    query.last_answered_timestamp AS lastAnsweredTimestamp,
                    query.query_state AS queryState,
                    query_type.name AS queryTypeName,
                    query_type.question_html AS questionHTML,
                    query_type.answer_html AS answerHTML,
                    "type".css AS typeCSS
                FROM \(tableName) AS \(tableAlias)
                JOIN query
                    ON query.instance_id = \(tableAlias).id
                JOIN query_type
                    ON query_type.id = query.query_type_id
                JOIN "type"
                    ON "type".id = query_type.type_id
                WHERE \(searchSQL)
                ORDER BY query.instance_id, query.query_type_id
                LIMIT 1 OFFSET ?
                """,
            arguments: arguments
        ) else {
            throw DatabaseError(message: "Failed to fetch the selected study query.")
        }

        return queryRow
    }

    private func makeStudyQuery(
        db: Database,
        typeInfo: InstanceSearchTypeInfo,
        queryRow: StudyQueryRow
    ) throws -> StudyQuery {
        let fields = try TypeField.fetchAll(
            db,
            sql: """
                SELECT
                    id,
                    type_id AS typeID,
                    name,
                    field_index AS fieldIndex,
                    field_display_index AS fieldDisplayIndex,
                    field_type AS fieldType
                FROM field
                WHERE type_id = ?
                ORDER BY field_index, id
                """,
            arguments: [typeInfo.typeID]
        )

        let tableName = "\"type\(typeInfo.typeID)\""
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT *
                FROM \(tableName)
                WHERE id = ?
                """,
            arguments: [queryRow.instanceID]
        ) else {
            throw DatabaseError(message: "Study instance not found.")
        }

        let fieldValuesByName = Dictionary(uniqueKeysWithValues: fields.map { field in
            (field.name, row["field\(field.fieldIndex)"] as String? ?? "")
        })
        let booleanFieldNames = Set(fields.filter { $0.fieldType == .boolean }.map(\.name))

        return StudyQuery(
            instanceID: queryRow.instanceID,
            queryTypeID: queryRow.queryTypeID,
            interval: queryRow.interval,
            maxInterval: queryRow.maxInterval,
            lastAnsweredTimestamp: queryRow.lastAnsweredTimestamp,
            queryState: QueryState(rawValue: queryRow.queryState) ?? .zero,
            typeName: typeInfo.typeName,
            queryTypeName: queryRow.queryTypeName,
            questionHTML: queryRow.questionHTML,
            answerHTML: queryRow.answerHTML,
            typeCSS: queryRow.typeCSS,
            fieldValuesByName: fieldValuesByName,
            booleanFieldNames: booleanFieldNames
        )
    }

    private func fetchStudyQueries(
        db: Database,
        typeInfo: InstanceSearchTypeInfo,
        parsedQuery: QuerySearchQuery,
        whereSQL: String,
        additionalArguments: StatementArguments
    ) throws -> [StudyQuery] {
        let tableName = "\"type\(typeInfo.typeID)\""
        let tableAlias = "instance_table"
        let searchConditions = makeQuerySearchConditions(
            tableAlias: tableAlias,
            typeName: typeInfo.typeName,
            typeID: typeInfo.typeID,
            fieldIndices: typeInfo.allFieldIndices,
            expression: parsedQuery.expression
        )
        var arguments = searchConditions.arguments
        arguments += additionalArguments
        let searchSQL = searchConditions.sql.isEmpty ? whereSQL : "(\(searchConditions.sql)) AND (\(whereSQL))"

        let rows = try StudyQueryRow.fetchAll(
            db,
            sql: """
                SELECT
                    query.instance_id AS instanceID,
                    query.query_type_id AS queryTypeID,
                    query.interval AS interval,
                    query.max_interval AS maxInterval,
                    query.last_answered_timestamp AS lastAnsweredTimestamp,
                    query.query_state AS queryState,
                    query_type.name AS queryTypeName,
                    query_type.question_html AS questionHTML,
                    query_type.answer_html AS answerHTML,
                    "type".css AS typeCSS
                FROM \(tableName) AS \(tableAlias)
                JOIN query
                    ON query.instance_id = \(tableAlias).id
                JOIN query_type
                    ON query_type.id = query.query_type_id
                JOIN "type"
                    ON "type".id = query_type.type_id
                WHERE \(searchSQL)
                ORDER BY query.instance_id, query.query_type_id
                """,
            arguments: arguments
        )

        return try rows.map { row in
            try makeStudyQuery(db: db, typeInfo: typeInfo, queryRow: row)
        }
    }

    // MARK: - PointMap study/search helpers

    private struct PointMapStudyRow: FetchableRecord, Decodable {
        let pointID: Int64
        let instanceID: Int64
        let pointName: String
        let latitude: Double
        let longitude: Double
        let interval: Int64
        let lastAnsweredTimestamp: Int64?
        let queryState: Int
        let isReverse: Bool
        let title: String
        let defaultCenterLat: Double
        let defaultCenterLng: Double
        let defaultZoom: Double
        let showAllPointsInQuestion: Bool
        let pointSize: PointMapPointSize
    }

    // A derived table that expands each pointmap_point into up to two rows — one
    // per enabled direction — exposing direction-neutral SRS columns (interval,
    // last_answered_timestamp, query_state) plus is_reverse. Aliased `pp`, it is
    // a drop-in replacement for `pointmap_point AS pp` so every existing
    // `pp.interval` / `pp.name` predicate keeps working while forward and reverse
    // are counted/scheduled as independent study units.
    nonisolated static let pointMapDirectionalFrom = """
        (
            SELECT p.id AS id, p.instance_id AS instance_id, p.name AS name,
                   p.latitude AS latitude, p.longitude AS longitude,
                   q.interval AS interval, q.last_answered_timestamp AS last_answered_timestamp,
                   q.query_state AS query_state, q.is_reverse AS is_reverse
            FROM pointmap_query AS q
            JOIN pointmap_point AS p ON p.id = q.point_id
        )
        """

    nonisolated static let boundaryMapDirectionalFrom = """
        (
            SELECT a.id AS id, a.instance_id AS instance_id, a.boundary_id AS boundary_id,
                   q.interval AS interval, q.last_answered_timestamp AS last_answered_timestamp,
                   q.query_state AS query_state, q.is_reverse AS is_reverse
            FROM boundarymap_query AS q
            JOIN boundarymap_attachment AS a ON a.id = q.attachment_id
        )
        """

    private struct PointMapInstanceSearchRow: FetchableRecord, Decodable {
        let instanceID: Int64
        let title: String
    }

    private struct PointMapGraphRow: FetchableRecord, Decodable {
        let instanceID: Int64
        let title: String
    }

    // `directionalAlias` is non-nil when the scanned rows are directional query
    // rows and names the alias exposing `is_reverse`; it is nil when scanning
    // instances or map elements, where `qt:` instead compiles to an enablement
    // EXISTS (`qt:` is parse-rejected in element search, so the nil case only
    // matters for instance search).
    nonisolated private func makePointMapSearchCondition(
        _ expression: SearchExpression,
        pointAlias: String,
        instanceAlias: String,
        directionalAlias: String?,
        includePointName: Bool
    ) -> (sql: String, arguments: StatementArguments) {
        switch expression {
        case .literal(let literal):
            let escaped = Self.escapeSQLiteLikePattern(literal)
            let pattern = "%\(escaped)%"
            var arguments = StatementArguments()
            if includePointName {
                arguments += [pattern, pattern]
                return (
                    "(COALESCE(\(pointAlias).name, '') LIKE ? ESCAPE '\\' OR COALESCE(\(instanceAlias).title, '') LIKE ? ESCAPE '\\')",
                    arguments
                )
            } else {
                arguments += [pattern]
                return (
                    "(COALESCE(\(instanceAlias).title, '') LIKE ? ESCAPE '\\')",
                    arguments
                )
            }
        case .type(let searchedTypeName):
            var arguments = StatementArguments()
            arguments += [POINTMAP_TYPE_NAME, searchedTypeName]
            return ("? = ? COLLATE NOCASE", arguments)
        case .typeID(let searchedTypeID):
            var arguments = StatementArguments()
            arguments += [searchedTypeID, POINTMAP_TYPE_NAME]
            return (Self.mapTypeIDCompareSQL, arguments)
        case .collection(let collectionName):
            var arguments = StatementArguments()
            arguments += [collectionName]
            return (
                """
                EXISTS (
                    SELECT 1
                    FROM instance_id_collection_id
                    JOIN collection
                        ON collection.id = instance_id_collection_id.collection_id
                    WHERE instance_id_collection_id.instance_id = \(instanceAlias).instance_id
                        AND collection.name = ? COLLATE NOCASE
                )
                """,
                arguments
            )
        case .collectionID(let collectionID):
            var arguments = StatementArguments()
            arguments += [collectionID]
            return (
                """
                EXISTS (
                    SELECT 1
                    FROM instance_id_collection_id
                    WHERE instance_id_collection_id.instance_id = \(instanceAlias).instance_id
                        AND instance_id_collection_id.collection_id = ?
                )
                """,
                arguments
            )
        case .id(let instanceID):
            var arguments = StatementArguments()
            arguments += [instanceID]
            return ("\(instanceAlias).instance_id = ?", arguments)
        case .noQueries:
            // A PointMap instance's queries are its points; a point counts only
            // while it has at least one direction enabled.
            return (
                """
                NOT EXISTS (
                    SELECT 1
                    FROM pointmap_query
                    JOIN pointmap_point ON pointmap_point.id = pointmap_query.point_id
                    WHERE pointmap_point.instance_id = \(instanceAlias).instance_id
                )
                """,
                StatementArguments()
            )
        case .new:
            // :new is standard-query-only; exclude all PointMap rows.
            return ("0", StatementArguments())
        case .office:
            // Office holdings are Person-only; no PointMap row can match.
            return ("0", StatementArguments())
        case .queryType(let searchedTypeName, let searchedQueryTypeName):
            var typeCompareArguments = StatementArguments()
            typeCompareArguments += [POINTMAP_TYPE_NAME, searchedTypeName]
            return Self.makeMapQueryTypeCondition(
                typeCompareSQL: "? = ? COLLATE NOCASE",
                typeCompareArguments: typeCompareArguments,
                searchedQueryTypeName: searchedQueryTypeName,
                queryTable: "pointmap_query",
                elementTable: "pointmap_point",
                elementIDColumn: "point_id",
                instanceAlias: instanceAlias,
                directionalAlias: directionalAlias
            )
        case .queryTypeID(let searchedTypeID, let searchedQueryTypeName):
            var typeCompareArguments = StatementArguments()
            typeCompareArguments += [searchedTypeID, POINTMAP_TYPE_NAME]
            return Self.makeMapQueryTypeCondition(
                typeCompareSQL: Self.mapTypeIDCompareSQL,
                typeCompareArguments: typeCompareArguments,
                searchedQueryTypeName: searchedQueryTypeName,
                queryTable: "pointmap_query",
                elementTable: "pointmap_point",
                elementIDColumn: "point_id",
                instanceAlias: instanceAlias,
                directionalAlias: directionalAlias
            )
        case .and(let left, let right):
            let l = makePointMapSearchCondition(left, pointAlias: pointAlias, instanceAlias: instanceAlias, directionalAlias: directionalAlias, includePointName: includePointName)
            let r = makePointMapSearchCondition(right, pointAlias: pointAlias, instanceAlias: instanceAlias, directionalAlias: directionalAlias, includePointName: includePointName)
            var args = l.arguments
            args += r.arguments
            return ("(\(l.sql)) AND (\(r.sql))", args)
        case .or(let left, let right):
            let l = makePointMapSearchCondition(left, pointAlias: pointAlias, instanceAlias: instanceAlias, directionalAlias: directionalAlias, includePointName: includePointName)
            let r = makePointMapSearchCondition(right, pointAlias: pointAlias, instanceAlias: instanceAlias, directionalAlias: directionalAlias, includePointName: includePointName)
            var args = l.arguments
            args += r.arguments
            return ("(\(l.sql)) OR (\(r.sql))", args)
        case .not(let inner):
            let i = makePointMapSearchCondition(inner, pointAlias: pointAlias, instanceAlias: instanceAlias, directionalAlias: directionalAlias, includePointName: includePointName)
            return ("NOT (\(i.sql))", i.arguments)
        }
    }

    nonisolated func makePointMapSearchConditions(
        expression: SearchExpression?,
        pointAlias: String,
        instanceAlias: String,
        directionalAlias: String?,
        includePointName: Bool
    ) -> (sql: String, arguments: StatementArguments) {
        guard let expression else {
            return ("", StatementArguments())
        }
        return makePointMapSearchCondition(
            expression,
            pointAlias: pointAlias,
            instanceAlias: instanceAlias,
            directionalAlias: directionalAlias,
            includePointName: includePointName
        )
    }

    // The map builders never receive the map type's row ID, so the ID variant
    // of `qt:` resolves it in SQL the way fetchPointMapTypeID does (name +
    // is_builtin) — a constant uncorrelated subquery. Args: [searchedTypeID,
    // map type name].
    nonisolated private static let mapTypeIDCompareSQL = """
        EXISTS (SELECT 1 FROM "type" WHERE "type".id = ? AND "type".name = ? AND "type".is_builtin = 1)
        """

    // `qt:`'s second argument for the map families: "Forward"/"Reverse"
    // (NOCASE). Anything else matches no map queries.
    nonisolated private static func mapDirectionIsReverse(_ queryTypeName: String) -> Bool? {
        if sqliteNocaseEquals(queryTypeName, "Forward") { return false }
        if sqliteNocaseEquals(queryTypeName, "Reverse") { return true }
        return nil
    }

    // The `qt:` body shared by the two map builders. Directional scans compare
    // the row's own is_reverse; instance scans check that the direction is
    // enabled on any of the instance's points/attachments (row existence per
    // direction = enabled, mirroring `.noQueries`).
    nonisolated private static func makeMapQueryTypeCondition(
        typeCompareSQL: String,
        typeCompareArguments: StatementArguments,
        searchedQueryTypeName: String,
        queryTable: String,
        elementTable: String,
        elementIDColumn: String,
        instanceAlias: String,
        directionalAlias: String?
    ) -> (sql: String, arguments: StatementArguments) {
        guard let isReverse = mapDirectionIsReverse(searchedQueryTypeName) else {
            return ("0", StatementArguments())
        }
        if let directionalAlias {
            return (
                "(\(typeCompareSQL) AND \(directionalAlias).is_reverse = \(isReverse ? 1 : 0))",
                typeCompareArguments
            )
        }
        return (
            """
            (\(typeCompareSQL) AND EXISTS (
                SELECT 1
                FROM \(queryTable)
                JOIN \(elementTable) ON \(elementTable).id = \(queryTable).\(elementIDColumn)
                WHERE \(elementTable).instance_id = \(instanceAlias).instance_id
                    AND \(queryTable).is_reverse = \(isReverse ? 1 : 0)
            ))
            """,
            typeCompareArguments
        )
    }

    private func fetchPointMapStudyRows(
        db: Database,
        parsedQuery: QuerySearchQuery,
        whereSQL: String,
        additionalArguments: StatementArguments
    ) throws -> [PointMapStudyRow] {
        let searchConditions = makePointMapSearchConditions(
            expression: parsedQuery.expression,
            pointAlias: "pp",
            instanceAlias: "pi",
            directionalAlias: "pp",
            includePointName: true
        )
        var arguments = searchConditions.arguments
        arguments += additionalArguments
        let searchSQL = searchConditions.sql.isEmpty ? whereSQL : "(\(searchConditions.sql)) AND (\(whereSQL))"

        return try PointMapStudyRow.fetchAll(
            db,
            sql: """
                SELECT
                    pp.id AS pointID,
                    pp.instance_id AS instanceID,
                    pp.name AS pointName,
                    pp.latitude AS latitude,
                    pp.longitude AS longitude,
                    pp.interval AS interval,
                    pp.last_answered_timestamp AS lastAnsweredTimestamp,
                    pp.query_state AS queryState,
                    pp.is_reverse AS isReverse,
                    pi.title AS title,
                    pi.default_center_lat AS defaultCenterLat,
                    pi.default_center_lng AS defaultCenterLng,
                    pi.default_zoom AS defaultZoom,
                    pi.show_all_points_in_question AS showAllPointsInQuestion,
                    COALESCE(pi.point_size, 'medium') AS pointSize
                FROM \(Self.pointMapDirectionalFrom) AS pp
                JOIN pointmap_instance AS pi
                    ON pi.instance_id = pp.instance_id
                WHERE \(searchSQL)
                ORDER BY pp.instance_id, pp.id, pp.is_reverse
                """,
            arguments: arguments
        )
    }

    private func fetchPointMapStudyQueries(
        db: Database,
        parsedQuery: QuerySearchQuery,
        whereSQL: String,
        additionalArguments: StatementArguments
    ) throws -> [StudyQuery] {
        let rows = try fetchPointMapStudyRows(
            db: db,
            parsedQuery: parsedQuery,
            whereSQL: whereSQL,
            additionalArguments: additionalArguments
        )

        // Group points per instance to build payloads
        var pointsByInstanceID: [Int64: [PointMapPoint]] = [:]
        let allPointRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, instance_id, name, hint, latitude, longitude
                FROM pointmap_point
                WHERE instance_id IN (
                    SELECT DISTINCT instance_id FROM pointmap_point
                )
                ORDER BY instance_id, id
                """
        )
        for row in allPointRows {
            let instanceID = row["instance_id"] as Int64? ?? 0
            let point = PointMapPoint(
                id: row["id"] as Int64? ?? 0,
                instanceID: instanceID,
                name: row["name"] as String? ?? "",
                latitude: row["latitude"] as Double? ?? 0,
                longitude: row["longitude"] as Double? ?? 0,
                hint: row["hint"] as String? ?? ""
            )
            pointsByInstanceID[instanceID, default: []].append(point)
        }

        // Cache boundary geometries per instance so the JSON decoding cost
        // is paid once per unique instance instead of once per query row.
        var boundariesByInstanceID: [Int64: [BoundaryGeometry]] = [:]
        return try rows.map { row in
            let boundaries: [BoundaryGeometry]
            if let cached = boundariesByInstanceID[row.instanceID] {
                boundaries = cached
            } else {
                boundaries = try Self.fetchBoundaryGeometries(db: db, instanceID: row.instanceID)
                boundariesByInstanceID[row.instanceID] = boundaries
            }
            let payload = PointMapStudyPayload(
                pointID: row.pointID,
                pointName: row.pointName,
                instanceTitle: row.title,
                points: pointsByInstanceID[row.instanceID] ?? [],
                defaultCenterLat: row.defaultCenterLat,
                defaultCenterLng: row.defaultCenterLng,
                defaultZoom: row.defaultZoom,
                showAllPointsInQuestion: row.showAllPointsInQuestion,
                boundaries: boundaries,
                isReverse: row.isReverse,
                hint: pointsByInstanceID[row.instanceID]?.first { $0.id == row.pointID }?.hint ?? "",
                pointSize: row.pointSize
            )
            return StudyQuery(
                instanceID: row.instanceID,
                queryTypeID: row.pointID,
                interval: row.interval,
                maxInterval: nil,
                lastAnsweredTimestamp: row.lastAnsweredTimestamp,
                queryState: QueryState(rawValue: row.queryState) ?? .zero,
                typeName: POINTMAP_TYPE_NAME,
                queryTypeName: row.pointName,
                questionHTML: "",
                answerHTML: "",
                typeCSS: "",
                fieldValuesByName: [:],
                kind: .pointMap,
                pointMapPayload: payload,
                isReverse: row.isReverse
            )
        }
    }

    private func fetchPointMapStudyQueryCount(
        db: Database,
        parsedQuery: QuerySearchQuery,
        whereSQL: String,
        additionalArguments: StatementArguments
    ) throws -> Int {
        let searchConditions = makePointMapSearchConditions(
            expression: parsedQuery.expression,
            pointAlias: "pp",
            instanceAlias: "pi",
            directionalAlias: "pp",
            includePointName: true
        )
        var arguments = searchConditions.arguments
        arguments += additionalArguments
        let searchSQL = searchConditions.sql.isEmpty ? whereSQL : "(\(searchConditions.sql)) AND (\(whereSQL))"

        return try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM \(Self.pointMapDirectionalFrom) AS pp
                JOIN pointmap_instance AS pi
                    ON pi.instance_id = pp.instance_id
                WHERE \(searchSQL)
                """,
            arguments: arguments
        ) ?? 0
    }

    private struct PointMapStudySummary {
        let totalCount: Int
        let newCount: Int
        let seenCount: Int
        let minimumSeenDueTimestamp: Int64?
    }

    private func fetchPointMapStudySummary(
        db: Database,
        parsedQuery: QuerySearchQuery
    ) throws -> PointMapStudySummary {
        let searchConditions = makePointMapSearchConditions(
            expression: parsedQuery.expression,
            pointAlias: "pp",
            instanceAlias: "pi",
            directionalAlias: "pp",
            includePointName: true
        )
        let whereClause = searchConditions.sql.isEmpty ? "" : "\nWHERE \(searchConditions.sql)"

        struct Row: FetchableRecord, Decodable {
            let totalCount: Int
            let newCount: Int
            let minimumSeenDueTimestamp: Int64?
        }

        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT
                    COUNT(*) AS totalCount,
                    COALESCE(SUM(CASE WHEN pp.interval = 0 THEN 1 ELSE 0 END), 0) AS newCount,
                    MIN(CASE WHEN pp.interval != 0 THEN pp.last_answered_timestamp + pp.interval END) AS minimumSeenDueTimestamp
                FROM \(Self.pointMapDirectionalFrom) AS pp
                JOIN pointmap_instance AS pi
                    ON pi.instance_id = pp.instance_id\(whereClause)
                """,
            arguments: searchConditions.arguments
        ) ?? Row(totalCount: 0, newCount: 0, minimumSeenDueTimestamp: nil)

        return PointMapStudySummary(
            totalCount: row.totalCount,
            newCount: row.newCount,
            seenCount: row.totalCount - row.newCount,
            minimumSeenDueTimestamp: row.minimumSeenDueTimestamp
        )
    }

    private func fetchRandomPointMapStudyQuery(
        db: Database,
        parsedQuery: QuerySearchQuery,
        whereSQL: String,
        additionalArguments: StatementArguments
    ) throws -> StudyQuery {
        let matchingCount = try fetchPointMapStudyQueryCount(
            db: db,
            parsedQuery: parsedQuery,
            whereSQL: whereSQL,
            additionalArguments: additionalArguments
        )
        guard matchingCount > 0 else {
            throw DatabaseError(message: "No PointMap study query matched the requested criteria.")
        }

        let searchConditions = makePointMapSearchConditions(
            expression: parsedQuery.expression,
            pointAlias: "pp",
            instanceAlias: "pi",
            directionalAlias: "pp",
            includePointName: true
        )
        var arguments = searchConditions.arguments
        arguments += additionalArguments
        let searchSQL = searchConditions.sql.isEmpty ? whereSQL : "(\(searchConditions.sql)) AND (\(whereSQL))"
        arguments += [Int.random(in: 0..<matchingCount)]

        guard let row = try PointMapStudyRow.fetchOne(
            db,
            sql: """
                SELECT
                    pp.id AS pointID,
                    pp.instance_id AS instanceID,
                    pp.name AS pointName,
                    pp.latitude AS latitude,
                    pp.longitude AS longitude,
                    pp.interval AS interval,
                    pp.last_answered_timestamp AS lastAnsweredTimestamp,
                    pp.query_state AS queryState,
                    pp.is_reverse AS isReverse,
                    pi.title AS title,
                    pi.default_center_lat AS defaultCenterLat,
                    pi.default_center_lng AS defaultCenterLng,
                    pi.default_zoom AS defaultZoom,
                    pi.show_all_points_in_question AS showAllPointsInQuestion,
                    COALESCE(pi.point_size, 'medium') AS pointSize
                FROM \(Self.pointMapDirectionalFrom) AS pp
                JOIN pointmap_instance AS pi
                    ON pi.instance_id = pp.instance_id
                WHERE \(searchSQL)
                ORDER BY pp.instance_id, pp.id, pp.is_reverse
                LIMIT 1 OFFSET ?
                """,
            arguments: arguments
        ) else {
            throw DatabaseError(message: "Failed to fetch selected PointMap study query.")
        }

        // Build full point list for this instance
        let pointRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, latitude, longitude
                FROM pointmap_point
                WHERE instance_id = ?
                ORDER BY id
                """,
            arguments: [row.instanceID]
        )
        let allPoints = pointRows.map { pr in
            PointMapPoint(
                id: pr["id"] as Int64? ?? 0,
                instanceID: row.instanceID,
                name: pr["name"] as String? ?? "",
                latitude: pr["latitude"] as Double? ?? 0,
                longitude: pr["longitude"] as Double? ?? 0
            )
        }

        let boundaries = try Self.fetchBoundaryGeometries(db: db, instanceID: row.instanceID)
        let payload = PointMapStudyPayload(
            pointID: row.pointID,
            pointName: row.pointName,
            instanceTitle: row.title,
            points: allPoints,
            defaultCenterLat: row.defaultCenterLat,
            defaultCenterLng: row.defaultCenterLng,
            defaultZoom: row.defaultZoom,
            showAllPointsInQuestion: row.showAllPointsInQuestion,
            boundaries: boundaries,
            isReverse: row.isReverse,
            pointSize: row.pointSize
        )
        return StudyQuery(
            instanceID: row.instanceID,
            queryTypeID: row.pointID,
            interval: row.interval,
            maxInterval: nil,
            lastAnsweredTimestamp: row.lastAnsweredTimestamp,
            queryState: QueryState(rawValue: row.queryState) ?? .zero,
            typeName: POINTMAP_TYPE_NAME,
            queryTypeName: row.pointName,
            questionHTML: "",
            answerHTML: "",
            typeCSS: "",
            fieldValuesByName: [:],
            kind: .pointMap,
            pointMapPayload: payload,
            isReverse: row.isReverse
        )
    }

    // MARK: - BoundaryMap study/search helpers

    private struct BoundaryMapStudyRow: FetchableRecord, Decodable {
        let attachmentID: Int64
        let instanceID: Int64
        let boundaryID: Int64
        let boundaryName: String
        let interval: Int64
        let lastAnsweredTimestamp: Int64?
        let queryState: Int
        let isReverse: Bool
        let title: String
        let defaultCenterLat: Double
        let defaultCenterLng: Double
        let defaultZoom: Double
        let showAllBoundariesInQuestion: Bool
    }

    private struct BoundaryMapInstanceSearchRow: FetchableRecord, Decodable {
        let instanceID: Int64
        let title: String
    }

    private struct BoundaryMapStudySummary {
        let totalCount: Int
        let newCount: Int
        let seenCount: Int
        let minimumSeenDueTimestamp: Int64?
    }

    private static func fetchBoundaryMapAttachedGeometries(
        db: Database,
        instanceID: Int64
    ) throws -> [BoundaryGeometry] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT b.id AS id, b.name AS name, b.geometry_json AS geometry_json, b.color AS color
                FROM boundarymap_attachment AS bq
                JOIN boundary AS b ON b.id = bq.boundary_id
                WHERE bq.instance_id = ?
                ORDER BY b.name COLLATE NOCASE, bq.id
                """,
            arguments: [instanceID]
        )
        return rows.compactMap { row in
            guard let data = row["geometry_json"] as Data? else { return nil }
            guard let parsed = AppDatabase.parseMultiPolygonJSON(data: data) else { return nil }
            return BoundaryGeometry(
                id: row["id"] as Int64? ?? 0,
                name: row["name"] as String? ?? "",
                geometry: parsed,
                color: BoundaryColor(rawValue: row["color"] as String? ?? "") ?? .red
            )
        }
    }

    // Boundaries on the instance with at least one enabled query direction (a
    // boundarymap_query row exists only for an enabled direction). Feeds the
    // study payload's reverse-click candidate set.
    private static func fetchBoundaryMapQueryableBoundaryIDs(
        db: Database,
        instanceID: Int64
    ) throws -> Set<Int64> {
        Set(try Int64.fetchAll(
            db,
            sql: """
                SELECT DISTINCT ba.boundary_id
                FROM boundarymap_attachment AS ba
                JOIN boundarymap_query AS q ON q.attachment_id = ba.id
                WHERE ba.instance_id = ?
                """,
            arguments: [instanceID]
        ))
    }

    // `directionalAlias`: see makePointMapSearchCondition.
    nonisolated private func makeBoundaryMapSearchCondition(
        _ expression: SearchExpression,
        attachmentAlias: String,
        instanceAlias: String,
        boundaryAlias: String,
        directionalAlias: String?,
        includeBoundaryName: Bool
    ) -> (sql: String, arguments: StatementArguments) {
        switch expression {
        case .literal(let literal):
            let escaped = Self.escapeSQLiteLikePattern(literal)
            let pattern = "%\(escaped)%"
            var arguments = StatementArguments()
            if includeBoundaryName {
                arguments += [pattern, pattern]
                return (
                    "(COALESCE(\(boundaryAlias).name, '') LIKE ? ESCAPE '\\' OR COALESCE(\(instanceAlias).title, '') LIKE ? ESCAPE '\\')",
                    arguments
                )
            } else {
                arguments += [pattern]
                return (
                    "(COALESCE(\(instanceAlias).title, '') LIKE ? ESCAPE '\\')",
                    arguments
                )
            }
        case .type(let searchedTypeName):
            var arguments = StatementArguments()
            arguments += [BOUNDARYMAP_TYPE_NAME, searchedTypeName]
            return ("? = ? COLLATE NOCASE", arguments)
        case .typeID(let searchedTypeID):
            var arguments = StatementArguments()
            arguments += [searchedTypeID, BOUNDARYMAP_TYPE_NAME]
            return (Self.mapTypeIDCompareSQL, arguments)
        case .collection(let collectionName):
            var arguments = StatementArguments()
            arguments += [collectionName]
            return (
                """
                EXISTS (
                    SELECT 1
                    FROM instance_id_collection_id
                    JOIN collection
                        ON collection.id = instance_id_collection_id.collection_id
                    WHERE instance_id_collection_id.instance_id = \(instanceAlias).instance_id
                        AND collection.name = ? COLLATE NOCASE
                )
                """,
                arguments
            )
        case .collectionID(let collectionID):
            var arguments = StatementArguments()
            arguments += [collectionID]
            return (
                """
                EXISTS (
                    SELECT 1
                    FROM instance_id_collection_id
                    WHERE instance_id_collection_id.instance_id = \(instanceAlias).instance_id
                        AND instance_id_collection_id.collection_id = ?
                )
                """,
                arguments
            )
        case .id(let instanceID):
            var arguments = StatementArguments()
            arguments += [instanceID]
            return ("\(instanceAlias).instance_id = ?", arguments)
        case .noQueries:
            // A BoundaryMap instance's queries are its boundarymap_query rows; a
            // boundary counts only while it has at least one direction enabled.
            return (
                """
                NOT EXISTS (
                    SELECT 1
                    FROM boundarymap_query
                    JOIN boundarymap_attachment ON boundarymap_attachment.id = boundarymap_query.attachment_id
                    WHERE boundarymap_attachment.instance_id = \(instanceAlias).instance_id
                )
                """,
                StatementArguments()
            )
        case .new:
            // :new is standard-query-only; exclude all BoundaryMap rows.
            return ("0", StatementArguments())
        case .office:
            // Office holdings are Person-only; no BoundaryMap row can match.
            return ("0", StatementArguments())
        case .queryType(let searchedTypeName, let searchedQueryTypeName):
            var typeCompareArguments = StatementArguments()
            typeCompareArguments += [BOUNDARYMAP_TYPE_NAME, searchedTypeName]
            return Self.makeMapQueryTypeCondition(
                typeCompareSQL: "? = ? COLLATE NOCASE",
                typeCompareArguments: typeCompareArguments,
                searchedQueryTypeName: searchedQueryTypeName,
                queryTable: "boundarymap_query",
                elementTable: "boundarymap_attachment",
                elementIDColumn: "attachment_id",
                instanceAlias: instanceAlias,
                directionalAlias: directionalAlias
            )
        case .queryTypeID(let searchedTypeID, let searchedQueryTypeName):
            var typeCompareArguments = StatementArguments()
            typeCompareArguments += [searchedTypeID, BOUNDARYMAP_TYPE_NAME]
            return Self.makeMapQueryTypeCondition(
                typeCompareSQL: Self.mapTypeIDCompareSQL,
                typeCompareArguments: typeCompareArguments,
                searchedQueryTypeName: searchedQueryTypeName,
                queryTable: "boundarymap_query",
                elementTable: "boundarymap_attachment",
                elementIDColumn: "attachment_id",
                instanceAlias: instanceAlias,
                directionalAlias: directionalAlias
            )
        case .and(let left, let right):
            let l = makeBoundaryMapSearchCondition(left, attachmentAlias: attachmentAlias, instanceAlias: instanceAlias, boundaryAlias: boundaryAlias, directionalAlias: directionalAlias, includeBoundaryName: includeBoundaryName)
            let r = makeBoundaryMapSearchCondition(right, attachmentAlias: attachmentAlias, instanceAlias: instanceAlias, boundaryAlias: boundaryAlias, directionalAlias: directionalAlias, includeBoundaryName: includeBoundaryName)
            var args = l.arguments
            args += r.arguments
            return ("(\(l.sql)) AND (\(r.sql))", args)
        case .or(let left, let right):
            let l = makeBoundaryMapSearchCondition(left, attachmentAlias: attachmentAlias, instanceAlias: instanceAlias, boundaryAlias: boundaryAlias, directionalAlias: directionalAlias, includeBoundaryName: includeBoundaryName)
            let r = makeBoundaryMapSearchCondition(right, attachmentAlias: attachmentAlias, instanceAlias: instanceAlias, boundaryAlias: boundaryAlias, directionalAlias: directionalAlias, includeBoundaryName: includeBoundaryName)
            var args = l.arguments
            args += r.arguments
            return ("(\(l.sql)) OR (\(r.sql))", args)
        case .not(let inner):
            let i = makeBoundaryMapSearchCondition(inner, attachmentAlias: attachmentAlias, instanceAlias: instanceAlias, boundaryAlias: boundaryAlias, directionalAlias: directionalAlias, includeBoundaryName: includeBoundaryName)
            return ("NOT (\(i.sql))", i.arguments)
        }
    }

    nonisolated func makeBoundaryMapSearchConditions(
        expression: SearchExpression?,
        attachmentAlias: String,
        instanceAlias: String,
        boundaryAlias: String,
        directionalAlias: String?,
        includeBoundaryName: Bool
    ) -> (sql: String, arguments: StatementArguments) {
        guard let expression else {
            return ("", StatementArguments())
        }
        return makeBoundaryMapSearchCondition(
            expression,
            attachmentAlias: attachmentAlias,
            instanceAlias: instanceAlias,
            boundaryAlias: boundaryAlias,
            directionalAlias: directionalAlias,
            includeBoundaryName: includeBoundaryName
        )
    }

    private func fetchBoundaryMapInstanceSearchRows(
        db: Database,
        expression: SearchExpression?
    ) throws -> [InstanceSearchResult] {
        // Instance-level search uses no boundary join, so include the boundary
        // table only via EXISTS in the literal predicate via the attachment+
        // boundary chain. Instead, search by title only (boundary names searched
        // via the query-search path).
        let searchConditions = makeBoundaryMapSearchConditions(
            expression: expression,
            attachmentAlias: "bq",
            instanceAlias: "bi",
            boundaryAlias: "b",
            directionalAlias: nil,
            includeBoundaryName: false
        )
        let whereClause = searchConditions.sql.isEmpty ? "" : "\nWHERE \(searchConditions.sql)"

        let rows = try BoundaryMapInstanceSearchRow.fetchAll(
            db,
            sql: """
                SELECT
                    bi.instance_id AS instanceID,
                    COALESCE(bi.title, '') AS title
                FROM boundarymap_instance AS bi\(whereClause)
                ORDER BY bi.title COLLATE NOCASE, bi.instance_id
                """,
            arguments: searchConditions.arguments
        )

        return rows.map { row in
            InstanceSearchResult(id: row.instanceID, displayValue: row.title)
        }
    }

    private func fetchBoundaryMapQuerySearchRows(
        db: Database,
        expression: SearchExpression?
    ) throws -> [QuerySearchResult] {
        let searchConditions = makeBoundaryMapSearchConditions(
            expression: expression,
            attachmentAlias: "bq",
            instanceAlias: "bi",
            boundaryAlias: "b",
            directionalAlias: "bq",
            includeBoundaryName: true
        )
        let whereClause = searchConditions.sql.isEmpty ? "" : "\nWHERE \(searchConditions.sql)"

        struct Row: FetchableRecord, Decodable {
            let instanceID: Int64
            let attachmentID: Int64
            let boundaryName: String
            let title: String
            let isReverse: Bool
        }

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT
                    bq.instance_id AS instanceID,
                    bq.id AS attachmentID,
                    COALESCE(b.name, '') AS boundaryName,
                    COALESCE(bi.title, '') AS title,
                    bq.is_reverse AS isReverse
                FROM \(Self.boundaryMapDirectionalFrom) AS bq
                JOIN boundarymap_instance AS bi
                    ON bi.instance_id = bq.instance_id
                JOIN boundary AS b
                    ON b.id = bq.boundary_id\(whereClause)
                ORDER BY bi.title COLLATE NOCASE, b.name COLLATE NOCASE, bq.id, bq.is_reverse
                """,
            arguments: searchConditions.arguments
        )

        return rows.map { row in
            QuerySearchResult(
                instanceID: row.instanceID,
                queryTypeID: row.attachmentID,
                displayValue: row.title,
                queryTypeName: row.boundaryName + (row.isReverse ? " (Reverse)" : " (Forward)"),
                isReverse: row.isReverse
            )
        }
    }

    private func fetchBoundaryMapTypeInstancesPageData(
        db: Database,
        expression: SearchExpression? = nil
    ) throws -> TypeInstancesPageData {
        struct BoundaryMapInstancesRow: FetchableRecord, Decodable {
            let instanceID: Int64
            let title: String
            let boundaryCount: Int
        }

        let searchConditions = makeBoundaryMapSearchConditions(
            expression: expression,
            attachmentAlias: "bq",
            instanceAlias: "bi",
            boundaryAlias: "b",
            directionalAlias: nil,
            includeBoundaryName: false
        )
        let whereClause = searchConditions.sql.isEmpty ? "" : "\nWHERE \(searchConditions.sql)"

        let rows = try BoundaryMapInstancesRow.fetchAll(
            db,
            sql: """
                SELECT
                    bi.instance_id AS instanceID,
                    COALESCE(bi.title, '') AS title,
                    (SELECT COUNT(*) FROM boundarymap_attachment AS bq WHERE bq.instance_id = bi.instance_id) AS boundaryCount
                FROM boundarymap_instance AS bi\(whereClause)
                ORDER BY bi.title COLLATE NOCASE, bi.instance_id
                """,
            arguments: searchConditions.arguments
        )

        let pageRows = rows.map { row in
            let label = "\(row.title) (\(row.boundaryCount) \(row.boundaryCount == 1 ? "query" : "queries"))"
            return TypeInstancesPageRow(
                id: row.instanceID,
                displayValue: label,
                enabledQueryTypeIDs: []
            )
        }

        return TypeInstancesPageData(
            displayFieldName: "Name",
            queryTypes: [],
            rows: pageRows
        )
    }

    private func fetchBoundaryMapStudyRows(
        db: Database,
        parsedQuery: QuerySearchQuery,
        whereSQL: String,
        additionalArguments: StatementArguments
    ) throws -> [BoundaryMapStudyRow] {
        let searchConditions = makeBoundaryMapSearchConditions(
            expression: parsedQuery.expression,
            attachmentAlias: "bq",
            instanceAlias: "bi",
            boundaryAlias: "b",
            directionalAlias: "bq",
            includeBoundaryName: true
        )
        var arguments = searchConditions.arguments
        arguments += additionalArguments
        let searchSQL = searchConditions.sql.isEmpty ? whereSQL : "(\(searchConditions.sql)) AND (\(whereSQL))"

        return try BoundaryMapStudyRow.fetchAll(
            db,
            sql: """
                SELECT
                    bq.id AS attachmentID,
                    bq.instance_id AS instanceID,
                    bq.boundary_id AS boundaryID,
                    COALESCE(b.name, '') AS boundaryName,
                    bq.interval AS interval,
                    bq.last_answered_timestamp AS lastAnsweredTimestamp,
                    bq.query_state AS queryState,
                    bq.is_reverse AS isReverse,
                    bi.title AS title,
                    bi.default_center_lat AS defaultCenterLat,
                    bi.default_center_lng AS defaultCenterLng,
                    bi.default_zoom AS defaultZoom,
                    bi.show_all_boundaries_in_question AS showAllBoundariesInQuestion
                FROM \(Self.boundaryMapDirectionalFrom) AS bq
                JOIN boundarymap_instance AS bi
                    ON bi.instance_id = bq.instance_id
                JOIN boundary AS b
                    ON b.id = bq.boundary_id
                WHERE \(searchSQL)
                ORDER BY bq.instance_id, bq.id, bq.is_reverse
                """,
            arguments: arguments
        )
    }

    private func fetchBoundaryMapStudyQueries(
        db: Database,
        parsedQuery: QuerySearchQuery,
        whereSQL: String,
        additionalArguments: StatementArguments
    ) throws -> [StudyQuery] {
        let rows = try fetchBoundaryMapStudyRows(
            db: db,
            parsedQuery: parsedQuery,
            whereSQL: whereSQL,
            additionalArguments: additionalArguments
        )

        // Cache attached geometries + queryable ids per instance — cost paid
        // once per unique instance instead of once per query row.
        var geometriesByInstanceID: [Int64: [BoundaryGeometry]] = [:]
        var queryableIDsByInstanceID: [Int64: Set<Int64>] = [:]
        return try rows.map { row in
            let geometries: [BoundaryGeometry]
            if let cached = geometriesByInstanceID[row.instanceID] {
                geometries = cached
            } else {
                geometries = try Self.fetchBoundaryMapAttachedGeometries(db: db, instanceID: row.instanceID)
                geometriesByInstanceID[row.instanceID] = geometries
            }
            let queryableIDs: Set<Int64>
            if let cached = queryableIDsByInstanceID[row.instanceID] {
                queryableIDs = cached
            } else {
                queryableIDs = try Self.fetchBoundaryMapQueryableBoundaryIDs(db: db, instanceID: row.instanceID)
                queryableIDsByInstanceID[row.instanceID] = queryableIDs
            }
            let payload = BoundaryMapStudyPayload(
                attachmentID: row.attachmentID,
                boundaryID: row.boundaryID,
                boundaryName: row.boundaryName,
                instanceTitle: row.title,
                geometries: geometries,
                queryableBoundaryIDs: queryableIDs,
                defaultCenterLat: row.defaultCenterLat,
                defaultCenterLng: row.defaultCenterLng,
                defaultZoom: row.defaultZoom,
                showAllBoundariesInQuestion: row.showAllBoundariesInQuestion,
                isReverse: row.isReverse
            )
            return StudyQuery(
                instanceID: row.instanceID,
                queryTypeID: row.attachmentID,
                interval: row.interval,
                maxInterval: nil,
                lastAnsweredTimestamp: row.lastAnsweredTimestamp,
                queryState: QueryState(rawValue: row.queryState) ?? .zero,
                typeName: BOUNDARYMAP_TYPE_NAME,
                queryTypeName: row.boundaryName,
                questionHTML: "",
                answerHTML: "",
                typeCSS: "",
                fieldValuesByName: [:],
                kind: .boundaryMap,
                boundaryMapPayload: payload,
                isReverse: row.isReverse
            )
        }
    }

    private func fetchBoundaryMapStudyQueryCount(
        db: Database,
        parsedQuery: QuerySearchQuery,
        whereSQL: String,
        additionalArguments: StatementArguments
    ) throws -> Int {
        let searchConditions = makeBoundaryMapSearchConditions(
            expression: parsedQuery.expression,
            attachmentAlias: "bq",
            instanceAlias: "bi",
            boundaryAlias: "b",
            directionalAlias: "bq",
            includeBoundaryName: true
        )
        var arguments = searchConditions.arguments
        arguments += additionalArguments
        let searchSQL = searchConditions.sql.isEmpty ? whereSQL : "(\(searchConditions.sql)) AND (\(whereSQL))"

        return try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM \(Self.boundaryMapDirectionalFrom) AS bq
                JOIN boundarymap_instance AS bi
                    ON bi.instance_id = bq.instance_id
                JOIN boundary AS b
                    ON b.id = bq.boundary_id
                WHERE \(searchSQL)
                """,
            arguments: arguments
        ) ?? 0
    }

    private func fetchBoundaryMapStudySummary(
        db: Database,
        parsedQuery: QuerySearchQuery
    ) throws -> BoundaryMapStudySummary {
        let searchConditions = makeBoundaryMapSearchConditions(
            expression: parsedQuery.expression,
            attachmentAlias: "bq",
            instanceAlias: "bi",
            boundaryAlias: "b",
            directionalAlias: "bq",
            includeBoundaryName: true
        )
        let whereClause = searchConditions.sql.isEmpty ? "" : "\nWHERE \(searchConditions.sql)"

        struct Row: FetchableRecord, Decodable {
            let totalCount: Int
            let newCount: Int
            let minimumSeenDueTimestamp: Int64?
        }

        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT
                    COUNT(*) AS totalCount,
                    COALESCE(SUM(CASE WHEN bq.interval = 0 THEN 1 ELSE 0 END), 0) AS newCount,
                    MIN(CASE WHEN bq.interval != 0 THEN bq.last_answered_timestamp + bq.interval END) AS minimumSeenDueTimestamp
                FROM \(Self.boundaryMapDirectionalFrom) AS bq
                JOIN boundarymap_instance AS bi
                    ON bi.instance_id = bq.instance_id
                JOIN boundary AS b
                    ON b.id = bq.boundary_id\(whereClause)
                """,
            arguments: searchConditions.arguments
        ) ?? Row(totalCount: 0, newCount: 0, minimumSeenDueTimestamp: nil)

        return BoundaryMapStudySummary(
            totalCount: row.totalCount,
            newCount: row.newCount,
            seenCount: row.totalCount - row.newCount,
            minimumSeenDueTimestamp: row.minimumSeenDueTimestamp
        )
    }

    private func fetchRandomBoundaryMapStudyQuery(
        db: Database,
        parsedQuery: QuerySearchQuery,
        whereSQL: String,
        additionalArguments: StatementArguments
    ) throws -> StudyQuery {
        let matchingCount = try fetchBoundaryMapStudyQueryCount(
            db: db,
            parsedQuery: parsedQuery,
            whereSQL: whereSQL,
            additionalArguments: additionalArguments
        )
        guard matchingCount > 0 else {
            throw DatabaseError(message: "No BoundaryMap study query matched the requested criteria.")
        }

        let searchConditions = makeBoundaryMapSearchConditions(
            expression: parsedQuery.expression,
            attachmentAlias: "bq",
            instanceAlias: "bi",
            boundaryAlias: "b",
            directionalAlias: "bq",
            includeBoundaryName: true
        )
        var arguments = searchConditions.arguments
        arguments += additionalArguments
        let searchSQL = searchConditions.sql.isEmpty ? whereSQL : "(\(searchConditions.sql)) AND (\(whereSQL))"
        arguments += [Int.random(in: 0..<matchingCount)]

        guard let row = try BoundaryMapStudyRow.fetchOne(
            db,
            sql: """
                SELECT
                    bq.id AS attachmentID,
                    bq.instance_id AS instanceID,
                    bq.boundary_id AS boundaryID,
                    COALESCE(b.name, '') AS boundaryName,
                    bq.interval AS interval,
                    bq.last_answered_timestamp AS lastAnsweredTimestamp,
                    bq.query_state AS queryState,
                    bq.is_reverse AS isReverse,
                    bi.title AS title,
                    bi.default_center_lat AS defaultCenterLat,
                    bi.default_center_lng AS defaultCenterLng,
                    bi.default_zoom AS defaultZoom,
                    bi.show_all_boundaries_in_question AS showAllBoundariesInQuestion
                FROM \(Self.boundaryMapDirectionalFrom) AS bq
                JOIN boundarymap_instance AS bi
                    ON bi.instance_id = bq.instance_id
                JOIN boundary AS b
                    ON b.id = bq.boundary_id
                WHERE \(searchSQL)
                ORDER BY bq.instance_id, bq.id, bq.is_reverse
                LIMIT 1 OFFSET ?
                """,
            arguments: arguments
        ) else {
            throw DatabaseError(message: "Failed to fetch selected BoundaryMap study query.")
        }

        let geometries = try Self.fetchBoundaryMapAttachedGeometries(db: db, instanceID: row.instanceID)
        let payload = BoundaryMapStudyPayload(
            attachmentID: row.attachmentID,
            boundaryID: row.boundaryID,
            boundaryName: row.boundaryName,
            instanceTitle: row.title,
            geometries: geometries,
            queryableBoundaryIDs: try Self.fetchBoundaryMapQueryableBoundaryIDs(db: db, instanceID: row.instanceID),
            defaultCenterLat: row.defaultCenterLat,
            defaultCenterLng: row.defaultCenterLng,
            defaultZoom: row.defaultZoom,
            showAllBoundariesInQuestion: row.showAllBoundariesInQuestion,
            isReverse: row.isReverse
        )
        return StudyQuery(
            instanceID: row.instanceID,
            queryTypeID: row.attachmentID,
            interval: row.interval,
            maxInterval: nil,
            lastAnsweredTimestamp: row.lastAnsweredTimestamp,
            queryState: QueryState(rawValue: row.queryState) ?? .zero,
            typeName: BOUNDARYMAP_TYPE_NAME,
            queryTypeName: row.boundaryName,
            questionHTML: "",
            answerHTML: "",
            typeCSS: "",
            fieldValuesByName: [:],
            kind: .boundaryMap,
            boundaryMapPayload: payload,
            isReverse: row.isReverse
        )
    }

    private func fetchBoundaryMapQueryPreview(db: Database, instanceID: Int64, attachmentID: Int64?) throws -> StudyQuery? {
        struct BoundaryMapInstanceRow: FetchableRecord, Decodable {
            let title: String
            let defaultCenterLat: Double
            let defaultCenterLng: Double
            let defaultZoom: Double
            let showAllBoundariesInQuestion: Bool
        }
        guard let instanceRow = try BoundaryMapInstanceRow.fetchOne(
            db,
            sql: """
                SELECT
                    COALESCE(title, '') AS title,
                    default_center_lat AS defaultCenterLat,
                    default_center_lng AS defaultCenterLng,
                    default_zoom AS defaultZoom,
                    show_all_boundaries_in_question AS showAllBoundariesInQuestion
                FROM boundarymap_instance
                WHERE instance_id = ?
                """,
            arguments: [instanceID]
        ) else {
            return nil
        }

        let geometries = try Self.fetchBoundaryMapAttachedGeometries(db: db, instanceID: instanceID)

        let highlighted: (attachmentID: Int64, boundaryID: Int64, name: String)?
        if let attachmentID {
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT bq.boundary_id AS boundaryID, COALESCE(b.name, '') AS name
                    FROM boundarymap_attachment AS bq
                    JOIN boundary AS b ON b.id = bq.boundary_id
                    WHERE bq.id = ? AND bq.instance_id = ?
                    """,
                arguments: [attachmentID, instanceID]
            ) else {
                return nil
            }
            highlighted = (
                attachmentID: attachmentID,
                boundaryID: row["boundaryID"] as Int64? ?? 0,
                name: row["name"] as String? ?? ""
            )
        } else {
            highlighted = nil
        }

        let payload = BoundaryMapStudyPayload(
            attachmentID: highlighted?.attachmentID ?? 0,
            boundaryID: highlighted?.boundaryID ?? 0,
            boundaryName: highlighted?.name ?? "",
            instanceTitle: instanceRow.title,
            geometries: geometries,
            queryableBoundaryIDs: try Self.fetchBoundaryMapQueryableBoundaryIDs(db: db, instanceID: instanceID),
            defaultCenterLat: instanceRow.defaultCenterLat,
            defaultCenterLng: instanceRow.defaultCenterLng,
            defaultZoom: instanceRow.defaultZoom,
            showAllBoundariesInQuestion: instanceRow.showAllBoundariesInQuestion,
            showHighlight: highlighted != nil
        )
        return StudyQuery(
            instanceID: instanceID,
            queryTypeID: highlighted?.attachmentID ?? 0,
            interval: 0,
            maxInterval: nil,
            lastAnsweredTimestamp: nil,
            queryState: .zero,
            typeName: BOUNDARYMAP_TYPE_NAME,
            queryTypeName: instanceRow.title,
            questionHTML: "",
            answerHTML: "",
            typeCSS: "",
            fieldValuesByName: [:],
            kind: .boundaryMap,
            boundaryMapPayload: payload
        )
    }

    private func chooseTypeSummary(
        from summaries: [StudyTypeSummary],
        totalWeight: Int,
        weight: KeyPath<StudyTypeSummary, Int>
    ) throws -> StudyTypeSummary {
        guard totalWeight > 0 else {
            throw DatabaseError(message: "No study query matched the requested criteria.")
        }

        var randomIndex = Int.random(in: 0..<totalWeight)
        for summary in summaries {
            let summaryWeight = summary[keyPath: weight]
            guard summaryWeight > 0 else { continue }

            if randomIndex < summaryWeight {
                return summary
            }

            randomIndex -= summaryWeight
        }

        throw DatabaseError(message: "Failed to choose a study query.")
    }

    private func parseInstanceSearchQuery(_ query: String) throws -> InstanceSearchQuery {
        let tokens = try tokenizeSearchQueryComponents(query)
        return InstanceSearchQuery(expression: try parseSearchExpression(tokens, allowsNoQueries: true, allowsNew: false))
    }

    nonisolated func parseQuerySearchQuery(_ query: String) throws -> QuerySearchQuery {
        let tokens = try tokenizeSearchQueryComponents(query)
        return QuerySearchQuery(expression: try parseSearchExpression(tokens, allowsNoQueries: false, allowsNew: true))
    }

    private func parseMapElementSearchQuery(_ query: String) throws -> MapElementSearchQuery {
        let tokens = try tokenizeSearchQueryComponents(query)
        return MapElementSearchQuery(expression: try parseSearchExpression(
            tokens, allowsNoQueries: false, allowsNew: false, allowsTypeCollectionId: false))
    }

    nonisolated private func tokenizeSearchQueryComponents(_ query: String) throws -> [String] {
        var tokens: [String] = []
        var currentToken = ""
        var isInsideQuotes = false

        func flushCurrentToken() {
            guard !currentToken.isEmpty else { return }
            tokens.append(currentToken)
            currentToken = ""
        }

        for character in query {
            if character == "\"" {
                isInsideQuotes.toggle()
                continue
            }

            if !isInsideQuotes && (character == "(" || character == ")") {
                flushCurrentToken()
                tokens.append(String(character))
                continue
            }

            if character.isWhitespace && !isInsideQuotes {
                flushCurrentToken()
                continue
            }

            currentToken.append(character)
        }

        guard !isInsideQuotes else {
            throw DatabaseError(message: "Search query has an unmatched double quote.")
        }

        flushCurrentToken()
        return tokens
    }

    nonisolated private func parseSearchExpression(_ tokens: [String], allowsNoQueries: Bool, allowsNew: Bool, allowsTypeCollectionId: Bool = true) throws -> SearchExpression? {
        struct Parser {
            let tokens: [String]
            let allowsNoQueries: Bool
            let allowsNew: Bool
            let allowsTypeCollectionId: Bool
            var index = 0

            mutating func parseExpression() throws -> SearchExpression? {
                try parseOrExpression()
            }

            mutating func parseOrExpression() throws -> SearchExpression? {
                guard var expression = try parseAndExpression() else { return nil }

                while currentToken == "OR" {
                    index += 1
                    guard let rightExpression = try parseAndExpression() else {
                        throw DatabaseError(message: "The OR operator requires an expression on both sides.")
                    }
                    expression = .or(expression, rightExpression)
                }

                return expression
            }

            mutating func parseAndExpression() throws -> SearchExpression? {
                guard var expression = try parsePrimaryExpression() else { return nil }

                while let token = currentToken, token != "OR", token != ")" {
                    guard let rightExpression = try parsePrimaryExpression() else { break }
                    expression = .and(expression, rightExpression)
                }

                return expression
            }

            mutating func parsePrimaryExpression() throws -> SearchExpression? {
                guard let token = currentToken else { return nil }

                if token == "(" {
                    index += 1
                    guard let expression = try parseOrExpression() else {
                        throw DatabaseError(message: "Parentheses must contain a search expression.")
                    }
                    guard currentToken == ")" else {
                        throw DatabaseError(message: "Search query has an unmatched parenthesis.")
                    }
                    index += 1
                    return expression
                }

                if token == ")" {
                    return nil
                }

                if token == "OR" {
                    throw DatabaseError(message: "The OR operator must appear between two search expressions.")
                }

                if token == "NOT" {
                    index += 1
                    guard let inner = try parsePrimaryExpression() else {
                        throw DatabaseError(message: "The NOT operator requires an expression after it.")
                    }
                    return .not(inner)
                }

                index += 1
                return try parseSearchComponent(token)
            }

            mutating func parseSearchComponent(_ token: String) throws -> SearchExpression {
                if token == ":noqueries" {
                    guard allowsNoQueries else {
                        throw DatabaseError(message: "The :noqueries component can only be used when searching instances.")
                    }
                    return .noQueries
                } else if token == ":new" {
                    guard allowsNew else {
                        throw DatabaseError(message: "The :new component can only be used when searching queries.")
                    }
                    return .new
                } else if token.hasPrefix("literal:") {
                    let literal = String(token.dropFirst("literal:".count))
                    guard !literal.isEmpty else {
                        throw DatabaseError(message: "The literal: component requires text after the colon.")
                    }
                    return .literal(literal)
                } else if token.hasPrefix("collection:") {
                    guard allowsTypeCollectionId else {
                        throw DatabaseError(message: "The collection: component cannot be used when searching points and boundaries.")
                    }
                    return try Self.parseCollectionComponent(
                        argument: String(token.dropFirst("collection:".count)),
                        componentName: "collection:"
                    )
                } else if token.hasPrefix("col:") {
                    guard allowsTypeCollectionId else {
                        throw DatabaseError(message: "The col: component cannot be used when searching points and boundaries.")
                    }
                    return try Self.parseCollectionComponent(
                        argument: String(token.dropFirst("col:".count)),
                        componentName: "col:"
                    )
                } else if token.hasPrefix("type:") {
                    guard allowsTypeCollectionId else {
                        throw DatabaseError(message: "The type: component cannot be used when searching points and boundaries.")
                    }
                    return try Self.parseTypeComponent(argument: String(token.dropFirst("type:".count)))
                } else if token.hasPrefix("id:") {
                    guard allowsTypeCollectionId else {
                        throw DatabaseError(message: "The id: component cannot be used when searching points and boundaries.")
                    }
                    let idString = String(token.dropFirst("id:".count))
                    guard !idString.isEmpty else {
                        throw DatabaseError(message: "The id: component requires an integer ID.")
                    }
                    guard let id = Int64(idString) else {
                        throw DatabaseError(message: "The id: component requires an integer ID.")
                    }
                    return .id(id)
                } else if token.hasPrefix("qt:") {
                    guard allowsTypeCollectionId else {
                        throw DatabaseError(message: "The qt: component cannot be used when searching points and boundaries.")
                    }
                    return try Self.parseQueryTypeComponent(argument: String(token.dropFirst("qt:".count)))
                } else if token.hasPrefix("office:") {
                    guard allowsTypeCollectionId else {
                        throw DatabaseError(message: "The office: component cannot be used when searching points and boundaries.")
                    }
                    // Name only — no ID variant: unlike type/collection names,
                    // office names MAY start with a digit, so office:123 must
                    // read as a name and an ID form would be ambiguous.
                    let officeName = String(token.dropFirst("office:".count))
                    guard !officeName.isEmpty else {
                        throw DatabaseError(message: "The office: component requires an office name.")
                    }
                    return .office(officeName)
                } else if !token.contains(":") {
                    return .literal(token)
                } else {
                    throw DatabaseError(message: "Unsupported search component: \(token)")
                }
            }

            var currentToken: String? {
                guard index < tokens.count else { return nil }
                return tokens[index]
            }

            // Parses a `collection:`/`col:` argument. A leading digit means a collection ID
            // (e.g. `col:67`); otherwise it's a collection name. Collection names can never
            // start with a digit (enforced on create/rename), so this is unambiguous.
            static func parseCollectionComponent(argument: String, componentName: String) throws -> SearchExpression {
                guard !argument.isEmpty else {
                    throw DatabaseError(message: "The \(componentName) component requires a collection name or ID.")
                }
                if let first = argument.first, first.isNumber {
                    guard let collectionID = Int64(argument) else {
                        throw DatabaseError(message: "The \(componentName) component requires a valid integer collection ID.")
                    }
                    return .collectionID(collectionID)
                }
                return .collection(argument)
            }

            // Parses a `type:` argument. A leading digit means a type ID (e.g.
            // `type:5`); otherwise it's a type name. Type names can never start
            // with a digit (enforced on create/rename), so this is unambiguous.
            static func parseTypeComponent(argument: String) throws -> SearchExpression {
                guard !argument.isEmpty else {
                    throw DatabaseError(message: "The type: component requires a type name or ID.")
                }
                if let first = argument.first, first.isNumber {
                    guard let typeID = Int64(argument) else {
                        throw DatabaseError(message: "The type: component requires a valid integer type ID.")
                    }
                    return .typeID(typeID)
                }
                return .type(argument)
            }

            // Parses a `qt:` argument of the form Type:QueryType or TypeID:QueryType.
            // The type part may not contain a colon; the query-type part may. A leading
            // digit means a type ID, like parseCollectionComponent (type names can
            // never start with a digit — enforced on create/rename — so this is
            // unambiguous).
            static func parseQueryTypeComponent(argument: String) throws -> SearchExpression {
                guard let colonIndex = argument.firstIndex(of: ":") else {
                    throw DatabaseError(message: "The qt: component requires a type and a query type separated by a colon, e.g. qt:Vocab:ToDefinition.")
                }
                let typeArgument = String(argument[..<colonIndex])
                let queryTypeName = String(argument[argument.index(after: colonIndex)...])
                guard !typeArgument.isEmpty else {
                    throw DatabaseError(message: "The qt: component requires a type name or ID before the second colon.")
                }
                guard !queryTypeName.isEmpty else {
                    throw DatabaseError(message: "The qt: component requires a query type name after the second colon.")
                }
                if let first = typeArgument.first, first.isNumber {
                    guard let typeID = Int64(typeArgument) else {
                        throw DatabaseError(message: "The qt: component requires a valid integer type ID.")
                    }
                    return .queryTypeID(typeID: typeID, queryTypeName: queryTypeName)
                }
                return .queryType(typeName: typeArgument, queryTypeName: queryTypeName)
            }
        }

        var parser = Parser(tokens: tokens, allowsNoQueries: allowsNoQueries, allowsNew: allowsNew, allowsTypeCollectionId: allowsTypeCollectionId)
        let expression = try parser.parseExpression()
        guard parser.index == tokens.count else {
            throw DatabaseError(message: "Search query has an unmatched parenthesis.")
        }
        return expression
    }

    private func makeInstanceSearchConditions(
        tableAlias: String,
        typeName: String,
        typeID: Int64,
        fieldIndices: [Int],
        expression: SearchExpression?
    ) -> (sql: String, arguments: StatementArguments) {
        makeSearchConditions(
            tableAlias: tableAlias,
            typeName: typeName,
            typeID: typeID,
            fieldIndices: fieldIndices,
            expression: expression,
            context: .instances
        )
    }

    // `srsAlias` names the table/alias carrying the SRS columns (`query` for
    // standard rows, `pq` for the person_query scans) — `:new` uses it, and
    // `qt:` derives the row-kind context from it ("pq" is the documented
    // person_query seam, see personQueryJoinFrom).
    nonisolated func makeQuerySearchConditions(
        tableAlias: String,
        typeName: String,
        typeID: Int64,
        fieldIndices: [Int],
        expression: SearchExpression?,
        srsAlias: String = "query"
    ) -> (sql: String, arguments: StatementArguments) {
        makeSearchConditions(
            tableAlias: tableAlias,
            typeName: typeName,
            typeID: typeID,
            fieldIndices: fieldIndices,
            expression: expression,
            srsAlias: srsAlias,
            context: srsAlias == "pq" ? .personQueries : .standardQueries
        )
    }

    nonisolated private func makeSearchConditions(
        tableAlias: String,
        typeName: String,
        typeID: Int64,
        fieldIndices: [Int],
        expression: SearchExpression?,
        srsAlias: String = "query",
        context: SearchConditionContext
    ) -> (sql: String, arguments: StatementArguments) {
        guard let expression else {
            return ("", StatementArguments())
        }

        return makeSearchCondition(
            expression,
            tableAlias: tableAlias,
            typeName: typeName,
            typeID: typeID,
            fieldIndices: fieldIndices,
            srsAlias: srsAlias,
            context: context
        )
    }

    nonisolated private func makeSearchCondition(
        _ expression: SearchExpression,
        tableAlias: String,
        typeName: String,
        typeID: Int64,
        fieldIndices: [Int],
        srsAlias: String = "query",
        context: SearchConditionContext
    ) -> (sql: String, arguments: StatementArguments) {
        switch expression {
        case .literal(let literal):
            var arguments = StatementArguments()
            let fieldConditions = fieldIndices.map { fieldIndex in
                "COALESCE(\(tableAlias).\"field\(fieldIndex)\", '') LIKE ? ESCAPE '\\'"
            }
            let escapedLiteral = Self.escapeSQLiteLikePattern(literal)
            let searchPattern = "%\(escapedLiteral)%"
            for _ in fieldIndices {
                arguments += [searchPattern]
            }
            return ("(\(fieldConditions.joined(separator: " OR ")))", arguments)

        case .collection(let collectionName):
            var arguments = StatementArguments()
            arguments += [collectionName]
            return (
                """
                EXISTS (
                    SELECT 1
                    FROM instance_id_collection_id
                    JOIN collection
                        ON collection.id = instance_id_collection_id.collection_id
                    WHERE instance_id_collection_id.instance_id = \(tableAlias).id
                        AND collection.name = ? COLLATE NOCASE
                )
                """,
                arguments
            )

        case .collectionID(let collectionID):
            var arguments = StatementArguments()
            arguments += [collectionID]
            return (
                """
                EXISTS (
                    SELECT 1
                    FROM instance_id_collection_id
                    WHERE instance_id_collection_id.instance_id = \(tableAlias).id
                        AND instance_id_collection_id.collection_id = ?
                )
                """,
                arguments
            )

        case .type(let searchedTypeName):
            var arguments = StatementArguments()
            arguments += [typeName, searchedTypeName]
            return ("? = ? COLLATE NOCASE", arguments)

        case .typeID(let searchedTypeID):
            var arguments = StatementArguments()
            arguments += [typeID, searchedTypeID]
            return ("? = ?", arguments)

        case .id(let instanceID):
            var arguments = StatementArguments()
            arguments += [instanceID]
            return ("\(tableAlias).id = ?", arguments)

        case .queryType(let searchedTypeName, let searchedQueryTypeName):
            var typeCompareArguments = StatementArguments()
            typeCompareArguments += [typeName, searchedTypeName]
            return makeQueryTypeCondition(
                typeCompareSQL: "? = ? COLLATE NOCASE",
                typeCompareArguments: typeCompareArguments,
                searchedQueryTypeName: searchedQueryTypeName,
                tableAlias: tableAlias,
                typeID: typeID,
                srsAlias: srsAlias,
                context: context
            )

        case .queryTypeID(let searchedTypeID, let searchedQueryTypeName):
            var typeCompareArguments = StatementArguments()
            typeCompareArguments += [typeID, searchedTypeID]
            return makeQueryTypeCondition(
                typeCompareSQL: "? = ?",
                typeCompareArguments: typeCompareArguments,
                searchedQueryTypeName: searchedQueryTypeName,
                tableAlias: tableAlias,
                typeID: typeID,
                srsAlias: srsAlias,
                context: context
            )

        case .office(let officeName):
            // Matches by HOLDING (person_office), not by per-office query
            // enablement — the qt: office-name form covers that. Holdings live
            // only on Person instances, so the clause is inert for every other
            // type (same precedent as .noQueries' person clause). In query
            // contexts this matches ALL of a holder's queries, like
            // .collection.
            var arguments = StatementArguments()
            arguments += [officeName]
            return (
                """
                EXISTS (
                    SELECT 1
                    FROM person_office
                    JOIN office
                        ON office.id = person_office.office_id
                    WHERE person_office.instance_id = \(tableAlias).id
                        AND office.name = ? COLLATE NOCASE
                )
                """,
                arguments
            )

        case .noQueries:
            // Built-in Person relationship queries count as queries too; other
            // types never have person_query rows, so the extra clause is inert.
            return (
                """
                NOT EXISTS (
                    SELECT 1
                    FROM query
                    WHERE query.instance_id = \(tableAlias).id
                )
                AND NOT EXISTS (
                    SELECT 1
                    FROM person_query
                    WHERE person_query.instance_id = \(tableAlias).id
                )
                """,
                StatementArguments()
            )

        case .new:
            return ("\(srsAlias).interval = 0", StatementArguments())

        case .and(let leftExpression, let rightExpression):
            let left = makeSearchCondition(leftExpression, tableAlias: tableAlias, typeName: typeName, typeID: typeID, fieldIndices: fieldIndices, srsAlias: srsAlias, context: context)
            let right = makeSearchCondition(rightExpression, tableAlias: tableAlias, typeName: typeName, typeID: typeID, fieldIndices: fieldIndices, srsAlias: srsAlias, context: context)
            var arguments = left.arguments
            arguments += right.arguments
            return ("(\(left.sql)) AND (\(right.sql))", arguments)

        case .or(let leftExpression, let rightExpression):
            let left = makeSearchCondition(leftExpression, tableAlias: tableAlias, typeName: typeName, typeID: typeID, fieldIndices: fieldIndices, srsAlias: srsAlias, context: context)
            let right = makeSearchCondition(rightExpression, tableAlias: tableAlias, typeName: typeName, typeID: typeID, fieldIndices: fieldIndices, srsAlias: srsAlias, context: context)
            var arguments = left.arguments
            arguments += right.arguments
            return ("(\(left.sql)) OR (\(right.sql))", arguments)

        case .not(let innerExpression):
            let inner = makeSearchCondition(innerExpression, tableAlias: tableAlias, typeName: typeName, typeID: typeID, fieldIndices: fieldIndices, srsAlias: srsAlias, context: context)
            return ("NOT (\(inner.sql))", inner.arguments)
        }
    }

    // The `qt:` body shared by the name and ID variants — only the type-part
    // compare differs. Per context: instance rows check enablement (a `query`
    // row of a matching query type, OR a matching person_query row — the
    // person clause is inert for non-Person types, same precedent as
    // `.noQueries`); standard query rows check their own query_type via a
    // self-contained EXISTS (several surfaces join `query` but not
    // `query_type`); person_query rows check kind/office.
    nonisolated private func makeQueryTypeCondition(
        typeCompareSQL: String,
        typeCompareArguments: StatementArguments,
        searchedQueryTypeName: String,
        tableAlias: String,
        typeID: Int64,
        srsAlias: String,
        context: SearchConditionContext
    ) -> (sql: String, arguments: StatementArguments) {
        switch context {
        case .instances:
            let personPredicate = Self.personQueryTypePredicate(
                queryTypeName: searchedQueryTypeName,
                alias: "person_query"
            )
            var arguments = typeCompareArguments
            arguments += [typeID, searchedQueryTypeName]
            arguments += personPredicate.arguments
            return (
                """
                (\(typeCompareSQL) AND (
                    EXISTS (
                        SELECT 1
                        FROM query
                        JOIN query_type
                            ON query_type.id = query.query_type_id
                        WHERE query.instance_id = \(tableAlias).id
                            AND query_type.type_id = ?
                            AND query_type.name = ? COLLATE NOCASE
                    )
                    OR EXISTS (
                        SELECT 1
                        FROM person_query
                        WHERE person_query.instance_id = \(tableAlias).id
                            AND \(personPredicate.sql)
                    )
                ))
                """,
                arguments
            )

        case .standardQueries:
            var arguments = typeCompareArguments
            arguments += [typeID, searchedQueryTypeName]
            return (
                """
                (\(typeCompareSQL) AND EXISTS (
                    SELECT 1
                    FROM query_type
                    WHERE query_type.id = \(srsAlias).query_type_id
                        AND query_type.type_id = ?
                        AND query_type.name = ? COLLATE NOCASE
                ))
                """,
                arguments
            )

        case .personQueries:
            let personPredicate = Self.personQueryTypePredicate(
                queryTypeName: searchedQueryTypeName,
                alias: srsAlias
            )
            var arguments = typeCompareArguments
            arguments += personPredicate.arguments
            return ("(\(typeCompareSQL) AND \(personPredicate.sql))", arguments)
        }
    }

    // The person_query predicate for a `qt:` second argument. A fixed
    // PersonQueryKind display name (NOCASE) matches that kind — "Children with"
    // matches every partnership's query and "Office" every holding's — and an
    // office name (NOCASE) matches that office's per-office queries. The
    // alternatives are OR'd, so a name that is both matches either.
    nonisolated static func personQueryTypePredicate(
        queryTypeName: String,
        alias: String
    ) -> (sql: String, arguments: StatementArguments) {
        var arguments = StatementArguments()
        var alternatives: [String] = []
        if let kind = PersonQueryKind.allCases.first(where: { sqliteNocaseEquals($0.displayName, queryTypeName) }) {
            alternatives.append("\(alias).kind = ?")
            arguments += [kind.rawValue]
        }
        alternatives.append("(\(alias).kind = ? AND \(alias).office_id IN (SELECT id FROM office WHERE name = ? COLLATE NOCASE))")
        arguments += [PersonQueryKind.office.rawValue, queryTypeName]
        return ("(\(alternatives.joined(separator: " OR ")))", arguments)
    }

    nonisolated func validateCollectionSearchComponents(
        _ collectionNames: [String],
        db: Database
    ) throws {
        for collectionName in Set(collectionNames) {
            let matchingCollectionName = try String.fetchOne(
                db,
                sql: """
                    SELECT name
                    FROM collection
                    WHERE name = ? COLLATE NOCASE
                    """,
                arguments: [collectionName]
            )

            if matchingCollectionName == nil {
                throw DatabaseError(message: "Collection does not exist: \(collectionName)")
            }
        }
    }

    nonisolated private static func escapeSQLiteLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    nonisolated static func collectionNames(in expression: SearchExpression?) -> [String] {
        guard let expression else { return [] }

        switch expression {
        case .literal, .type, .typeID, .id, .noQueries, .new, .collectionID, .queryType, .queryTypeID, .office:
            return []
        case .collection(let collectionName):
            return [collectionName]
        case .and(let leftExpression, let rightExpression), .or(let leftExpression, let rightExpression):
            return collectionNames(in: leftExpression) + collectionNames(in: rightExpression)
        case .not(let innerExpression):
            return collectionNames(in: innerExpression)
        }
    }

    nonisolated static func officeNames(in expression: SearchExpression?) -> [String] {
        guard let expression else { return [] }

        switch expression {
        case .literal, .type, .typeID, .id, .noQueries, .new, .collection, .collectionID, .queryType, .queryTypeID:
            return []
        case .office(let officeName):
            return [officeName]
        case .and(let leftExpression, let rightExpression), .or(let leftExpression, let rightExpression):
            return officeNames(in: leftExpression) + officeNames(in: rightExpression)
        case .not(let innerExpression):
            return officeNames(in: innerExpression)
        }
    }

    /// Mirrors validateCollectionSearchComponents for `office:` — a friendly
    /// error beats silently matching nothing when the name is mistyped.
    nonisolated func validateOfficeSearchComponents(
        _ officeNames: [String],
        db: Database
    ) throws {
        for officeName in Set(officeNames) {
            let matchingOfficeName = try String.fetchOne(
                db,
                sql: """
                    SELECT name
                    FROM office
                    WHERE name = ? COLLATE NOCASE
                    """,
                arguments: [officeName]
            )

            if matchingOfficeName == nil {
                throw DatabaseError(message: "Office does not exist: \(officeName)")
            }
        }
    }
}
