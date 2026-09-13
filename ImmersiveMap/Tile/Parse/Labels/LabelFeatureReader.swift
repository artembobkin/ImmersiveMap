// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt

/// Reads point features into labels, and adds the labels the parser
/// synthesizes itself (the ocean and sea names of the coarse zooms). Which
/// features are labelled, with which text and at which priority is the
/// label policy's answer (`TileLabelDecisions`); this only walks the points.
///
/// Called only with labels on: with them off the point features are skipped
/// whole by the dispatcher, decision engine included, and the switch is
/// prepared-cache identity so a tile prepared without labels never answers
/// a map that wants them.
struct LabelFeatureReader {
    private let labelDecisions: TileLabelDecisions
    private let mapStyle: any ImmersiveMapStyle
    private let tileExtent = TileCoordinateSpace.tileExtentDouble

    init(labelDecisions: TileLabelDecisions, mapStyle: any ImmersiveMapStyle) {
        self.labelDecisions = labelDecisions
        self.mapStyle = mapStyle
    }

    /// One label per point of the feature that lies inside the tile and
    /// that the policy decides to label. The POI icon is decided once for
    /// the feature, before its points are walked.
    func read(feature: MvtDecodedFeature,
              attributes: [String: MvtValue],
              style: FeatureStyle,
              geometry: TileLayerGeometry,
              layerName: String,
              tile: Tile,
              into result: inout ReadingStageResult) {
        guard let labelTextStyle = style.labelTextStyle else { return }
        let points = geometry.points(of: feature)
        let featureID = feature.hasID ? feature.id : nil
        let poiIcon = labelDecisions.poiIcon(attributes: attributes, layerName: layerName)
        for point in points where isPointInsideTile(point) {
            let anchor = SIMD2(Int16(point.x), Int16(point.y))
            let labelFeature = VectorTileLabelFeature(providerID: labelDecisions.providerID,
                                                      tile: tile,
                                                      layerName: layerName,
                                                      featureID: featureID,
                                                      anchor: anchor,
                                                      properties: attributes)
            guard let decision = labelDecisions.pointLabelDecision(feature: labelFeature,
                                                                   style: labelTextStyle,
                                                                   poiIcon: poiIcon) else {
                continue
            }
            result.textLabels.append(ParsedTextLabel(text: decision.text,
                                                     position: anchor,
                                                     key: decision.identity.runtimeKey,
                                                     sortKey: decision.priority.visibilityRank,
                                                     collisionPriority: decision.priority.collisionRank,
                                                     textStyle: decision.style,
                                                     poiIcon: decision.poiIcon,
                                                     minCameraZoom: style.labelMinCameraZoom))
        }
    }

    /// The ocean and sea names of zooms 0 to 2, which the tiles carry
    /// unreliably: added for every water body whose anchor falls in the tile
    /// and whose name no label of the tile already shows, styled as a
    /// `natural_label` feature so the style decides the look.
    func appendLowZoomWaterLabels(tile: Tile, into result: inout ReadingStageResult) {
        guard tile.z <= 2 else {
            return
        }

        let existingWaterText = Set(
            result.textLabels.filter { $0.textStyle.key == 3 || $0.textStyle.key == 4 }
                .map(\.text)
        )

        for fallback in LowZoomWaterLabels.labels(for: tile) {
            guard let name = labelDecisions.localizedName(from: fallback.names),
                  fallback.isDuplicate(of: existingWaterText) == false,
                  let point = LowZoomWaterLabels.tilePoint(forLatitude: fallback.latitude,
                                                           longitude: fallback.longitude,
                                                           tile: tile) else {
                continue
            }

            let attributes: [String: MvtValue] = [
                "class": .string(fallback.styleClass),
                "type": .string(fallback.styleClass),
                "name": .string(name)
            ]

            let style = mapStyle.makeStyle(data: DetFeatureStyleData(layerName: "natural_label",
                                                                     properties: attributes,
                                                                     tile: tile))
            guard let textStyle = style.labelTextStyle else {
                continue
            }

            result.textLabels.append(ParsedTextLabel(text: name,
                                                     position: point,
                                                     tile: tile,
                                                     featureId: 0,
                                                     hasFeatureId: false,
                                                     layerName: "natural_label",
                                                     sortKey: fallback.sortKey,
                                                     collisionPriority: fallback.sortKey,
                                                     textStyle: textStyle,
                                                     poiIcon: nil,
                                                     minCameraZoom: style.labelMinCameraZoom))
        }
    }

    private func isPointInsideTile(_ point: Point) -> Bool {
        point.x >= 0 &&
        point.x <= Int32(tileExtent) &&
        point.y >= 0 &&
        point.y <= Int32(tileExtent)
    }
}
