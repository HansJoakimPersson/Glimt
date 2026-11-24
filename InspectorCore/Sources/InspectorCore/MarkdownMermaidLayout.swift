import Foundation

/// Computes deterministic bounded node positions for the supported flowchart model.
public enum MermaidFlowchartLayoutEngine {
    public static let maximumWidth = 640.0
    public static let maximumHeight = 1_200.0
    private static let margin = 16.0
    private static let nodeGap = 24.0
    private static let rankGap = 40.0

    /// Computes deterministic node and edge layout within the caller's requested width cap.
    public static func layout(_ flowchart: MermaidFlowchart, maximumWidth requestedWidth: Double = maximumWidth,
                              checkpoint: () throws -> Void) throws -> Result<MermaidFlowchartLayout, MermaidDiagramDiagnostic> {
        guard !flowchart.nodes.isEmpty, flowchart.nodes.count <= MermaidFlowchartParser.maximumNodes,
              flowchart.edges.count <= MermaidFlowchartParser.maximumEdges else { return .failure(.resourceLimit) }
        let availableWidth = min(maximumWidth, requestedWidth)
        let contentWidth = availableWidth - margin * 2
        guard availableWidth.isFinite, contentWidth >= 80 else { return .failure(.resourceLimit) }

        let nodeIDs = flowchart.nodes.map(\.id)
        let indexes = Dictionary(uniqueKeysWithValues: nodeIDs.enumerated().map { ($0.element, $0.offset) })
        var outgoing = Array(repeating: [Int](), count: flowchart.nodes.count)
        var indegree = Array(repeating: 0, count: flowchart.nodes.count)
        for edge in flowchart.edges {
            try checkpoint()
            guard let source = indexes[edge.sourceID], let target = indexes[edge.targetID] else {
                return .failure(.malformedSyntax)
            }
            outgoing[source].append(target)
            indegree[target] += 1
        }

        var queue = indegree.indices.filter { indegree[$0] == 0 }
        var ranks = Array(repeating: 0, count: flowchart.nodes.count)
        var cursor = 0
        while cursor < queue.count {
            try checkpoint()
            let source = queue[cursor]
            cursor += 1
            for target in outgoing[source] {
                ranks[target] = max(ranks[target], ranks[source] + 1)
                indegree[target] -= 1
                if indegree[target] == 0 { queue.append(target) }
            }
        }
        guard queue.count == flowchart.nodes.count else { return .failure(.unsupportedLayout) }
        for edge in flowchart.edges {
            guard let source = indexes[edge.sourceID], let target = indexes[edge.targetID],
                  ranks[target] == ranks[source] + 1 else { return .failure(.unsupportedLayout) }
        }

        let layerCount = (ranks.max() ?? 0) + 1
        var layers = Array(repeating: [Int](), count: layerCount)
        for index in ranks.indices { layers[ranks[index]].append(index) }
        let sizes = flowchart.nodes.map { node in
            node.id == "__start" || node.id == "__end" ? (width: 20.0, height: 20.0) : nodeSize(for: node.label, maximumWidth: contentWidth)
        }
        var frames = Array(repeating: MermaidDiagramRect(x: 0, y: 0, width: 0, height: 0), count: flowchart.nodes.count)

        let isVertical = flowchart.direction == .topDown || flowchart.direction == .bottomTop
        let width: Double
        let height: Double
        if isVertical {
            var rowsByLayer: [[[Int]]] = []
            for layer in layers {
                var rows: [[Int]] = []
                var row: [Int] = []
                var rowWidth = 0.0
                for nodeIndex in layer {
                    try checkpoint()
                    let nextWidth = rowWidth + (row.isEmpty ? 0 : nodeGap) + sizes[nodeIndex].width
                    if !row.isEmpty && nextWidth > contentWidth {
                        rows.append(row)
                        row = []
                        rowWidth = 0
                    }
                    rowWidth += (row.isEmpty ? 0 : nodeGap) + sizes[nodeIndex].width
                    row.append(nodeIndex)
                }
                if !row.isEmpty { rows.append(row) }
                rowsByLayer.append(rows)
            }
            let layerHeights = rowsByLayer.map { rows in
                rows.reduce(0.0) { total, row in
                    total + (row.map { sizes[$0].height }.max() ?? 0)
                } + Double(max(0, rows.count - 1)) * nodeGap
            }
            var maxRowWidth = 0.0
            for rows in rowsByLayer {
                for row in rows {
                    var rowWidth = 0.0
                    for nodeIndex in row {
                        rowWidth += sizes[nodeIndex].width
                    }
                    rowWidth += Double(max(0, row.count - 1)) * nodeGap
                    maxRowWidth = max(maxRowWidth, rowWidth)
                }
            }
            width = maxRowWidth + margin * 2
            height = layerHeights.reduce(0, +) + Double(max(0, layers.count - 1)) * rankGap + margin * 2
            var layerY = margin
            for (rank, rows) in rowsByLayer.enumerated() {
                for row in rows {
                    let rowHeight = row.map { sizes[$0].height }.max() ?? 0
                    let rowWidth = row.reduce(0.0) { $0 + sizes[$1].width } + Double(max(0, row.count - 1)) * nodeGap
                    var x = margin + max(0, (maxRowWidth - rowWidth) / 2)
                    for nodeIndex in row {
                        let size = sizes[nodeIndex]
                        frames[nodeIndex] = .init(x: x, y: layerY + (rowHeight - size.height) / 2,
                                                  width: size.width, height: size.height)
                        x += size.width + nodeGap
                    }
                    layerY += rowHeight + nodeGap
                }
                if rank + 1 < rowsByLayer.count { layerY += rankGap - nodeGap }
            }
        } else {
            let primaryLayerSizes = layers.map { layer in layer.map { sizes[$0].width }.max() ?? 0 }
            let totalLayerHeight = layers.map { layer in
                layer.reduce(0.0) { $0 + sizes[$1].height } + Double(max(0, layer.count - 1)) * nodeGap
            }
            // Keep long LR/RL chains inside the preview width by starting a new horizontal band
            // before the next rank would exceed the available content width.
            var bands: [[Int]] = []
            var band: [Int] = []
            var bandWidth = 0.0
            for rank in layers.indices {
                try checkpoint()
                let nextWidth = bandWidth + (band.isEmpty ? 0 : rankGap) + primaryLayerSizes[rank]
                if !band.isEmpty && nextWidth > contentWidth {
                    bands.append(band)
                    band = []
                    bandWidth = 0
                }
                bandWidth += (band.isEmpty ? 0 : rankGap) + primaryLayerSizes[rank]
                band.append(rank)
            }
            if !band.isEmpty { bands.append(band) }

            let bandWidths = bands.map { ranks in
                ranks.reduce(0.0) { $0 + primaryLayerSizes[$1] }
                    + Double(max(0, ranks.count - 1)) * rankGap
            }
            let bandHeights = bands.map { ranks in
                ranks.map { totalLayerHeight[$0] }.max() ?? 0
            }
            width = (bandWidths.max() ?? 0) + margin * 2
            height = bandHeights.reduce(0, +) + Double(max(0, bands.count - 1)) * nodeGap + margin * 2

            var bandY = margin
            for (bandIndex, ranksInBand) in bands.enumerated() {
                var x = margin
                let bandHeight = bandHeights[bandIndex]
                for rank in ranksInBand {
                    let layer = layers[rank]
                    let layerWidth = primaryLayerSizes[rank]
                    let layerHeight = totalLayerHeight[rank]
                    var y = bandY + max(0, (bandHeight - layerHeight) / 2)
                    for nodeIndex in layer {
                        let size = sizes[nodeIndex]
                        frames[nodeIndex] = .init(x: x + (layerWidth - size.width) / 2, y: y,
                                                  width: size.width, height: size.height)
                        y += size.height + nodeGap
                    }
                    x += layerWidth + rankGap
                }
                bandY += bandHeight + nodeGap
            }
        }
        guard width.isFinite, height.isFinite, width <= availableWidth, height <= maximumHeight,
              width > 0, height > 0 else { return .failure(.resourceLimit) }

        switch flowchart.direction {
        case .topDown, .leftRight: break
        case .bottomTop:
            frames = frames.map { .init(x: $0.x, y: height - $0.y - $0.height, width: $0.width, height: $0.height) }
        case .rightLeft:
            frames = frames.map { .init(x: width - $0.x - $0.width, y: $0.y, width: $0.width, height: $0.height) }
        }
        let nodeFrames = Dictionary(uniqueKeysWithValues: nodeIDs.enumerated().map { ($0.element, frames[$0.offset]) })
        return .success(.init(size: (width, height), nodeFrames: nodeFrames))
    }

