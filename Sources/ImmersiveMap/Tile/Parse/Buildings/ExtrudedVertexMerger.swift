// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// Writes one building's volume into the tile's extruded streams with
/// every distinct vertex once.
///
/// The builders give each face its own corners, and the faces of a rounded
/// building meet in vertices of one position and one normal (a wall's top
/// is the bottom of the band over it, a bevel's sides are the ends of its
/// two walls): about 23 vertices to a footprint edge, 8 of them distinct.
/// Here the vertices that are the same bytes once quantized
/// (`ExtrudedVertexIn`) become one, and the indices follow. The triangles,
/// their order and their winding are as the builder gave them, so the
/// building's run of the indices is the run it was (`TileBuildingRange`).
///
/// Vertices are merged within one volume only, never across two: the
/// table is emptied for every mesh. The ordinal in the vertex would keep
/// most volumes apart by itself, but past 65535 volumes the rest share
/// one.
struct ExtrudedVertexMerger {
    /// The twelve bytes of a quantized vertex.
    private struct Key: Equatable {
        let low: UInt64
        let high: UInt32

        init(_ vertex: ExtrudedVertexIn) {
            (low, high) = withUnsafeBytes(of: vertex) { bytes in
                (bytes.loadUnaligned(fromByteOffset: 0, as: UInt64.self),
                 bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
            }
        }

        /// The slot the probing starts at, in a table of `mask + 1` slots.
        func slot(mask: Int) -> Int {
            let mixed = (low ^ (UInt64(high) &* 0xFF51_AFD7_ED55_8CCD)) &* 0x9E37_79B9_7F4A_7C15
            return Int(truncatingIfNeeded: mixed >> 32) & mask
        }
    }

    /// An open-addressing table over the volume's vertices, kept from one
    /// volume to the next: a slot holds a vertex's place in the tile's
    /// vertices plus one, zero while empty. A volume is a few hundred
    /// vertices, and the standard dictionary's hashing cost several times
    /// the write itself on a dense tile.
    private var slots: [UInt32] = []
    /// Where each of the mesh's own vertices went in the tile's.
    private var mergedIndices: [UInt32] = []

    mutating func append(_ mesh: ParsedExtrudedMesh,
                         styleIndex: UInt8,
                         buildingOrdinal: UInt16,
                         vertices: inout [ExtrudedVertexIn],
                         indices: inout [UInt32]) {
        assert(MemoryLayout<ExtrudedVertexIn>.size == 12, "The key reads the vertex's twelve bytes")
        // At most half full, so a probe ends within a few slots.
        var slotCount = 16
        while slotCount < mesh.vertices.count * 2 { slotCount *= 2 }
        let mask = slotCount - 1
        if slots.count < slotCount {
            slots = [UInt32](repeating: 0, count: slotCount)
        } else {
            for slot in 0 ..< slotCount { slots[slot] = 0 }
        }
        mergedIndices.removeAll(keepingCapacity: true)
        mergedIndices.reserveCapacity(mesh.vertices.count)
        for vertex in mesh.vertices {
            let quantized = ExtrudedVertexIn(position: vertex.position,
                                             normal: vertex.normal,
                                             styleIndex: styleIndex,
                                             buildingOrdinal: buildingOrdinal)
            let key = Key(quantized)
            var slot = key.slot(mask: mask)
            while true {
                let held = slots[slot]
                if held == 0 {
                    vertices.append(quantized)
                    // The count after the append is the vertex's place plus one.
                    slots[slot] = UInt32(vertices.count)
                    mergedIndices.append(UInt32(vertices.count - 1))
                    break
                }
                if Key(vertices[Int(held) - 1]) == key {
                    mergedIndices.append(held - 1)
                    break
                }
                slot = (slot + 1) & mask
            }
        }
        for index in mesh.indices {
            indices.append(mergedIndices[Int(index)])
        }
    }
}
