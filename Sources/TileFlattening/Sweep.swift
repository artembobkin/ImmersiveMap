// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// A non-horizontal part of an input edge, clipped to one strip and to the vertical bounds.
struct EdgePiece {
    var xTop: Double
    var yTop: Double
    var xBot: Double
    var yBot: Double
    /// Slope of the original edge, more accurate than the slope of a short clipped part.
    var dxdy: Double
    var paint: UInt16
    /// +1 when the original edge goes down, -1 when it goes up.
    var dir: Int16
}

/// A change of the winding number on the left wall of a strip, caused by geometry to the left of it.
/// It applies to everything below `y`.
struct WallEvent {
    var y: Double
    var paint: UInt16
    var delta: Int16
}

/// One finished color region: a polygon that is monotone in y, with a horizontal top and bottom.
///
/// Layout in `polyData` from `offset`: the x of the top points (left to right), the x of the bottom
/// points (left to right), then the intermediate points of the left side and of the right side as
/// (x, y) pairs from top to bottom. A side that runs along a strip wall stores no intermediate
/// points: they are generated later from the marks shared with the neighbour strip.
struct PolyHeader {
    static let leftOnWall: UInt8 = 1
    static let rightOnWall: UInt8 = 2

    var color: UInt32
    var flags: UInt8
    var yTop: Double
    var yBot: Double
    var offset: Int32
    var topCount: Int32
    var bottomCount: Int32
    var leftCount: Int32
    var rightCount: Int32
}

/// A growable array of plain values without the uniqueness and bounds checks of `Array`.
/// The sweep touches its scratch lists many times per event, and those checks dominate otherwise.
/// The owner must call `deallocate`.
struct UnsafeList<Element> {
    private var storage: UnsafeMutablePointer<Element>?
    private(set) var count = 0
    private var capacity = 0

    @inline(__always)
    var base: UnsafeMutablePointer<Element> { storage.unsafelyUnwrapped }

    @inline(__always)
    subscript(index: Int) -> Element {
        get { storage.unsafelyUnwrapped[index] }
        nonmutating set { storage.unsafelyUnwrapped[index] = newValue }
    }

    @inline(__always)
    mutating func append(_ element: Element) {
        if count == capacity { grow() }
        (storage.unsafelyUnwrapped + count).initialize(to: element)
        count += 1
    }

    @inline(__always)
    mutating func removeAll() {
        count = 0
    }

    @inline(__always)
    mutating func truncate(to newCount: Int) {
        count = newCount
    }

    @inline(never)
    private mutating func grow() {
        let newCapacity = max(64, capacity * 2)
        let newStorage = UnsafeMutablePointer<Element>.allocate(capacity: newCapacity)
        if let storage {
            newStorage.moveInitialize(from: storage, count: count)
            storage.deallocate()
        }
        storage = newStorage
        capacity = newCapacity
    }

    mutating func deallocate() {
        storage?.deallocate()
        storage = nil
        count = 0
        capacity = 0
    }
}

/// Sweeps one vertical strip from top to bottom and cuts it into colored monotone polygons.
///
/// Between two consecutive events the active edges do not cross, so they split the beam into
/// trapezoids. Walking the edges from left to right and keeping a winding number per paint gives
/// the visible color of each trapezoid. A trapezoid with the same color and the same sides as the
/// one above it extends that one, so a region is only cut where its own outline changes.
struct Sweep {
    /// Points closer than this are treated as the same point.
    static let epsX = 1e-5
    /// Crossings closer than this to a beam border are not cut out.
    static let epsY = 1e-9

    /// An edge piece that crosses the current beam.
    struct ActiveEdge {
        var xTop: Double
        var yTop: Double
        var xBot: Double
        var yBot: Double
        var dxdy: Double
        /// x at the top and at the bottom of the current beam.
        var xa: Double
        var xb: Double
        var index: Int32
        var paint: UInt16
        var dir: Int16

        @inline(__always)
        func x(at y: Double) -> Double {
            if y >= yBot { return xBot }
            let x = xTop + (y - yTop) * dxdy
            return xTop < xBot ? min(max(x, xTop), xBot) : min(max(x, xBot), xTop)
        }
    }