    /// Measures and clamps one label to bounded display columns and lines before layout allocation.
    private static func nodeSize(for label: String, maximumWidth: Double) -> (width: Double, height: Double) {
        let columns = label.unicodeScalars.reduce(into: 0) { count, scalar in
            let category = scalar.properties.generalCategory
            if category == .nonspacingMark || category == .enclosingMark || category == .spacingMark { return }
            count += scalar.value >= 0x2E80 ? 2 : 1
        }
        let lineCapacity = max(8, min(28, Int((maximumWidth - 16) / 8)))
        let lines = max(1, (columns + lineCapacity - 1) / lineCapacity)
        let width = Double(min(lineCapacity, max(8, columns)) * 8 + 16)
        let height = Double(lines * 18 + 16)
        return (width, height)
    }
}

/// Computes participant columns and message positions for bounded sequence diagrams.
public enum MermaidSequenceLayoutEngine {
    public static let maximumWidth = MermaidFlowchartLayoutEngine.maximumWidth
    public static let maximumHeight = MermaidFlowchartLayoutEngine.maximumHeight
    private static let margin = 16.0

    /// Computes participant columns and message rows with bounded label dimensions.
    public static func layout(_ diagram: MermaidSequenceDiagram, maximumWidth requestedWidth: Double = maximumWidth,
                              checkpoint: () throws -> Void) throws -> Result<MermaidSequenceDiagramLayout, MermaidDiagramDiagnostic> {
        guard diagram.participants.count >= 2, diagram.participants.count <= MermaidSequenceParser.maximumParticipants,
              !diagram.messages.isEmpty, diagram.messages.count <= MermaidSequenceParser.maximumMessages,
              requestedWidth.isFinite else { return .failure(.resourceLimit) }
        let width = min(maximumWidth, requestedWidth)
        let contentWidth = width - margin * 2
        let gap = 16.0
        let columnWidth = min(240, (contentWidth - Double(diagram.participants.count - 1) * gap) / Double(diagram.participants.count))
        guard columnWidth >= 76 else { return .failure(.resourceLimit) }
        let diagramWidth = margin * 2 + Double(diagram.participants.count) * columnWidth
            + Double(diagram.participants.count - 1) * gap

        var centers: [String: Double] = [:]
        var headerHeights: [String: Double] = [:]
        for (index, participant) in diagram.participants.enumerated() {
            try checkpoint()
            let center = margin + columnWidth / 2 + Double(index) * (columnWidth + gap)
            centers[participant.id] = center
            let capacity = max(6, Int((columnWidth - 12) / 7))
            let lines = max(1, (displayColumns(participant.label) + capacity - 1) / capacity)
            headerHeights[participant.id] = Double(lines * 16 + 16)
        }
        let headerHeight = headerHeights.values.max() ?? 0
        var y = margin + headerHeight + 24
        var positions: [Double] = []
        var labelWidths: [Double] = []
        var labelHeights: [Double] = []
        for (index, message) in diagram.messages.enumerated() {
            try checkpoint()
            guard let sourceX = centers[message.sourceID], let targetX = centers[message.targetID] else {
                return .failure(.malformedSyntax)
            }
            let textWidth = max(24, abs(targetX - sourceX) - 20)
            let capacity = max(4, Int(textWidth / 7))
            let lines = max(1, (displayColumns(message.text) + capacity - 1) / capacity)
            let labelHeight = Double(lines * 16)
            if index == 0 { y = max(y, margin + headerHeight + labelHeight + 24) }
            positions.append(y)
            labelWidths.append(textWidth)
            labelHeights.append(labelHeight)
            y += max(48, labelHeight + 20)
        }
        let height = y + margin
        guard height <= maximumHeight else { return .failure(.resourceLimit) }
        return .success(.init(size: (diagramWidth, height), participantCenters: centers,
                              participantColumnWidth: columnWidth,
                              participantHeaderHeights: headerHeights, messageYPositions: positions,
                              messageLabelWidths: labelWidths, messageLabelHeights: labelHeights))
    }

    /// Counts display columns so layout measurements match the renderer's Unicode width policy.
    private static func displayColumns(_ text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            let category = scalar.properties.generalCategory
            if category == .nonspacingMark || category == .enclosingMark || category == .spacingMark { return }
            count += scalar.value >= 0x2E80 ? 2 : 1
        }
    }
}
