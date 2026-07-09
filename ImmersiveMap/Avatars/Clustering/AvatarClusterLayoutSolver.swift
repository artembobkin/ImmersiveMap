// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  AvatarClusterLayoutSolver.swift
//  ImmersiveMap
//

import CoreGraphics
import simd

struct AvatarProjectedMarker {
    let marker: AvatarMarker
    let squashScale: SIMD2<Float>
    let screenPoint: ScreenPointOutput
    let drawOrder: Int
}

struct AvatarClusterMarkerItem {
    let marker: AvatarMarker
    let squashScale: SIMD2<Float>
    let screenPoint: ScreenPointOutput
    let drawOrder: Int

    init(marker: AvatarMarker,
         squashScale: SIMD2<Float>,
         screenPoint: ScreenPointOutput,
         drawOrder: Int) {
        self.marker = marker
        self.squashScale = squashScale
        self.screenPoint = screenPoint
        self.drawOrder = drawOrder
    }
}

struct AvatarClusterRenderable {
    let id: UInt64
    let memberIDs: [UInt64]
    let previewMarkers: [AvatarMarker]
    let screenPoint: ScreenPointOutput
    let drawOrder: Int
}

struct AvatarClusterLayout {
    static let empty = AvatarClusterLayout(markerItems: [],
                                           clusterItems: [],
                                           activeClusterIDs: [])

    let markerItems: [AvatarClusterMarkerItem]
    let clusterItems: [AvatarClusterRenderable]
    let activeClusterIDs: Set<UInt64>
}

struct AvatarClusterLayoutSolver {
    func solve(projectedMarkers: [AvatarProjectedMarker],
               markerSizePx: Float,
               collisionPaddingPx: Float) -> AvatarClusterLayout {
        guard projectedMarkers.isEmpty == false else {
            return .empty
        }

        let clusterThreshold = max(1.0, markerSizePx + collisionPaddingPx * 2.0)
        let candidates = projectedMarkers
            .filter { $0.marker.clusterPolicy == .event && $0.marker.isSelected == false }
            .sorted { lhs, rhs in lhs.marker.id < rhs.marker.id }
        let groups = clusterGroups(candidates: candidates, threshold: clusterThreshold)
        let clusteredIDs = Set(groups.flatMap { $0.map(\.marker.id) })

        var markerItems: [AvatarClusterMarkerItem] = []
        markerItems.reserveCapacity(projectedMarkers.count)
        var clusterItems: [AvatarClusterRenderable] = []
        clusterItems.reserveCapacity(groups.count)
        var activeClusterIDs = Set<UInt64>()

        for marker in projectedMarkers where clusteredIDs.contains(marker.marker.id) == false {
            markerItems.append(AvatarClusterMarkerItem(marker: marker.marker,
                                                       squashScale: marker.squashScale,
                                                       screenPoint: marker.screenPoint,
                                                       drawOrder: marker.drawOrder))
        }

        for group in groups {
            let sortedGroup = group.sorted { $0.marker.id < $1.marker.id }
            let memberIDs = sortedGroup.map(\.marker.id)
            let clusterID = Self.clusterID(memberIDs: memberIDs)
            activeClusterIDs.insert(clusterID)

            clusterItems.append(AvatarClusterRenderable(id: clusterID,
                                                        memberIDs: memberIDs,
                                                        previewMarkers: Array(sortedGroup.prefix(3).map(\.marker)),
                                                        screenPoint: centerScreenPoint(for: sortedGroup),
                                                        drawOrder: sortedGroup.map(\.drawOrder).max() ?? 0))
        }

        markerItems.sort {
            if $0.drawOrder != $1.drawOrder {
                return $0.drawOrder < $1.drawOrder
            }
            return $0.marker.id < $1.marker.id
        }
        clusterItems.sort {
            if $0.drawOrder != $1.drawOrder {
                return $0.drawOrder < $1.drawOrder
            }
            return $0.id < $1.id
        }

        return AvatarClusterLayout(markerItems: markerItems,
                                   clusterItems: clusterItems,
                                   activeClusterIDs: activeClusterIDs)
    }

    static func clusterID(memberIDs: [UInt64]) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for id in memberIDs.sorted() {
            var value = id
            for _ in 0..<8 {
                let byte = UInt8(truncatingIfNeeded: value)
                hash ^= UInt64(byte)
                hash &*= 0x100000001b3
                value >>= 8
            }
        }
        return hash == 0 ? 1 : hash
    }

    private func clusterGroups(candidates: [AvatarProjectedMarker],
                               threshold: Float) -> [[AvatarProjectedMarker]] {
        guard candidates.count > 1 else {
            return []
        }

        var disjointSet = DisjointSet(count: candidates.count)
        let thresholdSquared = threshold * threshold
        for lhsIndex in 0..<candidates.count {
            for rhsIndex in (lhsIndex + 1)..<candidates.count {
                let delta = candidates[lhsIndex].screenPoint.position - candidates[rhsIndex].screenPoint.position
                if simd_length_squared(delta) <= thresholdSquared {
                    disjointSet.union(lhsIndex, rhsIndex)
                }
            }
        }

        var groupedIndexes: [Int: [Int]] = [:]
        for index in candidates.indices {
            groupedIndexes[disjointSet.find(index), default: []].append(index)
        }

        return groupedIndexes.values
            .filter { $0.count > 1 }
            .map { indexes in indexes.map { candidates[$0] } }
            .sorted { lhs, rhs in
                let lhsID = lhs.map(\.marker.id).min() ?? 0
                let rhsID = rhs.map(\.marker.id).min() ?? 0
                return lhsID < rhsID
            }
    }

    private func centerScreenPoint(for group: [AvatarProjectedMarker]) -> ScreenPointOutput {
        guard group.isEmpty == false else {
            return ScreenPointOutput(position: .zero, depth: 0, visible: 0)
        }

        var position = SIMD2<Float>(repeating: 0)
        var depth: Float = 0
        var alpha: Float = 0
        for item in group {
            position += item.screenPoint.position
            depth += item.screenPoint.depth
            alpha += item.screenPoint.visibilityAlpha
        }
        let count = Float(group.count)
        return ScreenPointOutput(position: position / count,
                                 depth: depth / count,
                                 visible: 1,
                                 visibilityAlpha: alpha / count)
    }

}

private struct DisjointSet {
    private var parent: [Int]

    init(count: Int) {
        parent = Array(0..<count)
    }

    mutating func find(_ index: Int) -> Int {
        let currentParent = parent[index]
        if currentParent == index {
            return index
        }
        let root = find(currentParent)
        parent[index] = root
        return root
    }

    mutating func union(_ lhs: Int, _ rhs: Int) {
        let lhsRoot = find(lhs)
        let rhsRoot = find(rhs)
        guard lhsRoot != rhsRoot else { return }
        parent[max(lhsRoot, rhsRoot)] = min(lhsRoot, rhsRoot)
    }
}
