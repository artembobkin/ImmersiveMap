// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

struct RoadGeometryPhases<Layer> {
    let shadow: Layer
    let casing: Layer
    let fill: Layer
    let detail: Layer
    let overlay: Layer

    func layer(for role: RoadPassRole) -> Layer {
        switch role {
        case .shadow:
            return shadow
        case .casing:
            return casing
        case .fill:
            return fill
        case .detail:
            return detail
        case .overlay:
            return overlay
        }
    }

    func map<T>(_ transform: (Layer) -> T) -> RoadGeometryPhases<T> {
        RoadGeometryPhases<T>(shadow: transform(shadow),
                              casing: transform(casing),
                              fill: transform(fill),
                              detail: transform(detail),
                              overlay: transform(overlay))
    }

    var drawOrderLayers: [Layer] {
        [shadow, casing, fill, detail, overlay]
    }
}

extension RoadGeometryPhases: Equatable where Layer: Equatable {}

struct RoadStructureBuckets<Bucket> {
    let tunnel: Bucket
    let ground: Bucket
    let bridge: Bucket

    func bucket(for structureKind: TileMvtParser.RoadStructureKind) -> Bucket {
        switch structureKind {
        case .tunnel:
            return tunnel
        case .ground:
            return ground
        case .bridge:
            return bridge
        }
    }

    func map<T>(_ transform: (Bucket) -> T) -> RoadStructureBuckets<T> {
        RoadStructureBuckets<T>(tunnel: transform(tunnel),
                                ground: transform(ground),
                                bridge: transform(bridge))
    }

    var drawOrderBuckets: [Bucket] {
        [tunnel, ground, bridge]
    }
}

extension RoadStructureBuckets: Equatable where Bucket: Equatable {}
