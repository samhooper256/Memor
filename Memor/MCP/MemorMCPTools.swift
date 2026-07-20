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
            let created = try createInstanceCore(
                typeID: typeID,
                fieldValuesByID: fieldValuesByID,
                fieldValuesByName: fieldValuesByName,
                queryTypeIDs: Set(queryTypeIDs),
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
            return try jsonResult(updateInstance(
                instanceID: instanceID,
                fieldValuesByID: fieldValuesByID,
                fieldValuesByName: fieldValuesByName,
                queryTypeIDs: queryTypeIDs,
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

        // Person
        case "update_person_relations":
            return try updatePersonRelations(arguments: arguments, appDatabase: appDatabase)
        case "update_person_offices":
            return try updatePersonOffices(arguments: arguments, appDatabase: appDatabase)

        // Offices
        case "list_offices":
            return try listOffices(arguments: arguments, appDatabase: appDatabase)
        case "create_office":
            return try createOfficeTool(arguments: arguments, appDatabase: appDatabase)
        case "update_office":
            return try updateOfficeTool(arguments: arguments, appDatabase: appDatabase)
        case "delete_office":
            return try deleteOfficeTool(arguments: arguments, appDatabase: appDatabase)

        // PointMap
        case "create_pointmap_instance":
            return try jsonResult(createPointMapInstance(
                title: try arguments.requireString("title"),
                description: try arguments.optionalString("description") ?? "",
                defaultCenterLat: try arguments.optionalDouble("default_center_lat") ?? 0,
                defaultCenterLng: try arguments.optionalDouble("default_center_lng") ?? 0,
                defaultZoom: try arguments.optionalDouble("default_zoom") ?? 2,
                showAllPointsInQuestion: try arguments.optionalBool("show_all_points_in_question") ?? true,
                pointSize: try parsePointSize(arguments.optionalString("point_size")) ?? .medium,
                pointItems: try arguments.optionalObjectArray("points") ?? [],
                boundaryIDs: try arguments.optionalInt64Array("boundary_ids") ?? [],
                appDatabase: appDatabase
            ))
        case "update_pointmap_instance":
            return try jsonResult(updatePointMapInstance(
                instanceID: try arguments.requireInt64("instance_id"),
                title: try arguments.optionalString("title"),
                description: try arguments.optionalString("description"),
                defaultCenterLat: try arguments.optionalDouble("default_center_lat"),
                defaultCenterLng: try arguments.optionalDouble("default_center_lng"),
                defaultZoom: try arguments.optionalDouble("default_zoom"),
                showAllPointsInQuestion: try arguments.optionalBool("show_all_points_in_question"),
                pointSize: try parsePointSize(arguments.optionalString("point_size")),
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
            let hint = try arguments.optionalString("hint") ?? ""
            return try jsonResult(addPointMapPoint(
                instanceID: instanceID,
                name: name,
                latitude: latitude,
                longitude: longitude,
                forwardEnabled: forwardEnabled,
                reverseEnabled: reverseEnabled,
                hint: hint,
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
                hint: try arguments.optionalString("hint"),
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
                description: try arguments.optionalString("description") ?? "",
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
                description: try arguments.optionalString("description"),
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
                personKindRaw: try arguments.optionalString("person_kind"),
                personPartnershipID: try arguments.optionalInt64("partnership_id"),
                personOfficeID: try arguments.optionalInt64("office_id"),
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
            description: type.description,
            isBuiltin: type.isBuiltin,
            isPointMap: type.name == POINTMAP_TYPE_NAME,
            isBoundaryMap: type.name == BOUNDARYMAP_TYPE_NAME,
            isPerson: type.isPerson,
            instanceCount: type.instanceCount,
            fields: fields.map(FieldDTO.init),
            queryTypes: queryTypes.map(QueryTypeDTO.init),
            builtinQueryKinds: type.isPerson ? PersonQueryKind.allCases.map(\.rawValue) : nil
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
        let fieldValues = try resolveFieldValues(
            typeID: typeID,
            byID: fieldValuesByID,
            byName: fieldValuesByName,
            appDatabase: appDatabase
        )
        if type.isPerson {
            try validatePersonSexValues(typeID: typeID, fieldValues: fieldValues, appDatabase: appDatabase)
        }
        let instanceID = try appDatabase.makeInstance(
            forTypeID: typeID,
            fieldValuesByFieldID: fieldValues,
            queryTypeIDs: queryTypeIDs
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
                let created = try createInstanceCore(
                    typeID: typeID,
                    fieldValuesByID: fieldValuesByID,
                    fieldValuesByName: fieldValuesByName,
                    queryTypeIDs: queryTypeIDs,
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

        // Person field edits must run through savePersonInstance: a Sex change
        // flips the person's role on their children (or is blocked as a
        // contradiction), which the generic field write would silently skip.
        let type = try appDatabase.fetchType(typeID: current.typeID)
        if type?.isPerson == true {
            try validatePersonSexValues(typeID: current.typeID, fieldValues: mergedFieldValues, appDatabase: appDatabase)
            let personData = try appDatabase.fetchPersonEditorData(instanceID: instanceID)
            let enabledStandaloneKinds = Set(
                personData.builtinQueries.filter { $0.enabled && $0.partnershipID == nil }.map(\.kind)
            )
            do {
                _ = try appDatabase.savePersonInstance(
                    instanceID: instanceID,
                    fieldValuesByFieldID: mergedFieldValues,
                    queryTypeIDs: mergedQueryTypeIDs,
                    relations: personData.relations,
                    builtinEnabledKinds: enabledStandaloneKinds
                )
            } catch let error as PersonSaveError {
                let messages = error.conflicts
                    .map { "\($0.displayName): \($0.kind.description)" }
                    .joined(separator: "; ")
                throw MemorMCPToolError(message: "The change contradicts existing relationship data; nothing was saved. \(messages)")
            }
            postDatabaseChange()
            return OkDTO()
        }

        try appDatabase.updateInstance(
            instanceID: instanceID,
            fieldValuesByFieldID: mergedFieldValues,
            queryTypeIDs: mergedQueryTypeIDs
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
                enabled: data.enabledQueryTypeIDs.contains(queryType.id),
                interval: srs?.interval,
                queryState: srs?.queryState.rawValue,
                lastAnsweredTimestamp: srs?.lastAnsweredTimestamp
            )
        }

        var relations: PersonRelationsDTO? = nil
        var builtinQueries: [PersonBuiltinQueryDTO]? = nil
        if type.isPerson {
            let personData = try appDatabase.fetchPersonEditorData(instanceID: instanceID)
            relations = PersonRelationsDTO(
                relations: personData.relations,
                displayNames: personData.displayNamesByInstanceID,
                officeNames: personData.officeNamesByID
            )
            builtinQueries = try appDatabase.fetchPersonBuiltinQueryInfos(instanceID: instanceID)
                .map(PersonBuiltinQueryDTO.init)
        }

        return InstanceDetailDTO(
            instanceID: data.instanceID,
            typeID: data.typeID,
            typeName: type.name,
            maxInterval: data.maxInterval,
            fields: fieldRows,
            enabledQueryTypeIds: Array(data.enabledQueryTypeIDs).sorted(),
            queries: queries,
            relations: relations,
            builtinQueries: builtinQueries
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

    // MARK: - Person tools

    /// Rejects Person sex values the normalizer would otherwise silently
    /// coerce (anything but male/female, case-insensitive).
    private static func validatePersonSexValues(
        typeID: Int64,
        fieldValues: [Int64: String],
        appDatabase: AppDatabase
    ) throws {
        let sexFieldIDs = try appDatabase.fetchFields(forTypeID: typeID)
            .filter { $0.fieldType == .sex }
            .map(\.id)
        for fieldID in sexFieldIDs {
            guard let raw = fieldValues[fieldID] else { continue }
            let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !v.isEmpty && v != "male" && v != "female" {
                throw MemorMCPToolError(message: "Sex must be \"Male\" or \"Female\" (got \"\(raw)\").")
            }
        }
    }

    /// Parses a slot value: {"instance_id": n} | {"name": "..."} | null.
    private static func parsePersonRef(_ value: Value, argumentLabel: String) throws -> PersonRef? {
        if value.isNull { return nil }
        if let obj = value.objectValue {
            if let idValue = obj["instance_id"], let id = idValue.intValue {
                return .instance(Int64(id))
            }
            if let nameValue = obj["name"], let name = nameValue.stringValue {
                return .bare(name)
            }
        }
        throw MemorMCPToolError(message: "`\(argumentLabel)` must be {\"instance_id\": n}, {\"name\": \"...\"}, or null.")
    }

    /// Parses a child entry: an integer instance id, a bare-name string, or the
    /// object form used by slots.
    private static func parsePersonChildRef(_ value: Value, argumentLabel: String) throws -> PersonRef {
        if let id = value.intValue { return .instance(Int64(id)) }
        if let name = value.stringValue { return .bare(name) }
        if let obj = value.objectValue {
            if let idValue = obj["instance_id"], let id = idValue.intValue { return .instance(Int64(id)) }
            if let nameValue = obj["name"], let name = nameValue.stringValue { return .bare(name) }
        }
        throw MemorMCPToolError(message: "Every entry in `\(argumentLabel)` must be an instance id, a name string, or {\"instance_id\"}/{\"name\"}.")
    }

    /// Full-state relationship editor: a present key replaces that slot; an
    /// absent key keeps it. A present `partnerships` array is the COMPLETE list
    /// (omitted existing ids are removed; items without partnership_id create).
    /// Runs the same save routine as the UI, so propagation and contradiction
    /// blocking behave identically; conflicts come back as a structured error.
    private static func updatePersonRelations(
        arguments: [String: Value],
        appDatabase: AppDatabase
    ) throws -> CallTool.Result {
        let instanceID = try arguments.requireInt64("instance_id")
        let current = try appDatabase.fetchPersonEditorData(instanceID: instanceID)
        var relations = current.relations

        if let value = arguments["mother"] {
            relations.mother = try parsePersonRef(value, argumentLabel: "mother")
        }
        if let value = arguments["father"] {
            relations.father = try parsePersonRef(value, argumentLabel: "father")
        }
        if let value = arguments["adoptive_mother"] {
            relations.adoptiveMother = try parsePersonRef(value, argumentLabel: "adoptive_mother")
        }
        if let value = arguments["adoptive_father"] {
            relations.adoptiveFather = try parsePersonRef(value, argumentLabel: "adoptive_father")
        }

        if let items = try arguments.optionalObjectArray("partnerships") {
            var newPartners: [PersonPartnerDraft] = []
            for (index, item) in items.enumerated() {
                let label = "partnerships[\(index)]"
                let partnershipID = try item.optionalInt64("partnership_id")
                let existing = partnershipID.flatMap { id in
                    current.relations.partners.first { $0.partnershipID == id }
                }
                if partnershipID != nil && existing == nil {
                    throw MemorMCPToolError(message: "\(label): partnership_id \(partnershipID!) does not belong to instance \(instanceID).")
                }
                var partner: PersonRef
                if let value = item["partner"] {
                    guard let parsed = try parsePersonRef(value, argumentLabel: "\(label).partner") else {
                        throw MemorMCPToolError(message: "\(label).partner cannot be null.")
                    }
                    partner = parsed
                } else if let existing {
                    partner = existing.partner
                } else {
                    throw MemorMCPToolError(message: "\(label): new partnerships require `partner`.")
                }
                var children: [PersonChildDraft]
                if let childValues = item["children"]?.arrayValue {
                    children = try childValues.map {
                        PersonChildDraft(rowID: nil, child: try parsePersonChildRef($0, argumentLabel: "\(label).children"))
                    }
                } else {
                    children = existing?.children ?? []
                }
                newPartners.append(PersonPartnerDraft(
                    partnershipID: partnershipID,
                    partner: partner,
                    isMarried: try item.optionalBool("is_married") ?? existing?.isMarried ?? false,
                    startText: try item.optionalString("start") ?? existing?.startText ?? "",
                    endText: try item.optionalString("end") ?? existing?.endText ?? "",
                    children: children,
                    isChildrenQueryEnabled: try item.optionalBool("children_query_enabled")
                        ?? existing?.isChildrenQueryEnabled ?? false
                ))
            }
            relations.partners = newPartners
        }

        if let childValues = arguments["ungrouped_children"]?.arrayValue {
            relations.ungroupedChildren = try childValues.map {
                PersonChildDraft(rowID: nil, child: try parsePersonChildRef($0, argumentLabel: "ungrouped_children"))
            }
        }

        // Per-office rows carry officeID (their enablement rides the offices
        // payload); only true standalone kinds belong in builtinEnabledKinds.
        let enabledStandaloneKinds = Set(
            current.builtinQueries
                .filter { $0.enabled && $0.partnershipID == nil && $0.officeID == nil }
                .map(\.kind)
        )

        do {
            let result = try appDatabase.savePersonInstance(
                instanceID: instanceID,
                fieldValuesByFieldID: current.fieldValuesByFieldID,
                queryTypeIDs: current.enabledQueryTypeIDs,
                relations: relations,
                builtinEnabledKinds: enabledStandaloneKinds
            )
            postDatabaseChange()
            let updated = try appDatabase.fetchPersonEditorData(instanceID: instanceID)
            return try jsonResult(UpdatePersonRelationsResultDTO(
                instanceId: result.instanceID,
                resetQueryCount: result.resetQueryCount,
                relations: PersonRelationsDTO(
                    relations: updated.relations,
                    displayNames: updated.displayNamesByInstanceID,
                    officeNames: updated.officeNamesByID
                )
            ))
        } catch let error as PersonSaveError {
            let conflicts = error.conflicts.map { conflict in
                PersonConflictDTO(
                    instanceId: conflict.instanceID,
                    displayName: conflict.displayName,
                    message: conflict.kind.description
                )
            }
            let data = try encoder.encode(["contradictions": conflicts])
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return CallTool.Result(
                content: [.text(text: "The change contradicts existing relationship data; nothing was saved. \(text)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    /// Full-state office editing for one Person: `offices` is the COMPLETE
    /// ordered list of holdings (an omitted office is REMOVED, deleting its
    /// per-office query SRS and this person's succession links for it).
    /// Items name an EXISTING office by office_id or office_name; absent
    /// sub-keys inherit from the current holding. Linking a predecessor/
    /// successor AUTO-ADDS that office to the linked person.
    private static func updatePersonOffices(
        arguments: [String: Value],
        appDatabase: AppDatabase
    ) throws -> CallTool.Result {
        let instanceID = try arguments.requireInt64("instance_id")
        let current = try appDatabase.fetchPersonEditorData(instanceID: instanceID)
        var relations = current.relations

        guard let items = try arguments.optionalObjectArray("offices") else {
            throw MemorMCPToolError(message: "`offices` is required (pass [] to remove every office).")
        }

        let allOffices = try appDatabase.fetchOffices()
        var newOffices: [PersonOfficeDraft] = []
        for (index, item) in items.enumerated() {
            let label = "offices[\(index)]"

            let officeID: Int64
            if let id = try item.optionalInt64("office_id") {
                guard allOffices.contains(where: { $0.id == id }) else {
                    throw MemorMCPToolError(message: "\(label): office_id \(id) does not exist. Use list_offices or create_office first.")
                }
                officeID = id
            } else if let name = try item.optionalString("office_name") {
                guard let office = allOffices.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                    throw MemorMCPToolError(message: "\(label): no office named \u{201C}\(name)\u{201D} exists. Use create_office first (offices are never created implicitly).")
                }
                officeID = office.id
            } else {
                throw MemorMCPToolError(message: "\(label): exactly one of office_id / office_name is required.")
            }

            let existing = current.relations.offices.first { $0.officeID == officeID }
            newOffices.append(PersonOfficeDraft(
                personOfficeID: existing?.personOfficeID,
                officeID: officeID,
                whenBegan: try item.optionalString("when_began") ?? existing?.whenBegan ?? "",
                whenEnded: try item.optionalString("when_ended") ?? existing?.whenEnded ?? "",
                note: try item.optionalString("note") ?? existing?.note ?? "",
                predecessors: try item.optionalInt64Array("predecessors") ?? existing?.predecessors ?? [],
                successors: try item.optionalInt64Array("successors") ?? existing?.successors ?? [],
                isQueryEnabled: try item.optionalBool("query_enabled") ?? existing?.isQueryEnabled ?? false
            ))
        }
        relations.offices = newOffices

        let enabledStandaloneKinds = Set(
            current.builtinQueries
                .filter { $0.enabled && $0.partnershipID == nil && $0.officeID == nil }
                .map(\.kind)
        )

        do {
            let result = try appDatabase.savePersonInstance(
                instanceID: instanceID,
                fieldValuesByFieldID: current.fieldValuesByFieldID,
                queryTypeIDs: current.enabledQueryTypeIDs,
                relations: relations,
                builtinEnabledKinds: enabledStandaloneKinds
            )
            postDatabaseChange()
            let updated = try appDatabase.fetchPersonEditorData(instanceID: instanceID)
            return try jsonResult(UpdatePersonRelationsResultDTO(
                instanceId: result.instanceID,
                resetQueryCount: result.resetQueryCount,
                relations: PersonRelationsDTO(
                    relations: updated.relations,
                    displayNames: updated.displayNamesByInstanceID,
                    officeNames: updated.officeNamesByID
                )
            ))
        } catch let error as PersonSaveError {
            // Office edits alone can't produce contradictions, but field/
            // relationship state rides the same save; keep parity with
            // update_person_relations.
            let conflicts = error.conflicts.map { conflict in
                PersonConflictDTO(
                    instanceId: conflict.instanceID,
                    displayName: conflict.displayName,
                    message: conflict.kind.description
                )
            }
            let data = try encoder.encode(["contradictions": conflicts])
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return CallTool.Result(
                content: [.text(text: "The change contradicts existing relationship data; nothing was saved. \(text)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    // MARK: - Office tools

    private static func listOffices(arguments: [String: Value], appDatabase: AppDatabase) throws -> CallTool.Result {
        let query = try arguments.optionalString("query")
        let offices = try appDatabase.fetchOffices(matching: query)
        return try jsonResult(offices.map(OfficeSummaryDTO.init))
    }

    private static func createOfficeTool(arguments: [String: Value], appDatabase: AppDatabase) throws -> CallTool.Result {
        let name = try arguments.requireString("name")
        let description = try arguments.optionalString("description") ?? ""
        let officeID = try appDatabase.createOffice(name: name, description: description)
        postDatabaseChange()
        guard let office = try appDatabase.fetchOffice(officeID: officeID) else {
            throw MemorMCPToolError(message: "Failed to fetch the created office.")
        }
        return try jsonResult(OfficeSummaryDTO(office))
    }

    private static func updateOfficeTool(arguments: [String: Value], appDatabase: AppDatabase) throws -> CallTool.Result {
        let officeID = try arguments.requireInt64("office_id")
        let name = try arguments.optionalString("name")
        let description = try arguments.optionalString("description")
        guard name != nil || description != nil else {
            throw MemorMCPToolError(message: "Provide at least one of name / description.")
        }
        if let name {
            try appDatabase.renameOffice(officeID: officeID, name: name)
        }
        if let description {
            try appDatabase.setOfficeDescription(officeID: officeID, description: description)
        }
        postDatabaseChange()
        guard let office = try appDatabase.fetchOffice(officeID: officeID) else {
            throw MemorMCPToolError(message: "Office \(officeID) not found.")
        }
        return try jsonResult(OfficeSummaryDTO(office))
    }

    private static func deleteOfficeTool(arguments: [String: Value], appDatabase: AppDatabase) throws -> CallTool.Result {
        let officeID = try arguments.requireInt64("office_id")
        let holderCount = try appDatabase.fetchOffice(officeID: officeID)?.holderCount ?? 0
        let resetCount = try appDatabase.deleteOffice(officeID: officeID)
        postDatabaseChange()
        return try jsonResult([
            "ok": Value.bool(true),
            "removed_holder_count": Value.int(holderCount),
            "reset_query_count": Value.int(resetCount),
        ])
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
            reverseEnabled: try item.optionalBool("reverse_enabled") ?? false,
            hint: try item.optionalString("hint") ?? ""
        )
    }

    // Parses an optional point_size argument ("small"/"medium"/"large") into the enum.
    // Returns nil when the argument is absent (so update can preserve the current value);
    // throws on an unrecognized value.
    private static func parsePointSize(_ raw: String?) throws -> PointMapPointSize? {
        guard let raw else { return nil }
        guard let size = PointMapPointSize(rawValue: raw) else {
            throw MemorMCPToolError(message: "`point_size` must be one of: small, medium, large.")
        }
        return size
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
        description: String,
        defaultCenterLat: Double,
        defaultCenterLng: Double,
        defaultZoom: Double,
        showAllPointsInQuestion: Bool,
        pointSize: PointMapPointSize,
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
            description: description,
            defaultCenterLat: defaultCenterLat,
            defaultCenterLng: defaultCenterLng,
            defaultZoom: defaultZoom,
            showAllPointsInQuestion: showAllPointsInQuestion,
            pointSize: pointSize,
            points: drafts,
            boundaryIDs: boundaryIDs
        )
        postDatabaseChange()
        return CreatedPointMapInstanceDTO(instanceID: instanceID, pointCount: drafts.count)
    }

    private static func updatePointMapInstance(
        instanceID: Int64,
        title: String?,
        description: String?,
        defaultCenterLat: Double?,
        defaultCenterLng: Double?,
        defaultZoom: Double?,
        showAllPointsInQuestion: Bool?,
        pointSize: PointMapPointSize?,
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
            description: description ?? current.instance.description,
            defaultCenterLat: defaultCenterLat ?? current.instance.defaultCenterLat,
            defaultCenterLng: defaultCenterLng ?? current.instance.defaultCenterLng,
            defaultZoom: defaultZoom ?? current.instance.defaultZoom,
            showAllPointsInQuestion: showAllPointsInQuestion ?? current.instance.showAllPointsInQuestion,
            pointSize: pointSize ?? current.instance.pointSize,
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
        hint: String,
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
            reverseEnabled: reverseEnabled,
            hint: hint
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
        hint: String?,
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
            reverseInterval: old.reverseInterval,
            hint: hint ?? old.hint
        )
        try appDatabase.updatePointMapInstance(
            instanceID: instanceID,
            title: current.instance.title,
            description: current.instance.description,
            defaultCenterLat: current.instance.defaultCenterLat,
            defaultCenterLng: current.instance.defaultCenterLng,
            defaultZoom: current.instance.defaultZoom,
            showAllPointsInQuestion: current.instance.showAllPointsInQuestion,
            pointSize: current.instance.pointSize,
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
            description: current.instance.description,
            defaultCenterLat: current.instance.defaultCenterLat,
            defaultCenterLng: current.instance.defaultCenterLng,
            defaultZoom: current.instance.defaultZoom,
            showAllPointsInQuestion: current.instance.showAllPointsInQuestion,
            pointSize: current.instance.pointSize,
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
        description: String,
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
            description: description,
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
        description: String?,
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
            description: description ?? current.instance.description,
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
        personKindRaw: String?,
        personPartnershipID: Int64?,
        personOfficeID: Int64?,
        appDatabase: AppDatabase
    ) throws -> RenderedQueryDTO {
        let query: StudyQuery
        if let personKindRaw {
            guard let kind = PersonQueryKind(rawValue: personKindRaw) else {
                let valid = PersonQueryKind.allCases.map(\.rawValue).joined(separator: ", ")
                throw MemorMCPToolError(message: "Unknown person_kind `\(personKindRaw)`. Valid kinds: \(valid).")
            }
            try validatePersonKindShape(
                kind: kind, partnershipID: personPartnershipID, officeID: personOfficeID, label: "render_query"
            )
            // Built-in Person queries are HTML-rendered like standard queries.
            query = try appDatabase.fetchPersonQueryPreview(
                instanceID: instanceID,
                kind: kind,
                partnershipID: personPartnershipID,
                officeID: personOfficeID
            )
            return RenderedQueryDTO(
                kind: "person",
                instanceID: query.instanceID,
                typeName: query.typeName,
                queryTypeID: 0,
                queryTypeName: query.queryTypeName,
                questionHTML: try buildRenderedQuestionHTML(appDatabase: appDatabase, query: query),
                answerHTML: try buildRenderedAnswerHTML(appDatabase: appDatabase, query: query),
                instanceTitle: nil,
                point: nil,
                showAllPointsInQuestion: nil,
                boundary: nil,
                showAllBoundariesInQuestion: nil
            )
        }
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
        - type:ID — restrict to items of the type with this numeric ID, e.g. type:5. \
        A leading-digit argument is read as an ID; type names can never start with a digit, so this is unambiguous.
        - qt:type:queryType — restrict to the query type named queryType on the given type \
        (instance search: instances of the type with that query type enabled; query search: \
        that query type's queries), e.g. qt:Vocab:ToDefinition. The type may be a name or \
        numeric ID. Person built-in query names (Mother, Children with, an office's name, \
        All Offices, …) and map Forward/Reverse count as query type names: qt:Person:Mother, \
        "qt:Person:All Offices", qt:PointMap:Forward.
        - collection:name (or col:name) — restrict to items in the named collection.
        - col:ID (or collection:ID) — restrict to items in the collection with this numeric ID, e.g. col:67. \
        A leading-digit argument is read as an ID; collection names can never start with a digit, so this is unambiguous.
        - id:number — restrict to the single instance with this ID.
        - OR — match if either neighboring component matches (e.g. type:Term OR type:Concept).
        - NOT — exclude whatever the following component matches (e.g. NOT col:Archived).
        - ( … ) — group components to control how OR and AND combine.
        - Double quotes wrap a component containing spaces: "literal:hi there".

        Instance search only:
        - :noqueries — match only instances that have no queries enabled (a Person's \
        built-in relationship queries count as queries here).

        Query search only:
        - :new — match only queries that are new (never studied). Matches standard \
        queries and Person built-in relationship queries; map queries never match :new.

        Person built-in queries (Mother, Father, Parents, Adoptive Mother, Adoptive \
        Father, Children, Children with {partner}, Full Siblings, Office: {office}, \
        All Offices) appear in query search alongside the Person type's user-defined \
        queries; their rows carry person_kind (+ partnership_id for children_with, \
        + office_id for office) and query_type_id 0.

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

    /// Validates a built-in Person query item's discriminator shape:
    /// partnership_id exactly for children_with, office_id exactly for office.
    private static func validatePersonKindShape(
        kind: PersonQueryKind,
        partnershipID: Int64?,
        officeID: Int64?,
        label: String
    ) throws {
        if (kind == .childrenWith) != (partnershipID != nil) {
            throw MemorMCPToolError(message: "\(label): partnership_id is required exactly for person_kind `children_with`.")
        }
        if (kind == .office) != (officeID != nil) {
            throw MemorMCPToolError(message: "\(label): office_id is required exactly for person_kind `office`.")
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
            var personTargets: [QueryTarget] = []
            var standardItems: [[String: Value]] = []
            for (index, item) in items.enumerated() {
                if let kindRaw = try item.optionalString("person_kind") {
                    guard let kind = PersonQueryKind(rawValue: kindRaw) else {
                        throw MemorMCPToolError(message: "queries[\(index)]: unknown person_kind `\(kindRaw)`.")
                    }
                    let partnershipID = try item.optionalInt64("partnership_id")
                    let officeID = try item.optionalInt64("office_id")
                    try validatePersonKindShape(
                        kind: kind, partnershipID: partnershipID, officeID: officeID, label: "queries[\(index)]"
                    )
                    personTargets.append(QueryTarget(
                        instanceID: try item.requireInt64("instance_id"),
                        queryTypeID: 0,
                        isReverse: false,
                        kind: .person,
                        personKind: kind,
                        personPartnershipID: partnershipID,
                        personOfficeID: officeID
                    ))
                } else {
                    standardItems.append(item)
                }
            }
            if !personTargets.isEmpty {
                try appDatabase.resetQueryDueDates(targets: personTargets)
            }
            if !standardItems.isEmpty {
                let pairs = try parseQueryPairs(standardItems, argumentLabel: "queries")
                try appDatabase.resetQueryDueDates(instanceIDAndQueryTypeIDPairs: pairs)
            }
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
        // Items with `person_kind` target built-in Person queries; the rest are
        // ordinary {instance_id, query_type_id} pairs.
        var personItems: [(instanceID: Int64, kind: PersonQueryKind, partnershipID: Int64?, officeID: Int64?)] = []
        var standardItems: [[String: Value]] = []
        for (index, item) in queryItems.enumerated() {
            if let kindRaw = try item.optionalString("person_kind") {
                guard let kind = PersonQueryKind(rawValue: kindRaw) else {
                    let valid = PersonQueryKind.allCases.map(\.rawValue).joined(separator: ", ")
                    throw MemorMCPToolError(message: "queries[\(index)]: unknown person_kind `\(kindRaw)`. Valid kinds: \(valid).")
                }
                let instanceID = try item.requireInt64("instance_id")
                let partnershipID = try item.optionalInt64("partnership_id")
                let officeID = try item.optionalInt64("office_id")
                try validatePersonKindShape(
                    kind: kind, partnershipID: partnershipID, officeID: officeID, label: "queries[\(index)]"
                )
                personItems.append((instanceID, kind, partnershipID, officeID))
            } else {
                standardItems.append(item)
            }
        }
        for item in personItems {
            // The built-in query list validates the instance is a Person and
            // that the partnership/office holding belongs to it.
            let infos = try appDatabase.fetchPersonBuiltinQueryInfos(instanceID: item.instanceID)
            guard infos.contains(where: {
                $0.kind == item.kind && $0.partnershipID == item.partnershipID && $0.officeID == item.officeID
            }) else {
                let discriminator = item.partnershipID.map { " for partnership \($0)" }
                    ?? item.officeID.map { " for office \($0)" }
                    ?? ""
                throw MemorMCPToolError(message: "Instance \(item.instanceID) has no built-in query \(item.kind.rawValue)\(discriminator).")
            }
            try appDatabase.setPersonQueryEnabled(
                instanceID: item.instanceID,
                kind: item.kind,
                partnershipID: item.partnershipID,
                officeID: item.officeID,
                enabled: enabled
            )
        }
        if standardItems.isEmpty {
            postDatabaseChange()
            return OkDTO()
        }
        let pairs = try parseQueryPairs(standardItems, argumentLabel: "queries")
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
                description: "Create a new instance of an Object type (use create_pointmap_instance / create_boundarymap_instance for map types). Provide field values via field_values_by_field_name (field names to string values) and/or field_values_by_field_id (field IDs as strings to string values); at least one is required. query_type_ids is an optional array of enabled query type IDs.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type_id": int64Number,
                        "field_values_by_field_id": stringKeyedStringMap,
                        "field_values_by_field_name": nameKeyedStringMap,
                        "query_type_ids": int64Array
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
                                    "query_type_ids": int64Array
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
                description: "Update an existing Object instance (use the pointmap/boundarymap tools for map instances). Provide only what you want to change: omitted fields keep their existing values and an omitted query_type_ids keeps the existing set.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "instance_id": int64Number,
                        "field_values_by_field_id": stringKeyedStringMap,
                        "field_values_by_field_name": nameKeyedStringMap,
                        "query_type_ids": int64Array
                    ]),
                    "required": .array([.string("instance_id")])
                ])
            ),
            Tool(
                name: "delete_instance",
                description: "Delete an instance by ID. This removes the instance from all collections and deletes its queries. Deleting a Person converts every reference to them on other people (partner entries, parent slots, children) into a bare-name entry, preserving the family structure.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["instance_id": int64Number]),
                    "required": .array([.string("instance_id")])
                ])
            ),
            Tool(
                name: "get_instance",
                description: "Get an instance's full details: type, field values, per-query-type status (enabled, SRS interval in seconds, state, last answered), and max_interval. Person instances additionally return `relations` (mother/father/adoptive slots, ordered partnerships with is_married/start/end/children, ungrouped children; entries are {instance_id, display_value} or {name} for bare names) and `builtin_queries` (each built-in relationship query's kind, partnership_id, enablement, and SRS state). For PointMap/BoundaryMap instances, returns the map payload instead (kind, title, map settings, and points/attached boundaries with per-direction enabled flags).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["instance_id": int64Number]),
                    "required": .array([.string("instance_id")])
                ])
            ),
            Tool(
                name: "search_instances",
                description: "Search instances using Memor's instance search language: space-separated components combined with AND (literal:text, type:name (or type:ID by type ID), qt:type:queryType (instances of the type with the named query type enabled — user-defined, Person built-in, or map Forward/Reverse query names), collection:name / col:name (or col:ID by collection ID), id:number, :noqueries, OR, NOT, parentheses, double quotes for spaces; empty string matches all) — call describe_search_syntax for full documentation. Results are grouped by type with per-type total_count/truncated; at most `limit` instances are returned overall (default 50). Set include_field_values to also return each instance's full field values (Object instances only).",
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
                name: "update_person_relations",
                description: "Edit a Person instance's relationship slots with the same propagation and contradiction rules as the app: changes automatically update the other affected Person instances, and a change that contradicts existing data on another instance (an occupied mother/father slot, a sex/role mismatch, same-sex shared children) fails with a structured `contradictions` list and writes nothing. A present key replaces that slot; an absent key keeps it. mother/father/adoptive_mother/adoptive_father each take {\"instance_id\": n} (another Person), {\"name\": \"...\"} (a bare-name placeholder), or null (clear). `partnerships`, when present, is the COMPLETE ordered list: items with partnership_id keep/edit that partnership (absent sub-keys keep current values; SRS state survives), items without partnership_id create one, and omitted existing ids are REMOVED (their children fall back to the ungrouped list). Each partnership item: partner (as above; required for new), is_married, start, end (freetext), children (ordered array of instance ids and/or name strings; not allowed for same-sex couples), children_query_enabled. `ungrouped_children`, when present, replaces the ordered list of children not associated with any partner (adding an instance child fills their mother/father slot; removing one clears it). Office holdings are edited separately via update_person_offices. Returns the new full relations plus reset_query_count (non-zero when the Person type's reset-on-connection-change option is on).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "instance_id": int64Number,
                        "mother": .object(["description": .string("{\"instance_id\": n} | {\"name\": \"...\"} | null")]),
                        "father": .object(["description": .string("{\"instance_id\": n} | {\"name\": \"...\"} | null")]),
                        "adoptive_mother": .object(["description": .string("{\"instance_id\": n} | {\"name\": \"...\"} | null")]),
                        "adoptive_father": .object(["description": .string("{\"instance_id\": n} | {\"name\": \"...\"} | null")]),
                        "partnerships": .object([
                            "type": .string("array"),
                            "description": .string("Complete ordered partner list; see the tool description for item shape."),
                            "items": .object(["type": .string("object")])
                        ]),
                        "ungrouped_children": .object([
                            "type": .string("array"),
                            "description": .string("Ordered children without an associated partner: instance ids and/or name strings.")
                        ])
                    ]),
                    "required": .array([.string("instance_id")])
                ])
            ),

            Tool(
                name: "update_person_offices",
                description: "Edit a Person instance's office holdings. `offices` is the COMPLETE ordered list: an omitted office is REMOVED from this person (deleting its per-office query's SRS progress and this person's succession links for it — irreversible). Each item names an EXISTING office via exactly one of office_id / office_name (case-insensitive; unknown names are an error — offices are never created implicitly, use create_office first). Optional per item: when_began, when_ended, note (freetext; absent keys keep the current holding's values), predecessors, successors (COMPLETE arrays of Person instance ids for that office; absent keeps current; reciprocity is automatic — if A precedes B then B succeeds A — and linking a person who doesn't hold the office AUTO-ADDS it to them with empty fields), and query_enabled (the per-office built-in query; default keeps current / false for new holdings). Returns the person's updated relations (including offices) plus reset_query_count (non-zero when the Person type's reset-on-connection-change option is on).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "instance_id": int64Number,
                        "offices": .object([
                            "type": .string("array"),
                            "description": .string("Complete ordered holdings list; see the tool description for item shape."),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "office_id": int64Number,
                                    "office_name": stringValue,
                                    "when_began": stringValue,
                                    "when_ended": stringValue,
                                    "note": stringValue,
                                    "predecessors": int64Array,
                                    "successors": int64Array,
                                    "query_enabled": boolValue
                                ])
                            ])
                        ])
                    ]),
                    "required": .array([.string("instance_id"), .string("offices")])
                ])
            ),

            Tool(
                name: "list_offices",
                description: "List every office (the shared entities Person instances can hold, e.g. \"U.S. President\"), each with id, name, description, and holder_count (how many Person instances hold it). Optional `query` filters by name substring (case-insensitive).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": stringValue
                    ])
                ])
            ),
            Tool(
                name: "create_office",
                description: "Create a new office. Names are trimmed and must be unique case-insensitively. Offices must exist before they can be assigned to a Person via update_person_offices.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": stringValue,
                        "description": stringValue
                    ]),
                    "required": .array([.string("name")])
                ])
            ),
            Tool(
                name: "update_office",
                description: "Rename an office and/or set its description (at least one of name/description is required). Renaming does not reset any queries.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "office_id": int64Number,
                        "name": stringValue,
                        "description": stringValue
                    ]),
                    "required": .array([.string("office_id")])
                ])
            ),
            Tool(
                name: "delete_office",
                description: "Delete an office. This cascades IRREVERSIBLY with no confirmation: every Person's holding of it, all of its succession links, and every enabled per-office query (including SRS progress) are removed. Check holder_count via list_offices first.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "office_id": int64Number
                    ]),
                    "required": .array([.string("office_id")])
                ])
            ),

            Tool(
                name: "create_pointmap_instance",
                description: "Create a new PointMap instance (a named map with studyable points). Optional points array seeds initial points, each {name, latitude, longitude, forward_enabled? (default true), reverse_enabled? (default false), hint? (default empty)}. A point's hint is text shown in Study mode before the answer is revealed, on Forward queries only. description (default empty) is a free-text note about the instance; it is never shown in Study mode. default_center_lat/lng (default 0) and default_zoom (default 2) set the question map's initial viewport. point_size (\"small\"/\"medium\"/\"large\", default \"medium\") scales how large the markers render. boundary_ids optionally overlays boundary outlines on the map (discover via list_boundary_sets / list_boundaries).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": stringValue,
                        "description": stringValue,
                        "default_center_lat": numberValue,
                        "default_center_lng": numberValue,
                        "default_zoom": numberValue,
                        "show_all_points_in_question": boolValue,
                        "point_size": stringValue,
                        "points": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "name": stringValue,
                                    "latitude": numberValue,
                                    "longitude": numberValue,
                                    "forward_enabled": boolValue,
                                    "reverse_enabled": boolValue,
                                    "hint": stringValue
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
                description: "Update a PointMap instance's title, description (free-text note, never shown in Study mode), default viewport (center/zoom), show_all_points_in_question, point_size (\"small\"/\"medium\"/\"large\"), and/or attached boundary outlines (boundary_ids replaces the full set). Omitted arguments keep their current values; points are untouched (use add/update/delete_pointmap_point).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "instance_id": int64Number,
                        "title": stringValue,
                        "description": stringValue,
                        "default_center_lat": numberValue,
                        "default_center_lng": numberValue,
                        "default_zoom": numberValue,
                        "show_all_points_in_question": boolValue,
                        "point_size": stringValue,
                        "boundary_ids": int64Array
                    ]),
                    "required": .array([.string("instance_id")])
                ])
            ),
            Tool(
                name: "add_pointmap_point",
                description: "Add a point (query) to an existing PointMap instance, identified by instance_id. Provide the point name and its latitude (-90..90) / longitude (-180..180). forward_enabled (default true) and reverse_enabled (default false) control which of the point's two queries are enabled; set both to false for a point with no active query. hint (default empty) is text shown in Study mode before the answer is revealed, on Forward queries only.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "instance_id": int64Number,
                        "name": stringValue,
                        "latitude": numberValue,
                        "longitude": numberValue,
                        "forward_enabled": boolValue,
                        "reverse_enabled": boolValue,
                        "hint": stringValue
                    ]),
                    "required": .array([.string("instance_id"), .string("name"), .string("latitude"), .string("longitude")])
                ])
            ),
            Tool(
                name: "update_pointmap_point",
                description: "Update a point on a PointMap instance: name, hint, coordinates, and/or which query directions are enabled. Omitted arguments keep their current values (pass hint as an empty string to clear it). The hint is shown in Study mode before the answer is revealed, on Forward queries only. WARNING: disabling a direction (forward_enabled/reverse_enabled = false) permanently deletes that direction's SRS progress; re-enabling starts it as new.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "instance_id": int64Number,
                        "point_id": int64Number,
                        "name": stringValue,
                        "latitude": numberValue,
                        "longitude": numberValue,
                        "forward_enabled": boolValue,
                        "reverse_enabled": boolValue,
                        "hint": stringValue
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
                description: "Create a new BoundaryMap instance (a named map whose studyable items are attached boundary outlines, e.g. countries or states). boundaries is an array of {boundary_id, forward_enabled? (default true), reverse_enabled? (default false)} — discover boundary IDs via list_boundary_sets / list_boundaries. description (default empty) is a free-text note about the instance; it is never shown in Study mode. default_center_lat/lng (default 0) and default_zoom (default 2) set the question map's initial viewport.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": stringValue,
                        "description": stringValue,
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
                description: "Update a BoundaryMap instance: title, description (free-text note, never shown in Study mode), viewport settings, attach new boundaries (add_boundaries: [{boundary_id, forward_enabled?, reverse_enabled?}]), detach attachments (remove_attachment_ids — deletes their queries and SRS progress), and/or toggle query directions on existing attachments (set_enabled: [{attachment_id, forward_enabled?, reverse_enabled?}]). Omitted arguments keep their current values. Attachment IDs come from get_instance. WARNING: disabling a direction permanently deletes that direction's SRS progress.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "instance_id": int64Number,
                        "title": stringValue,
                        "description": stringValue,
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
                description: "Search queries (individual flashcards) using Memor's query search language — the same language Stack `search` expressions use, so a Stack's search returns exactly that Stack's queries. Components: literal:text, type:name (or type:ID by type ID), qt:type:queryType (that query type's queries on the named type — user-defined, Person built-in, or map Forward/Reverse query names), collection:name / col:name (or col:ID by collection ID), id:number, :new, OR, NOT, parentheses, double quotes for spaces; empty string matches all. Call describe_search_syntax for full documentation. Results are grouped by type with per-type total_count/truncated; at most `limit` queries are returned overall (default 50). For map queries, query_type_id is a point/attachment ID and is_reverse distinguishes the reverse card.",
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
                description: "Reset queries to new (interval 0, never answered), erasing their SRS progress. Provide exactly one of: `search` (a query-search expression; resets every matching query, including map queries) or `queries` (an array of items). Each item is either {instance_id, query_type_id} (standard queries; for map instances query_type_id is a point/attachment ID and both directions reset) or {instance_id, person_kind, partnership_id?, office_id?} for a Person's built-in queries (partnership_id required exactly for children_with; office_id required exactly for office). Irreversible.",
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
                                    "query_type_id": int64Number,
                                    "person_kind": stringValue,
                                    "partnership_id": int64Number,
                                    "office_id": int64Number
                                ]),
                                "required": .array([.string("instance_id")])
                            ])
                        ])
                    ])
                ])
            ),
            Tool(
                name: "set_queries_enabled",
                description: "Enable or disable queries. Each item is either {instance_id, query_type_id} (standard queries) or {instance_id, person_kind, partnership_id?, office_id?} for a Person's built-in queries (person_kind: mother/father/parents/adoptive_mother/adoptive_father/children/children_with/full_siblings/office/all_offices; partnership_id required exactly for children_with, office_id required exactly for office — discover ids via get_instance). Disabling deletes the query row — its SRS progress is permanently lost (for map instances, query_type_id is a point/attachment ID and both directions are disabled). Enabling creates the query as new; to enable map queries use update_pointmap_point or update_boundarymap_instance.",
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
                                    "query_type_id": int64Number,
                                    "person_kind": stringValue,
                                    "partnership_id": int64Number,
                                    "office_id": int64Number
                                ]),
                                "required": .array([.string("instance_id")])
                            ])
                        ])
                    ]),
                    "required": .array([.string("enabled"), .string("queries")])
                ])
            ),
            Tool(
                name: "set_max_interval",
                description: "Cap the SRS interval for all of an Object instance's queries, in seconds (e.g. 604800 = 7 days). Pass null (or omit max_interval) to remove the cap. Person built-in relationship queries have no max interval; on a Person instance this affects only its standard (user-defined) queries.",
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
                description: "Render a flashcard exactly as the user will see it. For Object-type queries, returns the final question_html and answer_html with field values substituted, the global template applied, and CSS inlined. For a Person's built-in queries, pass person_kind (plus partnership_id for children_with, or office_id for office) instead of query_type_id — the result is HTML like a standard query, with the answer computed from the current relationships/office holdings (a per-office answer is the fixed predecessors/person/successors layout; all_offices lists every holding via the office question template). For PointMap/BoundaryMap instances, pass a point/attachment ID as query_type_id and the result describes the map card (highlighted point or boundary) instead of HTML. Omit query_type_id to render the instance's first query.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "instance_id": int64Number,
                        "query_type_id": int64Number,
                        "person_kind": stringValue,
                        "partnership_id": int64Number,
                        "office_id": int64Number
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
                description: "List all stacks (saved query searches that the user studies). Set include_counts to also compute each stack's query counts by SRS color: blue (new), red (seen, due soon), green (answered correctly recently), magenta (interval >= 1 day); null counts mean the stack's search failed to parse. Computing counts can take tens of seconds on large databases — omit include_counts unless you need them.",
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
    let description: String
    let isBuiltin: Bool
    let isPointMap: Bool
    let isBoundaryMap: Bool
    let isPerson: Bool
    let instanceCount: Int

    init(_ type: FlashcardType) {
        id = type.id
        name = type.name
        description = type.description
        isBuiltin = type.isBuiltin
        isPointMap = type.name == POINTMAP_TYPE_NAME
        isBoundaryMap = type.name == BOUNDARYMAP_TYPE_NAME
        isPerson = type.isPerson
        instanceCount = type.instanceCount
    }
}

