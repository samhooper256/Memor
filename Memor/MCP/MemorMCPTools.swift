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
            return try jsonResult(searchInstances(
                query: query,
                limit: Int(try arguments.optionalInt64("limit") ?? 50),
                includeFieldValues: try arguments.optionalBool("include_field_values") ?? false,
                appDatabase: appDatabase
            ))

        // Nodes
        case "update_node_links":
            let instanceID = try arguments.requireInt64("instance_id")
            let linkFieldKey: String
            if let value = arguments["link_field"], let intKey = value.intValue {
                linkFieldKey = String(intKey)
            } else {
                linkFieldKey = try arguments.requireString("link_field")
            }
            let setTargetIDs = try arguments.optionalInt64Array("set_target_ids")
            let addTargetIDs = try arguments.optionalInt64Array("add_target_ids")
            let removeTargetIDs = try arguments.optionalInt64Array("remove_target_ids")
            return try jsonResult(updateNodeLinks(
                instanceID: instanceID,
                linkFieldKey: linkFieldKey,
                setTargetIDs: setTargetIDs,
                addTargetIDs: addTargetIDs,
                removeTargetIDs: removeTargetIDs,
                appDatabase: appDatabase
            ))
        case "search_node_candidates":
            let typeID = try arguments.requireInt64("type_id")
            let query = try arguments.optionalString("query") ?? ""
            let excludingInstanceID = try arguments.optionalInt64("excluding_instance_id")
            return try jsonResult(searchNodeCandidates(
                typeID: typeID,
                query: query,
                excludingInstanceID: excludingInstanceID,
                appDatabase: appDatabase
            ))

        // PointMap
        case "create_pointmap_instance":
            return try jsonResult(createPointMapInstance(
                title: try arguments.requireString("title"),
                defaultCenterLat: try arguments.optionalDouble("default_center_lat") ?? 0,
                defaultCenterLng: try arguments.optionalDouble("default_center_lng") ?? 0,
                defaultZoom: try arguments.optionalDouble("default_zoom") ?? 2,
                showAllPointsInQuestion: try arguments.optionalBool("show_all_points_in_question") ?? true,
                pointItems: try arguments.optionalObjectArray("points") ?? [],
                boundaryIDs: try arguments.optionalInt64Array("boundary_ids") ?? [],
                appDatabase: appDatabase
            ))
        case "update_pointmap_instance":
            return try jsonResult(updatePointMapInstance(
                instanceID: try arguments.requireInt64("instance_id"),
                title: try arguments.optionalString("title"),
                defaultCenterLat: try arguments.optionalDouble("default_center_lat"),
                defaultCenterLng: try arguments.optionalDouble("default_center_lng"),
                defaultZoom: try arguments.optionalDouble("default_zoom"),
                showAllPointsInQuestion: try arguments.optionalBool("show_all_points_in_question"),
                boundaryIDs: try arguments.optionalInt64Array("boundary_ids"),
                appDatabase: appDatabase
            ))
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
        case "update_pointmap_point":
            return try jsonResult(updatePointMapPoint(
                instanceID: try arguments.requireInt64("instance_id"),
                pointID: try arguments.requireInt64("point_id"),
                name: try arguments.optionalString("name"),
                latitude: try arguments.optionalDouble("latitude"),
                longitude: try arguments.optionalDouble("longitude"),
                forwardEnabled: try arguments.optionalBool("forward_enabled"),
                reverseEnabled: try arguments.optionalBool("reverse_enabled"),
                appDatabase: appDatabase
            ))
        case "delete_pointmap_point":
            return try jsonResult(deletePointMapPoint(
                instanceID: try arguments.requireInt64("instance_id"),
                pointID: try arguments.requireInt64("point_id"),
                appDatabase: appDatabase
            ))

        // BoundaryMap
        case "create_boundarymap_instance":
            return try jsonResult(createBoundaryMapInstance(
                title: try arguments.requireString("title"),
                defaultCenterLat: try arguments.optionalDouble("default_center_lat") ?? 0,
                defaultCenterLng: try arguments.optionalDouble("default_center_lng") ?? 0,
                defaultZoom: try arguments.optionalDouble("default_zoom") ?? 2,
                showAllBoundariesInQuestion: try arguments.optionalBool("show_all_boundaries_in_question") ?? true,
                boundaryItems: try arguments.optionalObjectArray("boundaries") ?? [],
                appDatabase: appDatabase
            ))
        case "update_boundarymap_instance":
            return try jsonResult(updateBoundaryMapInstance(
                instanceID: try arguments.requireInt64("instance_id"),
                title: try arguments.optionalString("title"),
                defaultCenterLat: try arguments.optionalDouble("default_center_lat"),
                defaultCenterLng: try arguments.optionalDouble("default_center_lng"),
                defaultZoom: try arguments.optionalDouble("default_zoom"),
                showAllBoundariesInQuestion: try arguments.optionalBool("show_all_boundaries_in_question"),
                addBoundaryItems: try arguments.optionalObjectArray("add_boundaries"),
                removeAttachmentIDs: try arguments.optionalInt64Array("remove_attachment_ids"),
                setEnabledItems: try arguments.optionalObjectArray("set_enabled"),
                appDatabase: appDatabase
            ))
        case "list_boundary_sets":
            return try jsonResult(listBoundarySets(appDatabase: appDatabase))
        case "list_boundaries":
            return try jsonResult(listBoundaries(
                boundarySetID: try arguments.requireInt64("boundary_set_id"),
                nameContains: try arguments.optionalString("name_contains"),
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
            return try jsonResult(searchQueries(
                query: query,
                limit: Int(try arguments.optionalInt64("limit") ?? 50),
                appDatabase: appDatabase
            ))
        case "reset_due_dates":
            return try jsonResult(resetDueDates(
                search: try arguments.optionalString("search"),
                queryItems: try arguments.optionalObjectArray("queries"),
                appDatabase: appDatabase
            ))
        case "set_queries_enabled":
            return try jsonResult(setQueriesEnabled(
                enabled: try arguments.requireBool("enabled"),
                queryItems: try arguments.requireObjectArray("queries"),
                appDatabase: appDatabase
            ))
        case "set_max_interval":
            return try jsonResult(setMaxIntervalTool(
                instanceID: try arguments.requireInt64("instance_id"),
                maxInterval: try arguments.optionalInt64("max_interval"),
                appDatabase: appDatabase
            ))
        case "render_query":
            return try jsonResult(renderQuery(
                instanceID: try arguments.requireInt64("instance_id"),
                queryTypeID: try arguments.optionalInt64("query_type_id"),
                appDatabase: appDatabase
            ))
        case "describe_search_syntax":
            return try jsonResult(SearchSyntaxDTO(documentation: searchSyntaxDocumentation))

        // Stacks
        case "list_stacks":
            return try jsonResult(listStacks(
                includeCounts: try arguments.optionalBool("include_counts") ?? false,
                appDatabase: appDatabase
            ))
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
        // Map instances have no field table, so detect them before
        // fetchInstanceEditorData (which would throw an unhelpful SQL error).
        if try appDatabase.fetchPointMapInstanceTitle(instanceID: instanceID) != nil {
            throw MemorMCPToolError(message: "Use update_pointmap_instance / update_pointmap_point to edit PointMap instances.")
        }
        if try appDatabase.fetchBoundaryMapInstanceTitle(instanceID: instanceID) != nil {
            throw MemorMCPToolError(message: "Use update_boundarymap_instance to edit BoundaryMap instances.")
        }
        let current = try appDatabase.fetchInstanceEditorData(instanceID: instanceID)
        guard let type = try appDatabase.fetchType(typeID: current.typeID) else {
            throw MemorMCPToolError(message: "Type not found: \(current.typeID).")
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

    private static func searchInstances(
        query: String,
        limit: Int,
        includeFieldValues: Bool,
        appDatabase: AppDatabase
    ) throws -> [InstanceSearchSectionDTO] {
        guard limit >= 1 else {
            throw MemorMCPToolError(message: "`limit` must be at least 1.")
        }
        let sections = try appDatabase.searchInstances(query: query)
        var remaining = limit
        return try sections.map { section in
            let totalCount = section.instances.count
            let taken = Array(section.instances.prefix(max(0, remaining)))
            remaining -= taken.count

            // Map types have no text fields, so fetchFields returns [] for them
            // and we skip the per-instance value lookups.
            var typeFields: [TypeField] = []
            if includeFieldValues, !taken.isEmpty {
                typeFields = try appDatabase.fetchFields(forTypeID: section.typeID)
            }

            let instances = try taken.map { instance -> InstanceSearchResultDTO in
                var fields: [InstanceFieldValueDTO]? = nil
                if includeFieldValues, !typeFields.isEmpty {
                    let data = try appDatabase.fetchInstanceEditorData(instanceID: instance.id)
                    fields = typeFields.map { field in
                        InstanceFieldValueDTO(
                            fieldID: field.id,
                            name: field.name,
                            value: data.fieldValuesByFieldID[field.id] ?? ""
                        )
                    }
                }
                return InstanceSearchResultDTO(id: instance.id, displayValue: instance.displayValue, fields: fields)
            }

            return InstanceSearchSectionDTO(
                typeID: section.typeID,
                typeName: section.typeName,
                totalCount: totalCount,
                truncated: instances.count < totalCount,
                instances: instances
            )
        }
    }

    // MARK: - Node tools

    private static func updateNodeLinks(
        instanceID: Int64,
        linkFieldKey: String,
        setTargetIDs: [Int64]?,
        addTargetIDs: [Int64]?,
        removeTargetIDs: [Int64]?,
        appDatabase: AppDatabase
    ) throws -> NodeLinkFieldDTO {
        if setTargetIDs != nil && (addTargetIDs != nil || removeTargetIDs != nil) {
            throw MemorMCPToolError(message: "Provide either `set_target_ids` or `add_target_ids`/`remove_target_ids`, not both.")
        }
        if setTargetIDs == nil && addTargetIDs == nil && removeTargetIDs == nil {
            throw MemorMCPToolError(message: "Provide `set_target_ids`, or `add_target_ids` and/or `remove_target_ids`.")
        }

        let current = try appDatabase.fetchInstanceEditorData(instanceID: instanceID)
        guard let type = try appDatabase.fetchType(typeID: current.typeID), type.isNode else {
            throw MemorMCPToolError(message: "Instance \(instanceID) is not a Node instance.")
        }
        let linkFields = try appDatabase.fetchLinkFields(forTypeID: current.typeID)
        let linkField = try resolveLinkField(key: linkFieldKey, in: linkFields)

        var targets = current.linkTargetsByLinkFieldID[linkField.id] ?? []
        if let setTargetIDs {
            var seen: Set<Int64> = []
            targets = setTargetIDs.filter { seen.insert($0).inserted }
        } else {
            if let removeTargetIDs {
                let removeSet = Set(removeTargetIDs)
                targets.removeAll { removeSet.contains($0) }
            }
            if let addTargetIDs {
                for targetID in addTargetIDs where !targets.contains(targetID) {
                    targets.append(targetID)
                }
            }
        }
        try validateLinkCounts(
            linkFields: linkFields,
            links: [linkField.id: targets],
            onlyLinkFieldIDs: [linkField.id]
        )

        // AppDatabase.updateInstance rewrites ALL links, so pass the full map
        // with just this field changed.
        var mergedLinks = current.linkTargetsByLinkFieldID
        mergedLinks[linkField.id] = targets
        try appDatabase.updateInstance(
            instanceID: instanceID,
            fieldValuesByFieldID: current.fieldValuesByFieldID,
            queryTypeIDs: current.enabledQueryTypeIDs,
            linksByLinkFieldID: mergedLinks
        )
        postDatabaseChange()

        // Re-fetch so the returned targets carry display summaries.
        let updated = try appDatabase.fetchInstanceEditorData(instanceID: instanceID)
        let resultTargetIDs = updated.linkTargetsByLinkFieldID[linkField.id] ?? []
        return NodeLinkFieldDTO(
            linkFieldID: linkField.id,
            name: linkField.name,
            minCount: linkField.minCount,
            maxCount: linkField.maxCount,
            targets: resultTargetIDs.map { targetID in
                NodeLinkTargetDTO(id: targetID, displayValue: updated.linkedNodeSummaries[targetID] ?? "")
            }
        )
    }

    private static func searchNodeCandidates(
        typeID: Int64,
        query: String,
        excludingInstanceID: Int64?,
        appDatabase: AppDatabase
    ) throws -> [NodeLinkTargetDTO] {
        guard let type = try appDatabase.fetchType(typeID: typeID) else {
            throw MemorMCPToolError(message: "Type not found: \(typeID).")
        }
        guard type.isNode else {
            throw MemorMCPToolError(message: "Type \(typeID) (\(type.name)) is not a Node type.")
        }
        let candidates = try appDatabase.fetchNodeCandidates(
            forTypeID: typeID,
            matching: query,
            excludingInstanceID: excludingInstanceID
        )
        return candidates.map { NodeLinkTargetDTO(id: $0.id, displayValue: $0.displayValue) }
    }

    // MARK: - PointMap tools

    private static func validateCoordinates(latitude: Double, longitude: Double) throws {
        guard latitude >= -90, latitude <= 90 else {
            throw MemorMCPToolError(message: "latitude must be between -90 and 90.")
        }
        guard longitude >= -180, longitude <= 180 else {
            throw MemorMCPToolError(message: "longitude must be between -180 and 180.")
        }
    }

    private static func parsePointDraft(_ item: [String: Value]) throws -> AppDatabase.PointMapPointDraft {
        let latitude = try item.requireDouble("latitude")
        let longitude = try item.requireDouble("longitude")
        try validateCoordinates(latitude: latitude, longitude: longitude)
        return AppDatabase.PointMapPointDraft(
            name: try item.requireString("name"),
            latitude: latitude,
            longitude: longitude,
            forwardEnabled: try item.optionalBool("forward_enabled") ?? true,
            reverseEnabled: try item.optionalBool("reverse_enabled") ?? false
        )
    }

    private static func validateBoundaryIDs(_ boundaryIDs: [Int64], appDatabase: AppDatabase) throws {
        guard !boundaryIDs.isEmpty else { return }
        let knownIDs = Set(try appDatabase.fetchAllBoundaryOptions().map(\.id))
        let unknownIDs = boundaryIDs.filter { !knownIDs.contains($0) }
        if !unknownIDs.isEmpty {
            throw MemorMCPToolError(message: "Unknown boundary id(s): \(unknownIDs.map(String.init).joined(separator: ", ")). Use list_boundary_sets and list_boundaries to discover boundaries.")
        }
    }

    private static func createPointMapInstance(
        title: String,
        defaultCenterLat: Double,
        defaultCenterLng: Double,
        defaultZoom: Double,
        showAllPointsInQuestion: Bool,
        pointItems: [[String: Value]],
        boundaryIDs: [Int64],
        appDatabase: AppDatabase
    ) throws -> CreatedPointMapInstanceDTO {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MemorMCPToolError(message: "`title` must not be empty.")
        }
        let drafts = try pointItems.enumerated().map { index, item in
            do {
                return try parsePointDraft(item)
            } catch let error as MemorMCPToolError {
                throw MemorMCPToolError(message: "points[\(index)]: \(error.message)")
            }
        }
        try validateBoundaryIDs(boundaryIDs, appDatabase: appDatabase)
        let instanceID = try appDatabase.makePointMapInstance(
            title: title,
            defaultCenterLat: defaultCenterLat,
            defaultCenterLng: defaultCenterLng,
            defaultZoom: defaultZoom,
            showAllPointsInQuestion: showAllPointsInQuestion,
            points: drafts,
            boundaryIDs: boundaryIDs
        )
        postDatabaseChange()
        return CreatedPointMapInstanceDTO(instanceID: instanceID, pointCount: drafts.count)
    }

    private static func updatePointMapInstance(
        instanceID: Int64,
        title: String?,
        defaultCenterLat: Double?,
        defaultCenterLng: Double?,
        defaultZoom: Double?,
        showAllPointsInQuestion: Bool?,
        boundaryIDs: [Int64]?,
        appDatabase: AppDatabase
    ) throws -> OkDTO {
        guard let current = try appDatabase.fetchPointMapInstance(instanceID: instanceID) else {
            throw MemorMCPToolError(message: "No PointMap instance with id \(instanceID).")
        }
        if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MemorMCPToolError(message: "`title` must not be empty.")
        }
        if let boundaryIDs {
            try validateBoundaryIDs(boundaryIDs, appDatabase: appDatabase)
        }
        try appDatabase.updatePointMapInstance(
            instanceID: instanceID,
            title: title ?? current.instance.title,
            defaultCenterLat: defaultCenterLat ?? current.instance.defaultCenterLat,
            defaultCenterLng: defaultCenterLng ?? current.instance.defaultCenterLng,
            defaultZoom: defaultZoom ?? current.instance.defaultZoom,
            showAllPointsInQuestion: showAllPointsInQuestion ?? current.instance.showAllPointsInQuestion,
            existingPoints: current.points,
            newPoints: [],
            boundaryIDs: boundaryIDs ?? current.boundaryIDs
        )
        postDatabaseChange()
        return OkDTO()
    }

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
        try validateCoordinates(latitude: latitude, longitude: longitude)
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

    private static func updatePointMapPoint(
        instanceID: Int64,
        pointID: Int64,
        name: String?,
        latitude: Double?,
        longitude: Double?,
        forwardEnabled: Bool?,
        reverseEnabled: Bool?,
        appDatabase: AppDatabase
    ) throws -> OkDTO {
        guard let current = try appDatabase.fetchPointMapInstance(instanceID: instanceID) else {
            throw MemorMCPToolError(message: "No PointMap instance with id \(instanceID).")
        }
        guard let index = current.points.firstIndex(where: { $0.id == pointID }) else {
            throw MemorMCPToolError(message: "No point with id \(pointID) on PointMap instance \(instanceID).")
        }
        var points = current.points
        let old = points[index]
        let newLatitude = latitude ?? old.latitude
        let newLongitude = longitude ?? old.longitude
        try validateCoordinates(latitude: newLatitude, longitude: newLongitude)
        points[index] = PointMapPoint(
            id: old.id,
            instanceID: old.instanceID,
            name: name ?? old.name,
            latitude: newLatitude,
            longitude: newLongitude,
            forwardEnabled: forwardEnabled ?? old.forwardEnabled,
            reverseEnabled: reverseEnabled ?? old.reverseEnabled,
            forwardInterval: old.forwardInterval,
            reverseInterval: old.reverseInterval
        )
        try appDatabase.updatePointMapInstance(
            instanceID: instanceID,
            title: current.instance.title,
            defaultCenterLat: current.instance.defaultCenterLat,
            defaultCenterLng: current.instance.defaultCenterLng,
            defaultZoom: current.instance.defaultZoom,
            showAllPointsInQuestion: current.instance.showAllPointsInQuestion,
            existingPoints: points,
            newPoints: [],
            boundaryIDs: current.boundaryIDs
        )
        postDatabaseChange()
        return OkDTO()
    }

    private static func deletePointMapPoint(
        instanceID: Int64,
        pointID: Int64,
        appDatabase: AppDatabase
    ) throws -> OkDTO {
        guard let current = try appDatabase.fetchPointMapInstance(instanceID: instanceID) else {
            throw MemorMCPToolError(message: "No PointMap instance with id \(instanceID).")
        }
        guard current.points.contains(where: { $0.id == pointID }) else {
            throw MemorMCPToolError(message: "No point with id \(pointID) on PointMap instance \(instanceID).")
        }
        try appDatabase.updatePointMapInstance(
            instanceID: instanceID,
            title: current.instance.title,
            defaultCenterLat: current.instance.defaultCenterLat,
            defaultCenterLng: current.instance.defaultCenterLng,
            defaultZoom: current.instance.defaultZoom,
            showAllPointsInQuestion: current.instance.showAllPointsInQuestion,
            existingPoints: current.points.filter { $0.id != pointID },
            newPoints: [],
            boundaryIDs: current.boundaryIDs
        )
        postDatabaseChange()
        return OkDTO()
    }

    // MARK: - BoundaryMap tools

    private static func parseBoundaryDraft(_ item: [String: Value]) throws -> AppDatabase.BoundaryMapBoundaryDraft {
        AppDatabase.BoundaryMapBoundaryDraft(
            boundaryID: try item.requireInt64("boundary_id"),
            forwardEnabled: try item.optionalBool("forward_enabled") ?? true,
            reverseEnabled: try item.optionalBool("reverse_enabled") ?? false
        )
    }

    private static func createBoundaryMapInstance(
        title: String,
        defaultCenterLat: Double,
        defaultCenterLng: Double,
        defaultZoom: Double,
        showAllBoundariesInQuestion: Bool,
        boundaryItems: [[String: Value]],
        appDatabase: AppDatabase
    ) throws -> CreatedBoundaryMapInstanceDTO {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MemorMCPToolError(message: "`title` must not be empty.")
        }
        let drafts = try boundaryItems.enumerated().map { index, item in
            do {
                return try parseBoundaryDraft(item)
            } catch let error as MemorMCPToolError {
                throw MemorMCPToolError(message: "boundaries[\(index)]: \(error.message)")
            }
        }
        try validateBoundaryIDs(drafts.map(\.boundaryID), appDatabase: appDatabase)
        let instanceID = try appDatabase.makeBoundaryMapInstance(
            title: title,
            defaultCenterLat: defaultCenterLat,
            defaultCenterLng: defaultCenterLng,
            defaultZoom: defaultZoom,
            showAllBoundariesInQuestion: showAllBoundariesInQuestion,
            boundaries: drafts
        )
        postDatabaseChange()
        return CreatedBoundaryMapInstanceDTO(instanceID: instanceID, attachmentCount: drafts.count)
    }

    private static func updateBoundaryMapInstance(
        instanceID: Int64,
        title: String?,
        defaultCenterLat: Double?,
        defaultCenterLng: Double?,
        defaultZoom: Double?,
        showAllBoundariesInQuestion: Bool?,
        addBoundaryItems: [[String: Value]]?,
        removeAttachmentIDs: [Int64]?,
        setEnabledItems: [[String: Value]]?,
        appDatabase: AppDatabase
    ) throws -> OkDTO {
        guard let current = try appDatabase.fetchBoundaryMapInstance(instanceID: instanceID) else {
            throw MemorMCPToolError(message: "No BoundaryMap instance with id \(instanceID).")
        }
        if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MemorMCPToolError(message: "`title` must not be empty.")
        }

        var attachments = current.attachments
        if let removeAttachmentIDs {
            let knownIDs = Set(attachments.map(\.id))
            let unknownIDs = removeAttachmentIDs.filter { !knownIDs.contains($0) }
            if !unknownIDs.isEmpty {
                throw MemorMCPToolError(message: "No attachment(s) with id(s) \(unknownIDs.map(String.init).joined(separator: ", ")) on BoundaryMap instance \(instanceID).")
            }
            let removeSet = Set(removeAttachmentIDs)
            attachments.removeAll { removeSet.contains($0.id) }
        }
        if let setEnabledItems {
            for item in setEnabledItems {
                let attachmentID = try item.requireInt64("attachment_id")
                guard let index = attachments.firstIndex(where: { $0.id == attachmentID }) else {
                    throw MemorMCPToolError(message: "No attachment with id \(attachmentID) on BoundaryMap instance \(instanceID).")
                }
                if let forward = try item.optionalBool("forward_enabled") {
                    attachments[index].forwardEnabled = forward
                }
                if let reverse = try item.optionalBool("reverse_enabled") {
                    attachments[index].reverseEnabled = reverse
                }
            }
        }

        var newDrafts: [AppDatabase.BoundaryMapBoundaryDraft] = []
        if let addBoundaryItems {
            newDrafts = try addBoundaryItems.enumerated().map { index, item in
                do {
                    return try parseBoundaryDraft(item)
                } catch let error as MemorMCPToolError {
                    throw MemorMCPToolError(message: "add_boundaries[\(index)]: \(error.message)")
                }
            }
            try validateBoundaryIDs(newDrafts.map(\.boundaryID), appDatabase: appDatabase)
        }

        try appDatabase.updateBoundaryMapInstance(
            instanceID: instanceID,
            title: title ?? current.instance.title,
            defaultCenterLat: defaultCenterLat ?? current.instance.defaultCenterLat,
            defaultCenterLng: defaultCenterLng ?? current.instance.defaultCenterLng,
            defaultZoom: defaultZoom ?? current.instance.defaultZoom,
            showAllBoundariesInQuestion: showAllBoundariesInQuestion ?? current.instance.showAllBoundariesInQuestion,
            existingAttachments: attachments,
            newBoundaries: newDrafts
        )
        postDatabaseChange()
        return OkDTO()
    }

    private static func listBoundarySets(appDatabase: AppDatabase) throws -> [BoundarySetDTO] {
        try appDatabase.fetchBoundarySets().map(BoundarySetDTO.init)
    }

    private static func listBoundaries(
        boundarySetID: Int64,
        nameContains: String?,
        appDatabase: AppDatabase
    ) throws -> [BoundaryDTO] {
        let sets = try appDatabase.fetchBoundarySets()
        guard sets.contains(where: { $0.id == boundarySetID }) else {
            throw MemorMCPToolError(message: "No boundary set with id \(boundarySetID).")
        }
        var boundaries = try appDatabase.fetchBoundaries(setID: boundarySetID)
        if let nameContains, !nameContains.isEmpty {
            boundaries = boundaries.filter { $0.name.localizedCaseInsensitiveContains(nameContains) }
        }
        return boundaries.map { BoundaryDTO(id: $0.id, name: $0.name) }
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

    private static func searchQueries(query: String, limit: Int, appDatabase: AppDatabase) throws -> [QuerySearchSectionDTO] {
        guard limit >= 1 else {
            throw MemorMCPToolError(message: "`limit` must be at least 1.")
        }
        let sections = try appDatabase.searchQueries(query: query)
        var remaining = limit
        return sections.map { section in
            let totalCount = section.queries.count
            let taken = Array(section.queries.prefix(max(0, remaining)))
            remaining -= taken.count
            return QuerySearchSectionDTO(
                typeID: section.typeID,
                typeName: section.typeName,
                totalCount: totalCount,
                truncated: taken.count < totalCount,
                queries: taken.map(QuerySearchResultDTO.init)
            )
        }
    }

    // MARK: - Rendering & docs tools

    private static func renderQuery(
        instanceID: Int64,
        queryTypeID: Int64?,
        appDatabase: AppDatabase
    ) throws -> RenderedQueryDTO {
        let query: StudyQuery
        if let queryTypeID {
            query = try appDatabase.fetchQueryPreview(instanceID: instanceID, queryTypeID: queryTypeID)
        } else {
            query = try appDatabase.fetchFirstQueryPreview(instanceID: instanceID)
        }

        switch query.kind {
        case .standard:
            return RenderedQueryDTO(
                kind: "standard",
                instanceID: query.instanceID,
                typeName: query.typeName,
                queryTypeID: query.queryTypeID,
                queryTypeName: query.queryTypeName,
                questionHTML: try buildRenderedQuestionHTML(appDatabase: appDatabase, query: query),
                answerHTML: try buildRenderedAnswerHTML(appDatabase: appDatabase, query: query),
                instanceTitle: nil,
                point: nil,
                showAllPointsInQuestion: nil,
                boundary: nil,
                showAllBoundariesInQuestion: nil
            )
        case .pointMap:
            guard let payload = query.pointMapPayload else {
                throw MemorMCPToolError(message: "PointMap query payload missing.")
            }
            let point = payload.points.first(where: { $0.id == payload.pointID })
            return RenderedQueryDTO(
                kind: "pointmap",
                instanceID: query.instanceID,
                typeName: query.typeName,
                queryTypeID: query.queryTypeID,
                queryTypeName: query.queryTypeName,
                questionHTML: nil,
                answerHTML: nil,
                instanceTitle: payload.instanceTitle,
                point: point.map { RenderedPointDTO(id: $0.id, name: $0.name, latitude: $0.latitude, longitude: $0.longitude) },
                showAllPointsInQuestion: payload.showAllPointsInQuestion,
                boundary: nil,
                showAllBoundariesInQuestion: nil
            )
        case .boundaryMap:
            guard let payload = query.boundaryMapPayload else {
                throw MemorMCPToolError(message: "BoundaryMap query payload missing.")
            }
            return RenderedQueryDTO(
                kind: "boundarymap",
                instanceID: query.instanceID,
                typeName: query.typeName,
                queryTypeID: query.queryTypeID,
                queryTypeName: query.queryTypeName,
                questionHTML: nil,
                answerHTML: nil,
                instanceTitle: payload.instanceTitle,
                point: nil,
                showAllPointsInQuestion: nil,
                boundary: RenderedBoundaryDTO(
                    attachmentID: payload.attachmentID,
                    boundaryID: payload.boundaryID,
                    name: payload.boundaryName
                ),
                showAllBoundariesInQuestion: payload.showAllBoundariesInQuestion
            )
        }
    }

    // Mirrors the in-app search help windows (Windows/SearchHelpWindowView.swift);
    // keep the two in sync when the grammar changes.
    private static let searchSyntaxDocumentation = """
        Memor has two search languages used by the MCP tools:

        1. INSTANCE SEARCH — used by search_instances. Matches instances of every type, \
        including PointMap and BoundaryMap instances.
        2. QUERY SEARCH — used by search_queries, reset_due_dates' `search`, and Stack \
        `search` expressions. Matches individual studyable queries (flashcards). A Stack \
        is exactly a saved query search: a Stack's search text returns precisely that \
        Stack's queries.

        Shared syntax (both languages):
        - Components are separated by spaces and combined with AND. An empty search matches everything.
        - literal:text — match items with a field containing text (case-insensitive substring). \
        A bare word with no prefix works the same way.
        - type:name — restrict to items of the named type.
        - collection:name (or col:name) — restrict to items in the named collection.
        - id:number — restrict to the single instance with this ID.
        - OR — match if either neighboring component matches (e.g. type:Term OR type:Concept).
        - NOT — exclude whatever the following component matches (e.g. NOT col:Archived).
        - ( … ) — group components to control how OR and AND combine.
        - Double quotes wrap a component containing spaces: "literal:hi there".

        Instance search only:
        - :noqueries — match only instances that have no query types enabled.

        Query search only:
        - :new — match only queries that are new (never studied).

        Examples:
        - type:Term col:Math — Term instances in the Math collection (or, in query search, their queries).
        - (col:Math OR col:Physics) :new — new queries in either collection.
        - "literal:Pythagorean theorem" NOT type:Proof — items containing the phrase, excluding Proof instances.
        """

    // MARK: - SRS maintenance tools

    private static func parseQueryPairs(_ items: [[String: Value]], argumentLabel: String) throws -> [(instanceID: Int64, queryTypeID: Int64)] {
        if items.isEmpty {
            throw MemorMCPToolError(message: "`\(argumentLabel)` must contain at least one item.")
        }
        return try items.enumerated().map { index, item in
            do {
                return (
                    instanceID: try item.requireInt64("instance_id"),
                    queryTypeID: try item.requireInt64("query_type_id")
                )
            } catch let error as MemorMCPToolError {
                throw MemorMCPToolError(message: "\(argumentLabel)[\(index)]: \(error.message)")
            }
        }
    }

    private static func resetDueDates(
        search: String?,
        queryItems: [[String: Value]]?,
        appDatabase: AppDatabase
    ) throws -> OkDTO {
        switch (search, queryItems) {
        case (let search?, nil):
            try appDatabase.resetQueryDueDates(query: search)
        case (nil, let items?):
            let pairs = try parseQueryPairs(items, argumentLabel: "queries")
            try appDatabase.resetQueryDueDates(instanceIDAndQueryTypeIDPairs: pairs)
        default:
            throw MemorMCPToolError(message: "Provide exactly one of `search` or `queries`.")
        }
        postDatabaseChange()
        return OkDTO()
    }

    private static func setQueriesEnabled(
        enabled: Bool,
        queryItems: [[String: Value]],
        appDatabase: AppDatabase
    ) throws -> OkDTO {
        let pairs = try parseQueryPairs(queryItems, argumentLabel: "queries")
        if enabled {
            // setQueryEnabled(true, ...) blindly inserts a query row, so validate
            // each pair first: reject map instances (their queries are keyed by
            // point/attachment, not query type) and query types from other types.
            var queryTypeIDsByTypeID: [Int64: Set<Int64>] = [:]
            for pair in pairs {
                if try appDatabase.fetchPointMapInstanceTitle(instanceID: pair.instanceID) != nil {
                    throw MemorMCPToolError(message: "Instance \(pair.instanceID) is a PointMap instance; use update_pointmap_point to enable its queries.")
                }
                if try appDatabase.fetchBoundaryMapInstanceTitle(instanceID: pair.instanceID) != nil {
                    throw MemorMCPToolError(message: "Instance \(pair.instanceID) is a BoundaryMap instance; use update_boundarymap_instance's set_enabled to enable its queries.")
                }
                let data = try appDatabase.fetchInstanceEditorData(instanceID: pair.instanceID)
                let validQueryTypeIDs: Set<Int64>
                if let cached = queryTypeIDsByTypeID[data.typeID] {
                    validQueryTypeIDs = cached
                } else {
                    validQueryTypeIDs = Set(try appDatabase.fetchQueryTypes(forTypeID: data.typeID).map(\.id))
                    queryTypeIDsByTypeID[data.typeID] = validQueryTypeIDs
                }
                guard validQueryTypeIDs.contains(pair.queryTypeID) else {
                    throw MemorMCPToolError(message: "Query type \(pair.queryTypeID) does not belong to instance \(pair.instanceID)'s type.")
                }
            }
            for pair in pairs {
                try appDatabase.setQueryEnabled(true, instanceID: pair.instanceID, queryTypeID: pair.queryTypeID)
            }
        } else {
            try appDatabase.disableQueries(instanceIDAndQueryTypeIDPairs: pairs)
        }
        postDatabaseChange()
        return OkDTO()
    }

    private static func setMaxIntervalTool(
        instanceID: Int64,
        maxInterval: Int64?,
        appDatabase: AppDatabase
    ) throws -> OkDTO {
        if let maxInterval, maxInterval <= 0 {
            throw MemorMCPToolError(message: "`max_interval` must be a positive number of seconds, or null to clear.")
        }
        if try appDatabase.fetchPointMapInstanceTitle(instanceID: instanceID) != nil
            || appDatabase.fetchBoundaryMapInstanceTitle(instanceID: instanceID) != nil {
            throw MemorMCPToolError(message: "max_interval applies to standard queries only; instance \(instanceID) is a map instance.")
        }
        // Validates the instance exists.
        _ = try appDatabase.fetchInstanceEditorData(instanceID: instanceID)
        try appDatabase.setMaxInterval(forInstanceID: instanceID, maxInterval: maxInterval)
        postDatabaseChange()
        return OkDTO()
    }

    // MARK: - Stack tools

    private static func listStacks(includeCounts: Bool, appDatabase: AppDatabase) throws -> [StackDTO] {
        let stacks = try appDatabase.fetchStacks()
        guard includeCounts else {
            return stacks.map { StackDTO($0) }
        }
        // refreshStackQueryCounts recomputes each stack's blue/red/green/magenta
        // counts (its only write is the stacks_last_updated_timestamp global). A
        // stack whose search fails to parse gets nil counts.
        let countsByStackID = try appDatabase.refreshStackQueryCounts()
        return stacks.map { stack in
            StackDTO(stack, counts: countsByStackID[stack.id] ?? nil)
        }
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
            let linkField = try resolveLinkField(key: key, in: linkFields)
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

    /// Resolves a link field from an ID (numeric string) or a name (exact
    /// match first, then unique case-insensitive).
    private static func resolveLinkField(key: String, in linkFields: [LinkField]) throws -> LinkField {
        if let id = Int64(key) {
            guard let match = linkFields.first(where: { $0.id == id }) else {
                throw MemorMCPToolError(message: "No link field with id \(id) on this type.")
            }
            return match
        }
        if let exact = linkFields.first(where: { $0.name == key }) {
            return exact
        }
        let caseInsensitive = linkFields.filter { $0.name.caseInsensitiveCompare(key) == .orderedSame }
        if caseInsensitive.count == 1 {
            return caseInsensitive[0]
        }
        let available = linkFields.map { "\($0.name) (id \($0.id))" }.joined(separator: ", ")
        throw MemorMCPToolError(message: "Unknown link field `\(key)`. Available link fields: \(available).")
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
                description: "Search instances using Memor's instance search language: space-separated components combined with AND (literal:text, type:name, collection:name / col:name, id:number, :noqueries, OR, NOT, parentheses, double quotes for spaces; empty string matches all) — call describe_search_syntax for full documentation. Results are grouped by type with per-type total_count/truncated; at most `limit` instances are returned overall (default 50). Set include_field_values to also return each instance's full field values (Object/Node instances only).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": stringValue,
                        "limit": int64Number,
                        "include_field_values": boolValue
                    ]),
                    "required": .array([.string("query")])
                ])
            ),

            Tool(
                name: "update_node_links",
                description: "Edit one link field's targets on a Node instance. Provide either set_target_ids (full ordered replacement) or add_target_ids/remove_target_ids (incremental); other link fields are untouched. link_field is the link field's name or ID. Targets must be instances of the same Node type (no self-links); the field's min/max target counts are enforced. Returns the field's resulting targets with display values.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "instance_id": int64Number,
                        "link_field": stringValue,
                        "set_target_ids": int64Array,
                        "add_target_ids": int64Array,
                        "remove_target_ids": int64Array
                    ]),
                    "required": .array([.string("instance_id"), .string("link_field")])
                ])
            ),
            Tool(
                name: "search_node_candidates",
                description: "Search instances of a Node type to find link targets. Matches against the type's primary field only; empty query lists all. Returns at most 100 results (id + display_value). excluding_instance_id omits one instance, e.g. the instance being linked from (self-links are not allowed).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type_id": int64Number,
                        "query": stringValue,
                        "excluding_instance_id": int64Number
                    ]),
                    "required": .array([.string("type_id")])
                ])
            ),

            Tool(
                name: "create_pointmap_instance",
                description: "Create a new PointMap instance (a named map with studyable points). Optional points array seeds initial points, each {name, latitude, longitude, forward_enabled? (default true), reverse_enabled? (default false)}. default_center_lat/lng (default 0) and default_zoom (default 2) set the question map's initial viewport. boundary_ids optionally overlays boundary outlines on the map (discover via list_boundary_sets / list_boundaries).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": stringValue,
                        "default_center_lat": numberValue,
                        "default_center_lng": numberValue,
                        "default_zoom": numberValue,
                        "show_all_points_in_question": boolValue,
                        "points": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "name": stringValue,
                                    "latitude": numberValue,
                                    "longitude": numberValue,
                                    "forward_enabled": boolValue,
                                    "reverse_enabled": boolValue
                                ]),
                                "required": .array([.string("name"), .string("latitude"), .string("longitude")])
                            ])
                        ]),
                        "boundary_ids": int64Array
                    ]),
                    "required": .array([.string("title")])
                ])
            ),
            Tool(
                name: "update_pointmap_instance",
                description: "Update a PointMap instance's title, default viewport (center/zoom), show_all_points_in_question, and/or attached boundary outlines (boundary_ids replaces the full set). Omitted arguments keep their current values; points are untouched (use add/update/delete_pointmap_point).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "instance_id": int64Number,
                        "title": stringValue,
                        "default_center_lat": numberValue,
                        "default_center_lng": numberValue,
                        "default_zoom": numberValue,
                        "show_all_points_in_question": boolValue,
                        "boundary_ids": int64Array
                    ]),
                    "required": .array([.string("instance_id")])
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
                name: "update_pointmap_point",
                description: "Update a point on a PointMap instance: name, coordinates, and/or which query directions are enabled. Omitted arguments keep their current values. WARNING: disabling a direction (forward_enabled/reverse_enabled = false) permanently deletes that direction's SRS progress; re-enabling starts it as new.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "instance_id": int64Number,
                        "point_id": int64Number,
                        "name": stringValue,
                        "latitude": numberValue,
                        "longitude": numberValue,
                        "forward_enabled": boolValue,
                        "reverse_enabled": boolValue
                    ]),
                    "required": .array([.string("instance_id"), .string("point_id")])
                ])
            ),
            Tool(
                name: "delete_pointmap_point",
                description: "Delete a point from a PointMap instance, along with both of its queries and their SRS progress. Irreversible.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "instance_id": int64Number,
                        "point_id": int64Number
                    ]),
                    "required": .array([.string("instance_id"), .string("point_id")])
                ])
            ),

            Tool(
                name: "create_boundarymap_instance",
                description: "Create a new BoundaryMap instance (a named map whose studyable items are attached boundary outlines, e.g. countries or states). boundaries is an array of {boundary_id, forward_enabled? (default true), reverse_enabled? (default false)} — discover boundary IDs via list_boundary_sets / list_boundaries. default_center_lat/lng (default 0) and default_zoom (default 2) set the question map's initial viewport.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": stringValue,
                        "default_center_lat": numberValue,
                        "default_center_lng": numberValue,
                        "default_zoom": numberValue,
                        "show_all_boundaries_in_question": boolValue,
                        "boundaries": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "boundary_id": int64Number,
                                    "forward_enabled": boolValue,
                                    "reverse_enabled": boolValue
                                ]),
                                "required": .array([.string("boundary_id")])
                            ])
                        ])
                    ]),
                    "required": .array([.string("title")])
                ])
            ),
            Tool(
                name: "update_boundarymap_instance",
                description: "Update a BoundaryMap instance: title/viewport settings, attach new boundaries (add_boundaries: [{boundary_id, forward_enabled?, reverse_enabled?}]), detach attachments (remove_attachment_ids — deletes their queries and SRS progress), and/or toggle query directions on existing attachments (set_enabled: [{attachment_id, forward_enabled?, reverse_enabled?}]). Omitted arguments keep their current values. Attachment IDs come from get_instance. WARNING: disabling a direction permanently deletes that direction's SRS progress.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "instance_id": int64Number,
                        "title": stringValue,
                        "default_center_lat": numberValue,
                        "default_center_lng": numberValue,
                        "default_zoom": numberValue,
                        "show_all_boundaries_in_question": boolValue,
                        "add_boundaries": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "boundary_id": int64Number,
                                    "forward_enabled": boolValue,
                                    "reverse_enabled": boolValue
                                ]),
                                "required": .array([.string("boundary_id")])
                            ])
                        ]),
                        "remove_attachment_ids": int64Array,
                        "set_enabled": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "attachment_id": int64Number,
                                    "forward_enabled": boolValue,
                                    "reverse_enabled": boolValue
                                ]),
                                "required": .array([.string("attachment_id")])
                            ])
                        ])
                    ]),
                    "required": .array([.string("instance_id")])
                ])
            ),
            Tool(
                name: "list_boundary_sets",
                description: "List the boundary sets (built-in collections of geographic boundary outlines, e.g. countries or US states) available for PointMap overlays and BoundaryMap attachments.",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            Tool(
                name: "list_boundaries",
                description: "List the boundaries in a boundary set (id + name). Optional name_contains filters case-insensitively, which is recommended for large sets.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "boundary_set_id": int64Number,
                        "name_contains": stringValue
                    ]),
                    "required": .array([.string("boundary_set_id")])
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
                description: "Search queries (individual flashcards) using Memor's query search language — the same language Stack `search` expressions use, so a Stack's search returns exactly that Stack's queries. Components: literal:text, type:name, collection:name / col:name, id:number, :new, OR, NOT, parentheses, double quotes for spaces; empty string matches all. Call describe_search_syntax for full documentation. Results are grouped by type with per-type total_count/truncated; at most `limit` queries are returned overall (default 50). For map queries, query_type_id is a point/attachment ID and is_reverse distinguishes the reverse card.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": stringValue,
                        "limit": int64Number
                    ]),
                    "required": .array([.string("query")])
                ])
            ),

            Tool(
                name: "reset_due_dates",
                description: "Reset queries to new (interval 0, never answered), erasing their SRS progress. Provide exactly one of: `search` (a query-search expression; resets every matching query, including map queries) or `queries` (an array of {instance_id, query_type_id} pairs; for map instances query_type_id is a point/attachment ID and both directions reset). Irreversible.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "search": stringValue,
                        "queries": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "instance_id": int64Number,
                                    "query_type_id": int64Number
                                ]),
                                "required": .array([.string("instance_id"), .string("query_type_id")])
                            ])
                        ])
                    ])
                ])
            ),
            Tool(
                name: "set_queries_enabled",
                description: "Enable or disable queries given as {instance_id, query_type_id} pairs. Disabling deletes the query row — its SRS progress is permanently lost (for map instances, query_type_id is a point/attachment ID and both directions are disabled). Enabling creates the query as new and works on Object/Node instances only; to enable map queries use update_pointmap_point or update_boundarymap_instance.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "enabled": boolValue,
                        "queries": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "instance_id": int64Number,
                                    "query_type_id": int64Number
                                ]),
                                "required": .array([.string("instance_id"), .string("query_type_id")])
                            ])
                        ])
                    ]),
                    "required": .array([.string("enabled"), .string("queries")])
                ])
            ),
            Tool(
                name: "set_max_interval",
                description: "Cap the SRS interval for all of an Object/Node instance's queries, in seconds (e.g. 604800 = 7 days). Pass null (or omit max_interval) to remove the cap.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "instance_id": int64Number,
                        "max_interval": int64Number
                    ]),
                    "required": .array([.string("instance_id")])
                ])
            ),
            Tool(
                name: "render_query",
                description: "Render a flashcard exactly as the user will see it. For Object/Node queries, returns the final question_html and answer_html with field values substituted, the global template applied, and CSS inlined. For PointMap/BoundaryMap instances, pass a point/attachment ID as query_type_id and the result describes the map card (highlighted point or boundary) instead of HTML. Omit query_type_id to render the instance's first query.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "instance_id": int64Number,
                        "query_type_id": int64Number
                    ]),
                    "required": .array([.string("instance_id")])
                ])
            ),
            Tool(
                name: "describe_search_syntax",
                description: "Get full documentation for Memor's search query languages: instance search (search_instances) and query search (search_queries, reset_due_dates, and Stack search expressions).",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),

            Tool(
                name: "list_stacks",
                description: "List all stacks (saved query searches that the user studies). Set include_counts to also compute each stack's query counts by SRS color: blue (new), red (seen, due soon), green (answered correctly recently), magenta (interval >= 1 day); null counts mean the stack's search failed to parse.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["include_counts": boolValue])
                ])
            ),
            Tool(
                name: "create_stack",
                description: "Create a new stack with a name and a query search expression (see search_queries / describe_search_syntax for the language; the stack contains exactly the queries its search matches).",
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
                description: "Rename a stack and/or change its query search expression (see search_queries / describe_search_syntax for the language). Provide at least one of name or search.",
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

private struct CreatedPointMapInstanceDTO: Encodable {
    let instanceID: Int64
    let pointCount: Int
}

private struct CreatedBoundaryMapInstanceDTO: Encodable {
    let instanceID: Int64
    let attachmentCount: Int
}

private struct BoundarySetDTO: Encodable {
    let id: Int64
    let name: String
    let isBuiltin: Bool
    let boundaryCount: Int

    init(_ set: BoundarySet) {
        id = set.id
        name = set.name
        isBuiltin = set.isBuiltin
        boundaryCount = set.boundaryCount
    }
}

private struct BoundaryDTO: Encodable {
    let id: Int64
    let name: String
}

private struct RenderedPointDTO: Encodable {
    let id: Int64
    let name: String
    let latitude: Double
    let longitude: Double
}

private struct RenderedBoundaryDTO: Encodable {
    let attachmentID: Int64
    let boundaryID: Int64
    let name: String
}

private struct RenderedQueryDTO: Encodable {
    let kind: String
    let instanceID: Int64
    let typeName: String
    let queryTypeID: Int64
    let queryTypeName: String
    // Standard (object/node) queries only.
    let questionHTML: String?
    let answerHTML: String?
    // Map queries only.
    let instanceTitle: String?
    let point: RenderedPointDTO?
    let showAllPointsInQuestion: Bool?
    let boundary: RenderedBoundaryDTO?
    let showAllBoundariesInQuestion: Bool?
}

private struct SearchSyntaxDTO: Encodable {
    let documentation: String
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
    // Present only when include_field_values is requested (never for map instances).
    let fields: [InstanceFieldValueDTO]?
}

private struct InstanceSearchSectionDTO: Encodable {
    let typeID: Int64
    let typeName: String
    let totalCount: Int
    let truncated: Bool
    let instances: [InstanceSearchResultDTO]
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
    // Map queries only: distinguishes a point/boundary's reverse card.
    let isReverse: Bool

    init(_ r: QuerySearchResult) {
        instanceID = r.instanceID
        queryTypeID = r.queryTypeID
        displayValue = r.displayValue
        queryTypeName = r.queryTypeName
        isReverse = r.isReverse
    }
}

private struct QuerySearchSectionDTO: Encodable {
    let typeID: Int64
    let typeName: String
    let totalCount: Int
    let truncated: Bool
    let queries: [QuerySearchResultDTO]
}

private struct StackDTO: Encodable {
    let id: Int64
    let name: String
    let search: String
    let description: String
    let isPinned: Bool
    // Present only when include_counts is requested; nil counts mean the
    // stack's search failed to parse.
    let blueQueryCount: Int?
    let redQueryCount: Int?
    let greenQueryCount: Int?
    let magentaQueryCount: Int?

    init(_ s: Stack, counts: StackQueryCounts? = nil) {
        id = s.id
        name = s.name
        search = s.search
        description = s.description
        isPinned = s.isPinned
        blueQueryCount = counts?.blueQueryCount
        redQueryCount = counts?.redQueryCount
        greenQueryCount = counts?.greenQueryCount
        magentaQueryCount = counts?.magentaQueryCount
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

    func optionalObjectArray(_ key: String) throws -> [[String: Value]]? {
        guard let v = self[key] else { return nil }
        if v.isNull { return nil }
        return try requireObjectArray(key)
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
