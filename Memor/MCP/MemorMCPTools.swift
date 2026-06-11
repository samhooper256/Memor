import Foundation
import GRDB
import MCP

enum MemorMCPTools {

    static func register(on server: Server, appDatabase: AppDatabase) async {
        let tools = allTools()

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            do {
                return try await dispatch(name: params.name, arguments: params.arguments ?? [:], appDatabase: appDatabase)
            } catch let error as MemorMCPToolError {
                return CallTool.Result(content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
            } catch {
                return CallTool.Result(content: [.text(text: "Unexpected error: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    // MARK: - Dispatch

    private static func dispatch(name: String, arguments: [String: Value], appDatabase: AppDatabase) async throws -> CallTool.Result {
        switch name {

        // Types
        case "list_types":
            return try jsonResult(listTypes(appDatabase: appDatabase))
        case "get_type":
            let typeID = try arguments.requireInt64("type_id")
            return try jsonResult(getType(typeID: typeID, appDatabase: appDatabase))

        // Instances
        case "create_instance":
            let typeID = try arguments.requireInt64("type_id")
            let fieldValuesByID = try arguments.optionalInt64KeyedStringMap("field_values_by_field_id")
            let fieldValuesByName = try arguments.optionalStringKeyedStringMap("field_values_by_field_name")
            let queryTypeIDs = try arguments.optionalInt64Array("query_type_ids") ?? []
            let rawLinks = try arguments.optionalValueObject("links")
            let created = try createInstanceCore(
                typeID: typeID,
                fieldValuesByID: fieldValuesByID,
                fieldValuesByName: fieldValuesByName,
                queryTypeIDs: Set(queryTypeIDs),
                rawLinks: rawLinks,
                appDatabase: appDatabase
            )
            postDatabaseChange()
            return try jsonResult(created)
        case "create_instances":
            let items = try arguments.requireObjectArray("instances")
            return try jsonResult(createInstances(items: items, appDatabase: appDatabase))
        case "update_instance":
            let instanceID = try arguments.requireInt64("instance_id")
            let fieldValuesByID = try arguments.optionalInt64KeyedStringMap("field_values_by_field_id")
            let fieldValuesByName = try arguments.optionalStringKeyedStringMap("field_values_by_field_name")
            let queryTypeIDs = try arguments.optionalInt64Array("query_type_ids").map(Set.init)
            let rawLinks = try arguments.optionalValueObject("links")
            return try jsonResult(updateInstance(
                instanceID: instanceID,
                fieldValuesByID: fieldValuesByID,
                fieldValuesByName: fieldValuesByName,
                queryTypeIDs: queryTypeIDs,
                rawLinks: rawLinks,
                appDatabase: appDatabase
            ))
        case "delete_instance":
            let instanceID = try arguments.requireInt64("instance_id")
            return try jsonResult(deleteInstance(instanceID: instanceID, appDatabase: appDatabase))
        case "get_instance":
            let instanceID = try arguments.requireInt64("instance_id")
            return try getInstanceResult(instanceID: instanceID, appDatabase: appDatabase)
        case "search_instances":
            let query = try arguments.requireString("query")
            return try jsonResult(searchInstances(query: query, appDatabase: appDatabase))

        // PointMap
        case "add_pointmap_point":
            let instanceID = try arguments.requireInt64("instance_id")
            let name = try arguments.requireString("name")
            let latitude = try arguments.requireDouble("latitude")
            let longitude = try arguments.requireDouble("longitude")
            let forwardEnabled = try arguments.optionalBool("forward_enabled") ?? true
            let reverseEnabled = try arguments.optionalBool("reverse_enabled") ?? false
            return try jsonResult(addPointMapPoint(
                instanceID: instanceID,
                name: name,
                latitude: latitude,
                longitude: longitude,
                forwardEnabled: forwardEnabled,
                reverseEnabled: reverseEnabled,
                appDatabase: appDatabase
            ))

        // Collections
        case "list_collections":
            return try jsonResult(listCollections(appDatabase: appDatabase))
        case "get_collection":
            let collectionID = try arguments.requireInt64("collection_id")
            return try jsonResult(getCollection(collectionID: collectionID, appDatabase: appDatabase))
        case "create_collection":
            let name = try arguments.requireString("name")
            return try jsonResult(createCollection(name: name, appDatabase: appDatabase))
        case "delete_collection":
            let collectionID = try arguments.requireInt64("collection_id")
            return try jsonResult(deleteCollection(collectionID: collectionID, appDatabase: appDatabase))
        case "rename_collection":
            let collectionID = try arguments.requireInt64("collection_id")
            let newName = try arguments.requireString("new_name")
            return try jsonResult(renameCollection(collectionID: collectionID, newName: newName, appDatabase: appDatabase))
        case "add_instance_to_collection":
            let instanceID = try arguments.requireInt64("instance_id")
            let collectionID = try arguments.requireInt64("collection_id")
            return try jsonResult(addInstanceToCollection(instanceID: instanceID, collectionID: collectionID, appDatabase: appDatabase))
        case "add_instances_to_collection":
            let instanceIDs = try arguments.requireInt64Array("instance_ids")
            let collectionID = try arguments.requireInt64("collection_id")
            return try jsonResult(addInstancesToCollection(instanceIDs: instanceIDs, collectionID: collectionID, appDatabase: appDatabase))
        case "remove_instance_from_collection":
            let instanceID = try arguments.requireInt64("instance_id")
            let collectionID = try arguments.requireInt64("collection_id")
            return try jsonResult(removeInstanceFromCollection(instanceID: instanceID, collectionID: collectionID, appDatabase: appDatabase))

        // Queries
        case "search_queries":
            let query = try arguments.requireString("query")
            return try jsonResult(searchQueries(query: query, appDatabase: appDatabase))

        // Stacks
        case "list_stacks":
            return try jsonResult(listStacks(appDatabase: appDatabase))
        case "create_stack":
            let name = try arguments.requireString("name")
            let search = try arguments.requireString("search")
            return try jsonResult(createStack(name: name, search: search, appDatabase: appDatabase))
        case "update_stack":
            let stackID = try arguments.requireInt64("stack_id")
            let newName = try arguments.optionalString("name")
            let newSearch = try arguments.optionalString("search")
            return try jsonResult(updateStack(stackID: stackID, name: newName, search: newSearch, appDatabase: appDatabase))
        case "delete_stack":
            let stackID = try arguments.requireInt64("stack_id")
            return try jsonResult(deleteStack(stackID: stackID, appDatabase: appDatabase))

        default:
            return CallTool.Result(content: [.text(text: "Unknown tool: \(name)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    private static func jsonResult<T: Encodable>(_ value: T) throws -> CallTool.Result {
        let data = try encoder.encode(value)
        let string = String(data: data, encoding: .utf8) ?? "{}"
        return CallTool.Result(content: [.text(text: string, annotations: nil, _meta: nil)], isError: false)
    }

    // MARK: - Type tools

    private static func listTypes(appDatabase: AppDatabase) throws -> [TypeSummaryDTO] {
        let types = try appDatabase.fetchTypes()
        return types.map(TypeSummaryDTO.init)
    }

    private static func getType(typeID: Int64, appDatabase: AppDatabase) throws -> TypeDetailDTO {
        guard let type = try appDatabase.fetchType(typeID: typeID) else {
            throw MemorMCPToolError(message: "Type not found: \(typeID).")
        }
        let fields = try appDatabase.fetchFields(forTypeID: typeID)
        let queryTypes = try appDatabase.fetchQueryTypes(forTypeID: typeID)
        return TypeDetailDTO(
            id: type.id,
            name: type.name,
            isBuiltin: type.isBuiltin,
            isPointMap: type.name == POINTMAP_TYPE_NAME,
            isBoundaryMap: type.name == BOUNDARYMAP_TYPE_NAME,
            isNode: type.isNode,
            instanceCount: type.instanceCount,
            fields: fields.map(FieldDTO.init),
            queryTypes: queryTypes.map(QueryTypeDTO.init)
        )
    }

    // MARK: - Instance tools

    /// Creates one instance without posting a database-change notification, so
    /// `create_instances` can batch many creations behind a single post.
    private static func createInstanceCore(
        typeID: Int64,
        fieldValuesByID: [Int64: String]?,
        fieldValuesByName: [String: String]?,
        queryTypeIDs: Set<Int64>,
        rawLinks: [String: Value]?,
        appDatabase: AppDatabase
    ) throws -> CreatedInstanceDTO {
        guard let type = try appDatabase.fetchType(typeID: typeID) else {
            throw MemorMCPToolError(message: "Type not found: \(typeID).")
        }
        if type.name == POINTMAP_TYPE_NAME {
            throw MemorMCPToolError(message: "Use create_pointmap_instance to create PointMap instances.")
        }
        if type.name == BOUNDARYMAP_TYPE_NAME {
            throw MemorMCPToolError(message: "Use create_boundarymap_instance to create BoundaryMap instances.")
        }
        if fieldValuesByID == nil && fieldValuesByName == nil {
            throw MemorMCPToolError(message: "Provide at least one of `field_values_by_field_id` or `field_values_by_field_name`.")
        }
        if rawLinks != nil && !type.isNode {
            throw MemorMCPToolError(message: "`links` is only valid for Node types; type \(typeID) (\(type.name)) is not a Node type.")
        }
        let fieldValues = try resolveFieldValues(
            typeID: typeID,
            byID: fieldValuesByID,
            byName: fieldValuesByName,
            appDatabase: appDatabase
        )
        var links: [Int64: [Int64]] = [:]
        if type.isNode {
            let linkFields = try appDatabase.fetchLinkFields(forTypeID: typeID)
            links = try resolveLinks(rawLinks: rawLinks ?? [:], linkFields: linkFields)
            try validateLinkCounts(linkFields: linkFields, links: links)
        }
        let instanceID = try appDatabase.makeInstance(
            forTypeID: typeID,
            fieldValuesByFieldID: fieldValues,
            queryTypeIDs: queryTypeIDs,
            linksByLinkFieldID: links
        )
        return CreatedInstanceDTO(instanceID: instanceID, typeID: typeID)
    }

    private static func createInstances(
        items: [[String: Value]],
        appDatabase: AppDatabase
    ) throws -> [BatchCreateResultDTO] {
        if items.isEmpty {
            throw MemorMCPToolError(message: "`instances` must contain at least one item.")
        }
        var results: [BatchCreateResultDTO] = []
        results.reserveCapacity(items.count)
        var anySucceeded = false
        for (index, item) in items.enumerated() {
            do {
                let typeID = try item.requireInt64("type_id")
                let fieldValuesByID = try item.optionalInt64KeyedStringMap("field_values_by_field_id")
                let fieldValuesByName = try item.optionalStringKeyedStringMap("field_values_by_field_name")
                let queryTypeIDs = Set(try item.optionalInt64Array("query_type_ids") ?? [])
                let rawLinks = try item.optionalValueObject("links")
                let created = try createInstanceCore(
                    typeID: typeID,
                    fieldValuesByID: fieldValuesByID,
                    fieldValuesByName: fieldValuesByName,
                    queryTypeIDs: queryTypeIDs,
                    rawLinks: rawLinks,
                    appDatabase: appDatabase
                )
                anySucceeded = true
                results.append(BatchCreateResultDTO(
                    index: index,
                    ok: true,
                    instanceID: created.instanceID,
                    typeID: created.typeID,
                    error: nil
                ))
            } catch {
                results.append(BatchCreateResultDTO(
                    index: index,
                    ok: false,
                    instanceID: nil,
                    typeID: nil,
                    error: toolErrorMessage(from: error)
                ))
            }
        }
        if anySucceeded {
            postDatabaseChange()
        }
        return results
    }

    private static func updateInstance(
        instanceID: Int64,
        fieldValuesByID: [Int64: String]?,
        fieldValuesByName: [String: String]?,
        queryTypeIDs: Set<Int64>?,
        rawLinks: [String: Value]?,
        appDatabase: AppDatabase
    ) throws -> OkDTO {
        let current = try appDatabase.fetchInstanceEditorData(instanceID: instanceID)
        guard let type = try appDatabase.fetchType(typeID: current.typeID) else {
            throw MemorMCPToolError(message: "Type not found: \(current.typeID).")
        }
        if type.name == POINTMAP_TYPE_NAME {
            throw MemorMCPToolError(message: "Use update_pointmap_instance / update_pointmap_point to edit PointMap instances.")
        }
        if type.name == BOUNDARYMAP_TYPE_NAME {
            throw MemorMCPToolError(message: "Use update_boundarymap_instance to edit BoundaryMap instances.")
        }
        if rawLinks != nil && !type.isNode {
            throw MemorMCPToolError(message: "`links` is only valid for Node types; instance \(instanceID) is not a Node instance.")
        }

        var mergedFieldValues = current.fieldValuesByFieldID
        if fieldValuesByID != nil || fieldValuesByName != nil {
            let updates = try resolveFieldValues(
                typeID: current.typeID,
                byID: fieldValuesByID,
                byName: fieldValuesByName,
                appDatabase: appDatabase
            )
            mergedFieldValues.merge(updates) { _, new in new }
        }
        let mergedQueryTypeIDs = queryTypeIDs ?? current.enabledQueryTypeIDs

        // AppDatabase.updateInstance rewrites ALL of a node instance's links from
        // the map it's given, so always pass the full merged map — passing only
        // the changed fields (or [:]) would silently wipe the others.
        var mergedLinks = current.linkTargetsByLinkFieldID
        if type.isNode, let rawLinks {
            let linkFields = try appDatabase.fetchLinkFields(forTypeID: current.typeID)
            let updates = try resolveLinks(rawLinks: rawLinks, linkFields: linkFields)
            mergedLinks.merge(updates) { _, new in new }
            try validateLinkCounts(linkFields: linkFields, links: mergedLinks, onlyLinkFieldIDs: Set(updates.keys))
        }

        try appDatabase.updateInstance(
            instanceID: instanceID,
            fieldValuesByFieldID: mergedFieldValues,
            queryTypeIDs: mergedQueryTypeIDs,
            linksByLinkFieldID: mergedLinks
        )
        postDatabaseChange()
        return OkDTO()
    }

    private static func deleteInstance(instanceID: Int64, appDatabase: AppDatabase) throws -> OkDTO {
        try appDatabase.deleteInstance(instanceID: instanceID)
        postDatabaseChange()
        return OkDTO()
    }

    private static func getInstanceResult(instanceID: Int64, appDatabase: AppDatabase) throws -> CallTool.Result {
        if let pointMap = try appDatabase.fetchPointMapInstance(instanceID: instanceID) {
            return try jsonResult(PointMapInstanceDTO(pointMap))
        }
        if let boundaryMap = try appDatabase.fetchBoundaryMapInstance(instanceID: instanceID) {
            return try jsonResult(BoundaryMapInstanceDTO(boundaryMap))
        }
        return try jsonResult(getInstance(instanceID: instanceID, appDatabase: appDatabase))
    }

    private static func getInstance(instanceID: Int64, appDatabase: AppDatabase) throws -> InstanceDetailDTO {
        let data = try appDatabase.fetchInstanceEditorData(instanceID: instanceID)
        guard let type = try appDatabase.fetchType(typeID: data.typeID) else {
            throw MemorMCPToolError(message: "Type not found: \(data.typeID).")
        }
        let fields = try appDatabase.fetchFields(forTypeID: data.typeID)
        let fieldRows = fields.map { field in
            InstanceFieldValueDTO(
                fieldID: field.id,
                name: field.name,
                value: data.fieldValuesByFieldID[field.id] ?? ""
            )
        }

        let queryTypes = try appDatabase.fetchQueryTypes(forTypeID: data.typeID)
        let srsInfoByQueryTypeID = Dictionary(
            uniqueKeysWithValues: try appDatabase.fetchQuerySRSInfo(forInstanceID: instanceID).map { ($0.queryTypeID, $0) }
        )
        let queries = queryTypes.map { queryType in
            let srs = srsInfoByQueryTypeID[queryType.id]
            return InstanceQueryInfoDTO(
                queryTypeID: queryType.id,
                name: queryType.name,
                isLinkQuery: queryType.isLinkQuery,
                enabled: data.enabledQueryTypeIDs.contains(queryType.id),
                interval: srs?.interval,
                queryState: srs?.queryState.rawValue,
                lastAnsweredTimestamp: srs?.lastAnsweredTimestamp
            )
        }

        var links: [NodeLinkFieldDTO]? = nil
        if type.isNode {
            let linkFields = try appDatabase.fetchLinkFields(forTypeID: data.typeID)
            links = linkFields.map { linkField in
                let targetIDs = data.linkTargetsByLinkFieldID[linkField.id] ?? []
                return NodeLinkFieldDTO(
                    linkFieldID: linkField.id,
                    name: linkField.name,
                    minCount: linkField.minCount,
                    maxCount: linkField.maxCount,
                    targets: targetIDs.map { targetID in
                        NodeLinkTargetDTO(id: targetID, displayValue: data.linkedNodeSummaries[targetID] ?? "")
                    }
                )
            }
        }

        return InstanceDetailDTO(
            instanceID: data.instanceID,
            typeID: data.typeID,
            typeName: type.name,
            isNode: type.isNode,
            maxInterval: data.maxInterval,
            fields: fieldRows,
            enabledQueryTypeIDs: Array(data.enabledQueryTypeIDs).sorted(),
            queries: queries,
            links: links
        )
    }

    private static func searchInstances(query: String, appDatabase: AppDatabase) throws -> [InstanceSearchSectionDTO] {
        let sections = try appDatabase.searchInstances(query: query)
        return sections.map(InstanceSearchSectionDTO.init)
    }

    // MARK: - PointMap tools

    private static func addPointMapPoint(
        instanceID: Int64,
        name: String,
        latitude: Double,
        longitude: Double,
        forwardEnabled: Bool,
        reverseEnabled: Bool,
        appDatabase: AppDatabase
    ) throws -> CreatedPointDTO {
        guard (try? appDatabase.fetchPointMapInstance(instanceID: instanceID)) ?? nil != nil else {
            throw MemorMCPToolError(message: "No PointMap instance with id \(instanceID).")
        }
        guard latitude >= -90, latitude <= 90 else {
            throw MemorMCPToolError(message: "latitude must be between -90 and 90.")
        }
        guard longitude >= -180, longitude <= 180 else {
            throw MemorMCPToolError(message: "longitude must be between -180 and 180.")
        }
        let pointID = try appDatabase.addPointMapPoint(
            instanceID: instanceID,
            name: name,
            latitude: latitude,
            longitude: longitude,
            forwardEnabled: forwardEnabled,
            reverseEnabled: reverseEnabled
        )
        postDatabaseChange()
        return CreatedPointDTO(pointID: pointID, instanceID: instanceID)
    }

    // MARK: - Collection tools

    private static func listCollections(appDatabase: AppDatabase) throws -> [CollectionDTO] {
        try appDatabase.fetchCollections().map(CollectionDTO.init)
    }

    private static func getCollection(collectionID: Int64, appDatabase: AppDatabase) throws -> CollectionDetailDTO {
        let collections = try appDatabase.fetchCollections()
        guard let collection = collections.first(where: { $0.id == collectionID }) else {
            throw MemorMCPToolError(message: "Collection not found: \(collectionID).")
        }
        let instances = try appDatabase.fetchCollectionInstances(collectionID: collectionID)
        return CollectionDetailDTO(
            collection: CollectionDTO(collection),
            instances: instances.map { CollectionInstanceDTO(id: $0.id, displayValue: $0.displayValue) }
        )
    }

    private static func createCollection(name: String, appDatabase: AppDatabase) throws -> CollectionDTO {
        let collection = try appDatabase.createCollection(name: name)
        postDatabaseChange()
        return CollectionDTO(collection)
    }

    private static func deleteCollection(collectionID: Int64, appDatabase: AppDatabase) throws -> OkDTO {
        try appDatabase.deleteCollection(id: collectionID)
        postDatabaseChange()
        return OkDTO()
    }

    private static func renameCollection(collectionID: Int64, newName: String, appDatabase: AppDatabase) throws -> OkDTO {
        try appDatabase.renameCollection(id: collectionID, to: newName)
        postDatabaseChange()
        return OkDTO()
    }

    private static func addInstanceToCollection(instanceID: Int64, collectionID: Int64, appDatabase: AppDatabase) throws -> OkDTO {
        try appDatabase.addInstance(instanceID, toCollectionID: collectionID)
        postDatabaseChange()
        return OkDTO()
    }

    private static func addInstancesToCollection(instanceIDs: [Int64], collectionID: Int64, appDatabase: AppDatabase) throws -> OkDTO {
        if instanceIDs.isEmpty {
            throw MemorMCPToolError(message: "`instance_ids` must contain at least one instance ID.")
        }
        for instanceID in instanceIDs {
            try appDatabase.addInstance(instanceID, toCollectionID: collectionID)
        }
        postDatabaseChange()
        return OkDTO()
    }

    private static func removeInstanceFromCollection(instanceID: Int64, collectionID: Int64, appDatabase: AppDatabase) throws -> OkDTO {
        try appDatabase.removeInstance(instanceID, fromCollectionID: collectionID)
        postDatabaseChange()
        return OkDTO()
    }

    // MARK: - Query tools

    private static func searchQueries(query: String, appDatabase: AppDatabase) throws -> [QuerySearchSectionDTO] {
        try appDatabase.searchQueries(query: query).map(QuerySearchSectionDTO.init)
    }

    // MARK: - Stack tools

    private static func listStacks(appDatabase: AppDatabase) throws -> [StackDTO] {
        try appDatabase.fetchStacks().map(StackDTO.init)
    }

    private static func createStack(name: String, search: String, appDatabase: AppDatabase) throws -> StackDTO {
        let stack = try appDatabase.createStack(name: name, search: search)
        postDatabaseChange()
        return StackDTO(stack)
    }

    private static func updateStack(stackID: Int64, name: String?, search: String?, appDatabase: AppDatabase) throws -> OkDTO {
        if name == nil && search == nil {
            throw MemorMCPToolError(message: "update_stack requires at least one of `name` or `search`.")
        }
        if let name = name {
            try appDatabase.updateStackName(id: stackID, name: name)
        }
        if let search = search {
            try appDatabase.updateStackSearch(id: stackID, search: search)
        }
        postDatabaseChange()
        return OkDTO()
    }

    private static func deleteStack(stackID: Int64, appDatabase: AppDatabase) throws -> OkDTO {
        try appDatabase.deleteStack(id: stackID)
        postDatabaseChange()
        return OkDTO()
    }

    // MARK: - Field-name / link resolution

    /// Merges ID-keyed and name-keyed field-value maps into a single ID-keyed
    /// map. Names resolve case-sensitively first, then case-insensitively when
    /// unique. ID-keyed entries win when both maps target the same field.
    private static func resolveFieldValues(
        typeID: Int64,
        byID: [Int64: String]?,
        byName: [String: String]?,
        appDatabase: AppDatabase
    ) throws -> [Int64: String] {
        var resolved: [Int64: String] = [:]
        if let byName, !byName.isEmpty {
            let fields = try appDatabase.fetchFields(forTypeID: typeID)
            for (name, value) in byName {
                if let exact = fields.first(where: { $0.name == name }) {
                    resolved[exact.id] = value
                    continue
                }
                let caseInsensitive = fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                if caseInsensitive.count == 1 {
                    resolved[caseInsensitive[0].id] = value
                } else if caseInsensitive.count > 1 {
                    throw MemorMCPToolError(message: "Field name `\(name)` in `field_values_by_field_name` matches multiple fields case-insensitively; use `field_values_by_field_id` instead.")
                } else {
                    let available = fields.map(\.name).joined(separator: ", ")
                    throw MemorMCPToolError(message: "Unknown field name `\(name)` in `field_values_by_field_name`. Available fields: \(available).")
                }
            }
        }
        if let byID {
            resolved.merge(byID) { _, idKeyed in idKeyed }
        }
        return resolved
    }

    /// Decodes a `links` argument — keys are link-field IDs (as numeric strings)
    /// or link-field names, values are arrays of target instance IDs — into an
    /// ID-keyed map. Target order is preserved; duplicates are dropped.
    private static func resolveLinks(
        rawLinks: [String: Value],
        linkFields: [LinkField]
    ) throws -> [Int64: [Int64]] {
        var resolved: [Int64: [Int64]] = [:]
        for (key, value) in rawLinks {
            let linkField: LinkField
            if let id = Int64(key) {
                guard let match = linkFields.first(where: { $0.id == id }) else {
                    throw MemorMCPToolError(message: "No link field with id \(id) on this type.")
                }
                linkField = match
            } else if let exact = linkFields.first(where: { $0.name == key }) {
                linkField = exact
            } else {
                let caseInsensitive = linkFields.filter { $0.name.caseInsensitiveCompare(key) == .orderedSame }
                if caseInsensitive.count == 1 {
                    linkField = caseInsensitive[0]
                } else {
                    let available = linkFields.map { "\($0.name) (id \($0.id))" }.joined(separator: ", ")
                    throw MemorMCPToolError(message: "Unknown link field `\(key)` in `links`. Available link fields: \(available).")
                }
            }
            guard let array = value.arrayValue else {
                throw MemorMCPToolError(message: "Value for link field `\(key)` in `links` must be an array of target instance IDs.")
            }
            let targetIDs = try array.map { elem -> Int64 in
                if let i = elem.intValue { return Int64(i) }
                if let s = elem.stringValue, let i = Int64(s) { return i }
                throw MemorMCPToolError(message: "Every target for link field `\(key)` in `links` must be an integer instance ID.")
            }
            var seen: Set<Int64> = []
            resolved[linkField.id] = targetIDs.filter { seen.insert($0).inserted }
        }
        return resolved
    }

    /// Validates link-target counts against each link field's min/max. When
    /// `onlyLinkFieldIDs` is non-nil, only those fields are checked (used by
    /// updates, where untouched fields keep their current — possibly
    /// pre-existing-invalid — targets).
    private static func validateLinkCounts(
        linkFields: [LinkField],
        links: [Int64: [Int64]],
        onlyLinkFieldIDs: Set<Int64>? = nil
    ) throws {
        for linkField in linkFields {
            if let onlyLinkFieldIDs, !onlyLinkFieldIDs.contains(linkField.id) { continue }
            let count = links[linkField.id]?.count ?? 0
            if count < linkField.minCount {
                throw MemorMCPToolError(message: "Link field `\(linkField.name)` (id \(linkField.id)) requires at least \(linkField.minCount) target(s); got \(count).")
            }
            if let maxCount = linkField.maxCount, count > maxCount {
                throw MemorMCPToolError(message: "Link field `\(linkField.name)` (id \(linkField.id)) allows at most \(maxCount) target(s); got \(count).")
            }
        }
    }

    private static func toolErrorMessage(from error: Error) -> String {
        if let toolError = error as? MemorMCPToolError {
            return toolError.message
        }
        if let dbError = error as? DatabaseError, let message = dbError.message {
            return message
        }
        return error.localizedDescription
    }

    // MARK: - UI refresh

    private static func postDatabaseChange() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
        }
    }

    // MARK: - Tool catalog

    private static func allTools() -> [Tool] {
        let int64Number: Value = .object(["type": .string("integer")])
        let numberValue: Value = .object(["type": .string("number")])
        let boolValue: Value = .object(["type": .string("boolean")])
        let stringValue: Value = .object(["type": .string("string")])
        let int64Array: Value = .object([
            "type": .string("array"),
            "items": .object(["type": .string("integer")])
        ])
        let stringKeyedStringMap: Value = .object([
            "type": .string("object"),
            "description": .string("Object whose keys are numeric IDs as strings and whose values are strings."),
            "additionalProperties": .object(["type": .string("string")])
        ])
        let nameKeyedStringMap: Value = .object([
            "type": .string("object"),
            "description": .string("Object whose keys are field names and whose values are strings."),
            "additionalProperties": .object(["type": .string("string")])
        ])
        let linksMap: Value = .object([
            "type": .string("object"),
            "description": .string("Node types only. Object whose keys are link-field IDs (as strings) or link-field names, and whose values are arrays of target instance IDs (same-type instances, ordered)."),
            "additionalProperties": int64Array
        ])

        return [
            Tool(
                name: "list_types",
                description: "List all existing flashcard types (without fields/query types).",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            Tool(
                name: "get_type",
                description: "Get full details for a type, including its fields and query types. Use this to discover field_ids and query_type_ids before calling create_instance.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["type_id": int64Number]),
                    "required": .array([.string("type_id")])
                ])
            ),

            Tool(
                name: "create_instance",
                description: "Create a new instance of an Object or Node type (use create_pointmap_instance / create_boundarymap_instance for map types). Provide field values via field_values_by_field_name (field names to string values) and/or field_values_by_field_id (field IDs as strings to string values); at least one is required. query_type_ids is an optional array of enabled query type IDs. For Node types, `links` optionally sets each link field's targets (key = link-field name or ID; value = array of same-type instance IDs); link-field min/max counts are enforced.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type_id": int64Number,
                        "field_values_by_field_id": stringKeyedStringMap,
                        "field_values_by_field_name": nameKeyedStringMap,
                        "query_type_ids": int64Array,
                        "links": linksMap
                    ]),
                    "required": .array([.string("type_id")])
                ])
            ),
            Tool(
                name: "create_instances",
                description: "Create many instances in a single call. Each item has the same shape as create_instance's arguments. Items are processed independently: the result is an array with one entry per item reporting either the created instance_id or an error message, so a bad item doesn't abort the rest of the batch.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "instances": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "type_id": int64Number,
                                    "field_values_by_field_id": stringKeyedStringMap,
                                    "field_values_by_field_name": nameKeyedStringMap,
                                    "query_type_ids": int64Array,
                                    "links": linksMap
                                ]),
                                "required": .array([.string("type_id")])
                            ])
                        ])
                    ]),
                    "required": .array([.string("instances")])
                ])
            ),
            Tool(
                name: "update_instance",
                description: "Update an existing Object or Node instance (use the pointmap/boundarymap tools for map instances). Provide only what you want to change: omitted fields keep their existing values, an omitted query_type_ids keeps the existing set, and for Node instances `links` replaces only the link fields it names (omitted link fields keep their current targets).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "instance_id": int64Number,
                        "field_values_by_field_id": stringKeyedStringMap,
                        "field_values_by_field_name": nameKeyedStringMap,
                        "query_type_ids": int64Array,
                        "links": linksMap
                    ]),
                    "required": .array([.string("instance_id")])
                ])
            ),
            Tool(
                name: "delete_instance",
                description: "Delete an instance by ID. This removes the instance from all collections and deletes its queries.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["instance_id": int64Number]),
                    "required": .array([.string("instance_id")])
                ])
            ),
            Tool(
                name: "get_instance",
                description: "Get an instance's full details: type, field values, per-query-type status (enabled, SRS interval in seconds, state, last answered), max_interval, and for Node instances each link field's targets. For PointMap/BoundaryMap instances, returns the map payload instead (kind, title, map settings, and points/attached boundaries with per-direction enabled flags).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["instance_id": int64Number]),
                    "required": .array([.string("instance_id")])
                ])
            ),
            Tool(
                name: "search_instances",
                description: "Search instances using Memor's instance search query language (e.g. \"literal:text col:Math type:Term\"). Empty string matches all.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["query": stringValue]),
                    "required": .array([.string("query")])
                ])
            ),

            Tool(
                name: "add_pointmap_point",
                description: "Add a point (query) to an existing PointMap instance, identified by instance_id. Provide the point name and its latitude (-90..90) / longitude (-180..180). forward_enabled (default true) and reverse_enabled (default false) control which of the point's two queries are enabled; set both to false for a point with no active query.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "instance_id": int64Number,
                        "name": stringValue,
                        "latitude": numberValue,
                        "longitude": numberValue,
                        "forward_enabled": boolValue,
                        "reverse_enabled": boolValue
                    ]),
                    "required": .array([.string("instance_id"), .string("name"), .string("latitude"), .string("longitude")])
                ])
            ),

            Tool(
                name: "list_collections",
                description: "List all collections with their instance counts.",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            Tool(
                name: "get_collection",
                description: "Get a collection's details including the list of instances it contains.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["collection_id": int64Number]),
                    "required": .array([.string("collection_id")])
                ])
            ),
            Tool(
                name: "create_collection",
                description: "Create a new collection with the given name.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["name": stringValue]),
                    "required": .array([.string("name")])
                ])
            ),
            Tool(
                name: "delete_collection",
                description: "Delete a collection by ID.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["collection_id": int64Number]),
                    "required": .array([.string("collection_id")])
                ])
            ),
            Tool(
                name: "rename_collection",
                description: "Rename a collection.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "collection_id": int64Number,
                        "new_name": stringValue
                    ]),
                    "required": .array([.string("collection_id"), .string("new_name")])
                ])
            ),
            Tool(
                name: "add_instance_to_collection",
                description: "Add an instance to a collection (idempotent).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "instance_id": int64Number,
                        "collection_id": int64Number
                    ]),
                    "required": .array([.string("instance_id"), .string("collection_id")])
                ])
            ),
            Tool(
                name: "add_instances_to_collection",
                description: "Add many instances (identified by ID) to a single collection. Idempotent for already-present instances.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "collection_id": int64Number,
                        "instance_ids": int64Array
                    ]),
                    "required": .array([.string("collection_id"), .string("instance_ids")])
                ])
            ),
            Tool(
                name: "remove_instance_from_collection",
                description: "Remove an instance from a collection.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "instance_id": int64Number,
                        "collection_id": int64Number
                    ]),
                    "required": .array([.string("instance_id"), .string("collection_id")])
                ])
            ),

            Tool(
                name: "search_queries",
                description: "Search queries (flashcards) using Memor's query search language. Empty string matches all queries.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["query": stringValue]),
                    "required": .array([.string("query")])
                ])
            ),

            Tool(
                name: "list_stacks",
                description: "List all stacks (saved query searches).",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            Tool(
                name: "create_stack",
                description: "Create a new stack with a name and a query search expression.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": stringValue,
                        "search": stringValue
                    ]),
                    "required": .array([.string("name"), .string("search")])
                ])
            ),
            Tool(
                name: "update_stack",
                description: "Rename a stack and/or change its search expression. Provide at least one of name or search.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "stack_id": int64Number,
                        "name": stringValue,
                        "search": stringValue
                    ]),
                    "required": .array([.string("stack_id")])
                ])
            ),
            Tool(
                name: "delete_stack",
                description: "Delete a stack by ID.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["stack_id": int64Number]),
                    "required": .array([.string("stack_id")])
                ])
            )
        ]
    }
}

