// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

final class TileRoadLabelsBuilder {
    private let textRenderer: TextRenderer
    private let roadLabelRepeatDistancePx: Float = 100.0
    private let tileExtent: Float = 4096.0
    private let tilePixelSize: Float = 512.0
    private let maxAnchorsPerPath: Int = 7
    init(textRenderer: TextRenderer) {
        self.textRenderer = textRenderer
    }

    func build(roadTextLabels: [TileMvtParser.RoadTextLabel], tile: Tile) -> PreparedTileCPU.RoadLabels {
        let mergedRoadTextLabels = mergeRoadTextLabels(roadTextLabels)
        let tileIndices = SIMD3<Int32>(Int32(tile.x), Int32(tile.y), Int32(tile.z))
        var roadPathInputs: [TilePointInput] = []
        var roadPathRanges: [RoadPathRange] = []
        var roadPathLabels: [RoadPathLabel] = []
        var roadLabelVertices: [LabelVertex] = []
        var roadLabelGlyphBounds: [SIMD4<Float>] = []
        var roadLabelGlyphBoundRanges: [LabelGlyphRange] = []
        var roadLabelSizes: [SIMD2<Float>] = []
        var roadLabelAnchors: [RoadLabelAnchor] = []
        var roadLabelAnchorRanges: [RoadLabelAnchorRange] = []
        var tileGlyphIndex = 0
        var labelStyle: LabelTextStyle?

        roadPathInputs.reserveCapacity(mergedRoadTextLabels.count * 4)
        for roadLabel in mergedRoadTextLabels {
            let rangeStart = roadPathInputs.count
            for point in roadLabel.path {
                let uvX = Double(point.x) / 4096.0
                let uvY = Double(point.y) / 4096.0
                let uv = SIMD2<Float>(Float(uvX), Float(uvY))
                roadPathInputs.append(TilePointInput(uv: uv,
                                                     tile: tileIndices,
                                                     tileSlotIndex: 0))
            }

            let count = roadPathInputs.count - rangeStart
            if count <= 0 {
                continue
            }

            let labelIndex = roadPathLabels.count
            roadPathLabels.append(RoadPathLabel(text: roadLabel.text, key: roadLabel.key))
            roadPathRanges.append(RoadPathRange(start: rangeStart,
                                                count: count,
                                                labelIndex: labelIndex))

            if labelStyle == nil {
                labelStyle = roadLabel.textStyle
            }
            // Все дорожные глифы тайла рисуются одним draw-call'ом с единственной
            // привязанной атлас-текстурой - её выбирает `labelStyle.weight` (стиль
            // первого лейбла). Геометрию каждого лейбла строим тем же весом: bold и
            // thin атласы имеют разные UV для одного кодпоинта, поэтому глиф,
            // собранный по другому атласу, сэмплился бы из неверной области = мусор
            // (тот же класс бага, что чинился у base-лейблов). `sizePx` при этом
            // остаётся пер-лейбловым - масштаб безопасно варьируется, он запекается
            // в геометрию вместе со своими анкор-габаритами.
            let atlasWeight = labelStyle?.weight ?? roadLabel.textStyle.weight
            assert(roadLabel.textStyle.weight == atlasWeight,
                   "Road labels in one tile must share a font weight: the tile binds a single atlas texture per draw.")
            let textMetrics = textRenderer.collectLabelVertices(for: roadLabel.text,
                                                                labelIndex: simd_int1(0),
                                                                scale: roadLabel.textStyle.sizePx,
                                                                normalizeY: false,
                                                                weight: atlasWeight)
            roadLabelSizes.append(SIMD2<Float>(textMetrics.size.width, textMetrics.size.height))

            let glyphStart = roadLabelGlyphBounds.count
            let glyphCount = textMetrics.vertices.count / 6
            if glyphCount > 0 {
                roadLabelGlyphBounds.reserveCapacity(glyphStart + glyphCount)
                for glyphIndex in 0..<glyphCount {
                    let glyphVertexStart = glyphIndex * 6
                    let glyphVertices = textMetrics.vertices[glyphVertexStart..<(glyphVertexStart + 6)]
                    var minX = Float.greatestFiniteMagnitude
                    var maxX = -Float.greatestFiniteMagnitude
                    var minY = Float.greatestFiniteMagnitude
                    var maxY = -Float.greatestFiniteMagnitude
                    for vertex in glyphVertices {
                        minX = min(minX, vertex.position.x)
                        maxX = max(maxX, vertex.position.x)
                        minY = min(minY, vertex.position.y)
                        maxY = max(maxY, vertex.position.y)
                    }
                    roadLabelGlyphBounds.append(SIMD4<Float>(minX, maxX, minY, maxY))
                }
            }
            roadLabelGlyphBoundRanges.append(LabelGlyphRange(start: glyphStart, count: glyphCount))

            let anchorStart = roadLabelAnchors.count
            var anchorCount = 0
            if glyphCount > 0 && count > 1 {
                let spacingTile = roadLabelRepeatDistancePx * (tileExtent / tilePixelSize)
                let labelWidthTile = textMetrics.size.width * (tileExtent / tilePixelSize)
                let anchors = buildAnchors(path: roadLabel.path,
                                           labelWidthTile: labelWidthTile,
                                           spacingTile: spacingTile,
                                           labelIndex: labelIndex)
                for anchor in anchors {
                    roadLabelAnchors.append(anchor)
                    anchorCount += 1
                    let glyphOffset = tileGlyphIndex
                    for glyphIndex in 0..<glyphCount {
                        let glyphVertexStart = glyphIndex * 6
                        let glyphVertices = textMetrics.vertices[glyphVertexStart..<(glyphVertexStart + 6)]
                        for vertex in glyphVertices {
                            var updated = vertex
                            updated.labelIndex = simd_int1(glyphOffset + glyphIndex)
                            roadLabelVertices.append(updated)
                        }
                    }
                    tileGlyphIndex += glyphCount
                }
            }
            roadLabelAnchorRanges.append(RoadLabelAnchorRange(start: anchorStart, count: anchorCount))
        }

        return PreparedTileCPU.RoadLabels(pathInputs: roadPathInputs,
                                          pathRanges: roadPathRanges,
                                          pathLabels: roadPathLabels,
                                          labelStyle: labelStyle,
                                          localGlyphVertices: roadLabelVertices,
                                          glyphBounds: roadLabelGlyphBounds,
                                          glyphBoundRanges: roadLabelGlyphBoundRanges,
                                          sizes: roadLabelSizes,
                                          anchorRanges: roadLabelAnchorRanges,
                                          anchors: roadLabelAnchors)
    }