private struct FieldDTO: Encodable {
    let id: Int64
    let name: String
    let fieldDisplayIndex: Int
    let fieldType: String
    let isProtected: Bool

    init(_ field: TypeField) {
        id = field.id
        name = field.name
        fieldDisplayIndex = field.fieldDisplayIndex
        fieldType = field.fieldType.rawValue
        isProtected = field.isProtected
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
    let description: String
    let isBuiltin: Bool
    let isPointMap: Bool
    let isBoundaryMap: Bool
    let isPerson: Bool
    let instanceCount: Int
    let fields: [FieldDTO]
    let queryTypes: [QueryTypeDTO]
    // Person only: the built-in relationship query kinds (enabled per instance).
    let builtinQueryKinds: [String]?
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
    // Standard (object-type) queries only.
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
    let enabled: Bool
    // SRS state; nil when the query is disabled. interval is in seconds
    // (0 = new/blue). queryState is the raw SRS state machine value (0-2).
    let interval: Int64?
    let queryState: Int?
    let lastAnsweredTimestamp: Int64?
}

private struct InstanceDetailDTO: Encodable {
    let instanceID: Int64
    let typeID: Int64
    let typeName: String
    let maxInterval: Int64?
    let fields: [InstanceFieldValueDTO]
    // Named `Ids` (not `IDs`) so snake-case encoding yields enabled_query_type_ids.
    let enabledQueryTypeIds: [Int64]
    let queries: [InstanceQueryInfoDTO]
    // Person instances only.
    let relations: PersonRelationsDTO?
    let builtinQueries: [PersonBuiltinQueryDTO]?
}

// MARK: Person DTOs

/// A slot entry: an instance ({instance_id, display_value}) or a bare name ({name}).
private struct PersonRefDTO: Encodable {
    let instanceId: Int64?
    let displayValue: String?
    let name: String?