    /// A visible edge, or a group of coinciding edges, between two colors in the current beam.
    struct Boundary {
        /// x at the top and at the bottom of the beam.
        var x: Double
        var xEnd: Double
        /// Smallest and largest piece index of the group. -1 is the left wall, -2 the right wall.
        var idLo: Int32
        var idHi: Int32
        /// Color to the right of the boundary. 0 is nothing.
        var color: UInt32
        /// Open span to the right of the boundary, or a negative state.
        var span: Int32
        var node: Int32
    }

    static let spanNone: Int32 = -1
    static let spanContinued: Int32 = -2
    static let spanToOpen: Int32 = -3

    /// A distinct point on the horizontal line of the current event.
    struct Node {
        var x: Double
        var lastP: Int32
        var lastC: Int32
        var countP: Int32
        var countC: Int32
        /// A marked node becomes a vertex of every region that touches it.
        var marked: Bool
    }

    struct OpenSpan {
        var color: UInt32
        var flags: UInt8
        var yTop: Double
        var topStart: Int32
        var topCount: Int32
        var leftHead: Int32
        var leftTail: Int32
        var leftCount: Int32
        var rightHead: Int32
        var rightTail: Int32
        var rightCount: Int32
    }

    struct ChainPoint {
        var x: Double
        var y: Double
        var next: Int32
    }

    // Input.
    var pieces: [EdgePiece]
    var wallEvents: [WallEvent]
    let wallL: Double
    let wallR: Double
    let minY: Double
    let maxY: Double
    let rowYs: [Double]
    let paints: [FlatColor]

    // Output.
    var polys: [PolyHeader] = []
    var polyData: [Double] = []
    /// Heights at which this strip has a vertex on its left and right wall, ascending.
    var leftMarks: [Double] = []
    var rightMarks: [Double] = []

    // Scratch, allocated only while `run` executes.
    private var paintColor = UnsafeList<UInt32>()
    private var paintOpaque = UnsafeList<Bool>()
    private var counts = UnsafeList<Int32>()
    private var mask = UnsafeList<UInt64>()
    private var active = UnsafeList<ActiveEdge>()
    private var previous = UnsafeList<Boundary>()
    private var current = UnsafeList<Boundary>()
    private var nodes = UnsafeList<Node>()
    private var spans = UnsafeList<OpenSpan>()
    private var freeSpans = UnsafeList<Int32>()
    private var chain = UnsafeList<ChainPoint>()
    private var topPool = UnsafeList<Double>()

    init(
        pieces: [EdgePiece],
        wallEvents: [WallEvent],
        wallL: Double,
        wallR: Double,
        minY: Double,
        maxY: Double,
        rowYs: [Double],
        paints: [FlatColor]
    ) {
        self.pieces = pieces
        self.wallEvents = wallEvents
        self.wallL = wallL
        self.wallR = wallR
        self.minY = minY
        self.maxY = maxY
        self.rowYs = rowYs
        self.paints = paints
    }

    private mutating func releaseScratch() {
        paintColor.deallocate()
        paintOpaque.deallocate()
        counts.deallocate()
        mask.deallocate()
        active.deallocate()
        previous.deallocate()
        current.deallocate()
        nodes.deallocate()
        spans.deallocate()
        freeSpans.deallocate()
        chain.deallocate()
        topPool.deallocate()
    }

    // MARK: Winding

    @inline(__always)
    private func addWinding(paint: UInt16, delta: Int32) {
        let p = Int(paint)
        let old = counts[p]
        let new = old + delta
        counts[p] = new
        if old == 0 {
            mask[p >> 6] |= 1 << UInt64(p & 63)
        } else if new == 0 {
            mask[p >> 6] &= ~(1 << UInt64(p & 63))
        }
    }

    /// The color seen from above for the current set of covering paints.
    @inline(__always)
    private func visibleColor() -> UInt32 {
        var w = mask.count - 1
        while w >= 0 {
            let bits = mask[w]
            if bits != 0 {
                let top = w * 64 + 63 - bits.leadingZeroBitCount
                if paintOpaque[top] { return paintColor[top] }
                return blendedColor(from: top)
            }
            w -= 1
        }
        return 0
    }

