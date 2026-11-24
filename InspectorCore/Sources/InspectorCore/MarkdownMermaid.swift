import Foundation
import MermaidLayout

/// Supported orientations for Mermaid flowcharts.
public enum MermaidFlowDirection: Equatable, Sendable {
    case topDown
    case bottomTop
    case leftRight
    case rightLeft
}

/// Geometric node forms accepted by the bounded flowchart parser.
public enum MermaidFlowchartNodeShape: Equatable, Sendable {
    case rectangle
    case rounded
    case diamond
}

/// Connector styles retained by the flowchart model and renderer.
public enum MermaidFlowchartEdgeStyle: Equatable, Sendable {
    case arrow
    case line
    case dottedArrow
    case thickArrow
}

/// A flowchart node with its parsed identity, visible label, and shape.
public struct MermaidFlowchartNode: Equatable, Sendable {
    public let id: String
    public let label: String
    public let shape: MermaidFlowchartNodeShape

    /// Creates a node using values already validated by the flowchart parser.
    public init(id: String, label: String, shape: MermaidFlowchartNodeShape) {
        self.id = id
        self.label = label
        self.shape = shape
    }
}

/// A directed flowchart connection, including optional label and visual style.
public struct MermaidFlowchartEdge: Equatable, Sendable {
    public let sourceID: String
    public let targetID: String
    public let label: String?
    public let style: MermaidFlowchartEdgeStyle

    /// Creates an edge between node identifiers from the parsed diagram.
    public init(sourceID: String, targetID: String, label: String?, style: MermaidFlowchartEdgeStyle) {
        self.sourceID = sourceID
        self.targetID = targetID
        self.label = label
        self.style = style
    }
}

/// Parsed flowchart content before layout coordinates are assigned.
public struct MermaidFlowchart: Equatable, Sendable {
    public let direction: MermaidFlowDirection
    public let nodes: [MermaidFlowchartNode]
    public let edges: [MermaidFlowchartEdge]

    /// Creates a flowchart model with its orientation, nodes, and connectors.
    public init(direction: MermaidFlowDirection, nodes: [MermaidFlowchartNode], edges: [MermaidFlowchartEdge]) {
        self.direction = direction
        self.nodes = nodes
        self.edges = edges
    }
}

/// A named actor or participant in a sequence diagram.
public struct MermaidSequenceParticipant: Equatable, Sendable {
    public let id: String
    public let label: String
    /// Creates a participant using the identifier and display label from the source.
    public init(id: String, label: String) { self.id = id; self.label = label }
}

/// Line styles supported for sequence diagram messages.
public enum MermaidSequenceMessageStyle: Equatable, Sendable { case solidArrow, dashedArrow }

/// A directed message between two sequence diagram participants.
public struct MermaidSequenceMessage: Equatable, Sendable {
    public let sourceID: String
    public let targetID: String
    public let text: String
    public let style: MermaidSequenceMessageStyle
    /// Creates a message with its parsed endpoints, text, and arrow style.
    public init(sourceID: String, targetID: String, text: String, style: MermaidSequenceMessageStyle) {
        self.sourceID = sourceID; self.targetID = targetID; self.text = text; self.style = style
    }
}

/// Parsed participants and messages before sequence layout is calculated.
public struct MermaidSequenceDiagram: Equatable, Sendable {
    public let participants: [MermaidSequenceParticipant]
    public let messages: [MermaidSequenceMessage]
    /// Creates a sequence model from its participants and ordered messages.
    public init(participants: [MermaidSequenceParticipant], messages: [MermaidSequenceMessage]) {
        self.participants = participants; self.messages = messages
    }
}

/// One displayed attribute or operation line inside a Mermaid class box.
public struct MermaidClassMember: Equatable, Sendable {
    public let text: String

    /// Creates a class member from its already parsed display text.
    public init(text: String) { self.text = text }
}

