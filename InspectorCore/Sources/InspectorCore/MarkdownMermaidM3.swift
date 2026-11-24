import Foundation

/// Parses the supported class-diagram subset and validates identifiers and declarations.
enum MermaidClassParser {
    static let maxClasses = 32
    static let maxMembersPerClass = 24
    static let maxRelations = 64
    static let maxLabelScalars = 96

    /// Parses the bounded class/member/relation subset and rejects unsupported statements explicitly.
    static func parse(_ source: String, checkpoint: () throws -> Void) throws -> Result<MermaidClassDiagram, MermaidDiagramDiagnostic> {
        guard source.utf8.count <= MermaidFlowchartParser.maximumSourceBytes else { return .failure(.resourceLimit) }
        let lines = source.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard lines.count <= MermaidFlowchartParser.maximumLines,
              let header = lines.first(where: { !$0.isEmpty }), header == "classDiagram" else { return .failure(.unsupportedSyntax) }
        var classes: [String: [String]] = [:]
        var order: [String] = []
        var relations: [MermaidClassRelation] = []
        var current: String?
        /// Accepts a bounded ASCII class identifier for the supported class-diagram subset.
        func valid(_ id: String) -> Bool {
            guard let first = id.unicodeScalars.first, (65...90).contains(Int(first.value)) || (97...122).contains(Int(first.value)) else { return false }
            return id.unicodeScalars.count <= 32 && id.unicodeScalars.dropFirst().allSatisfy { scalar in
                (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value)) || (48...57).contains(Int(scalar.value)) || scalar == "_"
            }
        }
        /// Adds a class once, enforcing the model count before appending to the stable order.
        func add(_ id: String) -> Bool {
            guard valid(id) else { return false }
            if classes[id] == nil { guard classes.count < maxClasses else { return false }; classes[id] = []; order.append(id) }
            return true
        }
        let tokens = ["<|--", "--|>", "<|..", "..|>", "*--", "--*", "o--", "--o", "..>", "<..", "-->" , "<--", "--", ".."]
        for line in lines.dropFirst() {
            try checkpoint()
            guard !line.isEmpty, !line.hasPrefix("%%") else { continue }
            if line == "}" { guard current != nil else { return .failure(.malformedSyntax) }; current = nil; continue }
            if let name = current {
                guard !line.contains("{") && !line.contains("}") else { return .failure(.unsupportedSyntax) }
                guard line.unicodeScalars.count <= maxLabelScalars, !line.isEmpty,
                      let existing = classes[name], existing.count < maxMembersPerClass else { return .failure(.resourceLimit) }
                classes[name, default: []].append(line); continue
            }
            if line.hasPrefix("class ") {
                let tail = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                guard let brace = tail.firstIndex(of: "{") else {
                    if valid(tail), classes[tail] == nil, classes.count >= maxClasses { return .failure(.resourceLimit) }
                    guard add(tail) else { return .failure(.malformedSyntax) }; continue
                }
                let id = String(tail[..<brace]).trimmingCharacters(in: .whitespaces)
                if valid(id), classes[id] == nil, classes.count >= maxClasses { return .failure(.resourceLimit) }
                guard add(id), tail[tail.index(after: brace)...].trimmingCharacters(in: .whitespaces).isEmpty else { return .failure(.malformedSyntax) }
                current = id; continue
            }
            if line.hasPrefix("<<") || line.hasPrefix("direction ") || line.hasPrefix("namespace ") { return .failure(.unsupportedSyntax) }
            guard let token = tokens.first(where: { line.range(of: $0) != nil }), let range = line.range(of: token) else { return .failure(.malformedSyntax) }
            let left = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            var rightTail = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            var label: String?
            if let colon = rightTail.firstIndex(of: ":") {
                label = rightTail[rightTail.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                rightTail = rightTail[..<colon].trimmingCharacters(in: .whitespaces)
                guard let value = label, !value.isEmpty, value.unicodeScalars.count <= maxLabelScalars else { return .failure(.malformedSyntax) }
            }
            guard valid(left), valid(rightTail), left != rightTail else { return .failure(.malformedSyntax) }
            guard relations.count < maxRelations, (classes[left] != nil || classes.count < maxClasses),
                  (classes[rightTail] != nil || classes.count < maxClasses) else { return .failure(.resourceLimit) }
            guard add(left), add(rightTail) else { return .failure(.malformedSyntax) }
            relations.append(.init(sourceID: left, targetID: rightTail, token: token, label: label))
        }
        guard current == nil else { return .failure(.malformedSyntax) }
        guard !classes.isEmpty else { return .failure(.malformedSyntax) }
        return .success(.init(classes: order.map { .init(id: $0, label: $0, members: (classes[$0] ?? []).map(MermaidClassMember.init(text:))) }, relations: relations))
    }
}

