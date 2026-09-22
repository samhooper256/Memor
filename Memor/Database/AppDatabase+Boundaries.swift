//
//  AppDatabase+Boundaries.swift
//  Memor
//
//  Public API for reading, importing, and associating named polygon
//  boundaries used as overlays on PointMap instances.
//

import Foundation
import GRDB

extension AppDatabase {
    // MARK: - Errors

    struct BoundaryImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Imported-file validation

    struct ImportedBoundaryFeature {
        let name: String
        let multiPolygonCoordinates: [[[[Double]]]]
    }

    /// Parses & validates the raw bytes of a .json/.geojson file — a user
    /// upload, or the bundled Natural Earth file the first-launch Countries
    /// seed reads — and returns the individual features ready for insertion.
    /// Throws a human-readable error on any validation failure. Accepts either
    /// a top-level array of GeoJSON Feature objects or a top-level GeoJSON
    /// FeatureCollection object. `nameProperty` is the `properties` key that
    /// supplies each boundary's display name: `name` for uploads (as the
    /// upload help documents); the seed passes Natural Earth's `NAME_EN`.
    static func parseUploadedBoundaryFile(
        data: Data,
        nameProperty: String = "name"
    ) throws -> [ImportedBoundaryFeature] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw BoundaryImportError(message: "File is not valid JSON.")
        }

        let array: [Any]
        if let arr = root as? [Any] {
            array = arr
        } else if let object = root as? [String: Any],
                  (object["type"] as? String) == "FeatureCollection" {
            guard let features = object["features"] as? [Any] else {
                throw BoundaryImportError(
                    message: "FeatureCollection is missing a 'features' array."
                )
            }
            array = features
        } else {
            throw BoundaryImportError(
                message: "Top-level JSON must be an array of GeoJSON Feature objects or a GeoJSON FeatureCollection."
            )
        }

        var results: [ImportedBoundaryFeature] = []
        results.reserveCapacity(array.count)

        for (index, element) in array.enumerated() {
            guard let feature = element as? [String: Any] else {
                throw BoundaryImportError(
                    message: "Feature #\(index + 1) is not an object."
                )
            }
            guard let properties = feature["properties"] as? [String: Any] else {
                throw BoundaryImportError(
                    message: "Feature #\(index + 1) has no 'properties' object."
                )
            }
            guard let name = properties[nameProperty] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BoundaryImportError(
                    message: "Feature #\(index + 1) is missing a non-empty 'properties.\(nameProperty)' string."
                )
            }
            guard let geometry = feature["geometry"] as? [String: Any] else {
                throw BoundaryImportError(
                    message: "Feature '\(name)' has no 'geometry' object."
                )
            }
            guard let type = geometry["type"] as? String else {
                throw BoundaryImportError(
                    message: "Feature '\(name)' has no 'geometry.type' string."
                )
            }

            let multiCoords: [[[[Double]]]]
            switch type {
            case "MultiPolygon":
                guard let c = geometry["coordinates"] as? [[[[Double]]]] else {
                    throw BoundaryImportError(
                        message: "Feature '\(name)' has invalid MultiPolygon coordinates."
                    )
                }
                multiCoords = c
            case "Polygon":
                guard let c = geometry["coordinates"] as? [[[Double]]] else {
                    throw BoundaryImportError(
                        message: "Feature '\(name)' has invalid Polygon coordinates."
                    )
                }
                multiCoords = [c]
            default:
                throw BoundaryImportError(
                    message: "Feature '\(name)' has unsupported geometry.type '\(type)'."
                )
            }

            // Validate at least one outer ring with at least 3 coordinates and
            // that each coordinate is a 2-element [lng, lat] pair within range.
            guard !multiCoords.isEmpty else {
                throw BoundaryImportError(
                    message: "Feature '\(name)' has no polygons."
                )
            }
            for (polyIdx, polygon) in multiCoords.enumerated() {
                guard !polygon.isEmpty else {
                    throw BoundaryImportError(
                        message: "Feature '\(name)' polygon #\(polyIdx + 1) has no rings."
                    )
                }
                for (ringIdx, ring) in polygon.enumerated() {
                    guard ring.count >= 3 else {
                        throw BoundaryImportError(
                            message: "Feature '\(name)' polygon #\(polyIdx + 1) ring #\(ringIdx + 1) has fewer than 3 coordinates."
                        )
                    }
                    for coord in ring {
                        guard coord.count == 2,
                              coord[0] >= -180, coord[0] <= 180,
                              coord[1] >= -90, coord[1] <= 90 else {
                            throw BoundaryImportError(
                                message: "Feature '\(name)' has an out-of-range or malformed coordinate."
                            )
                        }
                    }
                }
            }

            results.append(ImportedBoundaryFeature(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                multiPolygonCoordinates: multiCoords
            ))
        }

        if results.isEmpty {
            throw BoundaryImportError(message: "File contains no valid features.")
        }
        return results
    }

    // MARK: - Reads

    func fetchAllBoundaryOptions() throws -> [BoundaryWithSet] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        b.id AS boundary_id,
                        b.boundary_set_id AS boundary_set_id,
                        b.name AS boundary_name,
                        b.color AS boundary_color,
                        bs.name AS set_name,
                        bs.is_builtin AS is_builtin
                    FROM boundary AS b
                    JOIN boundary_set AS bs ON bs.id = b.boundary_set_id
                    ORDER BY bs.is_builtin DESC, bs.name COLLATE NOCASE, b.name COLLATE NOCASE
                    """
            )
            return rows.map { row in
                BoundaryWithSet(
                    boundary: Boundary(
                        id: row["boundary_id"] as Int64? ?? 0,
                        boundarySetID: row["boundary_set_id"] as Int64? ?? 0,
                        name: row["boundary_name"] as String? ?? "",
                        color: BoundaryColor(rawValue: row["boundary_color"] as String? ?? "") ?? .red
                    ),
                    setName: row["set_name"] as String? ?? "",
                    isBuiltin: ((row["is_builtin"] as Int64?) ?? 0) != 0
                )
            }
        }
    }

    func fetchBoundarySets() throws -> [BoundarySet] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        bs.id AS id,
                        bs.name AS name,
                        bs.is_builtin AS is_builtin,
                        bs.created_at AS created_at,
                        (SELECT COUNT(*) FROM boundary WHERE boundary_set_id = bs.id) AS boundary_count
                    FROM boundary_set AS bs
                    ORDER BY bs.is_builtin DESC, bs.name COLLATE NOCASE
                    """
            )
            return rows.map { row in
                BoundarySet(
                    id: row["id"] as Int64? ?? 0,
                    name: row["name"] as String? ?? "",
                    isBuiltin: ((row["is_builtin"] as Int64?) ?? 0) != 0,
                    createdAt: row["created_at"] as Int64? ?? 0,
                    boundaryCount: row["boundary_count"] as Int? ?? 0
                )
            }
        }
    }

    func fetchBoundaries(setID: Int64) throws -> [Boundary] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, boundary_set_id, name, color
                    FROM boundary
                    WHERE boundary_set_id = ?
                    ORDER BY name COLLATE NOCASE
                    """,
                arguments: [setID]
            )
            return rows.map { row in
                Boundary(
                    id: row["id"] as Int64? ?? 0,
                    boundarySetID: row["boundary_set_id"] as Int64? ?? 0,
                    name: row["name"] as String? ?? "",
                    color: BoundaryColor(rawValue: row["color"] as String? ?? "") ?? .red
                )
            }
        }
    }

    func fetchBoundaryIDs(forInstance instanceID: Int64) throws -> [Int64] {
        try dbQueue.read { db in
            try Self.fetchBoundaryIDs(db: db, instanceID: instanceID)
        }
    }

    static func fetchBoundaryIDs(db: Database, instanceID: Int64) throws -> [Int64] {
        try Int64.fetchAll(
            db,
            sql: """
                SELECT boundary_id
                FROM pointmap_boundary
                WHERE instance_id = ?
                """,
            arguments: [instanceID]
        )
    }

    func fetchBoundaryGeometry(boundaryID: Int64) throws -> ParsedMultiPolygon? {
        try dbQueue.read { db in
            guard let data = try Data.fetchOne(
                db,
                sql: "SELECT geometry_json FROM boundary WHERE id = ?",
                arguments: [boundaryID]
            ) else { return nil }
            return Self.parseMultiPolygonJSON(data: data)
        }
    }

    func fetchBoundaryGeometries(forInstance instanceID: Int64) throws -> [BoundaryGeometry] {
        try dbQueue.read { db in
            try Self.fetchBoundaryGeometries(db: db, instanceID: instanceID)
        }
    }

    static func fetchBoundaryGeometries(db: Database, instanceID: Int64) throws -> [BoundaryGeometry] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT b.id AS id, b.name AS name, b.geometry_json AS geometry_json, b.color AS color
                FROM pointmap_boundary AS pb
                JOIN boundary AS b ON b.id = pb.boundary_id
                WHERE pb.instance_id = ?
                ORDER BY b.name COLLATE NOCASE
                """,
            arguments: [instanceID]
        )
        return rows.compactMap { row in
            guard let data = row["geometry_json"] as Data? else { return nil }
            guard let parsed = parseMultiPolygonJSON(data: data) else { return nil }
            return BoundaryGeometry(
                id: row["id"] as Int64? ?? 0,
                name: row["name"] as String? ?? "",
                geometry: parsed,
                color: BoundaryColor(rawValue: row["color"] as String? ?? "") ?? .red
            )
        }
    }

    /// Where one boundary (or every boundary of a set) is in use — what a
    /// delete cascades through, for confirmation messages.
    struct BoundaryUsage {
        /// PointMap instances showing at least one of the boundaries as an overlay.
        let pointMapInstanceCount: Int
        /// BoundaryMap instances with at least one of the boundaries attached.
        let boundaryMapInstanceCount: Int
        /// Enabled Forward/Reverse queries (with SRS progress) on those attachments.
        let boundaryMapQueryCount: Int

        var isEmpty: Bool {
            pointMapInstanceCount == 0 && boundaryMapInstanceCount == 0
        }
    }

    func fetchBoundaryUsage(boundaryID: Int64) throws -> BoundaryUsage {
        try dbQueue.read { db in
            try Self.fetchBoundaryUsage(
                db: db,
                boundaryIDsSubquery: "SELECT id FROM boundary WHERE id = ?",
                argument: boundaryID
            )
        }
    }

    func fetchBoundaryUsage(setID: Int64) throws -> BoundaryUsage {
        try dbQueue.read { db in
            try Self.fetchBoundaryUsage(
                db: db,
                boundaryIDsSubquery: "SELECT id FROM boundary WHERE boundary_set_id = ?",
                argument: setID
            )
        }
    }

    private static func fetchBoundaryUsage(
        db: Database,
        boundaryIDsSubquery: String,
        argument: Int64
    ) throws -> BoundaryUsage {
        let pointMapInstanceCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(DISTINCT instance_id) FROM pointmap_boundary WHERE boundary_id IN (\(boundaryIDsSubquery))",
            arguments: [argument]
        ) ?? 0
        let boundaryMapInstanceCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(DISTINCT instance_id) FROM boundarymap_attachment WHERE boundary_id IN (\(boundaryIDsSubquery))",
            arguments: [argument]
        ) ?? 0
        let boundaryMapQueryCount = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM boundarymap_query
                WHERE attachment_id IN (
                    SELECT id FROM boundarymap_attachment WHERE boundary_id IN (\(boundaryIDsSubquery))
                )
                """,
            arguments: [argument]
        ) ?? 0
        return BoundaryUsage(
            pointMapInstanceCount: pointMapInstanceCount,
            boundaryMapInstanceCount: boundaryMapInstanceCount,
            boundaryMapQueryCount: boundaryMapQueryCount
        )
    }

    static func parseMultiPolygonJSON(data: Data) -> ParsedMultiPolygon? {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let coords = root["coordinates"] as? [[[[Double]]]] else { return nil }
        let rings: [[[ParsedMultiPolygon.Coordinate]]] = coords.map { polygon in
            polygon.map { ring in
                ring.compactMap { pair -> ParsedMultiPolygon.Coordinate? in
                    guard pair.count == 2 else { return nil }
                    return ParsedMultiPolygon.Coordinate(
                        latitude: pair[1],
                        longitude: pair[0]
                    )
                }
            }
        }
        return ParsedMultiPolygon(rings: rings)
    }

    // MARK: - Writes

    func setBoundaryColor(boundaryID: Int64, color: BoundaryColor) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE boundary SET color = ? WHERE id = ?",
                arguments: [color.rawValue, boundaryID]
            )
        }
    }

    /// Renames one boundary. Unlike the set-level rename this is allowed inside
    /// built-in sets too: the Countries seed never re-runs, so a renamed
    /// country stays renamed. Names are not unique (uploads may repeat them),
    /// so the only rule is non-empty.
    func renameBoundary(id: Int64, newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BoundaryImportError(message: "Boundary name must not be empty.")
        }
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE boundary SET name = ? WHERE id = ?",
                arguments: [trimmed, id]
            )
            if db.changesCount == 0 {
                throw BoundaryImportError(message: "Boundary not found.")
            }
        }
    }

    /// Deletes one boundary. Allowed in built-in sets (like rename). Cascades:
    /// PointMap overlay links, BoundaryMap attachments, and those attachments'
    /// queries — see `fetchBoundaryUsage(boundaryID:)` for a confirmation.
    func deleteBoundary(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM boundary WHERE id = ?", arguments: [id])
            if db.changesCount == 0 {
                throw BoundaryImportError(message: "Boundary not found.")
            }
        }
    }

    /// Appends already-parsed features to an existing set (built-in included)
    /// and returns the new boundary ids in feature order. Names are not
    /// unique, so a re-imported feature simply becomes a second boundary.
    @discardableResult
    func addBoundaries(toSet setID: Int64, features: [ImportedBoundaryFeature]) throws -> [Int64] {
        guard !features.isEmpty else {
            throw BoundaryImportError(message: "No features to add.")
        }
        return try dbQueue.write { db in
            let setExists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM boundary_set WHERE id = ?)",
                arguments: [setID]
            ) ?? false
            guard setExists else {
                throw BoundaryImportError(message: "Boundary set not found.")
            }
            return try Self.insertBoundaries(in: db, setID: setID, features: features)
        }
    }

    func setBoundaries(forInstance instanceID: Int64, boundaryIDs: [Int64]) throws {
        try dbQueue.write { db in
            try Self.setBoundaries(db: db, instanceID: instanceID, boundaryIDs: boundaryIDs)
        }
    }

    static func setBoundaries(db: Database, instanceID: Int64, boundaryIDs: [Int64]) throws {
        try db.execute(
            sql: "DELETE FROM pointmap_boundary WHERE instance_id = ?",
            arguments: [instanceID]
        )
        for boundaryID in boundaryIDs {
            try db.execute(
                sql: """
                    INSERT INTO pointmap_boundary (instance_id, boundary_id)
                    VALUES (?, ?)
                    """,
                arguments: [instanceID, boundaryID]
            )
        }
    }

    /// Creates a user boundary set. `features` may be empty (an empty set is a
    /// valid container to add boundaries to later); a blank name falls back
    /// to "Uploaded Boundaries". Returns the set's id.
    @discardableResult
    func importBoundarySet(
        name: String,
        features: [ImportedBoundaryFeature]
    ) throws -> Int64 {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Uploaded Boundaries" : trimmed
        return try dbQueue.write { db in
            try Self.insertBoundarySet(in: db, name: finalName, isBuiltin: false, features: features)
        }
    }

    /// Inserts a boundary set and one `boundary` row per feature inside an
    /// existing write transaction. Shared by user uploads and the first-launch
    /// Countries seed (AppDatabase+BoundarySeed.swift). Returns the set's id.
    @discardableResult
    static func insertBoundarySet(
        in db: Database,
        name: String,
        isBuiltin: Bool,
        features: [ImportedBoundaryFeature]
    ) throws -> Int64 {
        let createdAt = Int64(Date().timeIntervalSince1970)
        try db.execute(
            sql: """
                INSERT INTO boundary_set (name, is_builtin, created_at)
                VALUES (?, ?, ?)
                """,
            arguments: [name, isBuiltin ? 1 : 0, createdAt]
        )
        let setID = db.lastInsertedRowID
        try insertBoundaries(in: db, setID: setID, features: features)
        return setID
    }

    /// One `boundary` row per feature, appended to `setID`. Returns the new
    /// ids in feature order.
    @discardableResult
    static func insertBoundaries(
        in db: Database,
        setID: Int64,
        features: [ImportedBoundaryFeature]
    ) throws -> [Int64] {
        let encoder = JSONEncoder()
        var ids: [Int64] = []
        ids.reserveCapacity(features.count)
        for feature in features {
            let normalized = NormalizedGeometry(
                type: "MultiPolygon",
                coordinates: feature.multiPolygonCoordinates
            )
            let bytes = try encoder.encode(normalized)
            try db.execute(
                sql: """
                    INSERT INTO boundary (boundary_set_id, name, geometry_json)
                    VALUES (?, ?, ?)
                    """,
                arguments: [setID, feature.name, bytes]
            )
            ids.append(db.lastInsertedRowID)
        }
        return ids
    }

    /// The shape stored in `boundary.geometry_json`: always a MultiPolygon,
    /// so a GeoJSON Polygon is wrapped as a one-polygon MultiPolygon on import.
    struct NormalizedGeometry: Codable {
        let type: String
        let coordinates: [[[[Double]]]]
    }

    func renameBoundarySet(id: Int64, newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BoundaryImportError(message: "Set name must not be empty.")
        }
        try dbQueue.write { db in
            guard let isBuiltin = try Int64.fetchOne(
                db,
                sql: "SELECT is_builtin FROM boundary_set WHERE id = ?",
                arguments: [id]
            ) else {
                throw BoundaryImportError(message: "Boundary set not found.")
            }
            if isBuiltin != 0 {
                throw BoundaryImportError(message: "Cannot rename built-in boundary sets.")
            }
            try db.execute(
                sql: "UPDATE boundary_set SET name = ? WHERE id = ?",
                arguments: [trimmed, id]
            )
        }
    }

    func deleteBoundarySet(id: Int64) throws {
        try dbQueue.write { db in
            guard let isBuiltin = try Int64.fetchOne(
                db,
                sql: "SELECT is_builtin FROM boundary_set WHERE id = ?",
                arguments: [id]
            ) else {
                throw BoundaryImportError(message: "Boundary set not found.")
            }
            if isBuiltin != 0 {
                throw BoundaryImportError(message: "Cannot delete built-in boundary sets.")
            }
            try db.execute(
                sql: "DELETE FROM boundary_set WHERE id = ?",
                arguments: [id]
            )
        }
    }
}