// MARK: - DTOs

private struct OkDTO: Encodable {
    let ok = true
}

private struct TypeSummaryDTO: Encodable {
    let id: Int64
    let name: String
    let isBuiltin: Bool
    let isPointMap: Bool
    let isBoundaryMap: Bool
    let isNode: Bool
    let instanceCount: Int

    init(_ type: FlashcardType) {
        id = type.id
        name = type.name
        isBuiltin = type.isBuiltin
        isPointMap = type.name == POINTMAP_TYPE_NAME
        isBoundaryMap = type.name == BOUNDARYMAP_TYPE_NAME
        isNode = type.isNode
        instanceCount = type.instanceCount
    }
}

private struct FieldDTO: Encodable {
    let id: Int64
    let name: String
    let fieldDisplayIndex: Int

    init(_ field: TypeField) {
        id = field.id
        name = field.name
        fieldDisplayIndex = field.fieldDisplayIndex
    }
}

private struct QueryTypeDTO: Encodable {
    let id: Int64
    let name: String

    init(_ queryType: QueryType) {
        id = queryType.id
        name = queryType.name
    }
}

private struct TypeDetailDTO: Encodable {
    let id: Int64
    let name: String
    let isBuiltin: Bool
    let isPointMap: Bool
    let isBoundaryMap: Bool
    let isNode: Bool
    let instanceCount: Int
    let fields: [FieldDTO]
    let queryTypes: [QueryTypeDTO]
}