    /// Composites translucent paints over whatever lies below them.
    @inline(never)
    private func blendedColor(from top: Int) -> UInt32 {
        // Find the topmost opaque paint below. Nothing under it is visible.
        var bottom = top
        var p = top - 1
        while p >= 0 {
            if mask[p >> 6] & (1 << UInt64(p & 63)) != 0 {
                bottom = p
                if paintOpaque[p] { break }
            }
            p -= 1
        }
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0
        for p in bottom...top where mask[p >> 6] & (1 << UInt64(p & 63)) != 0 {
            let c = FlatColor(packed: paintColor[p])
            let sa = Double(c.a) / 255
            let outA = sa + a * (1 - sa)
            if outA > 0 {
                r = (Double(c.r) * sa + r * a * (1 - sa)) / outA
                g = (Double(c.g) * sa + g * a * (1 - sa)) / outA
                b = (Double(c.b) * sa + b * a * (1 - sa)) / outA
            }
            a = outA
        }
        let alpha = UInt8((a * 255).rounded())
        if alpha == 0 { return 0 }
        return FlatColor(r: UInt8(r.rounded()), g: UInt8(g.rounded()), b: UInt8(b.rounded()), a: alpha).packed
    }

    // MARK: Sweep

    mutating func run() {
        pieces.sort { $0.yTop < $1.yTop }
        wallEvents.sort { $0.y < $1.y }
        polys.reserveCapacity(pieces.count)
        polyData.reserveCapacity(pieces.count * 6)
        for paint in paints {
            paintColor.append(paint.packed)
            paintOpaque.append(paint.a == 255)
            counts.append(0)
        }
        for _ in 0..<max(1, (paints.count + 63) / 64) { mask.append(0) }
        defer { releaseScratch() }

        let pieceCount = pieces.count
        let wallCount = wallEvents.count
        let rowCount = rowYs.count
        var nextPiece = 0
        var nextWall = 0
        var nextRow = 0
        var y = minY
        var forced = false

        while nextRow < rowCount && rowYs[nextRow] <= y { nextRow += 1 }

        while y < maxY {
            // Events at y: winding changes on the left wall, edges that end and edges that start.
            while nextWall < wallCount && wallEvents[nextWall].y <= y {
                addWinding(paint: wallEvents[nextWall].paint, delta: Int32(wallEvents[nextWall].delta))
                nextWall += 1
            }
            var yNext = maxY
            var kept = 0
            for k in 0..<active.count {
                let yBot = active[k].yBot
                if yBot > y {
                    if kept != k { active[kept] = active[k] }
                    kept += 1
                    if yBot < yNext { yNext = yBot }
                }
            }
            active.truncate(to: kept)
            while nextPiece < pieceCount && pieces[nextPiece].yTop <= y {
                let piece = pieces[nextPiece]
                if piece.yBot > y {
                    active.append(ActiveEdge(
                        xTop: piece.xTop, yTop: piece.yTop, xBot: piece.xBot, yBot: piece.yBot, dxdy: piece.dxdy,
                        xa: piece.xTop, xb: piece.xTop, index: Int32(nextPiece), paint: piece.paint, dir: piece.dir
                    ))
                    if piece.yBot < yNext { yNext = piece.yBot }
                }
                nextPiece += 1
            }
            if nextRow < rowCount && rowYs[nextRow] < yNext { yNext = rowYs[nextRow] }
            if nextPiece < pieceCount && pieces[nextPiece].yTop < yNext { yNext = pieces[nextPiece].yTop }
            if nextWall < wallCount && wallEvents[nextWall].y < yNext { yNext = wallEvents[nextWall].y }

            yNext = orderActiveEdges(from: y, to: yNext)
            buildBoundaries()
            connect(at: y, forced: forced)
            swap(&previous, &current)

            y = yNext
            forced = false
            while nextRow < rowCount && rowYs[nextRow] <= y {
                forced = true
                nextRow += 1
            }
        }

        current.removeAll()
        connect(at: maxY, forced: true)
    }