    init(_ ref: PersonRef, displayNames: [Int64: String]) {
        switch ref {
        case .instance(let id):
            instanceId = id
            displayValue = displayNames[id] ?? ""
            name = nil
        case .bare(let bareName):
            instanceId = nil
            displayValue = nil
            name = bareName
        }
    }
}

private struct PersonPartnershipDTO: Encodable {
    let partnershipId: Int64?
    let partner: PersonRefDTO
    let isMarried: Bool
    let start: String
    let end: String
    let children: [PersonRefDTO]
    let childrenQueryEnabled: Bool
}

private struct PersonRelationsDTO: Encodable {
    let mother: PersonRefDTO?
    let father: PersonRefDTO?
    let adoptiveMother: PersonRefDTO?
    let adoptiveFather: PersonRefDTO?
    let partnerships: [PersonPartnershipDTO]
    let ungroupedChildren: [PersonRefDTO]
    let offices: [PersonOfficeDTO]

    init(relations: PersonRelationsDraft, displayNames: [Int64: String], officeNames: [Int64: String] = [:]) {
        mother = relations.mother.map { PersonRefDTO($0, displayNames: displayNames) }
        father = relations.father.map { PersonRefDTO($0, displayNames: displayNames) }
        adoptiveMother = relations.adoptiveMother.map { PersonRefDTO($0, displayNames: displayNames) }
        adoptiveFather = relations.adoptiveFather.map { PersonRefDTO($0, displayNames: displayNames) }
        partnerships = relations.partners.map { partner in
            PersonPartnershipDTO(
                partnershipId: partner.partnershipID,
                partner: PersonRefDTO(partner.partner, displayNames: displayNames),
                isMarried: partner.isMarried,
                start: partner.startText,
                end: partner.endText,
                children: partner.children.map { PersonRefDTO($0.child, displayNames: displayNames) },
                childrenQueryEnabled: partner.isChildrenQueryEnabled
            )
        }
        ungroupedChildren = relations.ungroupedChildren.map {
            PersonRefDTO($0.child, displayNames: displayNames)
        }
        offices = relations.offices.map { office in
            PersonOfficeDTO(
                officeId: office.officeID,
                officeName: officeNames[office.officeID] ?? "",
                whenBegan: office.whenBegan,
                whenEnded: office.whenEnded,
                note: office.note,
                predecessors: office.predecessors.map { PersonRefDTO(.instance($0), displayNames: displayNames) },
                successors: office.successors.map { PersonRefDTO(.instance($0), displayNames: displayNames) },
                queryEnabled: office.isQueryEnabled
            )
        }
    }
}

private struct PersonOfficeDTO: Encodable {
    let officeId: Int64
    let officeName: String
    let whenBegan: String
    let whenEnded: String
    let note: String
    let predecessors: [PersonRefDTO]
    let successors: [PersonRefDTO]
    let queryEnabled: Bool
}

private struct OfficeSummaryDTO: Encodable {
    let id: Int64
    let name: String
    let description: String
    let holderCount: Int