private struct CreatedInstanceDTO: Encodable {
    let instanceID: Int64
    let typeID: Int64
}

private struct BatchCreateResultDTO: Encodable {
    let index: Int
    let ok: Bool
    let instanceID: Int64?
    let typeID: Int64?
    let error: String?
}

private struct CreatedPointDTO: Encodable {
    let pointID: Int64
    let instanceID: Int64
}

private struct InstanceFieldValueDTO: Encodable {
    let fieldID: Int64
    let name: String
    let value: String
}

private struct InstanceQueryInfoDTO: Encodable {
    let queryTypeID: Int64
    let name: String
    let isLinkQuery: Bool
    let enabled: Bool
    // SRS state; nil when the query is disabled. interval is in seconds
    // (0 = new/blue). queryState is the raw SRS state machine value (0-2).
    let interval: Int64?
    let queryState: Int?
    let lastAnsweredTimestamp: Int64?
}

private struct NodeLinkTargetDTO: Encodable {
    let id: Int64
    let displayValue: String
}

private struct NodeLinkFieldDTO: Encodable {
    let linkFieldID: Int64
    let name: String
    let minCount: Int
    let maxCount: Int?
    let targets: [NodeLinkTargetDTO]
}

private struct InstanceDetailDTO: Encodable {
    let instanceID: Int64
    let typeID: Int64
    let typeName: String
    let isNode: Bool
    let maxInterval: Int64?
    let fields: [InstanceFieldValueDTO]
    let enabledQueryTypeIDs: [Int64]
    let queries: [InstanceQueryInfoDTO]
    // Node instances only.
    let links: [NodeLinkFieldDTO]?
}

