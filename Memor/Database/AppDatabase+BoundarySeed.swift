//
//  AppDatabase+BoundarySeed.swift
//  Memor
//
//  First-run seeding of the built-in "Countries" boundary set from the
//  bundled Natural Earth GeoJSON FeatureCollection.
//

import Foundation
import GRDB

extension AppDatabase {
    static let builtinCountryBoundarySetName = "Countries"

    /// The bundled Natural Earth "Admin 0 – Countries" layer at 1:50m scale
    /// (v5.1.2, an unmodified copy of the upstream file — see ATTRIBUTIONS.md).
    /// Each feature's `properties.NAME_EN` becomes the boundary's name.
    static let builtinCountryBoundaryResourceName = "ne_50m_admin_0_countries"
    static let builtinCountryBoundaryNameProperty = "NAME_EN"

    /// Seeds the built-in set the first time a database has none. Runs on
    /// every launch but returns immediately once a built-in set exists, so
    /// replacing the bundled file never touches an existing database. A
    /// missing or invalid file never throws: the seed is skipped with a
    /// console message and the app starts with no built-in boundaries.
    static func seedBuiltinCountryBoundaries(in db: Database) throws {
        let existingBuiltinCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM boundary_set WHERE is_builtin = 1"
        ) ?? 0
        if existingBuiltinCount > 0 { return }

        guard let url = Bundle.main.url(
            forResource: builtinCountryBoundaryResourceName,
            withExtension: "geojson"
        ) else {
            print("Boundary seed: \(builtinCountryBoundaryResourceName).geojson not found in bundle; skipping seed.")
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            print("Boundary seed: failed to read \(url.lastPathComponent): \(error)")
            return
        }

        // Same parser and validation as a user upload, so the bundled file is
        // held to the documented format (FeatureCollection or Feature array;
        // Polygon or MultiPolygon geometry, Polygons wrapped as MultiPolygons).
        let features: [ImportedBoundaryFeature]
        do {
            features = try parseUploadedBoundaryFile(
                data: data,
                nameProperty: builtinCountryBoundaryNameProperty
            )
        } catch {
            print("Boundary seed: bundled GeoJSON failed validation: \(error.localizedDescription)")
            return
        }

        try insertBoundarySet(
            in: db,
            name: builtinCountryBoundarySetName,
            isBuiltin: true,
            features: features
        )
    }
}
