//
//  DatabaseModels.swift
//  Memor
//
//  Plain-data structs and enums returned by AppDatabase.
//

import CoreLocation
import Foundation
import GRDB

nonisolated let POINTMAP_TYPE_NAME = "PointMap"
nonisolated let BOUNDARYMAP_TYPE_NAME = "BoundaryMap"

struct FlashcardType: Identifiable, FetchableRecord, Decodable, Hashable {
    let id: Int64
    let name: String
    let description: String
    let css: String
    let isBuiltin: Bool
    let instanceCount: Int
}

// Per-instance marker size for a PointMap. Medium == the historical fixed size.
// highlightedDiameter (answer/hover) is 1.5x normal, matching the original 12/18.
enum PointMapPointSize: String, Codable, CaseIterable, Hashable {
    case small
    case medium
    case large

    var normalDiameter: CGFloat {
        switch self {
        case .small: return 8
        case .medium: return 12
        case .large: return 18
        }
    }

    var highlightedDiameter: CGFloat {
        switch self {
        case .small: return 12
        case .medium: return 18
        case .large: return 27
        }
    }

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
}

struct PointMapInstance: Hashable {
    let instanceID: Int64
    let title: String
    let description: String
    let defaultCenterLat: Double
    let defaultCenterLng: Double
    let defaultZoom: Double
    let showAllPointsInQuestion: Bool
    var pointSize: PointMapPointSize = .medium
}

struct PointMapPoint: Identifiable, Hashable {
    let id: Int64
    let instanceID: Int64
    let name: String
    let latitude: Double
    let longitude: Double
    var forwardEnabled: Bool = true
    var reverseEnabled: Bool = false
    var forwardInterval: Int64 = 0
    var reverseInterval: Int64 = 0
    // Pre-reveal hint shown for Forward point queries in Study mode (default blank).
    var hint: String = ""
}

struct PointMapInstanceWithPoints: Hashable {
    let instance: PointMapInstance
    let points: [PointMapPoint]
    let boundaryIDs: [Int64]
}

struct BoundaryMapInstance: Hashable {
    let instanceID: Int64
    let title: String
    let description: String
    let defaultCenterLat: Double
    let defaultCenterLng: Double
    let defaultZoom: Double
    let showAllBoundariesInQuestion: Bool
}

struct BoundaryMapAttachedBoundary: Identifiable, Hashable {
    let id: Int64
    let instanceID: Int64
    let boundaryID: Int64
    let name: String
    var forwardEnabled: Bool = true
    var reverseEnabled: Bool = false
}

struct BoundaryMapInstanceWithBoundaries: Hashable {
    let instance: BoundaryMapInstance
    let attachments: [BoundaryMapAttachedBoundary]
}

// The kind of a field on an Object type. `text` is a free-text field;
// `boolean` is a checkbox stored as the text "0"/"1" in the type{N} table.
// A field's kind is fixed at creation time and cannot be changed afterward.
enum FieldKind: String, Codable, Hashable {
    case text
    case boolean
}

struct TypeField: Identifiable, FetchableRecord, Decodable {
    let id: Int64
    let typeID: Int64
    let name: String
    let fieldIndex: Int
    let fieldDisplayIndex: Int
    let isPrimary: Bool
    let fieldType: FieldKind

    init(
        id: Int64,
        typeID: Int64,
        name: String,
        fieldIndex: Int,
        fieldDisplayIndex: Int,
        isPrimary: Bool = false,
        fieldType: FieldKind = .text
    ) {
        self.id = id
        self.typeID = typeID
        self.name = name
        self.fieldIndex = fieldIndex
        self.fieldDisplayIndex = fieldDisplayIndex
        self.isPrimary = isPrimary
        self.fieldType = fieldType
    }

    // Lenient: SELECTs that don't project isPrimary / fieldType default them to
    // false / .text respectively.
    enum CodingKeys: String, CodingKey {
        case id, typeID, name, fieldIndex, fieldDisplayIndex, isPrimary, fieldType
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        typeID = try c.decode(Int64.self, forKey: .typeID)
        name = try c.decode(String.self, forKey: .name)
        fieldIndex = try c.decode(Int.self, forKey: .fieldIndex)
        fieldDisplayIndex = try c.decode(Int.self, forKey: .fieldDisplayIndex)
        isPrimary = (try? c.decodeIfPresent(Bool.self, forKey: .isPrimary)) ?? false
        fieldType = (try? c.decodeIfPresent(FieldKind.self, forKey: .fieldType)) ?? .text
    }
}

struct QueryType: Identifiable, FetchableRecord, Decodable {
    let id: Int64
    let typeID: Int64
    let name: String
    let questionHTML: String
    let answerHTML: String
}