private struct PointMapPointDTO: Encodable {
    let id: Int64
    let name: String
    let latitude: Double
    let longitude: Double
    let forwardEnabled: Bool
    let reverseEnabled: Bool
    let forwardInterval: Int64
    let reverseInterval: Int64

    init(_ point: PointMapPoint) {
        id = point.id
        name = point.name
        latitude = point.latitude
        longitude = point.longitude
        forwardEnabled = point.forwardEnabled
        reverseEnabled = point.reverseEnabled
        forwardInterval = point.forwardInterval
        reverseInterval = point.reverseInterval
    }
}

private struct PointMapInstanceDTO: Encodable {
    let kind = "pointmap"
    let instanceID: Int64
    let title: String
    let defaultCenterLat: Double
    let defaultCenterLng: Double
    let defaultZoom: Double
    let showAllPointsInQuestion: Bool
    let boundaryIDs: [Int64]
    let points: [PointMapPointDTO]

    init(_ instance: PointMapInstanceWithPoints) {
        instanceID = instance.instance.instanceID
        title = instance.instance.title
        defaultCenterLat = instance.instance.defaultCenterLat
        defaultCenterLng = instance.instance.defaultCenterLng
        defaultZoom = instance.instance.defaultZoom
        showAllPointsInQuestion = instance.instance.showAllPointsInQuestion
        boundaryIDs = instance.boundaryIDs
        points = instance.points.map(PointMapPointDTO.init)
    }
}

