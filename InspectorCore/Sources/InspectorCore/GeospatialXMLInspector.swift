import Foundation

/// Projects safe KML and GPX XML trees into bounded geospatial summaries for the shared Tree view.
/// Coordinates are reported as source data; no map, URL, style, or network resource is resolved.
enum GeospatialXMLInspector {
    private static let maximumNodes = 10_000
    private static let maximumFeatures = 2_000
    private static let maximumCoordinates = 10_000

    static func summarize(root: XMLNode, formatID: FormatID) -> StructuredValue? {
        guard case .element(let element) = root,
              localName(element.name) == (formatID == .kml ? "kml" : "gpx") else { return nil }
        var budget = TraversalBudget()
        if formatID == .kml {
            let placemarks = descendants(of: element, named: "placemark", budget: &budget)
            var features: [StructuredValue] = []
            for placemark in placemarks.prefix(maximumFeatures) where !budget.stopped {
                guard let feature = kmlFeature(placemark, budget: &budget) else { return nil }
                features.append(feature)
            }
            guard !budget.stopped else { return nil }
            let document = firstChild(named: "Document", in: element) ?? element
            return .object([
                .init(key: "Document", value: .string(text(named: "name", in: document) ?? "")),
                .init(key: "Placemark count", value: .number(String(placemarks.count))),
                .init(key: "Feature list truncated", value: .boolean(placemarks.count > features.count)),
                .init(key: "Features", value: .array(features))
            ])
        }

        let metadata = firstChild(named: "metadata", in: element)
        let waypoints = directChildren(named: "wpt", in: element)
        let routes = directChildren(named: "rte", in: element)
        let tracks = directChildren(named: "trk", in: element)
        guard validGPXCoordinates(in: element, budget: &budget) else { return nil }
        return .object([
            .init(key: "Name", value: .string(text(named: "name", in: metadata ?? element) ?? "")),
            .init(key: "Creator", value: .string(attribute("creator", in: element) ?? "")),
            .init(key: "Waypoints", value: .array(waypoints.prefix(maximumFeatures).map(gpxWaypoint))),
            .init(key: "Waypoints omitted", value: .number(String(max(waypoints.count - maximumFeatures, 0)))),
            .init(key: "Routes", value: .array(routes.prefix(maximumFeatures).map(gpxRoute))),
            .init(key: "Routes omitted", value: .number(String(max(routes.count - maximumFeatures, 0)))),
            .init(key: "Tracks", value: .array(tracks.prefix(maximumFeatures).map(gpxTrack))),
            .init(key: "Tracks omitted", value: .number(String(max(tracks.count - maximumFeatures, 0))))
        ])
    }

    // MARK: - KML

    private static func kmlFeature(_ placemark: XMLElement, budget: inout TraversalBudget) -> StructuredValue? {
        let geometries = descendants(of: placemark, named: nil, budget: &budget)
            .map { localName($0.name) }
            .filter { ["point", "linestring", "polygon", "multigeometry", "track", "multitrack"].contains($0) }
        let coordinateNodes = descendants(of: placemark, named: "coordinates", budget: &budget)
        guard validKMLCoordinates(in: coordinateNodes) else { return nil }
        let bounds = coordinateBounds(in: coordinateNodes)
        var uniqueGeometries: [String] = []
        for geometry in geometries where !uniqueGeometries.contains(geometry) { uniqueGeometries.append(geometry) }
        var members: [StructuredMember] = [
            .init(key: "Name", value: .string(text(named: "name", in: placemark) ?? "")),
            .init(key: "Geometry", value: .array(uniqueGeometries.map(StructuredValue.string))),
            .init(key: "Coordinate count", value: .number(String(bounds.count)))
        ]
        if let bounds = bounds.value { members.append(.init(key: "Bounds", value: bounds)) }
        return .object(members)
    }

    // MARK: - GPX

    private static func gpxWaypoint(_ waypoint: XMLElement) -> StructuredValue {
        var members = [
            StructuredMember(key: "Name", value: .string(text(named: "name", in: waypoint) ?? "")),
            StructuredMember(key: "Latitude", value: attributeNumber("lat", in: waypoint)),
            StructuredMember(key: "Longitude", value: attributeNumber("lon", in: waypoint))
        ]
        appendOptional("Elevation", text(named: "ele", in: waypoint), to: &members)
        appendOptional("Time", text(named: "time", in: waypoint), to: &members)
        return .object(members)
    }

    private static func gpxRoute(_ route: XMLElement) -> StructuredValue {
        let points = directChildren(named: "rtept", in: route)
        return routeSummary(route, points: points)
    }

    private static func gpxTrack(_ track: XMLElement) -> StructuredValue {
        let segments = directChildren(named: "trkseg", in: track)
        let points = segments.flatMap { directChildren(named: "trkpt", in: $0) }
            .prefix(maximumCoordinates)
        return routeSummary(track, points: Array(points), segmentCount: segments.count)
    }

    private static func routeSummary(_ route: XMLElement, points: [XMLElement], segmentCount: Int = 0) -> StructuredValue {
        let coordinates = points.compactMap { point -> Coordinate? in
            guard let latitude = numberAttribute("lat", in: point),
                  let longitude = numberAttribute("lon", in: point),
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
            return .init(latitude: latitude, longitude: longitude)
        }
        var members = [
            StructuredMember(key: "Name", value: .string(text(named: "name", in: route) ?? "")),
            StructuredMember(key: "Point count", value: .number(String(points.count))),
            StructuredMember(key: "Bounds", value: boundsValue(coordinates) ?? .null)
        ]
        if segmentCount > 0 { members.append(.init(key: "Segment count", value: .number(String(segmentCount)))) }
        return .object(members)
    }