/// A class diagram node and its ordered member lines.
public struct MermaidClassNode: Equatable, Sendable {
    public let id: String; public let label: String; public let members: [MermaidClassMember]
    /// Creates a class node from its source identifier, display label, and members.
    public init(id: String, label: String, members: [MermaidClassMember]) { self.id = id; self.label = label; self.members = members }
}

/// A Mermaid class relationship token connecting two class identifiers.
public struct MermaidClassRelation: Equatable, Sendable {
    public let sourceID: String; public let targetID: String; public let token: String; public let label: String?
    /// Creates a relation while preserving its Mermaid token and optional label.
    public init(sourceID: String, targetID: String, token: String, label: String?) { self.sourceID = sourceID; self.targetID = targetID; self.token = token; self.label = label }
}

/// Parsed class nodes and relationships before layout coordinates are assigned.
public struct MermaidClassDiagram: Equatable, Sendable {
    public let classes: [MermaidClassNode]; public let relations: [MermaidClassRelation]
    /// Creates a class diagram from its classes and relationships.
    public init(classes: [MermaidClassNode], relations: [MermaidClassRelation]) { self.classes = classes; self.relations = relations }
}

/// Canvas size and class frames produced by the bounded class layout engine.
public struct MermaidClassDiagramLayout: Equatable, Sendable {
    public let size: (width: Double, height: Double); public let classFrames: [String: MermaidDiagramRect]
    /// Compares rendered dimensions and class frames, excluding derived drawing conveniences.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.size.width == rhs.size.width && lhs.size.height == rhs.size.height && lhs.classFrames == rhs.classFrames }
    /// Creates layout geometry for the diagram's canvas and class identifiers.
    public init(size: (width: Double, height: Double), classFrames: [String: MermaidDiagramRect]) { self.size = size; self.classFrames = classFrames }
}

/// Failure categories that cause Markdown to retain the original diagram code block.
public enum MermaidDiagramDiagnostic: Error, Equatable, Sendable {
    case malformedSyntax
    case unsupportedSyntax
    case resourceLimit
    case unsupportedLayout
}

/// A diagram-space rectangle used by flowchart, sequence, and class renderers.
public struct MermaidDiagramRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    /// Creates a rectangle in the diagram's layout coordinate system.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Canvas size and node frames calculated for a flowchart.
public struct MermaidFlowchartLayout: Equatable, Sendable {
    public let size: (width: Double, height: Double)
    public let nodeFrames: [String: MermaidDiagramRect]

    /// Compares the stable geometry and routes used to draw a flowchart.
    public static func == (lhs: MermaidFlowchartLayout, rhs: MermaidFlowchartLayout) -> Bool {
        lhs.size.width == rhs.size.width && lhs.size.height == rhs.size.height && lhs.nodeFrames == rhs.nodeFrames
    }

    /// Creates flowchart geometry indexed by node identifier.
    public init(size: (width: Double, height: Double), nodeFrames: [String: MermaidDiagramRect]) {
        self.size = size
        self.nodeFrames = nodeFrames
    }
}

/// Canvas dimensions and measured positions for a sequence diagram.
public struct MermaidSequenceDiagramLayout: Equatable, Sendable {
    public let size: (width: Double, height: Double)
    public let participantCenters: [String: Double]
    public let participantColumnWidth: Double
    public let participantHeaderHeights: [String: Double]
    public let messageYPositions: [Double]
    public let messageLabelWidths: [Double]
    public let messageLabelHeights: [Double]
    /// Compares the sequence canvas, participant positions, and message placements.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.size.width == rhs.size.width && lhs.size.height == rhs.size.height
            && lhs.participantCenters == rhs.participantCenters && lhs.participantHeaderHeights == rhs.participantHeaderHeights
            && lhs.participantColumnWidth == rhs.participantColumnWidth
            && lhs.messageYPositions == rhs.messageYPositions
            && lhs.messageLabelWidths == rhs.messageLabelWidths && lhs.messageLabelHeights == rhs.messageLabelHeights
    }
    /// Creates sequence geometry from participant and message measurements.
    public init(size: (width: Double, height: Double), participantCenters: [String: Double],
                participantColumnWidth: Double,
                participantHeaderHeights: [String: Double],
                messageYPositions: [Double], messageLabelWidths: [Double], messageLabelHeights: [Double]) {
        self.size = size; self.participantCenters = participantCenters
        self.participantColumnWidth = participantColumnWidth
        self.participantHeaderHeights = participantHeaderHeights; self.messageYPositions = messageYPositions
        self.messageLabelWidths = messageLabelWidths; self.messageLabelHeights = messageLabelHeights
    }
}