private struct BoundaryAttachmentDTO: Encodable {
    let attachmentID: Int64
    let boundaryID: Int64
    let name: String
    let forwardEnabled: Bool
    let reverseEnabled: Bool

    init(_ attachment: BoundaryMapAttachedBoundary) {
        attachmentID = attachment.id
        boundaryID = attachment.boundaryID
        name = attachment.name
        forwardEnabled = attachment.forwardEnabled
        reverseEnabled = attachment.reverseEnabled
    }
}

private struct BoundaryMapInstanceDTO: Encodable {
    let kind = "boundarymap"
    let instanceID: Int64
    let title: String
    let defaultCenterLat: Double
    let defaultCenterLng: Double
    let defaultZoom: Double
    let showAllBoundariesInQuestion: Bool
    let attachments: [BoundaryAttachmentDTO]

    init(_ instance: BoundaryMapInstanceWithBoundaries) {
        instanceID = instance.instance.instanceID
        title = instance.instance.title
        defaultCenterLat = instance.instance.defaultCenterLat
        defaultCenterLng = instance.instance.defaultCenterLng
        defaultZoom = instance.instance.defaultZoom
        showAllBoundariesInQuestion = instance.instance.showAllBoundariesInQuestion
        attachments = instance.attachments.map(BoundaryAttachmentDTO.init)
    }
}

