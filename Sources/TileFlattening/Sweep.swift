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
/// (x, y, wall) triples from top to bottom. A side runs along a strip wall from the top when the
/// header's flag says so, and from a point whose `wall` is 1 to the next point. Such a stretch
/// stores no intermediate points: they are generated later from the marks shared with the
/// neighbour strip.
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
///
/// The hot members are `@_transparent`, which the compiler inlines even without optimization:
/// the list is generic, and a debug build neither specializes nor inlines a generic call, so
/// every element access was a call into unspecialized code that looked the pointer type's
/// metadata up in the runtime's cache, most of a debug build's parse. Inlined into the sweep,
/// the access is concrete. `!` is lowered by the compiler where `unsafelyUnwrapped` is a call.
struct UnsafeList<Element> {
    private var storage: UnsafeMutablePointer<Element>?
    private(set) var count = 0
    private var capacity = 0

    @_transparent
    var base: UnsafeMutablePointer<Element> { storage! }

    subscript(index: Int) -> Element {
        @_transparent get { storage![index] }
        @_transparent nonmutating set { storage![index] = newValue }
    }

    @_transparent
    mutating func append(_ element: Element) {
        if count == capacity { grow() }
        (storage! + count).initialize(to: element)
        count += 1
    }

    @_transparent
    mutating func removeAll() {
        count = 0
    }

    @_transparent
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

/// The integers from `lowerBound` up to, not including, `upperBound`, as a loop walks them.
/// A `for` over `Range<Int>` goes through the standard library's generic iterator, which a
/// debug build neither specializes nor inlines: every step was a witness-table call and a
/// metadata lookup. This sequence is concrete and its members are `@_transparent`, so a debug
/// build compiles the loop to a counter, as an optimized build does for a `Range`.
struct IndexRange: Sequence, IteratorProtocol {
    @usableFromInline var current: Int
    @usableFromInline let upperBound: Int

    /// `lower..<upper`. Empty when `upper <= lower`, where `Range` would trap.
    @_transparent
    init(_ lower: Int, _ upper: Int) {
        current = lower
        upperBound = upper
    }

    /// `lower...upper`.
    @_transparent
    init(_ lower: Int, through upper: Int) {
        current = lower
        upperBound = upper + 1
    }

    @_transparent
    func makeIterator() -> IndexRange { self }