    /// Sorts the active edges from left to right for the beam that starts at `y`, and shortens the
    /// beam to the first crossing inside it. Returns the bottom of the beam.
    private func orderActiveEdges(from y: Double, to limit: Double) -> Double {
        let n = active.count
        if n == 0 { return limit }
        let edges = active.base
        // Edges are ordered by their position at the top of the beam. Edges that start from the
        // same point (a vertex, or a crossing that ended the beam above) are ordered by slope,
        // which is their order just below that point. The list is nearly sorted already.
        if n > 1 {
            for k in 1..<n {
                // Most edges are in place already: look before moving anything.
                let d = edges[k].xa - edges[k - 1].xa
                if !(d < -Sweep.epsX || (d <= Sweep.epsX && edges[k].dxdy < edges[k - 1].dxdy)) { continue }
                let key = edges[k]
                edges[k] = edges[k - 1]
                var j = k - 2
                while j >= 0 {
                    let d = key.xa - edges[j].xa
                    if d < -Sweep.epsX || (d <= Sweep.epsX && key.dxdy < edges[j].dxdy) {
                        edges[j + 1] = edges[j]
                        j -= 1
                    } else {
                        break
                    }
                }
                edges[j + 1] = key
            }
        }
        var yNext = limit
        for k in 0..<n { edges[k].xb = edges[k].x(at: yNext) }
        // Neighbours that are swapped at the bottom cross inside the beam. The first crossing in
        // the beam is always between neighbours, so the smallest one found here is the first.
        var cut = yNext
        if n > 1 {
            for k in 0..<(n - 1) {
                let db = edges[k].xb - edges[k + 1].xb
                if db > Sweep.epsX {
                    let da = edges[k].xa - edges[k + 1].xa
                    if da < 0 {
                        let yCross = y + da / (da - db) * (yNext - y)
                        if yCross > y + Sweep.epsY && yCross < yNext - Sweep.epsY && yCross < cut {
                            cut = yCross
                        }
                    }
                }
            }
        }
        if cut < yNext {
            yNext = cut
            for k in 0..<n { edges[k].xb = edges[k].x(at: yNext) }
        }
        return yNext
    }

    /// Walks the ordered edges and keeps the ones where the visible color changes.
    /// Also moves every edge on to the bottom of the beam.
    private mutating func buildBoundaries() {
        current.removeAll()
        let n = active.count
        // The left wall starts the first group. Its winding comes from the wall events.
        var groupA = wallL
        var groupB = wallL
        var idLo: Int32 = -1
        var idHi: Int32 = -1
        var isWall = true
        var lastColor: UInt32 = 0
        // Rounding noise must not make positions decrease from left to right.
        var lastA = wallL
        var lastB = wallL

        for k in 0..<n {
            let edge = active.base + k
            lastA = min(max(edge.pointee.xa, lastA), wallR)
            lastB = min(max(edge.pointee.xb, lastB), wallR)
            // The edge has reached the bottom of this beam, which is the top of the next one.
            edge.pointee.xa = edge.pointee.xb
            let index = edge.pointee.index
            if abs(lastA - groupA) <= Sweep.epsX && abs(lastB - groupB) <= Sweep.epsX {
                if !isWall {
                    idLo = min(idLo, index)
                    idHi = max(idHi, index)
                }
            } else {
                let color = visibleColor()
                if isWall || color != lastColor {
                    current.append(Boundary(x: groupA, xEnd: groupB, idLo: idLo, idHi: idHi, color: color, span: Sweep.spanNone, node: -1))
                    lastColor = color
                }
                isWall = false
                groupA = lastA
                groupB = lastB
                idLo = index
                idHi = index
            }
            addWinding(paint: edge.pointee.paint, delta: Int32(edge.pointee.dir))
        }
        let color = visibleColor()
        if isWall || color != lastColor {
            current.append(Boundary(x: groupA, xEnd: groupB, idLo: idLo, idHi: idHi, color: color, span: Sweep.spanNone, node: -1))
        }
        // The right wall ends the strip. Edges lying on it are part of it.
        let rightWall = Boundary(x: wallR, xEnd: wallR, idLo: -2, idHi: -2, color: 0, span: Sweep.spanNone, node: -1)
        let last = current.count - 1
        if last > 0 && abs(current[last].x - wallR) <= Sweep.epsX && abs(current[last].xEnd - wallR) <= Sweep.epsX {
            current[last] = rightWall
        } else {
            current.append(rightWall)
        }

        if n > 0 {
            let edges = active.base
            for k in 0..<n {
                addWinding(paint: edges[k].paint, delta: -Int32(edges[k].dir))
            }
        }
    }