/// Bounded diagram models and layouts are optional so unsupported syntax retains code-block fallback.
public struct MarkdownMermaidBlock: Equatable, Sendable {
    public let range: NSRange
    /// Exact bounded text inside the Mermaid code fence, retained for Raw and unsupported-syntax fallback.
    public let source: String
    /// MermaidKit's typed diagram model, parsed during inspection and rendered by the shared native adapter.
    public let mermaidKitDiagram: MermaidDiagram?
    public let flowchart: MermaidFlowchart?
    public let layout: MermaidFlowchartLayout?
    public let diagnostic: MermaidDiagramDiagnostic?
    public let sequenceDiagram: MermaidSequenceDiagram?
    public let sequenceLayout: MermaidSequenceDiagramLayout?
    public let classDiagram: MermaidClassDiagram?
    public let classLayout: MermaidClassDiagramLayout?
    public let stateDiagram: MermaidFlowchart?

    /// Creates an optional parsed diagram result while retaining its source range.
    public init(range: NSRange, source: String = "", flowchart: MermaidFlowchart?, layout: MermaidFlowchartLayout?,
                diagnostic: MermaidDiagramDiagnostic?, sequenceDiagram: MermaidSequenceDiagram? = nil,
                sequenceLayout: MermaidSequenceDiagramLayout? = nil,
                classDiagram: MermaidClassDiagram? = nil, classLayout: MermaidClassDiagramLayout? = nil,
                stateDiagram: MermaidFlowchart? = nil,
                mermaidKitDiagram: MermaidDiagram? = nil) {
        self.range = range
        self.source = source
        self.mermaidKitDiagram = mermaidKitDiagram
            ?? (source.utf8.count <= 8 * 1_024 ? MermaidParser.parse(source) : nil)
        self.flowchart = flowchart
        self.layout = layout
        self.diagnostic = diagnostic
        self.sequenceDiagram = sequenceDiagram
        self.sequenceLayout = sequenceLayout
        self.classDiagram = classDiagram
        self.classLayout = classLayout
        self.stateDiagram = stateDiagram
    }
}

/// Parses the supported Mermaid sequence subset into bounded participant and message models.
enum MermaidSequenceParser {
    static let maximumParticipants = 32
    static let maximumMessages = 128
    static let maximumLabelScalars = 96

