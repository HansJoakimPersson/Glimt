import Foundation

/// Projects bounded GeoJSON values into feature and coordinate summaries for the shared Tree view.
/// The original JSON model remains available; no links, maps, or network resources are resolved.
enum GeoJSONInspector {
    private static let maximumFeatures = 2_000
    private static let maximumCoordinates = 10_000
    private static let maximumNodes = 10_000
    private static let geometryTypes: Set<String> = ["Point", "MultiPoint", "LineString", "MultiLineString", "Polygon", "MultiPolygon", "GeometryCollection"]

    private struct Coordinate {
        let longitude: Double
        let latitude: Double
    }

    private struct Budget {
        var nodes = 0
        var coordinates: [Coordinate] = []
        var stopped: Bool { nodes >= maximumNodes }
    }

    static func summarize(_ value: StructuredValue) throws -> StructuredValue? {
        guard case .object(let members) = value, let type = string("type", in: members) else { return nil }
        var budget = Budget()
        switch type {
        case "FeatureCollection":
            guard case .array(let features)? = member("features", in: members) else { return nil }
            var summaries: [StructuredValue] = []
            summaries.reserveCapacity(min(features.count, maximumFeatures))
            for (index, feature) in features.enumerated() {
                try Task.checkCancellation()
                guard let summary = try summarizeFeature(feature, budget: &budget) else { return nil }
                if index < maximumFeatures { summaries.append(summary) }
                if budget.stopped { return nil }
            }
            return .object([
                .init(key: "Type", value: .string(type)),
                .init(key: "Feature count", value: .number(String(features.count))),
                .init(key: "Features omitted", value: .number(String(max(features.count - summaries.count, 0)))),
                .init(key: "Features", value: .array(summaries))
            ])
        case "Feature":
            guard let feature = try summarizeFeature(value, budget: &budget) else { return nil }
            return .object([.init(key: "Type", value: .string(type)), .init(key: "Features", value: .array([feature]))])
        default:
            guard geometryTypes.contains(type), let summary = try summarizeGeometry(members, budget: &budget) else { return nil }
            return .object([.init(key: "Type", value: .string(type)), .init(key: "Geometry", value: summary)])
        }
    }

    private static func summarizeFeature(_ value: StructuredValue, budget: inout Budget) throws -> StructuredValue? {
        budget.nodes += 1
        guard !budget.stopped else { return nil }
        guard case .object(let members) = value, string("type", in: members) == "Feature",
              let geometryValue = member("geometry", in: members) else { return nil }
        let geometry: StructuredValue
        if case .null = geometryValue {
            geometry = .object([
                .init(key: "Type", value: .string("null")),
                .init(key: "Coordinate count", value: .number("0"))
            ])
        } else {
            guard case .object(let geometryMembers) = geometryValue,
                  let summary = try summarizeGeometry(geometryMembers, budget: &budget) else { return nil }
            geometry = summary
        }
        var result = [
            StructuredMember(key: "Name", value: .string(featureName(members) ?? "")),
            StructuredMember(key: "Geometry", value: geometry)
        ]
        if case .string(let id)? = member("id", in: members) {
            result.append(.init(key: "ID", value: .string(String(id.prefix(256)))))
        }
        return .object(result)
    }

    private static func summarizeGeometry(_ members: [StructuredMember], budget: inout Budget) throws -> StructuredValue? {
        guard let type = string("type", in: members), geometryTypes.contains(type) else { return nil }
        if type == "GeometryCollection" {
            guard case .array(let geometries)? = member("geometries", in: members) else { return nil }
            var summaries: [StructuredValue] = []
            summaries.reserveCapacity(min(geometries.count, maximumFeatures))
            for (index, geometry) in geometries.enumerated() {
                try Task.checkCancellation()
                guard case .object(let geometryMembers) = geometry,
                      let summary = try summarizeGeometry(geometryMembers, budget: &budget) else { return nil }
                if index < maximumFeatures { summaries.append(summary) }
                if budget.stopped { return nil }
            }
            return .object([
                .init(key: "Type", value: .string(type)),
                .init(key: "Geometries omitted", value: .number(String(max(geometries.count - summaries.count, 0)))),
                .init(key: "Geometries", value: .array(summaries))
            ])
        }
        let coordinateStart = budget.coordinates.count
        guard let coordinateValue = member("coordinates", in: members),
              collectPositions(coordinateValue, budget: &budget), !budget.stopped else { return nil }
        let positions = Array(budget.coordinates.dropFirst(coordinateStart))
        var result = [
            StructuredMember(key: "Type", value: .string(type)),
            StructuredMember(key: "Coordinate count", value: .number(String(positions.count)))
        ]
        if let bounds = boundsValue(positions) { result.append(.init(key: "Bounds", value: bounds)) }
        return .object(result)
    }

    private static func collectPositions(_ value: StructuredValue, budget: inout Budget) -> Bool {
        guard !budget.stopped, budget.coordinates.count < maximumCoordinates else { return false }
        budget.nodes += 1
        guard case .array(let values) = value else { return false }
        guard let first = values.first else { return true }
        if case .number = first {
            guard values.count >= 2 else { return false }
            let numbers = values.compactMap { item -> Double? in
                guard case .number(let text) = item, let number = Double(text), number.isFinite else { return nil }
                return number
            }
            guard numbers.count == values.count else { return false }
            let longitude = numbers[0], latitude = numbers[1]
            guard (-180...180).contains(longitude), (-90...90).contains(latitude),
                  budget.coordinates.count < maximumCoordinates else { return false }
            budget.coordinates.append(.init(longitude: longitude, latitude: latitude))
            return true
        }
        for child in values where !collectPositions(child, budget: &budget) { return false }
        return true
    }

    private static func boundsValue(_ coordinates: [Coordinate]) -> StructuredValue? {
        guard !coordinates.isEmpty else { return nil }
        let latitudes = coordinates.map(\.latitude), longitudes = coordinates.map(\.longitude)
        return .object([
            .init(key: "South", value: .number(String(latitudes.min() ?? 0))),
            .init(key: "West", value: .number(String(longitudes.min() ?? 0))),
            .init(key: "North", value: .number(String(latitudes.max() ?? 0))),
            .init(key: "East", value: .number(String(longitudes.max() ?? 0)))
        ])
    }

    private static func featureName(_ members: [StructuredMember]) -> String? {
        guard case .object(let properties)? = member("properties", in: members) else { return nil }
        for key in ["name", "title"] {
            if case .string(let value)? = member(key, in: properties), !value.isEmpty { return String(value.prefix(512)) }
        }
        return nil
    }

    private static func string(_ key: String, in members: [StructuredMember]) -> String? {
        guard case .string(let value)? = member(key, in: members) else { return nil }
        return value
    }

    private static func member(_ key: String, in members: [StructuredMember]) -> StructuredValue? {
        members.first(where: { $0.key == key })?.value
    }
}