    private func mergeRoadTextLabels(_ roadTextLabels: [TileMvtParser.RoadTextLabel]) -> [MergedRoadTextLabel] {
        guard roadTextLabels.isEmpty == false else {
            return []
        }

        let segments = roadTextLabels.enumerated().map { offset, label in
            TileLocalRoadSegment(sourceOrder: offset,
                                 text: label.text,
                                 style: label.textStyle,
                                 path: label.path)
        }

        let groupedSegments = Dictionary(grouping: segments, by: \.mergeKey)
        var mergedLabels: [MergedRoadTextLabel] = []
        mergedLabels.reserveCapacity(roadTextLabels.count)

        let sortedKeys = groupedSegments.keys.sorted(by: MergeKey.sortForDeterministicOrder)
        for key in sortedKeys {
            guard let groupSegments = groupedSegments[key] else {
                continue
            }
            mergedLabels.append(contentsOf: mergeSegmentGroup(groupSegments))
        }

        return mergedLabels.sorted(by: MergedRoadTextLabel.sortForDeterministicOrder)
    }

    private func mergeSegmentGroup(_ segments: [TileLocalRoadSegment]) -> [MergedRoadTextLabel] {
        guard segments.isEmpty == false else {
            return []
        }

        var unusedIndices = Set(segments.indices)
        var results: [MergedRoadTextLabel] = []
        results.reserveCapacity(segments.count)

        while unusedIndices.isEmpty == false {
            let seedIndex = unusedIndices.max { lhs, rhs in
                TileLocalRoadSegment.sortForSeedChoice(lhs: segments[lhs], rhs: segments[rhs]) == false
            }!
            unusedIndices.remove(seedIndex)

            var chain = segments[seedIndex]

            while let continuation = chooseTailContinuation(from: chain.path.last!,
                                                            segments: segments,
                                                            unusedIndices: unusedIndices) {
                unusedIndices.remove(continuation.index)
                let nextSegment = continuation.reverse ? segments[continuation.index].reversed() : segments[continuation.index]
                chain = chain.appending(nextSegment)
            }

            while let continuation = chooseHeadContinuation(from: chain.path.first!,
                                                            segments: segments,
                                                            unusedIndices: unusedIndices) {
                unusedIndices.remove(continuation.index)
                let nextSegment = continuation.reverse ? segments[continuation.index].reversed() : segments[continuation.index]
                chain = nextSegment.appending(chain)
            }

            results.append(MergedRoadTextLabel(text: chain.text,
                                               path: chain.path,
                                               key: makeMergedRoadLabelKey(text: chain.text,
                                                                           style: chain.style,
                                                                           path: chain.path),
                                               textStyle: chain.style,
                                               sourceOrder: chain.sourceOrder))
        }

        return results
    }