struct Collection: Identifiable, FetchableRecord, Decodable, Hashable {
    let id: Int64
    let name: String
    let description: String
    let visibleBeforeAnswer: Bool
    let instanceCount: Int
}

struct CollectionChecklistItem: Identifiable, Hashable {
    let id: Int64
    let name: String
    let isPinned: Bool
}

struct ImageFolderAccess: Identifiable, FetchableRecord, Decodable, Hashable {
    let id: Int64
    let path: String
}

struct Stack: Identifiable, FetchableRecord, Decodable, Hashable {
    let id: Int64
    let name: String
    let search: String
    let description: String
    let isPinned: Bool
    let blueQueryCount: Int
    let redQueryCount: Int
    let greenQueryCount: Int
    let magentaQueryCount: Int
}

struct CollectionInstanceSummary: Identifiable, Hashable {
    let id: Int64
    let displayValue: String
}

struct CollectionInstanceMembershipChange: Hashable {
    let collectionID: Int64
    let nonce: UUID
}

struct InstanceSearchSection: Identifiable, Hashable {
    let typeID: Int64
    let typeName: String
    let instances: [InstanceSearchResult]

    var id: Int64 { typeID }
}

struct InstanceSearchResult: Identifiable, Hashable {
    let id: Int64
    let displayValue: String
}

struct QuerySearchSection: Identifiable, Hashable {
    let typeID: Int64
    let typeName: String
    let queries: [QuerySearchResult]

    var id: Int64 { typeID }
}

struct QuerySearchResult: Identifiable, Hashable {
    let instanceID: Int64
    let queryTypeID: Int64
    let displayValue: String
    let queryTypeName: String
    // Map queries only: distinguishes a point/boundary's forward query from its
    // reverse query. Standard queries are always forward. Included in `id` so the
    // two directions are distinct, selectable rows.
    var isReverse: Bool = false

    var id: String { "\(instanceID):\(queryTypeID):\(isReverse ? "r" : "f")" }
}

enum MapElementKind: String, Hashable {
    case point
    case boundary
}

struct MapElementSearchSection: Identifiable, Hashable {
    let typeID: Int64
    let typeName: String
    let elements: [MapElementSearchResult]

    var id: Int64 { typeID }
}

struct MapElementSearchResult: Identifiable, Hashable {
    let instanceID: Int64
    let elementID: Int64       // pointID or attachmentID
    let displayValue: String   // instance title
    let elementName: String    // point/boundary name
    let kind: MapElementKind

    var id: String { "\(instanceID):\(elementID):\(kind.rawValue)" }
}

enum QueryTargetKind: Hashable {
    case standard   // `query` table, by (instance_id, query_type_id)
    case point      // `pointmap_query`, by (point_id, is_reverse)
    case boundary   // `boundarymap_query`, by (attachment_id, is_reverse)
}

// Identifies a single studyable query (a specific direction for map queries) so
// it can be reset or disabled. `queryTypeID` is a query_type id for standard
// queries, a point id for points, or an attachment id for boundaries.
struct QueryTarget: Hashable {
    let instanceID: Int64
    let queryTypeID: Int64
    let isReverse: Bool
    let kind: QueryTargetKind
}

struct TypeInstancesPageData {
    let displayFieldName: String
    let queryTypes: [QueryType]
    var rows: [TypeInstancesPageRow]
}

struct TypeInstancesPageRow: Identifiable, Hashable {
    let id: Int64
    let displayValue: String
    let enabledQueryTypeIDs: Set<Int64>
}

struct InstanceEditorData: Hashable {
    let instanceID: Int64
    let typeID: Int64
    let fieldValuesByFieldID: [Int64: String]
    let enabledQueryTypeIDs: Set<Int64>
    let maxInterval: Int64?
}

// Per-query SRS state for one instance, used by the MCP get_instance tool.
struct QuerySRSInfo: Hashable {
    let queryTypeID: Int64
    let interval: Int64
    let queryState: QueryState
    let lastAnsweredTimestamp: Int64?
    let maxInterval: Int64?
}

nonisolated struct StackQueryCounts: Hashable {
    let blueQueryCount: Int
    let redQueryCount: Int
    let greenQueryCount: Int
    let magentaQueryCount: Int
}

// Everything the Stacks page shows after a refresh, computed in one database
// round trip. A nil counts value means that stack's search failed to parse or
// validate.
nonisolated struct StacksRefreshData {
    let queryCountsByStackID: [Int64: StackQueryCounts?]
    let lastUpdatedTimestamp: Date
    let averageQueryInterval: Double?
}

enum StudyResponseRating: CaseIterable, Hashable {
    case again
    case hard
    case good
    case easy
}

