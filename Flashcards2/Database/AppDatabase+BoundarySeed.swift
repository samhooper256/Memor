//
//  AppDatabase+BoundarySeed.swift
//  Memor
//
//  First-run seeding of the built-in country-boundary set from a bundled
//  GeoJSON resource.
//

import Foundation
import GRDB

extension AppDatabase {
    static let builtinCountryBoundarySetName = "Countries"

    struct BundledBoundaryFeature: Decodable {
        let name: String
        let geometry: BundledGeometry

        struct BundledGeometry: Decodable {
            let type: String
            let coordinates: [[[[Double]]]]
        }
    }

    static func seedBuiltinCountryBoundaries(in db: Database) throws {
        let existingBuiltinCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM boundary_set WHERE is_builtin = 1"
        ) ?? 0
        if existingBuiltinCount > 0 { return }

        guard let url = Bundle.main.url(forResource: "world_countries", withExtension: "geojson") else {
            print("Boundary seed: world_countries.geojson not found in bundle; skipping seed.")
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            print("Boundary seed: failed to read \(url.lastPathComponent): \(error)")
            return
        }

        let features: [BundledBoundaryFeature]
        do {
            features = try JSONDecoder().decode([BundledBoundaryFeature].self, from: data)
        } catch {
            print("Boundary seed: failed to decode bundled GeoJSON: \(error)")
            return
        }

        let createdAt = Int64(Date().timeIntervalSince1970)
        try db.execute(
            sql: """
                INSERT INTO boundary_set (name, is_builtin, created_at)
                VALUES (?, 1, ?)
                """,
            arguments: [builtinCountryBoundarySetName, createdAt]
        )
        let setID = db.lastInsertedRowID

        let encoder = JSONEncoder()
        for feature in features {
            guard feature.geometry.type == "MultiPolygon" else { continue }
            let normalized = NormalizedGeometry(
                type: "MultiPolygon",
                coordinates: feature.geometry.coordinates
            )
            guard let geometryBytes = try? encoder.encode(normalized) else { continue }
            try db.execute(
                sql: """
                    INSERT INTO boundary (boundary_set_id, name, geometry_json)
                    VALUES (?, ?, ?)
                    """,
                arguments: [setID, feature.name, geometryBytes]
            )
        }
    }

    struct NormalizedGeometry: Codable {
        let type: String
        let coordinates: [[[[Double]]]]
    }
}