    /// Parses the supported participant and message subset while enforcing source and model limits.
    static func parse(_ source: String, checkpoint: () throws -> Void) throws -> Result<MermaidSequenceDiagram, MermaidDiagramDiagnostic> {
        guard source.utf8.count <= MermaidFlowchartParser.maximumSourceBytes else { return .failure(.resourceLimit) }
        let lines = source.split(whereSeparator: \.isNewline)
        guard lines.count <= MermaidFlowchartParser.maximumLines else { return .failure(.resourceLimit) }
        guard let header = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              header.trimmingCharacters(in: .whitespaces) == "sequenceDiagram" else { return .failure(.unsupportedSyntax) }

        var participants: [MermaidSequenceParticipant] = []
        var indexes: [String: Int] = [:]
        var explicit: Set<String> = []
        var messages: [MermaidSequenceMessage] = []

        /// Adds or upgrades a participant while rejecting conflicting explicit declarations.
        func add(_ id: String, _ label: String, explicit isExplicit: Bool) -> MermaidDiagramDiagnostic? {
            guard Self.isIdentifier(id), label.unicodeScalars.count <= maximumLabelScalars else { return .malformedSyntax }
            if let index = indexes[id] {
                if isExplicit, explicit.contains(id) { return participants[index].label == label ? nil : .malformedSyntax }
                if isExplicit { participants[index] = .init(id: id, label: label); explicit.insert(id) }
                return nil
            }
            guard participants.count < maximumParticipants else { return .resourceLimit }
            indexes[id] = participants.count
            participants.append(.init(id: id, label: label))
            if isExplicit { explicit.insert(id) }
            return nil
        }

        for line in lines.dropFirst() {
            try checkpoint()
            let statement = line.trimmingCharacters(in: .whitespaces)
            guard !statement.isEmpty, !statement.hasPrefix("%%") else { continue }
            let words = statement.split(whereSeparator: \.isWhitespace)
            if words.first == "actor" { return .failure(.unsupportedSyntax) }
            if words.first == "participant" {
                guard words.count >= 2 else { return .failure(.malformedSyntax) }
                let id = String(words[1])
                let label: String
                if words.count == 2 { label = id }
                else if words.count >= 4, words[2] == "as" {
                    label = words.dropFirst(3).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                } else { return .failure(.malformedSyntax) }
                guard !label.isEmpty else { return .failure(.malformedSyntax) }
                if let diagnostic = add(id, label, explicit: true) { return .failure(diagnostic) }
                continue
            }
            if ["alt", "else", "opt", "loop", "par", "and", "critical", "break", "end", "activate", "deactivate", "note", "rect", "autonumber"].contains(String(words.first ?? "")) {
                return .failure(.unsupportedSyntax)
            }
            guard let arrow = arrows.first(where: { statement.range(of: $0.token) != nil }),
                  let arrowRange = statement.range(of: arrow.token) else { return .failure(.malformedSyntax) }
            let sourceID = String(statement[..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let suffix = statement[arrowRange.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let colon = suffix.firstIndex(of: ":") else { return .failure(.malformedSyntax) }
            let targetID = String(suffix[..<colon]).trimmingCharacters(in: .whitespaces)
            let message = String(suffix[suffix.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard Self.isIdentifier(sourceID), Self.isIdentifier(targetID), sourceID != targetID,
                  !message.isEmpty, message.unicodeScalars.count <= maximumLabelScalars else { return .failure(.malformedSyntax) }
            guard messages.count < maximumMessages else { return .failure(.resourceLimit) }
            if let diagnostic = add(sourceID, sourceID, explicit: false) { return .failure(diagnostic) }
            if let diagnostic = add(targetID, targetID, explicit: false) { return .failure(diagnostic) }
            messages.append(.init(sourceID: sourceID, targetID: targetID, text: message, style: arrow.style))
        }
        guard participants.count >= 2, !messages.isEmpty else { return .failure(.malformedSyntax) }
        return .success(.init(participants: participants, messages: messages))
    }

    private static let arrows: [(token: String, style: MermaidSequenceMessageStyle)] = [
        ("-->>", .dashedArrow), ("->>", .solidArrow), ("-->", .dashedArrow), ("->", .solidArrow)
    ]

    /// Limits participant IDs to short ASCII identifiers accepted by the supported Mermaid subset.
    private static func isIdentifier(_ value: String) -> Bool {
        guard value.utf8.count <= 32, let first = value.utf8.first,
              (65...90).contains(first) || (97...122).contains(first) || first == 95 else { return false }
        return value.utf8.dropFirst().allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95
        }
    }
}

/// Parses the supported flowchart subset and applies source, line, node, and edge limits.
enum MermaidFlowchartParser {
    static let maximumSourceBytes = 8_192
    static let maximumLines = 256
    static let maximumNodes = 64
    static let maximumEdges = 128
    static let maximumIdentifierScalars = 32
    static let maximumLabelScalars = 96

    /// Parses supported flowchart statements; unsupported syntax returns a diagnostic for code fallback.
    static func parse(_ source: String, checkpoint: () throws -> Void) throws -> Result<MermaidFlowchart, MermaidDiagramDiagnostic> {
        guard source.utf8.count <= maximumSourceBytes else { return .failure(.resourceLimit) }
        let lines = source.split(whereSeparator: \.isNewline)
        guard lines.count <= maximumLines else { return .failure(.resourceLimit) }
        guard let headerLine = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return .failure(.malformedSyntax)
        }
        let header = headerLine.split(whereSeparator: \.isWhitespace)
        guard header.count == 2, header[1].count == 2 else { return .failure(.unsupportedSyntax) }
        guard header[0] == "flowchart" || header[0] == "graph" else { return .failure(.unsupportedSyntax) }
        let direction: MermaidFlowDirection
        switch header[1] {
        case "TD", "TB": direction = .topDown
        case "BT": direction = .bottomTop
        case "LR": direction = .leftRight
        case "RL": direction = .rightLeft
        default: return .failure(.unsupportedSyntax)
        }

        var nodes: [MermaidFlowchartNode] = []
        var nodeIndexes: [String: Int] = [:]
        var explicitNodes: Set<String> = []
        var edges: [MermaidFlowchartEdge] = []

        /// Adds or upgrades a node and rejects conflicting repeated explicit shapes or labels.
        func addNode(_ declaration: NodeDeclaration) -> MermaidDiagramDiagnostic? {
            if let index = nodeIndexes[declaration.id] {
                let existing = nodes[index]
                guard declaration.isExplicit else { return nil }
                if explicitNodes.contains(declaration.id) {
                    return existing.label == declaration.label && existing.shape == declaration.shape ? nil : .malformedSyntax
                }
                nodes[index] = declaration.node
                explicitNodes.insert(declaration.id)
                return nil
            }
            guard nodes.count < maximumNodes else { return .resourceLimit }
            nodeIndexes[declaration.id] = nodes.count
            nodes.append(declaration.node)
            if declaration.isExplicit { explicitNodes.insert(declaration.id) }
            return nil
        }

        for line in lines.dropFirst() {
            try checkpoint()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("%%") else { continue }
            if trimmed.hasPrefix("subgraph") || trimmed.hasPrefix("end") || trimmed.hasPrefix("class")
                || trimmed.hasPrefix("style ") || trimmed.hasPrefix("click ") || trimmed.hasPrefix("link ") {
                return .failure(.unsupportedSyntax)
            }
            var scanner = FlowchartLineScanner(trimmed)
            guard var current = scanner.node() else { return .failure(.malformedSyntax) }
            if let diagnostic = addNode(current) { return .failure(diagnostic) }
            scanner.skipSpaces()
            if scanner.isAtEnd { continue }

            while !scanner.isAtEnd {
                try checkpoint()
                guard let relation = scanner.relation(), let label = scanner.optionalEdgeLabel(),
                      let next = scanner.node() else { return .failure(.malformedSyntax) }
                if let diagnostic = addNode(next) { return .failure(diagnostic) }
                guard edges.count < maximumEdges else { return .failure(.resourceLimit) }
                edges.append(.init(sourceID: current.id, targetID: next.id, label: label, style: relation))
                current = next
                scanner.skipSpaces()
            }
        }
        guard !nodes.isEmpty else { return .failure(.malformedSyntax) }
        return .success(.init(direction: direction, nodes: nodes, edges: edges))
    }

    /// Carries a node's parsed values and whether its declaration supplied an explicit shape.
    private struct NodeDeclaration {
        let id: String
        let label: String
        let shape: MermaidFlowchartNodeShape
        let isExplicit: Bool
        var node: MermaidFlowchartNode { .init(id: id, label: label, shape: shape) }
    }

    /// Tokenizes one flowchart statement while enforcing the parser's bounded grammar.
    private struct FlowchartLineScanner {
        private let characters: [Character]
        private var index = 0
        var isAtEnd: Bool { index == characters.count }

        /// Starts scanning a single source line without normalizing its token boundaries.
        init(_ line: String) { characters = Array(line) }

        /// Advances over horizontal or Unicode whitespace before parsing the next token.
        mutating func skipSpaces() {
            while index < characters.count && characters[index].isWhitespace { index += 1 }
        }

        /// Parses one bounded ASCII node declaration, including the supported shape delimiters.
        mutating func node() -> NodeDeclaration? {
            skipSpaces()
            let start = index
            guard index < characters.count, isASCIIIdentifierStart(characters[index]) else { return nil }
            index += 1
            while index < characters.count, isASCIIIdentifierContinuation(characters[index]) { index += 1 }
            let id = String(characters[start..<index])
            guard id.unicodeScalars.count <= maximumIdentifierScalars else { return nil }
            skipSpaces()
            guard index < characters.count else {
                return .init(id: id, label: id, shape: .rectangle, isExplicit: false)
            }
            let opening = characters[index]
            let closing: Character
            let shape: MermaidFlowchartNodeShape
            switch opening {
            case "[": closing = "]"; shape = .rectangle
            case "(": closing = ")"; shape = .rounded
            case "{": closing = "}"; shape = .diamond
            default: return .init(id: id, label: id, shape: .rectangle, isExplicit: false)
            }
            index += 1
            let labelStart = index
            while index < characters.count && characters[index] != closing {
                if "[]{}()".contains(characters[index]) { return nil }
                index += 1
            }
            guard index < characters.count else { return nil }
            let label = String(characters[labelStart..<index]).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, label.unicodeScalars.count <= maximumLabelScalars else { return nil }
            index += 1
            return .init(id: id, label: label, shape: shape, isExplicit: true)
        }

        /// Consumes the longest supported relation token at the current scanner position.
        mutating func relation() -> MermaidFlowchartEdgeStyle? {
            skipSpaces()
            let candidates: [(String, MermaidFlowchartEdgeStyle)] = [
                ("-.->", .dottedArrow), ("==>", .thickArrow), ("-->", .arrow), ("---", .line)
            ]
            for (token, style) in candidates {
                let tokenCharacters = Array(token)
                guard index + tokenCharacters.count <= characters.count,
                      Array(characters[index..<(index + tokenCharacters.count)]) == tokenCharacters else { continue }
                index += tokenCharacters.count
                return style
            }
            return nil
        }

        /// Distinguishes no label from malformed or unterminated label syntax.
        mutating func optionalEdgeLabel() -> String?? {
            skipSpaces()
            guard index < characters.count, characters[index] == "|" else { return .some(nil) }
            index += 1
            let start = index
            while index < characters.count && characters[index] != "|" { index += 1 }
            guard index < characters.count else { return nil }
            let label = String(characters[start..<index]).trimmingCharacters(in: .whitespaces)
            guard label.unicodeScalars.count <= 64 else { return nil }
            index += 1
            return .some(label.isEmpty ? nil : label)
        }

        /// Restricts identifiers to ASCII letters at their first character.
        private func isASCIIIdentifierStart(_ character: Character) -> Bool {
            ("A"..."Z").contains(character) || ("a"..."z").contains(character)
        }

        /// Allows ASCII letters, digits, and underscore after the identifier's first character.
        private func isASCIIIdentifierContinuation(_ character: Character) -> Bool {
            isASCIIIdentifierStart(character) || ("0"..."9").contains(character) || character == "_"
        }
    }
}
