//
//  AppDatabase+Schema.swift
//  Memor
//
//  One-shot schema creation. Extracted from AppDatabase.swift for readability.
//

import Foundation
import GRDB

extension AppDatabase {
    static func createSchema(in dbQueue: DatabaseQueue, isNewDatabase: Bool) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS "type" (
                    id INTEGER PRIMARY KEY,
                    name TEXT,
                    description TEXT,
                    css TEXT,
                    is_builtin INTEGER NOT NULL DEFAULT 0,
                    kind TEXT NOT NULL DEFAULT 'object'
                ) STRICT
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS field (
                    id INTEGER PRIMARY KEY,
                    type_id INTEGER NOT NULL REFERENCES "type"(id),
                    name TEXT,
                    field_index INTEGER,
                    field_display_index INTEGER,
                    is_primary INTEGER NOT NULL DEFAULT 0,
                    field_type TEXT NOT NULL DEFAULT 'text'
                ) STRICT
                """)

            // Link fields belong to Node types only. Created before query_type so
            // the query_type.link_field_id foreign key target exists.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS link_field (
                    id INTEGER PRIMARY KEY,
                    type_id INTEGER NOT NULL REFERENCES "type"(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    is_parent INTEGER NOT NULL DEFAULT 0,
                    min_count INTEGER NOT NULL DEFAULT 0,
                    max_count INTEGER,
                    link_field_index INTEGER NOT NULL
                ) STRICT
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS query_type (
                    id INTEGER PRIMARY KEY,
                    type_id INTEGER NOT NULL REFERENCES "type"(id),
                    name TEXT,
                    question_html TEXT,
                    answer_html TEXT,
                    link_field_id INTEGER REFERENCES link_field(id) ON DELETE CASCADE
                ) STRICT
                """)

            try migrateNodeTypeColumns(db: db)
            try migrateTypeDescriptionColumn(db: db)
            try migrateFieldTypeColumn(db: db)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS globals (
                    name TEXT PRIMARY KEY,
                    value TEXT
                ) STRICT
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS collection (
                    id INTEGER PRIMARY KEY,
                    name TEXT,
                    description TEXT,
                    visible_before_answer INTEGER NOT NULL DEFAULT 1
                ) STRICT
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS instance_id_type_id (
                    instance_id INTEGER PRIMARY KEY,
                    type_id INTEGER REFERENCES "type"(id)
                ) STRICT
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS instance_id_collection_id (
                    instance_id INTEGER REFERENCES instance_id_type_id(instance_id) ON DELETE CASCADE,
                    collection_id INTEGER REFERENCES collection(id) ON DELETE CASCADE
                ) STRICT
                """)

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_instance_collection_instance
                    ON instance_id_collection_id(instance_id, collection_id)
                """)

            // Directed edges between instances of a Node type. Cascades clean up
            // edges when either endpoint instance, or the link field, is deleted.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS node_link (
                    id INTEGER PRIMARY KEY,
                    source_instance_id INTEGER NOT NULL
                        REFERENCES instance_id_type_id(instance_id) ON DELETE CASCADE,
                    link_field_id INTEGER NOT NULL
                        REFERENCES link_field(id) ON DELETE CASCADE,
                    target_instance_id INTEGER NOT NULL
                        REFERENCES instance_id_type_id(instance_id) ON DELETE CASCADE,
                    order_index INTEGER NOT NULL DEFAULT 0
                ) STRICT
                """)

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_node_link_source
                    ON node_link(source_instance_id, link_field_id)
                """)

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_node_link_target
                    ON node_link(target_instance_id)
                """)
            
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS query (
                    instance_id INTEGER REFERENCES instance_id_type_id(instance_id) ON DELETE CASCADE,
                    query_type_id INTEGER REFERENCES query_type(id) ON DELETE CASCADE,
                    query_state INTEGER NOT NULL DEFAULT 0,
                    last_answered_timestamp INTEGER DEFAULT NULL,
                    interval INTEGER NOT NULL DEFAULT 0,
                    max_interval INTEGER DEFAULT NULL,
                    PRIMARY KEY (instance_id, query_type_id)
                ) STRICT
                """)

            try migrateQueryStateColumn(db: db, table: "query")
            try migrateQueryMaxIntervalColumn(db: db)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS stack (
                    id INTEGER PRIMARY KEY,
                    name TEXT,
                    search TEXT,
                    description TEXT,
                    is_pinned INTEGER NOT NULL DEFAULT 0
                ) STRICT
                """)

            try migrateStackPinnedColumn(db: db)
            try migrateStackDescriptionColumn(db: db)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS image_file (
                    id INTEGER PRIMARY KEY,
                    path TEXT UNIQUE,
                    bookmark_data BLOB
                ) STRICT
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS image_folder (
                    id INTEGER PRIMARY KEY,
                    path TEXT UNIQUE,
                    bookmark_data BLOB
                ) STRICT
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pinned_collection (
                    type_id INTEGER NOT NULL REFERENCES "type"(id) ON DELETE CASCADE,
                    collection_id INTEGER NOT NULL REFERENCES collection(id) ON DELETE CASCADE,
                    PRIMARY KEY (type_id, collection_id)
                ) STRICT
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sticky_field (
                    type_id INTEGER NOT NULL REFERENCES "type"(id) ON DELETE CASCADE,
                    field_id INTEGER NOT NULL,
                    PRIMARY KEY (type_id, field_id)
                ) STRICT
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS type_query_default (
                    type_id INTEGER NOT NULL REFERENCES "type"(id) ON DELETE CASCADE,
                    query_type_id INTEGER NOT NULL REFERENCES query_type(id) ON DELETE CASCADE,
                    is_enabled INTEGER NOT NULL,
                    PRIMARY KEY (type_id, query_type_id)
                ) STRICT
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pointmap_instance (
                    instance_id INTEGER PRIMARY KEY
                        REFERENCES instance_id_type_id(instance_id) ON DELETE CASCADE,
                    title TEXT NOT NULL DEFAULT '',
                    description TEXT NOT NULL DEFAULT '',
                    default_center_lat REAL NOT NULL DEFAULT 0,
                    default_center_lng REAL NOT NULL DEFAULT 0,
                    default_zoom REAL NOT NULL DEFAULT 2,
                    show_all_points_in_question INTEGER NOT NULL DEFAULT 1,
                    point_size TEXT NOT NULL DEFAULT 'medium'
                ) STRICT
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pointmap_point (
                    id INTEGER PRIMARY KEY,
                    instance_id INTEGER NOT NULL
                        REFERENCES pointmap_instance(instance_id) ON DELETE CASCADE,
                    name TEXT NOT NULL DEFAULT '',
                    hint TEXT NOT NULL DEFAULT '',
                    latitude REAL NOT NULL,
                    longitude REAL NOT NULL,
                    interval INTEGER NOT NULL DEFAULT 0,
                    last_answered_timestamp INTEGER DEFAULT NULL,
                    query_state INTEGER NOT NULL DEFAULT 0,
                    forward_enabled INTEGER NOT NULL DEFAULT 1,
                    reverse_enabled INTEGER NOT NULL DEFAULT 0,
                    reverse_interval INTEGER NOT NULL DEFAULT 0,
                    reverse_last_answered_timestamp INTEGER DEFAULT NULL,
                    reverse_query_state INTEGER NOT NULL DEFAULT 0
                ) STRICT
                """)

            try migrateQueryStateColumn(db: db, table: "pointmap_point")
            try migrateReverseQueryColumns(db: db, table: "pointmap_point")
            try migratePointMapPointHintColumn(db: db)
            try migratePointMapInstancePointSizeColumn(db: db)
            try migratePointMapInstanceDescriptionColumn(db: db)

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_pointmap_point_instance
                    ON pointmap_point(instance_id)
                """)

            // Each point has 0, 1, or 2 first-class queries (one per direction).
            // A row's existence == that direction being enabled. The legacy inline
            // SRS columns on pointmap_point are now dormant; the one-time backfill
            // below seeds this table from them.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pointmap_query (
                    id INTEGER PRIMARY KEY,
                    point_id INTEGER NOT NULL
                        REFERENCES pointmap_point(id) ON DELETE CASCADE,
                    is_reverse INTEGER NOT NULL,
                    interval INTEGER NOT NULL DEFAULT 0,
                    last_answered_timestamp INTEGER DEFAULT NULL,
                    query_state INTEGER NOT NULL DEFAULT 0,
                    UNIQUE(point_id, is_reverse)
                ) STRICT
                """)

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_pointmap_query_point
                    ON pointmap_query(point_id)
                """)

            try backfillPointMapQueries(db: db)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS boundary_set (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    is_builtin INTEGER NOT NULL DEFAULT 0,
                    created_at INTEGER NOT NULL
                ) STRICT
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS boundary (
                    id INTEGER PRIMARY KEY,
                    boundary_set_id INTEGER NOT NULL REFERENCES boundary_set(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    geometry_json BLOB NOT NULL
                ) STRICT
                """)

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_boundary_set_id
                    ON boundary(boundary_set_id)
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pointmap_boundary (
                    instance_id INTEGER NOT NULL
                        REFERENCES pointmap_instance(instance_id) ON DELETE CASCADE,
                    boundary_id INTEGER NOT NULL
                        REFERENCES boundary(id) ON DELETE CASCADE,
                    PRIMARY KEY (instance_id, boundary_id)
                ) STRICT
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS boundarymap_instance (
                    instance_id INTEGER PRIMARY KEY
                        REFERENCES instance_id_type_id(instance_id) ON DELETE CASCADE,
                    title TEXT NOT NULL DEFAULT '',
                    description TEXT NOT NULL DEFAULT '',
                    default_center_lat REAL NOT NULL DEFAULT 0,
                    default_center_lng REAL NOT NULL DEFAULT 0,
                    default_zoom REAL NOT NULL DEFAULT 2,
                    show_all_boundaries_in_question INTEGER NOT NULL DEFAULT 1
                ) STRICT
                """)

            // BoundaryMap mirrors PointMap: a boundarymap_attachment is the
            // linkable identity entity (its id is the stable attachmentID used in
            // links/previews), and boundarymap_query holds 0/1/2 first-class
            // directional queries. Historically a single boundarymap_query table
            // doubled as both; this one-time transform splits it, preserving the
            // attachment ids. Must run BEFORE the unconditional CREATE statements
            // below so the rename frees the boundarymap_query name first.
            try migrateBoundaryMapQuerySplit(db: db)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS boundarymap_attachment (
                    id INTEGER PRIMARY KEY,
                    instance_id INTEGER NOT NULL
                        REFERENCES boundarymap_instance(instance_id) ON DELETE CASCADE,
                    boundary_id INTEGER NOT NULL
                        REFERENCES boundary(id) ON DELETE CASCADE,
                    UNIQUE(instance_id, boundary_id)
                ) STRICT
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS boundarymap_query (
                    id INTEGER PRIMARY KEY,
                    attachment_id INTEGER NOT NULL
                        REFERENCES boundarymap_attachment(id) ON DELETE CASCADE,
                    is_reverse INTEGER NOT NULL,
                    interval INTEGER NOT NULL DEFAULT 0,
                    last_answered_timestamp INTEGER DEFAULT NULL,
                    query_state INTEGER NOT NULL DEFAULT 0,
                    UNIQUE(attachment_id, is_reverse)
                ) STRICT
                """)

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_boundarymap_attachment_instance
                    ON boundarymap_attachment(instance_id)
                """)

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_boundarymap_query_attachment
                    ON boundarymap_query(attachment_id)
                """)

            try migrateBoundaryMapInstanceDescriptionColumn(db: db)

            // Seed the built-in PointMap type (idempotent)
            let existingPointMapTypeID = try Int64.fetchOne(
                db,
                sql: """
                    SELECT id FROM "type" WHERE name = ? AND is_builtin = 1
                    """,
                arguments: [POINTMAP_TYPE_NAME]
            )
            if existingPointMapTypeID == nil {
                try db.execute(
                    sql: """
                        INSERT INTO "type" (name, css, is_builtin)
                        VALUES (?, ?, 1)
                        """,
                    arguments: [POINTMAP_TYPE_NAME, ""]
                )
            }

            // Seed the built-in BoundaryMap type (idempotent)
            let existingBoundaryMapTypeID = try Int64.fetchOne(
                db,
                sql: """
                    SELECT id FROM "type" WHERE name = ? AND is_builtin = 1
                    """,
                arguments: [BOUNDARYMAP_TYPE_NAME]
            )
            if existingBoundaryMapTypeID == nil {
                try db.execute(
                    sql: """
                        INSERT INTO "type" (name, css, is_builtin)
                        VALUES (?, ?, 1)
                        """,
                    arguments: [BOUNDARYMAP_TYPE_NAME, ""]
                )
            }

            if isNewDatabase {
                try db.execute(
                    sql: """
                        INSERT INTO globals (name, value)
                        VALUES (?, ?), (?, ?), (?, ?)
                        """,
                    arguments: [
                        "global_query_html",
                        """
                        <main>
                            {{#Content}}
                        </main>
                        """,
                        "global_query_css",
                        """
                        main {
                            display: flex;
                            flex-direction: column;
                            flex-wrap: nowrap;
                            justify-content: center;
                            text-align: center;
                            font-family: Arial;
                            color: white;
                            padding: 16px;
                        }

                        hr {
                            margin-left: 0;
                            margin-right: 0;
                        }
                        
                        img {
                            max-height: 500px;
                            width: auto;
                        }
                        
                        e {
                            color: gray
                        }
                        """,
                        "stacks_last_updated_timestamp",
                        String(Int(Date().timeIntervalSince1970))
                    ]
                )

                try db.execute(
                    sql: """
                        INSERT INTO "type" (name, css)
                        VALUES (?, ?)
                        """,
                    arguments: ["Front+Back", ""]
                )
                let frontBackTypeID = db.lastInsertedRowID

                try db.execute(
                    sql: """
                        INSERT INTO field (type_id, name, field_index, field_display_index)
                        VALUES (?, ?, ?, ?), (?, ?, ?, ?)
                        """,
                    arguments: [frontBackTypeID, "Front", 1, 1, frontBackTypeID, "Back", 2, 2]
                )
                let frontBackFieldIDs = (db.lastInsertedRowID - 1, db.lastInsertedRowID)
                
                try db.execute(
                    sql: """
                        INSERT INTO query_type (type_id, name, question_html, answer_html)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        frontBackTypeID,
                        "Front->Back",
                        "<div>{{Front}}</div>",
                        uniteQuestionAndAnswerWithDefaultSeparator(questionHTML: "{{#QuestionContent}}", answerHTML: "<div>{{Back}}</div>")
                    ]
                )
                
                // Make table for the Front+Back type
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS "type\(frontBackTypeID)" (
                        id INTEGER PRIMARY KEY,
                        field\(frontBackFieldIDs.0) TEXT,
                        field\(frontBackFieldIDs.1) TEXT,
                        FOREIGN KEY (id) REFERENCES instance_id_type_id(instance_id) ON DELETE CASCADE
                    ) STRICT
                    """)

            }

            // Runs on every launch; early-returns when a built-in set already
            // exists, so this is effectively one-shot per database.
            try seedBuiltinCountryBoundaries(in: db)
        }
    }

    // Idempotent: on a fresh DB the new column already exists and the legacy
    // columns are absent, so every branch is a no-op. On a pre-existing DB the
    // new column is added with default 0 and then existing rows are bumped to
    // state 2 (treat the user's current corpus as already-learned), after
    // which the legacy boolean columns are dropped.
    private static func migrateQueryStateColumn(db: Database, table: String) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(table)\")")
        let names = Set(info.compactMap { $0["name"] as String? })

        if !names.contains("query_state") {
            try db.execute(sql: "ALTER TABLE \"\(table)\" ADD COLUMN query_state INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "UPDATE \"\(table)\" SET query_state = 2")
        }
        if names.contains("was_last_answer_correct") {
            try db.execute(sql: "ALTER TABLE \"\(table)\" DROP COLUMN was_last_answer_correct")
        }
        if names.contains("has_been_answered_good_or_higher") {
            try db.execute(sql: "ALTER TABLE \"\(table)\" DROP COLUMN has_been_answered_good_or_higher")
        }
    }

    // Adds the forward/reverse query columns to a map-query table
    // (pointmap_point or boundarymap_query) for databases created before reverse
    // queries existed. Idempotent: each ALTER runs only when its column is
    // absent, so this is a no-op on fresh installs. Existing rows default to
    // forward_enabled = 1, reverse_enabled = 0 — all current queries are forward.
    private static func migrateReverseQueryColumns(db: Database, table: String) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(table)\")")
        let names = Set(info.compactMap { $0["name"] as String? })

        if !names.contains("forward_enabled") {
            try db.execute(sql: "ALTER TABLE \"\(table)\" ADD COLUMN forward_enabled INTEGER NOT NULL DEFAULT 1")
        }
        if !names.contains("reverse_enabled") {
            try db.execute(sql: "ALTER TABLE \"\(table)\" ADD COLUMN reverse_enabled INTEGER NOT NULL DEFAULT 0")
        }
        if !names.contains("reverse_interval") {
            try db.execute(sql: "ALTER TABLE \"\(table)\" ADD COLUMN reverse_interval INTEGER NOT NULL DEFAULT 0")
        }
        if !names.contains("reverse_last_answered_timestamp") {
            try db.execute(sql: "ALTER TABLE \"\(table)\" ADD COLUMN reverse_last_answered_timestamp INTEGER DEFAULT NULL")
        }
        if !names.contains("reverse_query_state") {
            try db.execute(sql: "ALTER TABLE \"\(table)\" ADD COLUMN reverse_query_state INTEGER NOT NULL DEFAULT 0")
        }
    }

    // Adds the is_pinned column to the stack table for databases created before
    // stack pinning existed. Idempotent: the ALTER runs only when the column is
    // absent, so this is a no-op on fresh installs. Existing rows default to
    // is_pinned = 0 — i.e. unpinned.
    // Adds the per-point hint column to databases created before point hints
    // existed. Idempotent: the ALTER runs only when the column is absent, so it's
    // a no-op on fresh installs. Existing rows default to '' (blank hint),
    // preserving all points and their query state.
    private static func migratePointMapPointHintColumn(db: Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(\"pointmap_point\")")
        let names = Set(info.compactMap { $0["name"] as String? })
        if !names.contains("hint") {
            try db.execute(sql: "ALTER TABLE \"pointmap_point\" ADD COLUMN hint TEXT NOT NULL DEFAULT ''")
        }
    }

    // Adds the per-instance point_size column to pointmap_instance for databases
    // created before the Point Size setting existed. Idempotent: the ALTER runs only
    // when the column is absent. Existing rows default to 'medium' (= the historical
    // fixed marker size), so they look identical to before.
    private static func migratePointMapInstancePointSizeColumn(db: Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(\"pointmap_instance\")")
        let names = Set(info.compactMap { $0["name"] as String? })
        if !names.contains("point_size") {
            try db.execute(sql: "ALTER TABLE \"pointmap_instance\" ADD COLUMN point_size TEXT NOT NULL DEFAULT 'medium'")
        }
    }

    // Adds the per-instance description column to pointmap_instance for databases
    // created before instance descriptions existed. Idempotent: the ALTER runs only
    // when the column is absent. Existing rows default to '' (blank note).
    private static func migratePointMapInstanceDescriptionColumn(db: Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(\"pointmap_instance\")")
        let names = Set(info.compactMap { $0["name"] as String? })
        if !names.contains("description") {
            try db.execute(sql: "ALTER TABLE \"pointmap_instance\" ADD COLUMN description TEXT NOT NULL DEFAULT ''")
        }
    }

    // Adds the per-instance description column to boundarymap_instance for databases
    // created before instance descriptions existed. Idempotent: the ALTER runs only
    // when the column is absent. Existing rows default to '' (blank note).
    private static func migrateBoundaryMapInstanceDescriptionColumn(db: Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(\"boundarymap_instance\")")
        let names = Set(info.compactMap { $0["name"] as String? })
        if !names.contains("description") {
            try db.execute(sql: "ALTER TABLE \"boundarymap_instance\" ADD COLUMN description TEXT NOT NULL DEFAULT ''")
        }
    }

    private static func migrateStackPinnedColumn(db: Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(\"stack\")")
        let names = Set(info.compactMap { $0["name"] as String? })
        if !names.contains("is_pinned") {
            try db.execute(sql: "ALTER TABLE \"stack\" ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0")
        }
    }

    // Adds the description column to the stack table for databases created before
    // stack descriptions existed. Idempotent: the ALTER runs only when the column is
    // absent, so this is a no-op on fresh installs. Existing rows default to NULL,
    // which fetchStacks coalesces to an empty string.
    private static func migrateStackDescriptionColumn(db: Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(\"stack\")")
        let names = Set(info.compactMap { $0["name"] as String? })
        if !names.contains("description") {
            try db.execute(sql: "ALTER TABLE \"stack\" ADD COLUMN description TEXT")
        }
    }

    // Adds the description column to the type table for databases created before
    // type descriptions existed. Idempotent: the ALTER runs only when the column is
    // absent, so this is a no-op on fresh installs. Existing rows default to NULL,
    // which the type fetch SELECTs coalesce to an empty string.
    private static func migrateTypeDescriptionColumn(db: Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(\"type\")")
        let names = Set(info.compactMap { $0["name"] as String? })
        if !names.contains("description") {
            try db.execute(sql: "ALTER TABLE \"type\" ADD COLUMN description TEXT")
        }
    }

    // Adds the field.field_type column (text/boolean) to databases created before
    // Boolean fields existed. Idempotent. Existing fields default to 'text', i.e.
    // ordinary free-text fields, unchanged.
    private static func migrateFieldTypeColumn(db: Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(field)")
        let names = Set(info.compactMap { $0["name"] as String? })
        if !names.contains("field_type") {
            try db.execute(sql: "ALTER TABLE field ADD COLUMN field_type TEXT NOT NULL DEFAULT 'text'")
        }
    }

    // Adds the Node-type columns (type.kind, field.is_primary,
    // query_type.link_field_id) to databases created before Node types existed.
    // Idempotent: each ALTER runs only when its column is absent, so this is a
    // no-op on fresh installs. The link_field and node_link tables are created
    // with CREATE TABLE IF NOT EXISTS in createSchema, so no migration is needed
    // for them. Existing rows default to kind = 'object', is_primary = 0,
    // link_field_id = NULL — i.e. ordinary Object types, unchanged.
    private static func migrateNodeTypeColumns(db: Database) throws {
        let typeInfo = try Row.fetchAll(db, sql: "PRAGMA table_info(\"type\")")
        if !Set(typeInfo.compactMap { $0["name"] as String? }).contains("kind") {
            try db.execute(sql: "ALTER TABLE \"type\" ADD COLUMN kind TEXT NOT NULL DEFAULT 'object'")
        }

        let fieldInfo = try Row.fetchAll(db, sql: "PRAGMA table_info(field)")
        if !Set(fieldInfo.compactMap { $0["name"] as String? }).contains("is_primary") {
            try db.execute(sql: "ALTER TABLE field ADD COLUMN is_primary INTEGER NOT NULL DEFAULT 0")
        }

        let queryTypeInfo = try Row.fetchAll(db, sql: "PRAGMA table_info(query_type)")
        if !Set(queryTypeInfo.compactMap { $0["name"] as String? }).contains("link_field_id") {
            try db.execute(sql: "ALTER TABLE query_type ADD COLUMN link_field_id INTEGER REFERENCES link_field(id) ON DELETE CASCADE")
        }
    }

    // Adds the nullable max_interval column to the query table for databases
    // created before max_interval existed. No-op on fresh installs.
    private static func migrateQueryMaxIntervalColumn(db: Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(\"query\")")
        let names = Set(info.compactMap { $0["name"] as String? })
        if !names.contains("max_interval") {
            try db.execute(sql: "ALTER TABLE \"query\" ADD COLUMN max_interval INTEGER DEFAULT NULL")
        }
    }

    // One-time backfill: seed pointmap_query from the legacy inline SRS columns on
    // pointmap_point. Guarded by a globals flag so it runs exactly once — otherwise
    // a direction the user later disables (its query row deleted) would be
    // resurrected from the still-present inline columns on the next launch. After
    // this runs, pointmap_query is the sole source of truth for point queries.
    private static func backfillPointMapQueries(db: Database) throws {
        let alreadyDone = try String.fetchOne(
            db,
            sql: "SELECT value FROM globals WHERE name = 'pointmap_query_backfill_done'"
        ) != nil
        guard !alreadyDone else { return }

        try db.execute(sql: """
            INSERT INTO pointmap_query (point_id, is_reverse, interval, last_answered_timestamp, query_state)
            SELECT id, 0, interval, last_answered_timestamp, query_state
            FROM pointmap_point WHERE forward_enabled = 1
            """)
        try db.execute(sql: """
            INSERT INTO pointmap_query (point_id, is_reverse, interval, last_answered_timestamp, query_state)
            SELECT id, 1, reverse_interval, reverse_last_answered_timestamp, reverse_query_state
            FROM pointmap_point WHERE reverse_enabled = 1
            """)
        try db.execute(sql: "INSERT INTO globals (name, value) VALUES ('pointmap_query_backfill_done', '1')")
    }

    // One-time split of the legacy boundarymap_query table (which doubled as both
    // the attachment identity and the inline forward/reverse SRS holder) into a
    // boundarymap_attachment identity table plus a per-direction boundarymap_query.
    // Existing ids are preserved as attachment ids so links/previews keep working.
    // Detected via the old-only `reverse_interval` column; guarded by a globals
    // flag. No-op on fresh installs and on every subsequent launch.
    private static func migrateBoundaryMapQuerySplit(db: Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(boundarymap_query)")
        let columns = Set(info.compactMap { $0["name"] as String? })
        let isLegacyShape = columns.contains("reverse_interval")
        guard isLegacyShape else { return }

        let alreadyDone = try String.fetchOne(
            db,
            sql: "SELECT value FROM globals WHERE name = 'boundarymap_query_split_done'"
        ) != nil
        guard !alreadyDone else { return }

        try db.execute(sql: "ALTER TABLE boundarymap_query RENAME TO boundarymap_query_legacy")

        try db.execute(sql: """
            CREATE TABLE boundarymap_attachment (
                id INTEGER PRIMARY KEY,
                instance_id INTEGER NOT NULL
                    REFERENCES boundarymap_instance(instance_id) ON DELETE CASCADE,
                boundary_id INTEGER NOT NULL
                    REFERENCES boundary(id) ON DELETE CASCADE,
                UNIQUE(instance_id, boundary_id)
            ) STRICT
            """)
        try db.execute(sql: """
            INSERT INTO boundarymap_attachment (id, instance_id, boundary_id)
            SELECT id, instance_id, boundary_id FROM boundarymap_query_legacy
            """)

        try db.execute(sql: """
            CREATE TABLE boundarymap_query (
                id INTEGER PRIMARY KEY,
                attachment_id INTEGER NOT NULL
                    REFERENCES boundarymap_attachment(id) ON DELETE CASCADE,
                is_reverse INTEGER NOT NULL,
                interval INTEGER NOT NULL DEFAULT 0,
                last_answered_timestamp INTEGER DEFAULT NULL,
                query_state INTEGER NOT NULL DEFAULT 0,
                UNIQUE(attachment_id, is_reverse)
            ) STRICT
            """)
        try db.execute(sql: """
            INSERT INTO boundarymap_query (attachment_id, is_reverse, interval, last_answered_timestamp, query_state)
            SELECT id, 0, interval, last_answered_timestamp, query_state
            FROM boundarymap_query_legacy WHERE forward_enabled = 1
            """)
        try db.execute(sql: """
            INSERT INTO boundarymap_query (attachment_id, is_reverse, interval, last_answered_timestamp, query_state)
            SELECT id, 1, reverse_interval, reverse_last_answered_timestamp, reverse_query_state
            FROM boundarymap_query_legacy WHERE reverse_enabled = 1
            """)

        try db.execute(sql: "DROP TABLE boundarymap_query_legacy")
        try db.execute(sql: "INSERT INTO globals (name, value) VALUES ('boundarymap_query_split_done', '1')")
    }
}