    /// Connects the beam that ends at `y` (`previous`) with the beam that starts there (`current`):
    /// regions whose color and sides carry on are extended, the others are closed and new ones opened.
    /// With `forced` every region is closed, which produces a horizontal grid line.
    private mutating func connect(at y: Double, forced: Bool) {
        let nP = previous.count
        let nC = current.count
        let previous = self.previous
        let current = self.current

        // Merge the positions of both beams into one list of nodes, so that the regions above and
        // below the line share exactly the same points.
        nodes.removeAll()
        var i = 0
        var j = 0
        var lastX = -Double.infinity
        while i < nP || j < nC {
            let fromPrevious: Bool
            if j >= nC {
                fromPrevious = true
            } else if i >= nP {
                fromPrevious = false
            } else {
                fromPrevious = previous[i].xEnd <= current[j].x
            }
            let x = fromPrevious ? previous[i].xEnd : current[j].x
            if x > lastX + Sweep.epsX {
                nodes.append(Node(x: x, lastP: -1, lastC: -1, countP: 0, countC: 0, marked: forced))
                lastX = x
            }
            let node = nodes.count - 1
            if fromPrevious {
                previous.base[i].node = Int32(node)
                nodes.base[node].lastP = Int32(i)
                nodes.base[node].countP += 1
                i += 1
            } else {
                current.base[j].node = Int32(node)
                nodes.base[node].lastC = Int32(j)
                nodes.base[node].countC += 1
                j += 1
            }
        }
        let nodeCount = nodes.count
        if nodeCount == 0 { return }
        let nodes = self.nodes.base

        // A node where the outline does not simply pass through along one edge is a vertex.
        if !forced {
            for n in 0..<nodeCount {
                let node = nodes[n]
                if node.countP != 1 || node.countC != 1 {
                    nodes[n].marked = true
                } else {
                    let p = previous[Int(node.lastP)]
                    let c = current[Int(node.lastC)]
                    if p.idLo != c.idLo || p.idHi != c.idHi { nodes[n].marked = true }
                }
            }
        }

        // Decide which regions carry on. The ends of every region that closes or opens become
        // vertices, also for the neighbours that carry on past them.
        if nC > 1 {
            let current = current.base
            for j in 0..<(nC - 1) {
                let color = current[j].color
                if color == 0 { continue }
                let left = Int(current[j].node)
                let right = Int(current[j + 1].node)
                if left == right {
                    // Zero width at the top. Skip it when it is zero at the bottom too.
                    if current[j + 1].xEnd - current[j].xEnd <= Sweep.epsX { continue }
                    current[j].span = Sweep.spanToOpen
                    nodes[left].marked = true
                    continue
                }
                var continued = false
                if !forced {
                    let i = Int(nodes[left].lastP)
                    // A side on a strip wall must stay on the wall for the whole region.
                    if i >= 0 && i + 1 < nP
                        && Int(previous[i + 1].node) == right
                        && previous[i].span >= 0
                        && previous[i].color == color
                        && (i == 0) == (j == 0)
                        && (i + 1 == nP - 1) == (j + 1 == nC - 1) {
                        current[j].span = previous[i].span
                        previous.base[i].span = Sweep.spanContinued
                        continued = true
                    }
                }
                if !continued {
                    current[j].span = Sweep.spanToOpen
                    nodes[left].marked = true
                    nodes[right].marked = true
                }
            }
        }
        if nP > 1 {
            for i in 0..<(nP - 1) where previous[i].span >= 0 {
                nodes[Int(previous[i].node)].marked = true
                nodes[Int(previous[i + 1].node)].marked = true
            }
            for i in 0..<(nP - 1) where previous[i].span >= 0 {
                closeSpan(previous[i].span, from: Int(previous[i].node), to: Int(previous[i + 1].node), y: y)
            }
        }
        if nC > 1 {
            let current = current.base
            for j in 0..<(nC - 1) {
                let span = current[j].span
                let left = Int(current[j].node)
                let right = Int(current[j + 1].node)
                if span >= 0 {
                    let s = spans.base + Int(span)
                    if nodes[left].marked && s.pointee.flags & PolyHeader.leftOnWall == 0 {
                        chain.append(ChainPoint(x: nodes[left].x, y: y, next: -1))
                        let point = Int32(chain.count - 1)
                        if s.pointee.leftTail >= 0 { chain.base[Int(s.pointee.leftTail)].next = point } else { s.pointee.leftHead = point }
                        s.pointee.leftTail = point
                        s.pointee.leftCount += 1
                    }
                    if nodes[right].marked && s.pointee.flags & PolyHeader.rightOnWall == 0 {
                        chain.append(ChainPoint(x: nodes[right].x, y: y, next: -1))
                        let point = Int32(chain.count - 1)
                        if s.pointee.rightTail >= 0 { chain.base[Int(s.pointee.rightTail)].next = point } else { s.pointee.rightHead = point }
                        s.pointee.rightTail = point
                        s.pointee.rightCount += 1
                    }
                } else if span == Sweep.spanToOpen {
                    var flags: UInt8 = 0
                    if j == 0 { flags |= PolyHeader.leftOnWall }
                    if j + 1 == nC - 1 { flags |= PolyHeader.rightOnWall }
                    current[j].span = openSpan(color: current[j].color, flags: flags, from: left, to: right, y: y)
                }
            }
        }

        if nodes[0].marked { leftMarks.append(y) }
        if nodes[nodeCount - 1].marked { rightMarks.append(y) }
    }

