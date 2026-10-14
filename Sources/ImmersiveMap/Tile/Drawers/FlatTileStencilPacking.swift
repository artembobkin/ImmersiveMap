// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The flat map's tile-priority stencil reference, packed from a source's
/// ring and its zoom (`TileSourceStencilPriority`): the rank of the ring
/// of the slot the source stands in, in the high bits, and the source's
/// zoom, in the low bits, so one greaterEqual test settles both. The ring
/// prepass (`RingStencilRenderSubsystem`) marks every pixel of the ground
/// with the rank of its ring and no zoom before any tile draws, so a
/// source passes on its own ring and on the farther ones and fails on a
/// nearer ring whatever is painted there, and on a ring it passes where a
/// coarser source painted and fails where a finer one did.
///
/// The rings are the frame's bands (`FlatRingBand`) by zoom: consecutive
/// bands of one zoom are one ring, since their tiles are the same tiles,
/// and the nearest ring has the highest rank. The priority's six bits are
/// split by the frame: the ring takes as many as its ranks need, up to
/// three (seven rings, the farther ones sharing the lowest rank), the zoom
/// takes the rest, at least three, as a code relative to the frame's
/// target zoom with 0 kept for "nobody painted": the target zoom and the
/// levels below it take the top code, the levels above it the codes down
/// to 1, and anything coarser shares 1.
struct FlatTileStencilPacking: Equatable {
    /// One ring: its zoom, its rank (the nearest ring's the highest, the
    /// farthest 1) and its last band's distance in rings of target tiles.
    struct Ring: Equatable {
        let zoom: Int
        let rank: UInt32
        let distance: Int
    }

    /// The rings, nearest first.
    let rings: [Ring]
    let targetZoom: Int
    /// The bits the zoom code takes: a ring's rank sits above them.
    let zoomBits: Int

    static let priorityBits = 6
    static let maximumRingBits = 3

    init(bands: [FlatRingBand], targetZoom: Int) {
        var rings: [Ring] = []
        for band in bands {
            if let last = rings.last, last.zoom == band.zoom {
                rings[rings.count - 1] = Ring(zoom: band.zoom, rank: 0, distance: band.distance)
            } else {
                rings.append(Ring(zoom: band.zoom, rank: 0, distance: band.distance))
            }
        }
        let ringCount = min(rings.count, (1 << Self.maximumRingBits) - 1)
        self.rings = rings.enumerated().map { index, ring in
            Ring(zoom: ring.zoom, rank: UInt32(max(ringCount - index, 1)), distance: ring.distance)
        }
        self.targetZoom = targetZoom
        let ringBits = max(1, UInt32.bitWidth - UInt32(ringCount).leadingZeroBitCount)
        self.zoomBits = Self.priorityBits - min(ringBits, Self.maximumRingBits)
    }

    /// The highest zoom code: the target zoom's and every finer source's.
    var maximumZoomCode: UInt32 { (1 << UInt32(zoomBits)) - 1 }

    /// The rank of the ring of a slot of `slotZoom`. A zoom no band has
    /// (none should be) takes the nearest ring's, so nothing of such a
    /// source is left out.
    func rank(slotZoom: Int) -> UInt32 {
        rings.first { $0.zoom == slotZoom }?.rank ?? rings.first?.rank ?? 0
    }

    /// The zoom's code: relative to the target zoom, never 0.
    func zoomCode(sourceZoom: Int) -> UInt32 {
        let top = Int(maximumZoomCode)
        return UInt32(min(max(sourceZoom - targetZoom + top, 1), top))
    }

    /// The stencil reference of a source of `sourceZoom` drawn for a slot
    /// of `slotZoom`: a source standing in several slots takes the
    /// nearest ring among them, so it draws in every slot it stands in.
    func reference(sourceZoom: Int, slotZoom: Int) -> UInt32 {
        (rank(slotZoom: slotZoom) << UInt32(zoomBits)) | zoomCode(sourceZoom: sourceZoom)
    }

    /// The mark the prepass writes over a ring's ground: its rank and no
    /// zoom, so every source of the ring passes over it.
    func ringMark(_ ring: Ring) -> UInt32 {
        ring.rank << UInt32(zoomBits)
    }
}