    @_transparent
    mutating func next() -> Int? {
        if current >= upperBound { return nil }
        defer { current += 1 }
        return current
    }
}

/// Sweeps one vertical strip from top to bottom and cuts it into colored monotone polygons.
///
/// Between two consecutive events the active edges do not cross, so they split the beam into
/// trapezoids. Walking the edges from left to right and keeping a winding number per paint gives
/// the visible color of each trapezoid. A trapezoid with the same color as the one above it
/// extends that one, so a region is only cut where its own outline changes, and where it changes
/// the cut is a diagonal between two vertices of the outline (`connect`). The mesh then has no
/// vertex that the outlines, the crossings of the outlines and the grid do not have.
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
        /// Two regions of one color that met from above at a vertex (`meetX`, `meetY`) go on as one
        /// region below it. Both stay open: this span is the left part and `partner` the right part,
        /// and the first vertex of the outline below the meeting point gets a diagonal from it, which
        /// settles where one part ends. -1 for a region in one piece.
        var partner: Int32
        var meetX: Double
        var meetY: Double
    }

    /// The spans of one color that meet at the current event line: the previous spans that end or
    /// carry on there and the current spans that start or carry on, as far as they overlap.
    struct Component {
        @_transparent static var fallback: UInt8 { 0 }
        @_transparent static var continuation: UInt8 { 1 }
        @_transparent static var split: UInt8 { 2 }
        @_transparent static var merge: UInt8 { 3 }

        var color: UInt32
        var firstPrev: Int32
        var lastPrev: Int32
        var firstCur: Int32
        var lastCur: Int32
        var prevCount: Int32
        var curCount: Int32
        var kind: UInt8
    }

    struct ChainPoint {
        var x: Double
        var y: Double
        var next: Int32
        /// The side runs along the strip wall from this point to the next one (or to the bottom).
        /// The wall's vertices are only known at the end, from both strips, and the triangulator
        /// puts them in then.
        var wallAfter: Bool
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
    private var components = UnsafeList<Component>()
    private var previousInComponent = UnsafeList<Bool>()

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
        components.deallocate()
        previousInComponent.deallocate()
    }

    // MARK: Winding

    @inline(__always)
    private mutating func addWinding(paint: UInt16, delta: Int32) {
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
    private mutating func visibleColor() -> UInt32 {
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
    private mutating func blendedColor(from top: Int) -> UInt32 {
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
        for p in IndexRange(bottom, through: top) where mask[p >> 6] & (1 << UInt64(p & 63)) != 0 {
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
        for _ in IndexRange(0, max(1, (paints.count + 63) / 64)) { mask.append(0) }
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
            for k in IndexRange(0, active.count) {
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
    private mutating func orderActiveEdges(from y: Double, to limit: Double) -> Double {
        let n = active.count
        if n == 0 { return limit }
        let edges = active.base
        // Edges are ordered by their position at the top of the beam. Edges that start from the
        // same point (a vertex, or a crossing that ended the beam above) are ordered by slope,
        // which is their order just below that point. The list is nearly sorted already.
        if n > 1 {
            for k in IndexRange(1, n) {
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
        for k in IndexRange(0, n) { edges[k].xb = edges[k].x(at: yNext) }
        // Neighbours that are swapped at the bottom cross inside the beam. The first crossing in
        // the beam is always between neighbours, so the smallest one found here is the first.
        var cut = yNext
        if n > 1 {
            for k in IndexRange(0, n - 1) {
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
            for k in IndexRange(0, n) { edges[k].xb = edges[k].x(at: yNext) }
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

        for k in IndexRange(0, n) {
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
            for k in IndexRange(0, n) {
                addWinding(paint: edges[k].paint, delta: -Int32(edges[k].dir))
            }
        }
    }


    /// Connects the beam that ends at `y` (`previous`) with the beam that starts there (`current`):
    /// regions whose color and sides carry on are extended, the others are closed and new ones opened.
    /// With `forced` every region is closed, which produces a horizontal grid line.
    ///
    /// A region is only cut where its own outline makes it. Where a region of another color starts
    /// inside it, diagonals from its lowest vertex reach around the start (`splitComponent`), and where
    /// two regions of one color meet below a region that ends between them, both stay open as the two
    /// parts of one region until the next vertex of its outline, which a diagonal from the meeting
    /// point reaches (`mergeComponent`). Closing the neighbours of such a vertex with a horizontal
    /// cut would put a vertex on every edge level with it, and those vertices were most of the mesh.
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

        // A region that starts at a point opens from it. One that is a point at the bottom of its
        // first beam too is nothing. With `forced` every other region opens too.
        if nC > 1 {
            for j in IndexRange(0, nC - 1) where current[j].color != 0 {
                if current[j].node == current[j + 1].node {
                    if current[j + 1].xEnd - current[j].xEnd <= Sweep.epsX { continue }
                    current.base[j].span = Sweep.spanToOpen
                    nodes[Int(current[j].node)].marked = true
                } else if forced {
                    current.base[j].span = Sweep.spanToOpen
                }
            }
        }
        if !forced {
            // A node where the outline does not simply pass through along one edge is a vertex.
            for n in IndexRange(0, nodeCount) {
                let node = nodes[n]
                if node.countP != 1 || node.countC != 1 {
                    nodes[n].marked = true
                } else {
                    let p = previous[Int(node.lastP)]
                    let c = current[Int(node.lastC)]
                    if p.idLo != c.idLo || p.idHi != c.idHi { nodes[n].marked = true }
                }
            }
            connectComponents(at: y)
        }

        // The regions that end here: with `forced` all of them, otherwise the ones no region below
        // carries on. Their ends are vertices already.
        if nP > 1 {
            for i in IndexRange(0, nP - 1) where previous[i].span >= 0 {
                closeSpan(previous[i].span, from: Int(previous[i].node), to: Int(previous[i + 1].node), y: y)
            }
        }
        // The regions that start here.
        if nC > 1 {
            for j in IndexRange(0, nC - 1) where current[j].span == Sweep.spanToOpen {
                var flags: UInt8 = 0
                if j == 0 { flags |= PolyHeader.leftOnWall }
                if j + 1 == nC - 1 { flags |= PolyHeader.rightOnWall }
                current.base[j].span = openSpan(color: current[j].color, flags: flags, from: Int(current[j].node), to: Int(current[j + 1].node), y: y)
            }
        }

        if nodes[0].marked { leftMarks.append(y) }
        if nodes[nodeCount - 1].marked { rightMarks.append(y) }
    }

    // MARK: Components

    /// Groups the spans of one color that overlap across the event line into components, decides for
    /// each how its regions carry on, and carries them on.
    ///
    /// A span that carries on keeps its index in `current[j].span`. A current span that opens is
    /// left at `spanToOpen` and a previous span that closes keeps its index, for `connect` to finish.
    private mutating func connectComponents(at y: Double) {
        let nP = previous.count
        let nC = current.count
        let previous = self.previous
        let current = self.current
        let nodes = self.nodes.base
        components.removeAll()
        previousInComponent.removeAll()
        for _ in IndexRange(0, nP) { previousInComponent.append(false) }

        // The previous spans of a current span's color under it are its component, and a previous
        // span under two current spans joins their components.
        var i = 0
        if nC > 1 {
            for j in IndexRange(0, nC - 1) {
                let color = current[j].color
                if color == 0 { continue }
                let cl = Int(current[j].node)
                let cr = Int(current[j + 1].node)
                if cl == cr { continue }
                while i < nP - 1 && Int(previous[i + 1].node) <= cl { i += 1 }
                var first = -1
                var last = -1
                var count: Int32 = 0
                var k = i
                while k < nP - 1 && Int(previous[k].node) < cr {
                    // A span that ends in a point carries nothing on.
                    if previous[k].span >= 0 && previous[k].color == color && previous[k].node != previous[k + 1].node {
                        if first < 0 { first = k }
                        last = k
                        count += 1
                    }
                    k += 1
                }
                if first < 0 {
                    current.base[j].span = Sweep.spanToOpen
                    continue
                }
                for i in IndexRange(first, through: last) where previous[i].color == color { previousInComponent[i] = true }
                let n = components.count
                if n > 0 && components[n - 1].color == color && Int(components[n - 1].lastPrev) == first {
                    components[n - 1].lastCur = Int32(j)
                    components[n - 1].curCount += 1
                    components[n - 1].lastPrev = Int32(last)
                    components[n - 1].prevCount += count - 1
                } else {
                    components.append(Component(
                        color: color, firstPrev: Int32(first), lastPrev: Int32(last),
                        firstCur: Int32(j), lastCur: Int32(j), prevCount: count, curCount: 1, kind: Component.fallback
                    ))
                }
            }
        }

        // The ends of a span that opens or closes on its own are vertices.
        if nP > 1 {
            for i in IndexRange(0, nP - 1) where previous[i].span >= 0 {
                if !previousInComponent[i] {
                    nodes[Int(previous[i].node)].marked = true
                    nodes[Int(previous[i + 1].node)].marked = true
                }
            }
        }
        if nC > 1 {
            for j in IndexRange(0, nC - 1) where current[j].span == Sweep.spanToOpen {
                nodes[Int(current[j].node)].marked = true
                nodes[Int(current[j + 1].node)].marked = true
            }
        }

        // The kind of every component, and the vertices it makes: the ends of the spans a
        // component closes and opens the plain way, and the corners where a side steps along
        // the line. Every other vertex is one already, as the end of a boundary.
        for c in IndexRange(0, components.count) {
            let component = components[c]
            let kind = classify(component)
            components[c].kind = kind
            let pl = Int(previous[nextPrevious(of: component, after: -1)].node)
            let pr = Int(previous[Int(component.lastPrev) + 1].node)
            let cl = Int(current[nextCurrent(of: component, after: -1)].node)
            let cr = Int(current[Int(component.lastCur) + 1].node)
            switch kind {
            case Component.fallback:
                for i in IndexRange(Int(component.firstPrev), through: Int(component.lastPrev))
                where previous[i].span >= 0 && previous[i].color == component.color {
                    nodes[Int(previous[i].node)].marked = true
                    nodes[Int(previous[i + 1].node)].marked = true
                }
                for j in IndexRange(Int(component.firstCur), through: Int(component.lastCur))
                where current[j].color == component.color && current[j].node != current[j + 1].node {
                    nodes[Int(current[j].node)].marked = true
                    nodes[Int(current[j + 1].node)].marked = true
                }
            default:
                if pl != cl {
                    nodes[pl].marked = true
                    nodes[cl].marked = true
                }
                if pr != cr {
                    nodes[pr].marked = true
                    nodes[cr].marked = true
                }
            }
        }

        for c in IndexRange(0, components.count) {
            let component = components[c]
            switch component.kind {
            case Component.continuation:
                continueComponent(component, at: y)
            case Component.split:
                splitComponent(component, at: y)
            case Component.merge:
                mergeComponent(component, at: y)
            default:
                // Closed and opened the plain way by `connect`.
                for j in IndexRange(Int(component.firstCur), through: Int(component.lastCur))
                where current[j].color == component.color && current[j].node != current[j + 1].node {
                    current.base[j].span = Sweep.spanToOpen
                }
            }
        }
    }

    // These helpers are `mutating` although they change nothing: a non-mutating method on `self`
    // in a debug build copies the struct for the call, retaining and releasing each of its arrays,
    // and the empty ones among them share one global object that every strip's thread then
    // fights over.

    /// The previous span of the component after `after` (-1 for the first), or -1.
    private mutating func nextPrevious(of component: Component, after: Int) -> Int {
        var i = after < 0 ? Int(component.firstPrev) : after + 1
        while i <= Int(component.lastPrev) {
            if previous[i].span >= 0 && previous[i].color == component.color { return i }
            i += 1
        }
        return -1
    }

    /// The current span of the component after `after` (-1 for the first), or -1.
    private mutating func nextCurrent(of component: Component, after: Int) -> Int {
        var j = after < 0 ? Int(component.firstCur) : after + 1
        while j <= Int(component.lastCur) {
            if current[j].color == component.color && current[j].node != current[j + 1].node { return j }
            j += 1
        }
        return -1
    }

    private mutating func classify(_ component: Component) -> UInt8 {
        let firstPrev = nextPrevious(of: component, after: -1)
        let lastPrev = Int(component.lastPrev)
        let firstCur = nextCurrent(of: component, after: -1)
        let lastCur = Int(component.lastCur)
        let pl = Int(previous[firstPrev].node)
        let pr = Int(previous[lastPrev + 1].node)
        let cl = Int(current[firstCur].node)
        let cr = Int(current[lastCur + 1].node)
        if component.prevCount == 1 && component.curCount == 1 {
            // The same sides, or both sides stepped right, which both chains can do: a region's
            // left side narrows that way and its right side widens.
            if (pl == cl && pr == cr) || (pl < cl && pr < cr) { return Component.continuation }
            if cl >= pl && cr <= pr { return Component.split }
            if cl <= pl && cr >= pr { return Component.merge }
            return Component.fallback
        }
        if component.prevCount == 1 {
            return cl >= pl && cr <= pr ? Component.split : Component.fallback
        }
        if component.curCount == 1 {
            return cl <= pl && cr >= pr ? Component.merge : Component.fallback
        }
        return Component.fallback
    }

    /// One previous span carries on as one current span with the same sides, or with both sides
    /// stepped to the right along the line.
    private mutating func continueComponent(_ component: Component, at y: Double) {
        let nodes = self.nodes.base
        let i = nextPrevious(of: component, after: -1)
        let j = nextCurrent(of: component, after: -1)
        let pl = Int(previous[i].node)
        let pr = Int(previous[i + 1].node)
        let cl = Int(current[j].node)
        let cr = Int(current[j + 1].node)
        var span = previous[i].span
        let leftWall = j == 0
        let rightWall = j + 1 == current.count - 1
        for n in IndexRange(pl, through: cl) where nodes[n].marked {
            if spans[Int(span)].partner >= 0 {
                span = resolveLeft(span, at: n, y: y, wallAfter: leftWall)
            } else {
                appendLeft(span, x: nodes[n].x, y: y, wallAfter: leftWall)
            }
        }
        for n in IndexRange(pr, through: cr) where nodes[n].marked {
            if spans[Int(span)].partner >= 0 {
                span = resolveRight(span, at: n, y: y, wallAfter: rightWall)
            } else {
                appendRight(span, x: nodes[n].x, y: y, wallAfter: rightWall)
            }
        }
        current.base[j].span = span
        previous.base[i].span = Sweep.spanContinued
    }

    /// One previous span carries on as several current spans with regions of other colors starting
    /// between them, or as one narrower current span.
    ///
    /// The beam of the previous span below its lowest vertex is a trapezoid, so a diagonal from that
    /// vertex reaches every point of the line inside the span. The span is cut by such diagonals
    /// into the parts that carry on, one for each current span, and the fans over the starts
    /// between them. The part on the side of the lowest vertex is the previous span itself, the
    /// part on the other side is a new span that starts at the vertex. When the span is two parts
    /// waiting at a meeting point, that point is the lowest vertex and the parts are the two.
    private mutating func splitComponent(_ component: Component, at y: Double) {
        let nodes = self.nodes.base
        let i = nextPrevious(of: component, after: -1)
        let a = Int(previous[i].node)
        let b = Int(previous[i + 1].node)
        let color = component.color
        let span = previous[i].span
        var left: Int32
        var right: Int32
        let vx: Double
        let vy: Double
        if spans[Int(span)].partner >= 0 {
            left = span
            right = spans[Int(span)].partner
            vx = spans[Int(span)].meetX
            vy = spans[Int(span)].meetY
            spans[Int(span)].partner = -1
        } else {
            // The lowest vertex of the span. The side below it goes to the new span, with the wall
            // if the side runs along one there, and the diagonal takes its place on the old span.
            let open = spans[Int(span)]
            let leftTail = open.leftTail >= 0 ? chain[Int(open.leftTail)] : ChainPoint(x: 0, y: -.infinity, next: -1, wallAfter: false)
            let rightTail = open.rightTail >= 0 ? chain[Int(open.rightTail)] : ChainPoint(x: 0, y: -.infinity, next: -1, wallAfter: false)
            if open.rightTail >= 0 && rightTail.y >= leftTail.y {
                left = span
                vx = rightTail.x
                vy = rightTail.y
                right = openPointSpan(color: color, flags: rightTail.wallAfter ? PolyHeader.rightOnWall : 0, x: vx, y: vy)
                chain[Int(open.rightTail)].wallAfter = false
            } else if open.leftTail >= 0 {
                right = span
                vx = leftTail.x
                vy = leftTail.y
                left = openPointSpan(color: color, flags: leftTail.wallAfter ? PolyHeader.leftOnWall : 0, x: vx, y: vy)
                chain[Int(open.leftTail)].wallAfter = false
            } else {
                // No vertex on either side: the top-right corner.
                left = span
                vx = topPool[Int(open.topStart + open.topCount - 1)]
                vy = open.yTop
                right = openPointSpan(color: color, flags: open.flags & PolyHeader.rightOnWall, x: vx, y: vy)
                spans[Int(span)].flags &= ~PolyHeader.rightOnWall
            }
        }
        previous.base[i].span = Sweep.spanContinued

        let firstCur = nextCurrent(of: component, after: -1)
        let lastCur = Int(component.lastCur)
        let firstLeft = Int(current[firstCur].node)
        let firstRight = Int(current[firstCur + 1].node)
        let lastLeft = Int(current[lastCur].node)
        let lastRight = Int(current[lastCur + 1].node)
        let nC = current.count
        var leftOwns = -1
        var rightOwns = -1
        if firstLeft > a {
            closeSpan(left, from: a, to: firstLeft, y: y)
        } else {
            leftOwns = firstCur
            appendRight(left, x: nodes[firstRight].x, y: y, wallAfter: firstCur + 1 == nC - 1)
            if nodes[a].marked {
                appendLeft(left, x: nodes[a].x, y: y, wallAfter: firstCur == 0)
            }
            current.base[firstCur].span = left
        }
        if lastRight < b {
            closeSpan(right, from: lastRight, to: b, y: y)
        } else if lastCur != leftOwns {
            rightOwns = lastCur
            appendLeft(right, x: nodes[lastLeft].x, y: y, wallAfter: lastCur == 0)
            if nodes[b].marked {
                appendRight(right, x: nodes[b].x, y: y, wallAfter: lastCur + 1 == nC - 1)
            }
            current.base[lastCur].span = right
        }
        // The current spans between start at the vertex, as do the fans over the starts between
        // the current spans.
        var j = firstCur
        var previousRight = -1
        while j >= 0 {
            let cl = Int(current[j].node)
            let cr = Int(current[j + 1].node)
            if previousRight >= 0 && cl > previousRight {
                let fan = openPointSpan(color: color, flags: 0, x: vx, y: vy)
                closeSpan(fan, from: previousRight, to: cl, y: y)
            }
            if j != leftOwns && j != rightOwns {
                let part = openPointSpan(color: color, flags: 0, x: vx, y: vy)
                appendLeft(part, x: nodes[cl].x, y: y, wallAfter: j == 0)
                appendRight(part, x: nodes[cr].x, y: y, wallAfter: j + 1 == nC - 1)
                current.base[j].span = part
            }
            previousRight = cr
            j = nextCurrent(of: component, after: j)
        }
    }

    /// Several previous spans carry on as one current span: the regions of other colors between
    /// them end here, and so may regions on either side of them. The first span goes on as the left
    /// part, or a new span whose top covers the bottoms of the regions that ended left of it, and
    /// the last span goes on as the right part, stepping right along the line to the right end.
    /// The parts meet at the left end of the last span, and the next vertex below settles them.
    /// With one previous span that starts at the left end there is one part, which steps right.
    private mutating func mergeComponent(_ component: Component, at y: Double) {
        let nodes = self.nodes.base
        let j = nextCurrent(of: component, after: -1)
        let a = Int(current[j].node)
        let b = Int(current[j + 1].node)
        let first = nextPrevious(of: component, after: -1)
        var last = first
        while true {
            let next = nextPrevious(of: component, after: last)
            if next < 0 { break }
            last = next
        }
        let firstLeft = Int(previous[first].node)
        let firstRight = Int(previous[first + 1].node)
        let lastLeft = Int(previous[last].node)
        let lastRight = Int(previous[last + 1].node)

        let leftWall = j == 0
        let rightWall = j + 1 == current.count - 1
        if first == last && firstLeft == a {
            // One part. Its right side steps to the right end.
            var span = previous[first].span
            var from = firstRight
            if spans[Int(span)].partner >= 0 {
                span = resolveRight(span, at: firstRight, y: y, wallAfter: firstRight == b && rightWall)
                from = firstRight + 1
            }
            if nodes[a].marked {
                appendLeft(span, x: nodes[a].x, y: y, wallAfter: leftWall)
            }
            for n in IndexRange(from, through: b) where n > firstRight || nodes[n].marked {
                appendRight(span, x: nodes[n].x, y: y, wallAfter: n == b && rightWall)
            }
            previous.base[first].span = Sweep.spanContinued
            current.base[j].span = span
            return
        }

        // The left part.
        var left: Int32
        var from: Int
        if firstLeft == a {
            left = previous[first].span
            from = firstRight
            if spans[Int(left)].partner >= 0 {
                left = resolveRight(left, at: firstRight, y: y, wallAfter: false)
                from = firstRight + 1
            }
            if nodes[a].marked {
                appendLeft(left, x: nodes[a].x, y: y, wallAfter: leftWall)
            }
            previous.base[first].span = Sweep.spanContinued
        } else {
            let flags: UInt8 = j == 0 ? PolyHeader.leftOnWall : 0
            left = openSpan(color: component.color, flags: flags, from: a, to: lastLeft, y: y)
            from = lastLeft + 1
        }
        // The spans between close, and the first when a new span took its place.
        var i = firstLeft == a ? nextPrevious(of: component, after: first) : first
        while i >= 0 && i != last {
            closeSpan(previous[i].span, from: Int(previous[i].node), to: Int(previous[i + 1].node), y: y)
            previous.base[i].span = Sweep.spanContinued
            i = nextPrevious(of: component, after: i)
        }
        for n in IndexRange(from, through: lastLeft) { appendRight(left, x: nodes[n].x, y: y, wallAfter: false) }
        // The right part, meeting the left one at its left end.
        var right = previous[last].span
        if spans[Int(right)].partner >= 0 {
            right = resolveLeft(right, at: lastLeft, y: y, wallAfter: false)
        } else {
            appendLeft(right, x: nodes[lastLeft].x, y: y, wallAfter: false)
        }
        for n in IndexRange(lastRight, through: b) where n > lastRight || nodes[n].marked {
            appendRight(right, x: nodes[n].x, y: y, wallAfter: n == b && rightWall)
        }
        previous.base[last].span = Sweep.spanContinued
        spans[Int(left)].partner = right
        spans[Int(left)].meetX = nodes[lastLeft].x
        spans[Int(left)].meetY = y
        current.base[j].span = left
    }

    // MARK: Spans

    /// The diagonal from the meeting point of the two parts of `span` to the vertex at `node` on
    /// its left side: the left part closes there and the right part goes on with the vertex on its
    /// left side. Returns the right part.
    private mutating func resolveLeft(_ span: Int32, at node: Int, y: Double, wallAfter: Bool) -> Int32 {
        let partner = spans[Int(span)].partner
        spans[Int(span)].partner = -1
        closeSpan(span, from: node, to: node, y: y)
        appendLeft(partner, x: nodes[node].x, y: y, wallAfter: wallAfter)
        return partner
    }

    /// The diagonal from the meeting point to the vertex at `node` on the right side: the right part
    /// closes there and the left part goes on with the vertex on its right side. Returns the left part.
    private mutating func resolveRight(_ span: Int32, at node: Int, y: Double, wallAfter: Bool) -> Int32 {
        let partner = spans[Int(span)].partner
        spans[Int(span)].partner = -1
        closeSpan(partner, from: node, to: node, y: y)
        appendRight(span, x: nodes[node].x, y: y, wallAfter: wallAfter)
        return span
    }

    private mutating func appendLeft(_ span: Int32, x: Double, y: Double, wallAfter: Bool) {
        chain.append(ChainPoint(x: x, y: y, next: -1, wallAfter: wallAfter))
        let point = Int32(chain.count - 1)
        let s = spans.base + Int(span)
        if s.pointee.leftTail >= 0 { chain[Int(s.pointee.leftTail)].next = point } else { s.pointee.leftHead = point }
        s.pointee.leftTail = point
        s.pointee.leftCount += 1
    }

    private mutating func appendRight(_ span: Int32, x: Double, y: Double, wallAfter: Bool) {
        chain.append(ChainPoint(x: x, y: y, next: -1, wallAfter: wallAfter))
        let point = Int32(chain.count - 1)
        let s = spans.base + Int(span)
        if s.pointee.rightTail >= 0 { chain[Int(s.pointee.rightTail)].next = point } else { s.pointee.rightHead = point }
        s.pointee.rightTail = point
        s.pointee.rightCount += 1
    }

    private mutating func openSpan(color: UInt32, flags: UInt8, from: Int, to: Int, y: Double) -> Int32 {
        let topStart = Int32(topPool.count)
        for n in IndexRange(from, through: to) { topPool.append(nodes[n].x) }
        return store(OpenSpan(
            color: color, flags: flags, yTop: y,
            topStart: topStart, topCount: Int32(to - from + 1),
            leftHead: -1, leftTail: -1, leftCount: 0,
            rightHead: -1, rightTail: -1, rightCount: 0,
            partner: -1, meetX: 0, meetY: 0
        ))
    }

    /// A span that starts at one point above the current line.
    private mutating func openPointSpan(color: UInt32, flags: UInt8, x: Double, y: Double) -> Int32 {
        let topStart = Int32(topPool.count)
        topPool.append(x)
        return store(OpenSpan(
            color: color, flags: flags, yTop: y,
            topStart: topStart, topCount: 1,
            leftHead: -1, leftTail: -1, leftCount: 0,
            rightHead: -1, rightTail: -1, rightCount: 0,
            partner: -1, meetX: 0, meetY: 0
        ))
    }

    private mutating func store(_ span: OpenSpan) -> Int32 {
        if freeSpans.count > 0 {
            let free = freeSpans[freeSpans.count - 1]
            freeSpans.truncate(to: freeSpans.count - 1)
            spans[Int(free)] = span
            return free
        }
        spans.append(span)
        return Int32(spans.count - 1)
    }

    /// Closes a span with the nodes `from` through `to` as its bottom. Two parts waiting at a
    /// meeting point close as two polygons, cut by the diagonal from that point to the bottom node
    /// nearest to it.
    private mutating func closeSpan(_ index: Int32, from: Int, to: Int, y: Double) {
        let partner = spans[Int(index)].partner
        if partner >= 0 {
            spans[Int(index)].partner = -1
            let meetX = spans[Int(index)].meetX
            var nearest = from
            for n in IndexRange(from, through: to) where abs(nodes[n].x - meetX) < abs(nodes[nearest].x - meetX) {
                nearest = n
            }
            closeSinglePart(index, from: from, to: nearest, y: y)
            closeSinglePart(partner, from: nearest, to: to, y: y)
            return
        }
        closeSinglePart(index, from: from, to: to, y: y)
    }

    private mutating func closeSinglePart(_ index: Int32, from: Int, to: Int, y: Double) {
        let span = spans[Int(index)]
        freeSpans.append(index)
        let bottomCount = to - from + 1
        // A region that starts and ends in a single point with straight sides has no area.
        if span.topCount == 1 && bottomCount == 1 && span.leftCount == 0 && span.rightCount == 0 {
            return
        }
        let offset = polyData.count
        let topStart = Int(span.topStart)
        for k in IndexRange(0, Int(span.topCount)) { polyData.append(topPool[topStart + k]) }
        for n in IndexRange(from, through: to) { polyData.append(nodes[n].x) }
        var point = span.leftHead
        while point >= 0 {
            polyData.append(chain[Int(point)].x)
            polyData.append(chain[Int(point)].y)
            polyData.append(chain[Int(point)].wallAfter ? 1 : 0)
            point = chain[Int(point)].next
        }
        point = span.rightHead
        while point >= 0 {
            polyData.append(chain[Int(point)].x)
            polyData.append(chain[Int(point)].y)
            polyData.append(chain[Int(point)].wallAfter ? 1 : 0)
            point = chain[Int(point)].next
        }
        polys.append(PolyHeader(
            color: span.color, flags: span.flags, yTop: span.yTop, yBot: y,
            offset: Int32(offset), topCount: span.topCount, bottomCount: Int32(bottomCount),
            leftCount: span.leftCount, rightCount: span.rightCount
        ))
    }
}
