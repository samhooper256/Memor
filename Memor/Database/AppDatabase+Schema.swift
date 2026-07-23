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
                    field_type TEXT NOT NULL DEFAULT 'text',
                    is_protected INTEGER NOT NULL DEFAULT 0
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

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS stack (
                    id INTEGER PRIMARY KEY,
                    name TEXT,
                    search TEXT,
                    description TEXT,
                    is_pinned INTEGER NOT NULL DEFAULT 0
                ) STRICT
                """)

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

            // Row existence == that field's editor renders collapsed (header
            // bar only) in the Add/Edit Instance windows. Per (type, field)
            // like sticky_field, so the preference survives across sessions.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS collapsed_field (
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

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_pointmap_point_instance
                    ON pointmap_point(instance_id)
                """)

            // Each point has 0, 1, or 2 first-class queries (one per direction).
            // A row's existence == that direction being enabled. The inline SRS
            // columns on pointmap_point are dormant legacy columns.
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
            // directional queries.
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
            // successor in office". Each endpoint is a Person instance OR a
            // bare name (exactly one of id/bare per side); at least one side
            // must be an instance — that side owns the edge (a bare peer has
            // no view of its own). The composite FKs to person_office mean an
            // INSTANCE endpoint can only exist while that person holds the
            // office (a NULL id disables its FK), and deleting a holding, an
            // office, or a person cascades its edges. (X,A,B) and (X,B,A) may
            // coexist (Cleveland/Harrison); exact duplicate edges (including
            // bare ones, via the two partial unique indexes) and self-links
            // cannot. The definition body is shared with the one-off rebuild
            // below so the two can't drift.
            let successionTableBody = """
                    id INTEGER PRIMARY KEY,
                    office_id INTEGER NOT NULL
                        REFERENCES office(id) ON DELETE CASCADE,
                    predecessor_id INTEGER,
                    predecessor_bare TEXT,
                    successor_id INTEGER,
                    successor_bare TEXT,
                    CHECK ((predecessor_id IS NULL) != (predecessor_bare IS NULL)),
                    CHECK ((successor_id IS NULL) != (successor_bare IS NULL)),
                    CHECK (predecessor_id IS NOT NULL OR successor_id IS NOT NULL),
                    CHECK (predecessor_id != successor_id),
                    UNIQUE (office_id, predecessor_id, successor_id),
                    FOREIGN KEY (predecessor_id, office_id)
                        REFERENCES person_office(instance_id, office_id) ON DELETE CASCADE,
                    FOREIGN KEY (successor_id, office_id)
                        REFERENCES person_office(instance_id, office_id) ON DELETE CASCADE
                """
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS person_office_succession (
                \(successionTableBody)
                ) STRICT
                """)
            // Bare-name endpoints were added July 2026. Databases from before
            // then have NOT NULL endpoint ids and no bare columns; neither
            // nullability nor table CHECKs can be ALTERed in, so rebuild once,
            // preserving row ids (peers render in edge-creation order). The
            // dropped indexes are recreated just below.
            let successionColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(person_office_succession)")
                .map { $0["name"] as String }
            if !successionColumns.contains("predecessor_bare") {
                try db.execute(sql: """
                    CREATE TABLE person_office_succession_new (
                    \(successionTableBody)
                    ) STRICT
                    """)
                try db.execute(sql: """
                    INSERT INTO person_office_succession_new (id, office_id, predecessor_id, successor_id)
                    SELECT id, office_id, predecessor_id, successor_id FROM person_office_succession
                    """)
                try db.execute(sql: "DROP TABLE person_office_succession")
                try db.execute(sql: "ALTER TABLE person_office_succession_new RENAME TO person_office_succession")
            }
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_person_office_succession_pred
                    ON person_office_succession(predecessor_id, office_id)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_person_office_succession_succ
                    ON person_office_succession(successor_id, office_id)
                """)
            // UNIQUE treats NULLs as distinct, so the table-level UNIQUE only
            // covers instance-instance edges; these cover the two bare shapes.
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_person_office_succession_unique_bare_pred
                    ON person_office_succession(office_id, predecessor_bare, successor_id)
                    WHERE predecessor_id IS NULL
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_person_office_succession_unique_bare_succ
                    ON person_office_succession(office_id, predecessor_id, successor_bare)
                    WHERE successor_id IS NULL
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
            // SQLite UNIQUE treats NULLs as distinct, so a single
            // UNIQUE(instance_id, kind, partnership_id, office_id) would allow
            // duplicate rows; three partial unique indexes cover the three row
            // shapes (INSERT OR IGNORE respects partial unique indexes).
            // (The standalone index's "2" suffix is historical.)
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
            try migratePersonTimePeriodField(db: db)
            try migratePersonDisplayNameField(db: db)

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

    // Seeds the built-in Person type (idempotent, PointMap pattern): the type
    // row, its fields — deletable Name/Description plus protected
    // Sex/TimePeriod/DisplayName (DisplayName: an optional prettier/shorter
    // name preferred over Name as link text in computed Person query HTML;
    // display slot 2, seeded COLLAPSED via a collapsed_field row) — the
    // dynamic type{N} table, and one premade (ordinary, deletable) "Name"
    // query type. Runs on every launch; no-ops once the type exists.
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

        // DisplayName's field_index (5) is out of display order deliberately:
        // Sex must stay field2 (the NOT NULL DEFAULT column below), so the
        // later-added field takes the next free index while its
        // field_display_index slots it between Name and Sex — matching the
        // shape the one-off migration produces on older databases.
        try db.execute(
            sql: """
                INSERT INTO field (type_id, name, field_index, field_display_index, field_type, is_protected)
                VALUES
                    (?, 'Name',        1, 1, 'text', 0),
                    (?, 'DisplayName', 5, 2, 'text', 1),
                    (?, 'Sex',         2, 3, 'sex',  1),
                    (?, 'TimePeriod',  3, 4, 'text', 1),
                    (?, 'Description', 4, 5, 'text', 0)
                """,
            arguments: [personTypeID, personTypeID, personTypeID, personTypeID, personTypeID]
        )

        // DisplayName starts collapsed — it's optional and shouldn't take
        // space or Tab stops until the user opts in by expanding it.
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO collapsed_field (type_id, field_id)
                SELECT type_id, id FROM field WHERE type_id = ? AND name = 'DisplayName'
                """,
            arguments: [personTypeID]
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
                    <div class="TimePeriod">{{TimePeriod}}</div>
                    """
                )
            ]
        )
    }

    // Person's protected WhenBorn/WhenDied fields were merged into a single
    // protected TimePeriod field in July 2026. Fresh databases seed the new
    // shape; this one-off migrates existing ones in place: WhenBorn's column
    // takes "born–died" (en dash; a row where both sides are blank stays
    // blank), WhenBorn's field row is renamed to TimePeriod (keeping its id,
    // field_index, display slot, and protection), and WhenDied's column and
    // row are dropped, compacting display indices like deleteField does.
    // Query HTML that referenced {{WhenBorn}}/{{WhenDied}} is intentionally
    // NOT rewritten (the user edits it by hand). Guarded by the field table's
    // state — once WhenBorn/WhenDied are gone it no-ops forever.
    private static func migratePersonTimePeriodField(db: Database) throws {
        guard let personTypeID = try Int64.fetchOne(
            db,
            sql: """
                SELECT id FROM "type" WHERE name = ? AND is_builtin = 1
                """,
            arguments: [PERSON_TYPE_NAME]
        ) else { return }

        func protectedField(named name: String) throws -> Row? {
            try Row.fetchOne(
                db,
                sql: """
                    SELECT id, field_index, field_display_index FROM field
                    WHERE type_id = ? AND name = ? AND is_protected = 1
                    """,
                arguments: [personTypeID, name]
            )
        }
        guard let born = try protectedField(named: "WhenBorn"),
              let died = try protectedField(named: "WhenDied") else { return }
        let bornIndex = born["field_index"] as Int64
        let diedIndex = died["field_index"] as Int64

        try db.execute(sql: """
            UPDATE "type\(personTypeID)"
            SET "field\(bornIndex)" =
                CASE WHEN COALESCE("field\(bornIndex)", '') = '' AND COALESCE("field\(diedIndex)", '') = ''
                     THEN "field\(bornIndex)"
                     ELSE COALESCE("field\(bornIndex)", '') || '–' || COALESCE("field\(diedIndex)", '')
                END
            """)
        try db.execute(
            sql: "UPDATE field SET name = 'TimePeriod' WHERE id = ?",
            arguments: [born["id"] as Int64]
        )
        try db.execute(sql: """
            ALTER TABLE "type\(personTypeID)" DROP COLUMN "field\(diedIndex)"
            """)
        try db.execute(
            sql: "DELETE FROM field WHERE id = ?",
            arguments: [died["id"] as Int64]
        )
        try db.execute(
            sql: """
                UPDATE field
                SET field_display_index = field_display_index - 1
                WHERE type_id = ? AND field_display_index > ?
                """,
            arguments: [personTypeID, died["field_display_index"] as Int64]
        )
    }

    // Person gained a protected DisplayName field in July 2026: an optional
    // prettier/shorter name preferred over Name for the link text of computed
    // Person query HTML (see personEntryHTML). Fresh databases seed it; this
    // one-off adds it to existing ones — display slot 2 (between Name and
    // Sex, everything from Sex down shifts one), a fresh field_index (next
    // free; existing columns never renumber), and a collapsed_field row so it
    // starts collapsed. Guarded by the field's absence, so it no-ops forever
    // after; must run after the TimePeriod migration so display indices are
    // already compacted.
    private static func migratePersonDisplayNameField(db: Database) throws {
        guard let personTypeID = try Int64.fetchOne(
            db,
            sql: """
                SELECT id FROM "type" WHERE name = ? AND is_builtin = 1
                """,
            arguments: [PERSON_TYPE_NAME]
        ) else { return }

        let existingID = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM field WHERE type_id = ? AND name = 'DisplayName'",
            arguments: [personTypeID]
        )
        guard existingID == nil else { return }

        let nextIndex = (try Int64.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(field_index), 0) FROM field WHERE type_id = ?",
            arguments: [personTypeID]
        ) ?? 0) + 1

        try db.execute(sql: """
            ALTER TABLE "type\(personTypeID)" ADD COLUMN "field\(nextIndex)" TEXT
            """)
        try db.execute(
            sql: """
                UPDATE field
                SET field_display_index = field_display_index + 1
                WHERE type_id = ? AND field_display_index >= 2
                """,
            arguments: [personTypeID]
        )
        try db.execute(
            sql: """
                INSERT INTO field (type_id, name, field_index, field_display_index, field_type, is_protected)
                VALUES (?, 'DisplayName', ?, 2, 'text', 1)
                """,
            arguments: [personTypeID, nextIndex]
        )
        try db.execute(
            sql: "INSERT OR IGNORE INTO collapsed_field (type_id, field_id) VALUES (?, ?)",
            arguments: [personTypeID, db.lastInsertedRowID]
        )
    }

}