private struct InstanceSearchResultDTO: Encodable {
    let id: Int64
    let displayValue: String

    init(_ r: InstanceSearchResult) {
        id = r.id
        displayValue = r.displayValue
    }
}

private struct InstanceSearchSectionDTO: Encodable {
    let typeID: Int64
    let typeName: String
    let instances: [InstanceSearchResultDTO]

    init(_ s: InstanceSearchSection) {
        typeID = s.typeID
        typeName = s.typeName
        instances = s.instances.map(InstanceSearchResultDTO.init)
    }
}

private struct CollectionDTO: Encodable {
    let id: Int64
    let name: String
    let description: String
    let visibleBeforeAnswer: Bool
    let instanceCount: Int

    init(_ c: Collection) {
        id = c.id
        name = c.name
        description = c.description
        visibleBeforeAnswer = c.visibleBeforeAnswer
        instanceCount = c.instanceCount
    }
}

private struct CollectionInstanceDTO: Encodable {
    let id: Int64
    let displayValue: String
}

private struct CollectionDetailDTO: Encodable {
    let collection: CollectionDTO
    let instances: [CollectionInstanceDTO]
}

private struct QuerySearchResultDTO: Encodable {
    let instanceID: Int64
    let queryTypeID: Int64
    let displayValue: String
    let queryTypeName: String