/// Parses Mermaid state-diagram declarations within the supported bounded subset.
enum MermaidStateParser {
    static let maxStates = 48
    static let maxTransitions = 96
    /// Converts supported state transitions to the shared flowchart model for existing layout/rendering.
    static func parse(_ source: String, checkpoint: () throws -> Void) throws -> Result<MermaidFlowchart, MermaidDiagramDiagnostic> {
        guard source.utf8.count <= MermaidFlowchartParser.maximumSourceBytes else { return .failure(.resourceLimit) }
        let lines = source.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard lines.count <= MermaidFlowchartParser.maximumLines,
              let header = lines.first(where: { !$0.isEmpty }), ["stateDiagram", "stateDiagram-v2"].contains(header) else { return .failure(.unsupportedSyntax) }
        var nodes: [String: MermaidFlowchartNode] = [:]; var order: [String] = []; var edges: [MermaidFlowchartEdge] = []
        var starts = 0; var ends = 0
        /// Accepts bounded state IDs and the special initial/final marker.
        func valid(_ id: String) -> Bool {
            if id == "[*]" { return true }
            guard let first = id.unicodeScalars.first, (65...90).contains(Int(first.value)) || (97...122).contains(Int(first.value)) else { return false }
            return id.unicodeScalars.count <= 32 && id.unicodeScalars.dropFirst().allSatisfy { scalar in
                (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value)) || (48...57).contains(Int(scalar.value)) || scalar == "_" || scalar == "."
            }
        }
        /// Adds each ordinary state once; the special marker is represented by synthetic endpoints later.
        func add(_ id: String) -> Bool {
            guard valid(id) else { return false }
            if id == "[*]" { return true }
            if nodes[id] == nil { guard nodes.count < maxStates else { return false }; nodes[id] = .init(id: id, label: id, shape: .rounded); order.append(id) }
            return true
        }
        for line in lines.dropFirst() {
            try checkpoint(); guard !line.isEmpty, !line.hasPrefix("%%") else { continue }
            if line.hasPrefix("state ") || line.contains("{") || line == "}" || line.hasPrefix("direction ") { return .failure(.unsupportedSyntax) }
            guard let arrow = line.range(of: "-->" ) else { return .failure(.malformedSyntax) }
            let source = String(line[..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
            var tail = String(line[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
            var label: String?
            if let colon = tail.firstIndex(of: ":") { label = tail[tail.index(after: colon)...].trimmingCharacters(in: .whitespaces); tail = tail[..<colon].trimmingCharacters(in: .whitespaces) }
            guard valid(source), valid(tail), source != tail, label?.unicodeScalars.count ?? 0 <= 96,
                  (label == nil || !(label ?? "").isEmpty), edges.count < maxTransitions,
                  (source == "[*]" || nodes[source] != nil || nodes.count < maxStates),
                  (tail == "[*]" || nodes[tail] != nil || nodes.count < maxStates),
                  add(source), add(tail) else { return .failure(edges.count >= maxTransitions || nodes.count >= maxStates ? .resourceLimit : .malformedSyntax) }
            if source == "[*]" { starts += 1 }; if tail == "[*]" { ends += 1 }
            guard starts <= 1, ends <= 1 else { return .failure(.unsupportedSyntax) }
            let from = source == "[*]" ? "__start" : source; let to = tail == "[*]" ? "__end" : tail
            if source == "[*]" { nodes[from] = .init(id: from, label: "", shape: .rounded); if !order.contains(from) { order.insert(from, at: 0) } }
            if tail == "[*]" { nodes[to] = .init(id: to, label: "", shape: .rounded); if !order.contains(to) { order.append(to) } }
            edges.append(.init(sourceID: from, targetID: to, label: label, style: .arrow))
        }
        guard !edges.isEmpty, nodes.count <= maxStates + 2 else { return .failure(.malformedSyntax) }
        return .success(.init(direction: .topDown, nodes: order.compactMap { nodes[$0] }, edges: edges))
    }
}

/// Computes bounded class-card frames and relation spacing for Mermaid class diagrams.
public enum MermaidClassLayoutEngine {
    /// Places class boxes and relation endpoints within a bounded canvas, checking cancellation during layout.
    public static func layout(_ diagram: MermaidClassDiagram, maximumWidth: Double = 640, checkpoint: () throws -> Void) throws -> Result<MermaidClassDiagramLayout, MermaidDiagramDiagnostic> {
        guard !diagram.classes.isEmpty, diagram.classes.count <= MermaidClassParser.maxClasses,
              diagram.relations.count <= MermaidClassParser.maxRelations, maximumWidth.isFinite, maximumWidth >= 180 else { return .failure(.resourceLimit) }
        let cardWidth = min(640, maximumWidth) - 104
        let relationCapacity = max(4, Int(72 / 7))
        let longestRelationLabel = diagram.relations.compactMap(\.label).map(displayColumns).max() ?? 0
        let relationGap = max(72.0, Double((longestRelationLabel + relationCapacity - 1) / relationCapacity * 16 + 16))
        var frames: [String: MermaidDiagramRect] = [:]
        var y = 16.0
        for item in diagram.classes {
            try checkpoint()
            let memberCapacity = max(4, Int((cardWidth - 16) / 6))
            let memberHeight = item.members.reduce(0.0) { partial, member in
                let lines = max(1, (displayColumns(member.text) + memberCapacity - 1) / memberCapacity)
                return partial + Double(lines * 16 + 4)
            }
            let height = min(42 + memberHeight, 522)
            frames[item.id] = .init(x: 88, y: y, width: cardWidth, height: height)
            y += height + relationGap
        }
        let height = y - relationGap + 16
        guard height <= 1200 else { return .failure(.resourceLimit) }
        return .success(.init(size: (maximumWidth, height), classFrames: frames))
    }

    /// Estimates card width in display columns for member and relation labels.
    private static func displayColumns(_ text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            let category = scalar.properties.generalCategory
            if category == .nonspacingMark || category == .enclosingMark || category == .spacingMark { return }
            count += scalar.value >= 0x2E80 ? 2 : 1
        }
    }
}