    init(_ office: OfficeSummary) {
        id = office.id
        name = office.name
        description = office.description
        holderCount = office.holderCount
    }
}

private struct PersonBuiltinQueryDTO: Encodable {
    let kind: String
    let partnershipId: Int64?
    let officeId: Int64?
    let displayName: String
    let enabled: Bool
    let interval: Int64?
    let queryState: Int?
    let lastAnsweredTimestamp: Int64?

    init(_ info: PersonBuiltinQueryInfo) {
        kind = info.kind.rawValue
        partnershipId = info.partnershipID
        officeId = info.officeID
        displayName = info.displayName
        enabled = info.enabled
        interval = info.interval
        queryState = info.queryState?.rawValue
        lastAnsweredTimestamp = info.lastAnsweredTimestamp
    }
}

private struct UpdatePersonRelationsResultDTO: Encodable {
    let ok = true
    let instanceId: Int64
    let resetQueryCount: Int
    let relations: PersonRelationsDTO
}

private struct PersonConflictDTO: Encodable {
    let instanceId: Int64?
    let displayName: String
    let message: String
}

private struct PointMapPointDTO: Encodable {
    let id: Int64
    let name: String
    let hint: String
    let latitude: Double
    let longitude: Double
    let forwardEnabled: Bool
    let reverseEnabled: Bool
    let forwardInterval: Int64
    let reverseInterval: Int64