    private mutating func openSpan(color: UInt32, flags: UInt8, from: Int, to: Int, y: Double) -> Int32 {
        let topStart = Int32(topPool.count)
        for n in from...to { topPool.append(nodes[n].x) }
        let span = OpenSpan(
            color: color, flags: flags, yTop: y,
            topStart: topStart, topCount: Int32(to - from + 1),
            leftHead: -1, leftTail: -1, leftCount: 0,
            rightHead: -1, rightTail: -1, rightCount: 0
        )
        if freeSpans.count > 0 {
            let free = freeSpans[freeSpans.count - 1]
            freeSpans.truncate(to: freeSpans.count - 1)
            spans[Int(free)] = span
            return free
        }
        spans.append(span)
        return Int32(spans.count - 1)
    }

    private mutating func closeSpan(_ index: Int32, from: Int, to: Int, y: Double) {
        let span = spans[Int(index)]
        freeSpans.append(index)
        let bottomCount = to - from + 1
        // A region that starts and ends in a single point with straight sides has no area.
        if span.topCount == 1 && bottomCount == 1 && span.leftCount == 0 && span.rightCount == 0 {
            return
        }
        let offset = polyData.count
        let topStart = Int(span.topStart)
        for k in 0..<Int(span.topCount) { polyData.append(topPool[topStart + k]) }
        for n in from...to { polyData.append(nodes[n].x) }
        var point = span.leftHead
        while point >= 0 {
            polyData.append(chain[Int(point)].x)
            polyData.append(chain[Int(point)].y)
            point = chain[Int(point)].next
        }
        point = span.rightHead
        while point >= 0 {
            polyData.append(chain[Int(point)].x)
            polyData.append(chain[Int(point)].y)
            point = chain[Int(point)].next
        }
        polys.append(PolyHeader(
            color: span.color, flags: span.flags, yTop: span.yTop, yBot: y,
            offset: Int32(offset), topCount: span.topCount, bottomCount: Int32(bottomCount),
            leftCount: span.leftCount, rightCount: span.rightCount
        ))
    }
}