    init(_ r: QuerySearchResult) {
        instanceID = r.instanceID
        queryTypeID = r.queryTypeID
        displayValue = r.displayValue
        queryTypeName = r.queryTypeName
    }
}

private struct QuerySearchSectionDTO: Encodable {
    let typeID: Int64
    let typeName: String
    let queries: [QuerySearchResultDTO]

    init(_ s: QuerySearchSection) {
        typeID = s.typeID
        typeName = s.typeName
        queries = s.queries.map(QuerySearchResultDTO.init)
    }
}

private struct StackDTO: Encodable {
    let id: Int64
    let name: String
    let search: String

    init(_ s: Stack) {
        id = s.id
        name = s.name
        search = s.search
    }
}

// MARK: - Argument parsing helpers

private extension [String: Value] {

    func requireString(_ key: String) throws -> String {
        guard let v = self[key], let s = v.stringValue else {
            throw MemorMCPToolError(message: "Missing or non-string argument `\(key)`.")
        }
        return s
    }

    func optionalString(_ key: String) throws -> String? {
        guard let v = self[key] else { return nil }
        if v.isNull { return nil }
        guard let s = v.stringValue else {
            throw MemorMCPToolError(message: "Argument `\(key)` must be a string.")
        }
        return s
    }

    func requireInt64(_ key: String) throws -> Int64 {
        guard let v = self[key] else {
            throw MemorMCPToolError(message: "Missing argument `\(key)`.")
        }
        if let i = v.intValue {
            return Int64(i)
        }
        if let s = v.stringValue, let i = Int64(s) {
            return i
        }
        throw MemorMCPToolError(message: "Argument `\(key)` must be an integer.")
    }

