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
                    is_builtin INTEGER NOT NULL DEFAULT 0
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

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS query_type (
                    id INTEGER PRIMARY KEY,
                    type_id INTEGER NOT NULL REFERENCES "type"(id),
                    name TEXT,
                    question_html TEXT,
                    answer_html TEXT
                ) STRICT
                """)

            try migrateFieldPrimaryColumn(db: db)
            try migrateTypeDescriptionColumn(db: db)
            try migrateFieldTypeColumn(db: db)
            try migrateFieldProtectedColumn(db: db)

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

            // MARK: Person relationship tables
            //
            // Relationships between two Person INSTANCES are stored exactly once,
            // so both people's views agree by construction. Bare-name entries
            // (free text standing in for someone without an instance) anchor to
            // the one instance side and carry no reciprocity. Foreign keys
            // reference instance_id_type_id as CASCADE backstops only — the real
            // deletion semantics (convert references to bare names) run in Swift
            // before the generic instance delete.

            // One row per partnership "stint" (duplicates between the same two
            // people are allowed — e.g. married, divorced, remarried). is_married
            // and the freetext start/end are stored once here, so both partners'
            // views are guaranteed consistent. Each side keeps its own position
            // in its own partner list (a_order_index / b_order_index). Row ids
            // are STABLE across edits (UPDATE in place, never delete+reinsert)
            // because person_query's children_with rows anchor SRS state to them.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS person_partnership (
                    id INTEGER PRIMARY KEY,
                    a_id INTEGER NOT NULL
                        REFERENCES instance_id_type_id(instance_id) ON DELETE CASCADE,
                    b_id INTEGER
                        REFERENCES instance_id_type_id(instance_id) ON DELETE CASCADE,
                    b_bare TEXT,
                    is_married INTEGER NOT NULL DEFAULT 0,
                    start_text TEXT NOT NULL DEFAULT '',
                    end_text TEXT NOT NULL DEFAULT '',
                    a_order_index INTEGER NOT NULL DEFAULT 0,
                    b_order_index INTEGER,
                    CHECK ((b_id IS NULL) != (b_bare IS NULL)),
                    CHECK (b_id IS NULL OR b_id != a_id),
                    CHECK ((b_id IS NULL) = (b_order_index IS NULL))
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_person_partnership_a ON person_partnership(a_id)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_person_partnership_b ON person_partnership(b_id)
                """)

            // A child of a partnership: ONE row per grouped child, so the
            // children's order is shared between both parents by construction.
            // An instance child can be grouped at most once globally (one
            // biological mother + father).
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS person_partnership_child (
                    id INTEGER PRIMARY KEY,
                    partnership_id INTEGER NOT NULL
                        REFERENCES person_partnership(id) ON DELETE CASCADE,
                    child_id INTEGER
                        REFERENCES instance_id_type_id(instance_id) ON DELETE CASCADE,
                    child_bare TEXT,
                    order_index INTEGER NOT NULL DEFAULT 0,
                    CHECK ((child_id IS NULL) != (child_bare IS NULL))
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_person_partnership_child_unique
                    ON person_partnership_child(child_id) WHERE child_id IS NOT NULL
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_person_partnership_child_partnership
                    ON person_partnership_child(partnership_id)
                """)

            // The child-side canonical slots: 0-or-1 mother/father/adoptive_mother/
            // adoptive_father per child (DB-enforced by UNIQUE(child_id, role)).
            // Grouping-implied biological parents are MATERIALIZED here by the
            // save routine, so "who is C's mother" is always one indexed lookup.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS person_parent (
                    id INTEGER PRIMARY KEY,
                    child_id INTEGER NOT NULL
                        REFERENCES instance_id_type_id(instance_id) ON DELETE CASCADE,
                    role TEXT NOT NULL
                        CHECK (role IN ('mother','father','adoptive_mother','adoptive_father')),
                    parent_id INTEGER
                        REFERENCES instance_id_type_id(instance_id) ON DELETE CASCADE,
                    parent_bare TEXT,
                    CHECK ((parent_id IS NULL) != (parent_bare IS NULL)),
                    CHECK (parent_id IS NULL OR parent_id != child_id),
                    UNIQUE (child_id, role)
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_person_parent_parent ON person_parent(parent_id)
                """)

            // Parent-side list of UNGROUPED children (not associated with any
            // partner): holds their order plus bare-name children. For instance
            // children this is a maintained projection of person_parent
            // (invariant: a person_direct_child row exists iff the child's
            // matching person_parent row names this parent and the child is not
            // grouped under any of this parent's partnerships).
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS person_direct_child (
                    id INTEGER PRIMARY KEY,
                    parent_id INTEGER NOT NULL
                        REFERENCES instance_id_type_id(instance_id) ON DELETE CASCADE,
                    child_id INTEGER
                        REFERENCES instance_id_type_id(instance_id) ON DELETE CASCADE,
                    child_bare TEXT,
                    order_index INTEGER NOT NULL DEFAULT 0,
                    CHECK ((child_id IS NULL) != (child_bare IS NULL)),
                    CHECK (child_id IS NULL OR child_id != parent_id)
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_person_direct_child_unique
                    ON person_direct_child(parent_id, child_id) WHERE child_id IS NOT NULL
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_person_direct_child_parent
                    ON person_direct_child(parent_id)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_person_direct_child_child
                    ON person_direct_child(child_id)
                """)

            // MARK: Person office tables

            // User-created offices (e.g. "U.S. President"). Names are unique
            // case-insensitively. Must be created before person_office and
            // before person_query's office_id column (FK targets).
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS office (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    description TEXT NOT NULL DEFAULT ''
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_office_name_unique
                    ON office(name COLLATE NOCASE)
                """)

            // One row per (person, office) holding. UNIQUE(instance_id, office_id)
            // both enforces one holding per office per person and is the parent
            // key for person_office_succession's composite FKs. order_index is
            // the person's own office display/study order.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS person_office (
                    id INTEGER PRIMARY KEY,
                    instance_id INTEGER NOT NULL
                        REFERENCES instance_id_type_id(instance_id) ON DELETE CASCADE,
                    office_id INTEGER NOT NULL
                        REFERENCES office(id) ON DELETE CASCADE,
                    when_began TEXT NOT NULL DEFAULT '',
                    when_ended TEXT NOT NULL DEFAULT '',
                    note TEXT NOT NULL DEFAULT '',
                    order_index INTEGER NOT NULL DEFAULT 0,
                    UNIQUE (instance_id, office_id)
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_person_office_office
                    ON person_office(office_id)
                """)

            // One row per directed succession fact, stored ONCE (reciprocity by
            // construction, like person_partnership): "predecessor precedes
            // successor in office". The composite FKs to person_office mean an
            // edge can only exist while BOTH endpoints hold the office, and
            // deleting a holding, an office, or a person cascades its edges.
            // (X,A,B) and (X,B,A) may coexist (Cleveland/Harrison); exact
            // duplicate edges and self-links cannot.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS person_office_succession (
                    id INTEGER PRIMARY KEY,
                    office_id INTEGER NOT NULL
                        REFERENCES office(id) ON DELETE CASCADE,
                    predecessor_id INTEGER NOT NULL,
                    successor_id INTEGER NOT NULL,
                    CHECK (predecessor_id != successor_id),
                    UNIQUE (office_id, predecessor_id, successor_id),
                    FOREIGN KEY (predecessor_id, office_id)
                        REFERENCES person_office(instance_id, office_id) ON DELETE CASCADE,
                    FOREIGN KEY (successor_id, office_id)
                        REFERENCES person_office(instance_id, office_id) ON DELETE CASCADE
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_person_office_succession_pred
                    ON person_office_succession(predecessor_id, office_id)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_person_office_succession_succ
                    ON person_office_succession(successor_id, office_id)
                """)

            // Built-in Person queries (Mother/Father/Parents/Adoptive Mother/
            // Adoptive Father/Children/Children with {partner}/Full Siblings/
            // Office: {office}/All Offices). A row's existence == that query
            // being enabled for that instance (mirrors pointmap_query).
            // partnership_id is non-NULL exactly for kind = 'children_with';
            // office_id is non-NULL exactly for kind = 'office' (one row per
            // holding). The kind set is a closed Swift enum (PersonQueryKind) —
            // no CHECK constraint, since SQLite CHECKs can't be altered later.
            // Must be created after person_partnership and office (FK targets).
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS person_query (
                    id INTEGER PRIMARY KEY,
                    instance_id INTEGER NOT NULL
                        REFERENCES instance_id_type_id(instance_id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    partnership_id INTEGER
                        REFERENCES person_partnership(id) ON DELETE CASCADE,
                    office_id INTEGER
                        REFERENCES office(id) ON DELETE CASCADE,
                    interval INTEGER NOT NULL DEFAULT 0,
                    last_answered_timestamp INTEGER DEFAULT NULL,
                    query_state INTEGER NOT NULL DEFAULT 0
                ) STRICT
                """)
            // Databases created before Offices existed lack office_id; must run
            // before the index block below (the indexes reference the column).
            try migratePersonQueryOfficeColumn(db: db)
            // SQLite UNIQUE treats NULLs as distinct, so a single
            // UNIQUE(instance_id, kind, partnership_id, office_id) would allow
            // duplicate rows; three partial unique indexes cover the three row
            // shapes (INSERT OR IGNORE respects partial unique indexes).
            // The pre-Offices standalone index (WHERE partnership_id IS NULL
            // only) would reject a second office row per instance, so it is
            // dropped and replaced under a new name (idempotent every launch).
            try db.execute(sql: """
                DROP INDEX IF EXISTS idx_person_query_unique_standalone
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_person_query_unique_standalone2
                    ON person_query(instance_id, kind)
                    WHERE partnership_id IS NULL AND office_id IS NULL
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_person_query_unique_partner
                    ON person_query(instance_id, kind, partnership_id) WHERE partnership_id IS NOT NULL
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_person_query_unique_office
                    ON person_query(instance_id, kind, office_id) WHERE office_id IS NOT NULL
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_person_query_instance ON person_query(instance_id)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_person_query_partnership ON person_query(partnership_id)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_person_query_office ON person_query(office_id)
                """)

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

            try seedPersonType(db: db)

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

    // Adds the field.is_protected column (built-in Person fields that can't be
    // renamed or deleted) to databases created before the Person type existed.
    // Idempotent. Existing fields default to unprotected.
    private static func migrateFieldProtectedColumn(db: Database) throws {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(field)")
        let names = Set(info.compactMap { $0["name"] as String? })
        if !names.contains("is_protected") {
            try db.execute(sql: "ALTER TABLE field ADD COLUMN is_protected INTEGER NOT NULL DEFAULT 0")
        }
    }

    // Seeds the built-in Person type (idempotent, PointMap pattern): the type
    // row, its fields — deletable Name/Description plus protected
    // Sex/WhenBorn/WhenDied — the dynamic type{N} table, and one premade
    // (ordinary, deletable) "Name" query type. Runs on every launch; no-ops
    // once the type exists.
    private static func seedPersonType(db: Database) throws {
        let existingPersonTypeID = try Int64.fetchOne(
            db,
            sql: """
                SELECT id FROM "type" WHERE name = ? AND is_builtin = 1
                """,
            arguments: [PERSON_TYPE_NAME]
        )
        guard existingPersonTypeID == nil else { return }

        try db.execute(
            sql: """
                INSERT INTO "type" (name, css, is_builtin)
                VALUES (?, ?, 1)
                """,
            arguments: [PERSON_TYPE_NAME, ""]
        )
        let personTypeID = db.lastInsertedRowID

        try db.execute(
            sql: """
                INSERT INTO field (type_id, name, field_index, field_display_index, field_type, is_protected)
                VALUES
                    (?, 'Name',        1, 1, 'text', 0),
                    (?, 'Sex',         2, 2, 'sex',  1),
                    (?, 'WhenBorn',    3, 3, 'text', 1),
                    (?, 'WhenDied',    4, 4, 'text', 1),
                    (?, 'Description', 5, 5, 'text', 0)
                """,
            arguments: [personTypeID, personTypeID, personTypeID, personTypeID, personTypeID]
        )

        // Sex is required with default Male; the NOT NULL DEFAULT guarantees a
        // value even for rows written before a caller knew about the field.
        try db.execute(sql: """
            CREATE TABLE "type\(personTypeID)" (
                id INTEGER PRIMARY KEY,
                field1 TEXT,
                field2 TEXT NOT NULL DEFAULT 'Male',
                field3 TEXT,
                field4 TEXT,
                field5 TEXT,
                FOREIGN KEY (id) REFERENCES instance_id_type_id(instance_id) ON DELETE CASCADE
            ) STRICT
            """)

        try db.execute(
            sql: """
                INSERT INTO query_type (type_id, name, question_html, answer_html)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [
                personTypeID,
                "Name",
                "<div class=\"Name\">{{Name}}</div>",
                uniteQuestionAndAnswerWithDefaultSeparator(
                    questionHTML: "{{#QuestionContent}}",
                    answerHTML: """
                    <div class="Description">{{Description}}</div>
                    <div class="WhenBorn">{{WhenBorn}}</div>
                    <div class="WhenDied">{{WhenDied}}</div>
                    """
                )
            ]
        )
    }

    // Adds the field.is_primary column to databases created before it existed.
    // Idempotent: the ALTER runs only when the column is absent, so this is a
    // no-op on fresh installs. is_primary marks the field that supplies an
    // instance's display value (falling back to display order when unset).
    private static func migrateFieldPrimaryColumn(db: Database) throws {
        let fieldInfo = try Row.fetchAll(db, sql: "PRAGMA table_info(field)")
        if !Set(fieldInfo.compactMap { $0["name"] as String? }).contains("is_primary") {
            try db.execute(sql: "ALTER TABLE field ADD COLUMN is_primary INTEGER NOT NULL DEFAULT 0")
        }
    }

    // MARK: - Node purge (one-time, destructive)

    /// Destroys everything Node-related in a pre-existing database: all
    /// `kind = 'node'` types (with their instances, fields, query types, and SRS
    /// state), the `node_link` and `link_field` tables, `type.kind`, and
    /// `query_type.link_field_id`. The Node feature was removed from the app.
    ///
    /// Must run BEFORE `createSchema` and outside its transaction:
    /// `query_type.link_field_id` carries a foreign key, which makes plain
    /// `DROP COLUMN` illegal, and `DROP TABLE query_type` with foreign keys ON
    /// would fire the implicit-DELETE cascade and wipe every `query` row (all
    /// SRS state). The only safe path is a rename/copy/drop rebuild under
    /// `PRAGMA foreign_keys = OFF`, and that pragma cannot change inside a
    /// transaction — hence `writeWithoutTransaction` with an explicit inner
    /// transaction (a crash mid-purge rolls back and retries next launch).
    ///
    /// Idempotency is structural: every step is guarded by sqlite_master /
    /// table_info checks, so fresh databases and already-purged databases no-op
    /// before the pragma is touched.
    static func purgeNodeMachinery(in dbQueue: DatabaseQueue) throws {
        try dbQueue.writeWithoutTransaction { db in
            let typeHasKind = try columnExists(db, table: "type", column: "kind")
            let queryTypeHasLinkFieldID = try columnExists(db, table: "query_type", column: "link_field_id")
            let hasNodeLinkTable = try tableExists(db, "node_link")
            let hasLinkFieldTable = try tableExists(db, "link_field")
            guard typeHasKind || queryTypeHasLinkFieldID || hasNodeLinkTable || hasLinkFieldTable else {
                return
            }

            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            defer { try? db.execute(sql: "PRAGMA foreign_keys = ON") }

            try db.inTransaction {
                // 1. Destroy node types and everything hanging off them. Foreign
                //    keys are OFF, so children are deleted explicitly, parents last.
                if typeHasKind {
                    let nodeTypeIDs = try Int64.fetchAll(
                        db,
                        sql: "SELECT id FROM \"type\" WHERE kind = 'node'"
                    )
                    if !nodeTypeIDs.isEmpty {
                        let idList = nodeTypeIDs.map(String.init).joined(separator: ", ")
                        try db.execute(sql: """
                            DELETE FROM query WHERE query_type_id IN
                                (SELECT id FROM query_type WHERE type_id IN (\(idList)))
                            """)
                        try db.execute(sql: """
                            DELETE FROM query WHERE instance_id IN
                                (SELECT instance_id FROM instance_id_type_id WHERE type_id IN (\(idList)))
                            """)
                        try db.execute(sql: """
                            DELETE FROM instance_id_collection_id WHERE instance_id IN
                                (SELECT instance_id FROM instance_id_type_id WHERE type_id IN (\(idList)))
                            """)
                        try db.execute(sql: "DELETE FROM instance_id_type_id WHERE type_id IN (\(idList))")
                        if try tableExists(db, "type_query_default") {
                            try db.execute(sql: "DELETE FROM type_query_default WHERE type_id IN (\(idList))")
                        }
                        try db.execute(sql: "DELETE FROM query_type WHERE type_id IN (\(idList))")
                        try db.execute(sql: "DELETE FROM field WHERE type_id IN (\(idList))")
                        if try tableExists(db, "sticky_field") {
                            try db.execute(sql: "DELETE FROM sticky_field WHERE type_id IN (\(idList))")
                        }
                        if try tableExists(db, "pinned_collection") {
                            try db.execute(sql: "DELETE FROM pinned_collection WHERE type_id IN (\(idList))")
                        }
                        for typeID in nodeTypeIDs {
                            try db.execute(sql: "DROP TABLE IF EXISTS \"type\(typeID)\"")
                        }
                        try db.execute(sql: "DELETE FROM \"type\" WHERE id IN (\(idList))")
                    }
                }
                try db.execute(sql: "DROP TABLE IF EXISTS node_link")

                // 2. Rebuild query_type without link_field_id. The DROP does not
                //    cascade into `query` (foreign keys OFF), and query's FK clause
                //    references "query_type" by name, which the RENAME restores.
                if queryTypeHasLinkFieldID {
                    try db.execute(sql: """
                        CREATE TABLE query_type_new (
                            id INTEGER PRIMARY KEY,
                            type_id INTEGER NOT NULL REFERENCES "type"(id),
                            name TEXT,
                            question_html TEXT,
                            answer_html TEXT
                        ) STRICT
                        """)
                    try db.execute(sql: """
                        INSERT INTO query_type_new (id, type_id, name, question_html, answer_html)
                        SELECT id, type_id, name, question_html, answer_html FROM query_type
                        """)
                    try db.execute(sql: "DROP TABLE query_type")
                    try db.execute(sql: "ALTER TABLE query_type_new RENAME TO query_type")
                }
                try db.execute(sql: "DROP TABLE IF EXISTS link_field")

                // 3. type.kind is a plain column (no index, CHECK, or FK), so a
                //    straight DROP COLUMN is legal even on a STRICT table.
                if typeHasKind {
                    try db.execute(sql: "ALTER TABLE \"type\" DROP COLUMN kind")
                }

                // 4. Refuse to commit a purge that broke referential integrity.
                let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
                guard violations.isEmpty else {
                    throw DatabaseError(message: "Node purge failed the foreign-key integrity check.")
                }
                return .commit
            }
        }
    }

    private static func tableExists(_ db: Database, _ name: String) throws -> Bool {
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [name]
        ) ?? 0 > 0
    }

    private static func columnExists(_ db: Database, table: String, column: String) throws -> Bool {
        let info = try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(table)\")")
        return Set(info.compactMap { $0["name"] as String? }).contains(column)
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

    // Adds the nullable office_id column to person_query for databases created
    // before Offices existed (SQLite permits ALTER ... ADD COLUMN with a
    // REFERENCES clause when the default is NULL). Existing rows stay NULL, so
    // every pre-existing query is untouched. No-op on fresh installs.
    private static func migratePersonQueryOfficeColumn(db: Database) throws {
        if try !columnExists(db, table: "person_query", column: "office_id") {
            try db.execute(sql: """
                ALTER TABLE "person_query" ADD COLUMN office_id INTEGER
                    REFERENCES office(id) ON DELETE CASCADE
                """)
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