    private func chooseTailContinuation(from endpoint: SIMD2<Int16>,
                                        segments: [TileLocalRoadSegment],
                                        unusedIndices: Set<Int>) -> (index: Int, reverse: Bool)? {
        var best: (index: Int, reverse: Bool)?
        for index in unusedIndices {
            let segment = segments[index]
            if segment.path.first == endpoint {
                if let currentBest = best {
                    let bestSegment = currentBest.reverse ? segments[currentBest.index].reversed() : segments[currentBest.index]
                    if TileLocalRoadSegment.sortForContinuationChoice(lhs: segment, rhs: bestSegment) {
                        best = (index, false)
                    }
                } else {
                    best = (index, false)
                }
            } else if segment.path.last == endpoint {
                let candidate = segment.reversed()
                if let currentBest = best {
                    let bestSegment = currentBest.reverse ? segments[currentBest.index].reversed() : segments[currentBest.index]
                    if TileLocalRoadSegment.sortForContinuationChoice(lhs: candidate, rhs: bestSegment) {
                        best = (index, true)
                    }
                } else {
                    best = (index, true)
                }
            }
        }
        return best
    }

    private func chooseHeadContinuation(from endpoint: SIMD2<Int16>,
                                        segments: [TileLocalRoadSegment],
                                        unusedIndices: Set<Int>) -> (index: Int, reverse: Bool)? {
        var best: (index: Int, reverse: Bool)?
        for index in unusedIndices {
            let segment = segments[index]
            if segment.path.last == endpoint {
                if let currentBest = best {
                    let bestSegment = currentBest.reverse ? segments[currentBest.index].reversed() : segments[currentBest.index]
                    if TileLocalRoadSegment.sortForContinuationChoice(lhs: segment, rhs: bestSegment) {
                        best = (index, false)
                    }
                } else {
                    best = (index, false)
                }
            } else if segment.path.first == endpoint {
                let candidate = segment.reversed()
                if let currentBest = best {
                    let bestSegment = currentBest.reverse ? segments[currentBest.index].reversed() : segments[currentBest.index]
                    if TileLocalRoadSegment.sortForContinuationChoice(lhs: candidate, rhs: bestSegment) {
                        best = (index, true)
                    }
                } else {
                    best = (index, true)
                }
            }
        }
        return best
    }

