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

    /// Parses & validates the raw bytes of a user-uploaded .json/.geojson file
    /// and returns the individual features ready for insertion. Throws a
    /// human-readable error on any validation failure. Accepts either a
    /// top-level array of GeoJSON Feature objects or a top-level GeoJSON
    /// FeatureCollection object.
    static func parseUploadedBoundaryFile(data: Data) throws -> [ImportedBoundaryFeature] {
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
            guard let name = properties["name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BoundaryImportError(
                    message: "Feature #\(index + 1) is missing a non-empty 'properties.name' string."
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
                        name: row["boundary_name"] as String? ?? ""
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
                    SELECT id, boundary_set_id, name
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
                    name: row["name"] as String? ?? ""
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
                SELECT b.id AS id, b.name AS name, b.geometry_json AS geometry_json
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
                geometry: parsed
            )
        }
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

    @discardableResult
    func importBoundarySet(
        name: String,
        features: [ImportedBoundaryFeature]
    ) throws -> Int64 {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Uploaded Boundaries" : trimmed
        guard !features.isEmpty else {
            throw BoundaryImportError(message: "No features to import.")
        }
        let createdAt = Int64(Date().timeIntervalSince1970)
        let encoder = JSONEncoder()

        return try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO boundary_set (name, is_builtin, created_at)
                    VALUES (?, 0, ?)
                    """,
                arguments: [finalName, createdAt]
            )
            let setID = db.lastInsertedRowID

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
            }
            return setID
        }
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