    func requireDouble(_ key: String) throws -> Double {
        guard let v = self[key] else {
            throw MemorMCPToolError(message: "Missing argument `\(key)`.")
        }
        if let d = v.doubleValue { return d }
        if let i = v.intValue { return Double(i) }
        if let s = v.stringValue, let d = Double(s) { return d }
        throw MemorMCPToolError(message: "Argument `\(key)` must be a number.")
    }

    func optionalBool(_ key: String) throws -> Bool? {
        guard let v = self[key] else { return nil }
        if v.isNull { return nil }
        if let b = v.boolValue { return b }
        throw MemorMCPToolError(message: "Argument `\(key)` must be a boolean.")
    }

    func optionalInt64Array(_ key: String) throws -> [Int64]? {
        guard let v = self[key] else { return nil }
        if v.isNull { return nil }
        guard let array = v.arrayValue else {
            throw MemorMCPToolError(message: "Argument `\(key)` must be an array.")
        }
        return try array.map { elem -> Int64 in
            if let i = elem.intValue { return Int64(i) }
            if let s = elem.stringValue, let i = Int64(s) { return i }
            throw MemorMCPToolError(message: "Every element of `\(key)` must be an integer.")
        }
    }

    func requireInt64Array(_ key: String) throws -> [Int64] {
        guard let v = self[key] else {
            throw MemorMCPToolError(message: "Missing argument `\(key)`.")
        }
        guard let array = v.arrayValue else {
            throw MemorMCPToolError(message: "Argument `\(key)` must be an array.")
        }
        return try array.map { elem -> Int64 in
            if let i = elem.intValue { return Int64(i) }
            if let s = elem.stringValue, let i = Int64(s) { return i }
            throw MemorMCPToolError(message: "Every element of `\(key)` must be an integer.")
        }
    }

    func requireObjectArray(_ key: String) throws -> [[String: Value]] {
        guard let v = self[key] else {
            throw MemorMCPToolError(message: "Missing argument `\(key)`.")
        }
        guard let array = v.arrayValue else {
            throw MemorMCPToolError(message: "Argument `\(key)` must be an array.")
        }
        return try array.map { elem -> [String: Value] in
            guard let obj = elem.objectValue else {
                throw MemorMCPToolError(message: "Every element of `\(key)` must be an object.")
            }
            return obj
        }
    }

    func requireInt64KeyedStringMap(_ key: String) throws -> [Int64: String] {
        guard let v = self[key], let obj = v.objectValue else {
            throw MemorMCPToolError(message: "Argument `\(key)` must be an object mapping field IDs to strings.")
        }
        var out: [Int64: String] = [:]
        for (k, val) in obj {
            guard let id = Int64(k) else {
                throw MemorMCPToolError(message: "Key `\(k)` in `\(key)` is not a valid integer.")
            }
            guard let s = val.stringValue else {
                throw MemorMCPToolError(message: "Value for key `\(k)` in `\(key)` must be a string.")
            }
            out[id] = s
        }
        return out
    }

    func optionalInt64KeyedStringMap(_ key: String) throws -> [Int64: String]? {
        guard let v = self[key] else { return nil }
        if v.isNull { return nil }
        return try requireInt64KeyedStringMap(key)
    }

    func optionalStringKeyedStringMap(_ key: String) throws -> [String: String]? {
        guard let v = self[key] else { return nil }
        if v.isNull { return nil }
        guard let obj = v.objectValue else {
            throw MemorMCPToolError(message: "Argument `\(key)` must be an object mapping names to strings.")
        }
        var out: [String: String] = [:]
        for (k, val) in obj {
            guard let s = val.stringValue else {
                throw MemorMCPToolError(message: "Value for key `\(k)` in `\(key)` must be a string.")
            }
            out[k] = s
        }
        return out
    }

    func optionalValueObject(_ key: String) throws -> [String: Value]? {
        guard let v = self[key] else { return nil }
        if v.isNull { return nil }
        guard let obj = v.objectValue else {
            throw MemorMCPToolError(message: "Argument `\(key)` must be an object.")
        }
        return obj
    }

    func optionalInt64(_ key: String) throws -> Int64? {
        guard let v = self[key] else { return nil }
        if v.isNull { return nil }
        if let i = v.intValue { return Int64(i) }
        if let s = v.stringValue, let i = Int64(s) { return i }
        throw MemorMCPToolError(message: "Argument `\(key)` must be an integer.")
    }

    func optionalDouble(_ key: String) throws -> Double? {
        guard let v = self[key] else { return nil }
        if v.isNull { return nil }
        if let d = v.doubleValue { return d }
        if let i = v.intValue { return Double(i) }
        if let s = v.stringValue, let d = Double(s) { return d }
        throw MemorMCPToolError(message: "Argument `\(key)` must be a number.")
    }

    func requireBool(_ key: String) throws -> Bool {
        guard let v = self[key], let b = v.boolValue else {
            throw MemorMCPToolError(message: "Missing or non-boolean argument `\(key)`.")
        }
        return b
    }
}

struct MemorMCPToolError: Error {
    let message: String
}