    private func makeMergedRoadLabelKey(text: String,
                                        style: LabelTextStyle,
                                        path: [SIMD2<Int16>]) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(style.key)
        hasher.combine(style.fillColor.x.bitPattern)
        hasher.combine(style.fillColor.y.bitPattern)
        hasher.combine(style.fillColor.z.bitPattern)
        hasher.combine(style.strokeColor.x.bitPattern)
        hasher.combine(style.strokeColor.y.bitPattern)
        hasher.combine(style.strokeColor.z.bitPattern)
        hasher.combine(style.strokeWidthPx.bitPattern)
        hasher.combine(style.sizePx.bitPattern)
        hasher.combine(style.weight.rawValue)
        hasher.combine(path.count)
        for point in path {
            hasher.combine(point.x)
            hasher.combine(point.y)
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    private func buildAnchors(path: [SIMD2<Int16>],
                              labelWidthTile: Float,
                              spacingTile: Float,
                              labelIndex: Int) -> [RoadLabelAnchor] {
        guard path.count > 1 else {
            return []
        }

        var points: [SIMD2<Float>] = []
        points.reserveCapacity(path.count)
        for point in path {
            points.append(SIMD2<Float>(Float(point.x), Float(point.y)))
        }

        var segmentLengths: [Float] = []
        segmentLengths.reserveCapacity(points.count - 1)
        var totalLength: Float = 0.0
        for i in 1..<points.count {
            let length = simd_length(points[i] - points[i - 1])
            segmentLengths.append(length)
            totalLength += length
        }

        guard totalLength > 0.0 else {
            return []
        }

        guard labelWidthTile > 0.0 else {
            return []
        }
        let footprintWidth = min(labelWidthTile, totalLength)
        let halfFootprintWidth = footprintWidth * 0.5

        var anchorDistances: [Float] = []
        if totalLength <= spacingTile {
            anchorDistances = [totalLength * 0.5]
        } else {
            let maxDistance = totalLength - halfFootprintWidth
            var distance = max(spacingTile * 0.5, halfFootprintWidth)
            while distance <= maxDistance && anchorDistances.count < maxAnchorsPerPath {
                anchorDistances.append(distance)
                distance += spacingTile
            }
        }

        var anchors: [RoadLabelAnchor] = []
        anchors.reserveCapacity(anchorDistances.count)
        for (ordinal, distance) in anchorDistances.enumerated() {
            guard isAnchorValid(distance: distance,
                                labelWidthTile: footprintWidth,
                                points: points,
                                segmentLengths: segmentLengths,
                                totalLength: totalLength) else {
                continue
            }

            var segmentIndex = 0
            var accumulated: Float = 0.0
            var segmentLength = segmentLengths.first ?? 0.0
            while segmentIndex < segmentLengths.count - 1,
                  accumulated + segmentLength < distance {
                accumulated += segmentLength
                segmentIndex += 1
                segmentLength = segmentLengths[segmentIndex]
            }

            var t: Float = 0.0
            if segmentLength > 0.0 {
                t = (distance - accumulated) / segmentLength
            }
            t = min(max(t, 0.0), 1.0)
            anchors.append(RoadLabelAnchor(pathIndex: UInt32(labelIndex),
                                           segmentIndex: UInt32(segmentIndex),
                                           t: t,
                                           distanceAlongPath: totalLength > 0.0 ? (distance / totalLength) : 0.0,
                                           anchorOrdinal: UInt32(ordinal)))
        }

        return anchors
    }

    private func isAnchorValid(distance: Float,
                               labelWidthTile: Float,
                               points _: [SIMD2<Float>],
                               segmentLengths _: [Float],
                               totalLength: Float) -> Bool {
        let halfLabelWidth = labelWidthTile * 0.5
        guard distance >= halfLabelWidth,
              distance <= totalLength - halfLabelWidth else {
            return false
        }
        return true
    }
}

private struct MergeKey: Hashable {
    let text: String
    let styleKey: Int
    let fillColor: SIMD3<UInt32>
    let strokeColor: SIMD3<UInt32>
    let strokeWidthPx: UInt32
    let sizePx: UInt32
    let weightRawValue: UInt8

    init(text: String, style: LabelTextStyle) {
        self.text = text
        self.styleKey = style.key
        self.fillColor = SIMD3<UInt32>(style.fillColor.x.bitPattern,
                                       style.fillColor.y.bitPattern,
                                       style.fillColor.z.bitPattern)
        self.strokeColor = SIMD3<UInt32>(style.strokeColor.x.bitPattern,
                                         style.strokeColor.y.bitPattern,
                                         style.strokeColor.z.bitPattern)
        self.strokeWidthPx = style.strokeWidthPx.bitPattern
        self.sizePx = style.sizePx.bitPattern
        self.weightRawValue = style.weight.rawValue
    }

    static func sortForDeterministicOrder(lhs: MergeKey, rhs: MergeKey) -> Bool {
        if lhs.text != rhs.text {
            return lhs.text < rhs.text
        }
        if lhs.styleKey != rhs.styleKey {
            return lhs.styleKey < rhs.styleKey
        }
        if lhs.weightRawValue != rhs.weightRawValue {
            return lhs.weightRawValue < rhs.weightRawValue
        }
        if lhs.sizePx != rhs.sizePx {
            return lhs.sizePx < rhs.sizePx
        }
        if lhs.strokeWidthPx != rhs.strokeWidthPx {
            return lhs.strokeWidthPx < rhs.strokeWidthPx
        }
        if lhs.fillColor.x != rhs.fillColor.x {
            return lhs.fillColor.x < rhs.fillColor.x
        }
        if lhs.fillColor.y != rhs.fillColor.y {
            return lhs.fillColor.y < rhs.fillColor.y
        }
        if lhs.fillColor.z != rhs.fillColor.z {
            return lhs.fillColor.z < rhs.fillColor.z
        }
        if lhs.strokeColor.x != rhs.strokeColor.x {
            return lhs.strokeColor.x < rhs.strokeColor.x
        }
        if lhs.strokeColor.y != rhs.strokeColor.y {
            return lhs.strokeColor.y < rhs.strokeColor.y
        }
        return lhs.strokeColor.z < rhs.strokeColor.z
    }
}

private struct TileLocalRoadSegment {
    let sourceOrder: Int
    let text: String
    let style: LabelTextStyle
    let path: [SIMD2<Int16>]
    let length: Float
    let mergeKey: MergeKey