    init(_ point: PointMapPoint) {
        id = point.id
        name = point.name
        hint = point.hint
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
    let description: String
    let defaultCenterLat: Double
    let defaultCenterLng: Double
    let defaultZoom: Double
    let showAllPointsInQuestion: Bool
    let pointSize: String
    // Named `Ids` (not `IDs`) so snake-case encoding yields boundary_ids.
    let boundaryIds: [Int64]
    let points: [PointMapPointDTO]

    init(_ instance: PointMapInstanceWithPoints) {
        instanceID = instance.instance.instanceID
        title = instance.instance.title
        description = instance.instance.description
        defaultCenterLat = instance.instance.defaultCenterLat
        defaultCenterLng = instance.instance.defaultCenterLng
        defaultZoom = instance.instance.defaultZoom
        showAllPointsInQuestion = instance.instance.showAllPointsInQuestion
        pointSize = instance.instance.pointSize.rawValue
        boundaryIds = instance.boundaryIDs
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
    let description: String
    let defaultCenterLat: Double
    let defaultCenterLng: Double
    let defaultZoom: Double
    let showAllBoundariesInQuestion: Bool
    let attachments: [BoundaryAttachmentDTO]

    init(_ instance: BoundaryMapInstanceWithBoundaries) {
        instanceID = instance.instance.instanceID
        title = instance.instance.title
        description = instance.instance.description
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
    // Built-in Person queries only (query_type_id is 0 for them).
    let personKind: String?
    let partnershipId: Int64?
    let officeId: Int64?

    init(_ r: QuerySearchResult) {
        instanceID = r.instanceID
        queryTypeID = r.queryTypeID
        displayValue = r.displayValue
        queryTypeName = r.queryTypeName
        isReverse = r.isReverse
        personKind = r.personKind?.rawValue
        partnershipId = r.personPartnershipID
        officeId = r.personOfficeID
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