    // MARK: - Bounded XML traversal

    private struct TraversalBudget {
        var visited = 0
        var stopped: Bool { visited >= maximumNodes || Task.isCancelled }
    }

    private static func descendants(of root: XMLElement, named target: String?, budget: inout TraversalBudget) -> [XMLElement] {
        var result: [XMLElement] = []
        var pending = [root]
        while let current = pending.popLast(), !budget.stopped {
            budget.visited += 1
            if target == nil || localName(current.name) == target { result.append(current) }
            let children = current.children.compactMap { node -> XMLElement? in
                guard case .element(let element) = node else { return nil }
                return element
            }
            pending.append(contentsOf: children.reversed())
        }
        return result
    }

    private static func directChildren(named name: String, in element: XMLElement) -> [XMLElement] {
        element.children.compactMap { node -> XMLElement? in
            guard case .element(let child) = node, localName(child.name) == name else { return nil }
            return child
        }
    }

    private static func firstChild(named name: String, in element: XMLElement) -> XMLElement? {
        directChildren(named: name, in: element).first
    }

    private static func text(named name: String, in element: XMLElement) -> String? {
        guard let child = firstChild(named: name, in: element) else { return nil }
        let value = child.children.compactMap { node -> String? in
            guard case .text(let text) = node else { return nil }
            return text
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value.prefix(512))
    }

    private static func attribute(_ name: String, in element: XMLElement) -> String? {
        element.attributes.first(where: { localName($0.name) == name })?.value
    }

    private static func attributeNumber(_ name: String, in element: XMLElement) -> StructuredValue {
        guard let value = attribute(name, in: element), let number = Double(value), number.isFinite else { return .null }
        return .number(value)
    }

    private static func numberAttribute(_ name: String, in element: XMLElement) -> Double? {
        guard let value = attribute(name, in: element), let number = Double(value), number.isFinite else { return nil }
        return number
    }

    private static func coordinateBounds(in nodes: [XMLElement]) -> (count: Int, value: StructuredValue?) {
        var points: [Coordinate] = []
        for node in nodes {
            let text = node.children.compactMap { child -> String? in
                guard case .text(let value) = child else { return nil }
                return value
            }.joined()
            let remaining = maximumCoordinates - points.count
            for tuple in text.split(maxSplits: remaining, whereSeparator: { $0.isWhitespace }).prefix(remaining) {
                if Task.isCancelled { break }
                let values = tuple.split(separator: ",", omittingEmptySubsequences: false)
                guard values.count >= 2, let longitude = Double(values[0]), let latitude = Double(values[1]),
                      longitude.isFinite, latitude.isFinite,
                      (-180...180).contains(longitude), (-90...90).contains(latitude) else { continue }
                points.append(.init(latitude: latitude, longitude: longitude))
            }
            if points.count >= maximumCoordinates { break }
        }
        return (points.count, boundsValue(points))
    }

    private static func validGPXCoordinates(in root: XMLElement, budget: inout TraversalBudget) -> Bool {
        let points = descendants(of: root, named: nil, budget: &budget).filter {
            ["wpt", "rtept", "trkpt"].contains(localName($0.name))
        }
        guard !budget.stopped else { return false }
        return points.allSatisfy { point in
            guard let latitude = numberAttribute("lat", in: point),
                  let longitude = numberAttribute("lon", in: point) else { return false }
            return (-90...90).contains(latitude) && (-180...180).contains(longitude)
        }
    }

    private static func validKMLCoordinates(in nodes: [XMLElement]) -> Bool {
        for node in nodes {
            let text = node.children.compactMap { child -> String? in
                guard case .text(let value) = child else { return nil }
                return value
            }.joined()
            let remaining = maximumCoordinates
            for tuple in text.split(maxSplits: remaining, whereSeparator: { $0.isWhitespace }).prefix(remaining) {
                if Task.isCancelled { return false }
                let values = tuple.split(separator: ",", omittingEmptySubsequences: false)
                guard values.count >= 2, let longitude = Double(values[0]), let latitude = Double(values[1]),
                      longitude.isFinite, latitude.isFinite,
                      (-180...180).contains(longitude), (-90...90).contains(latitude) else { return false }
            }
        }
        return true
    }

    private struct Coordinate {
        let latitude: Double
        let longitude: Double
    }

    private static func boundsValue(_ coordinates: [Coordinate]) -> StructuredValue? {
        guard let first = coordinates.first else { return nil }
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        return .object([
            .init(key: "South", value: .number(String(latitudes.min() ?? first.latitude))),
            .init(key: "West", value: .number(String(longitudes.min() ?? first.longitude))),
            .init(key: "North", value: .number(String(latitudes.max() ?? first.latitude))),
            .init(key: "East", value: .number(String(longitudes.max() ?? first.longitude)))
        ])
    }

    private static func appendOptional(_ key: String, _ value: String?, to members: inout [StructuredMember]) {
        if let value { members.append(.init(key: key, value: .string(value))) }
    }

    private static func localName(_ name: String) -> String {
        String(name.split(separator: ":").last ?? Substring(name)).lowercased()
    }
}