    init(sourceOrder: Int,
         text: String,
         style: LabelTextStyle,
         path: [SIMD2<Int16>]) {
        self.sourceOrder = sourceOrder
        self.text = text
        self.style = style
        self.path = path
        self.length = TileLocalRoadSegment.measureLength(path)
        self.mergeKey = MergeKey(text: text, style: style)
    }

    func reversed() -> TileLocalRoadSegment {
        TileLocalRoadSegment(sourceOrder: sourceOrder,
                             text: text,
                             style: style,
                             path: Array(path.reversed()))
    }

    func appending(_ other: TileLocalRoadSegment) -> TileLocalRoadSegment {
        var combinedPath = path
        let shouldDropDuplicate = combinedPath.last == other.path.first
        combinedPath.append(contentsOf: other.path.dropFirst(shouldDropDuplicate ? 1 : 0))
        return TileLocalRoadSegment(sourceOrder: min(sourceOrder, other.sourceOrder),
                                    text: text,
                                    style: style,
                                    path: combinedPath)
    }

    static func sortForSeedChoice(lhs: TileLocalRoadSegment, rhs: TileLocalRoadSegment) -> Bool {
        if lhs.length != rhs.length {
            return lhs.length < rhs.length
        }
        if lhs.path.first?.x != rhs.path.first?.x {
            return (lhs.path.first?.x ?? 0) < (rhs.path.first?.x ?? 0)
        }
        if lhs.path.first?.y != rhs.path.first?.y {
            return (lhs.path.first?.y ?? 0) < (rhs.path.first?.y ?? 0)
        }
        return lhs.sourceOrder > rhs.sourceOrder
    }

    static func sortForContinuationChoice(lhs: TileLocalRoadSegment, rhs: TileLocalRoadSegment) -> Bool {
        if lhs.length != rhs.length {
            return lhs.length > rhs.length
        }
        let lhsEnd = lhs.path.last ?? .zero
        let rhsEnd = rhs.path.last ?? .zero
        if lhsEnd.x != rhsEnd.x {
            return lhsEnd.x < rhsEnd.x
        }
        if lhsEnd.y != rhsEnd.y {
            return lhsEnd.y < rhsEnd.y
        }
        return lhs.sourceOrder < rhs.sourceOrder
    }

    private static func measureLength(_ path: [SIMD2<Int16>]) -> Float {
        guard path.count > 1 else {
            return 0
        }
        var total: Float = 0
        for index in 1..<path.count {
            total += simd_length(SIMD2<Float>(Float(path[index].x - path[index - 1].x),
                                              Float(path[index].y - path[index - 1].y)))
        }
        return total
    }
}

private struct MergedRoadTextLabel {
    let text: String
    let path: [SIMD2<Int16>]
    let key: UInt64
    let textStyle: LabelTextStyle
    let sourceOrder: Int

    static func sortForDeterministicOrder(lhs: MergedRoadTextLabel, rhs: MergedRoadTextLabel) -> Bool {
        if lhs.text != rhs.text {
            return lhs.text < rhs.text
        }
        let lhsFirst = lhs.path.first ?? .zero
        let rhsFirst = rhs.path.first ?? .zero
        if lhsFirst.x != rhsFirst.x {
            return lhsFirst.x < rhsFirst.x
        }
        if lhsFirst.y != rhsFirst.y {
            return lhsFirst.y < rhsFirst.y
        }
        if lhs.path.count != rhs.path.count {
            return lhs.path.count > rhs.path.count
        }
        return lhs.sourceOrder < rhs.sourceOrder
    }
}
