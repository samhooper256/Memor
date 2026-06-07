//
//  BoundaryMapInstanceEditor.swift
//  Memor
//
//  BoundaryMap-specific models, sidebar entry row, and helpers used by the
//  instance editor.
//

import AppKit
import Combine
import CoreLocation
import Foundation
import MapKit
import SwiftUI

struct BoundaryMapAttachmentDraft: Identifiable, Hashable {
    let localID: UUID
    let boundaryID: Int64
    let name: String
    var forwardEnabled: Bool = true
    var reverseEnabled: Bool = false

    var id: UUID { localID }
}

enum BoundaryMapSortMode: Hashable, CaseIterable {
    case creation
    case alphabetical

    var displayName: String {
        switch self {
        case .creation: return "Creation order"
        case .alphabetical: return "A–Z"
        }
    }
}

enum BoundaryMapEntryRef: Hashable, Identifiable {
    case existing(Int64)
    case new(UUID)

    var id: String {
        switch self {
        case .existing(let id): return "e:\(id)"
        case .new(let localID): return "n:\(localID.uuidString)"
        }
    }
}

struct BoundaryMapEntryRow: View {
    let name: String
    @Binding var forwardEnabled: Bool
    @Binding var reverseEnabled: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(name.isEmpty ? "(unnamed)" : name)
                .foregroundStyle(name.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)

            ArrowCheckbox(isOn: $forwardEnabled, glyph: "\u{2192}", help: "Forward query (guess the name)")
            ArrowCheckbox(isOn: $reverseEnabled, glyph: "\u{2190}", help: "Reverse query (click the location)")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// Returns true if the given coordinate falls inside the outer ring of any
/// polygon in the geometry. Used by the editor to identify which attached
/// boundary the user right-clicked on.
func boundaryContains(coordinate: CLLocationCoordinate2D, geometry: ParsedMultiPolygon) -> Bool {
    for polygon in geometry.rings {
        guard let outer = polygon.first, outer.count >= 3 else { continue }
        if pointInRing(point: coordinate, ring: outer) {
            return true
        }
    }
    return false
}

private func pointInRing(
    point: CLLocationCoordinate2D,
    ring: [ParsedMultiPolygon.Coordinate]
) -> Bool {
    var inside = false
    var j = ring.count - 1
    for i in 0..<ring.count {
        let xi = ring[i].longitude
        let yi = ring[i].latitude
        let xj = ring[j].longitude
        let yj = ring[j].latitude
        let intersects = ((yi > point.latitude) != (yj > point.latitude))
            && (point.longitude < (xj - xi) * (point.latitude - yi) / (yj - yi + .leastNormalMagnitude) + xi)
        if intersects { inside.toggle() }
        j = i
    }
    return inside
}