enum StudyQueryKind: Hashable {
    case standard
    case pointMap
    case boundaryMap
}

struct PointMapStudyPayload: Hashable {
    let pointID: Int64
    let pointName: String
    let instanceTitle: String
    let points: [PointMapPoint]
    let defaultCenterLat: Double
    let defaultCenterLng: Double
    let defaultZoom: Double
    let showAllPointsInQuestion: Bool
    var showHighlight: Bool = true
    var boundaries: [BoundaryGeometry] = []
    var isReverse: Bool = false
    // The answer point's hint, shown before reveal on Forward queries (default blank).
    var hint: String = ""
    // Per-instance marker size for rendering the points on the map.
    var pointSize: PointMapPointSize = .medium
}

struct BoundaryMapStudyPayload: Hashable {
    let attachmentID: Int64
    let boundaryID: Int64
    let boundaryName: String
    let instanceTitle: String
    let geometries: [BoundaryGeometry]
    let defaultCenterLat: Double
    let defaultCenterLng: Double
    let defaultZoom: Double
    let showAllBoundariesInQuestion: Bool
    var showHighlight: Bool = true
    var isReverse: Bool = false
}

struct BoundarySet: Identifiable, Hashable {
    let id: Int64
    let name: String
    let isBuiltin: Bool
    let createdAt: Int64
    let boundaryCount: Int
}

struct Boundary: Identifiable, Hashable {
    let id: Int64
    let boundarySetID: Int64
    let name: String
}

struct BoundaryWithSet: Identifiable, Hashable {
    let boundary: Boundary
    let setName: String
    let isBuiltin: Bool

    var id: Int64 { boundary.id }
}

struct ParsedMultiPolygon: Hashable {
    // Outer index = polygon; next index = ring (0 = outer, 1+ = holes); innermost = coordinate list.
    let rings: [[[Coordinate]]]

    struct Coordinate: Hashable {
        let latitude: Double
        let longitude: Double

        var clLocation: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }
}

struct BoundaryGeometry: Identifiable, Hashable {
    let id: Int64
    let name: String
    let geometry: ParsedMultiPolygon
}

struct StudyQuery: Identifiable, Hashable {
    let instanceID: Int64
    let queryTypeID: Int64
    let interval: Int64
    let maxInterval: Int64?
    let lastAnsweredTimestamp: Int64?
    let queryState: QueryState
    let typeName: String
    let queryTypeName: String
    let questionHTML: String
    let answerHTML: String
    let typeCSS: String
    let fieldValuesByName: [String: String]
    // Names of the instance's boolean fields, so the template renderer can map
    // {{Name}} → "true"/"false" and {{Name:bit}} → "1"/"0". Empty for map queries.
    var booleanFieldNames: Set<String> = []
    var kind: StudyQueryKind = .standard
    var pointMapPayload: PointMapStudyPayload? = nil
    var boundaryMapPayload: BoundaryMapStudyPayload? = nil
    // Map queries only: distinguishes a point/boundary's forward card from its
    // reverse card. Standard queries are always forward. Included in `id` so the
    // two directions are distinct cards for study selection, undo, and dedup.
    var isReverse: Bool = false

    var id: String { "\(instanceID):\(queryTypeID):\(isReverse ? "r" : "f")" }

    func withFieldValues(_ newFieldValuesByName: [String: String]) -> StudyQuery {
        StudyQuery(
            instanceID: instanceID,
            queryTypeID: queryTypeID,
            interval: interval,
            maxInterval: maxInterval,
            lastAnsweredTimestamp: lastAnsweredTimestamp,
            queryState: queryState,
            typeName: typeName,
            queryTypeName: queryTypeName,
            questionHTML: questionHTML,
            answerHTML: answerHTML,
            typeCSS: typeCSS,
            fieldValuesByName: newFieldValuesByName,
            booleanFieldNames: booleanFieldNames,
            kind: kind,
            pointMapPayload: pointMapPayload,
            boundaryMapPayload: boundaryMapPayload,
            isReverse: isReverse
        )
    }
}

enum StudySelectionResult: Hashable {
    case query(StudyQuery)
    case completed
}

struct StudyQueryBuckets: Hashable {
    let blueQueries: [StudyQuery]
    let redQueries: [StudyQuery]
    let greenQueries: [StudyQuery]
}

struct GraphNode: Hashable {
    let instanceID: Int64
    let label: String
}

struct GraphEdge: Hashable {
    let fromInstanceID: Int64
    let toInstanceID: Int64
}

struct GraphData: Hashable {
    let nodes: [GraphNode]
    let sourceNodeIDs: Set<Int64>
    let edges: [GraphEdge]
}
