# Earcut

`Earcut` is the ear-clipping polygon triangulator, a Swift port of
[mapbox/earcut](https://github.com/mapbox/earcut) (ISC license, notice in
`THIRD-PARTY-NOTICES.md` at the repository root). It is its own SwiftPM target
so that the algorithm depends on nothing in the engine and the engine reaches
it through one public entry point.

## API

The module exposes one type, the `Earcut` enum, with two static functions:

- `Earcut.tessellate(data:holeIndices:dim:)` takes the flat coordinate layout
  of the reference implementation (every ring's vertices back to back, the
  outer ring first, `holeIndices` naming the vertex at which each hole starts)
  and returns vertex indices, three per triangle.
- `Earcut.deviation(data:holeIndices:dim:triangles:)` measures how far the
  triangles' summed area is from the polygon's own, the reference
  implementation's quality check.

Callers `import Earcut`. Inside the package that is `ParsePolygon` (the
concave fills of a tile) and `RoofGeometryBuilder` (the sloped roof surfaces);
the tests are `Tests/EarcutTests`, which import the module the way a client
would, without `@testable`.

## Files

`Earcut.swift` is the public enum and nothing else: the two static entry
points and the shoelace sum they share. Everything below it is
`EarcutCore`, one triangulation of one polygon, split by the phase of the
algorithm it belongs to:

- `EarcutCore.swift`: the node struct, the pool the nodes live in, and `run`,
  which is the whole algorithm read top to bottom.
- `EarcutLinkedList.swift`: building a ring into the circular doubly linked
  list, and pruning the vertices that carry no shape.
- `EarcutEarClipping.swift`: the slicing loop, the ear test in both its plain
  and its z-order hashed form, and the fallbacks a stuck polygon falls
  through.
- `EarcutHoles.swift`: bridging every hole into the outer ring, left to right.
- `EarcutZOrder.swift`: the Morton curve and the merge sort over it, which is
  what makes the ear test on a large polygon a local scan.
- `EarcutGeometry.swift`: the predicates, from triangle area to whether a
  diagonal stays inside the polygon.
- `EarcutNodePool.swift`: allocating and relinking nodes, the only code that
  writes the `prev`/`next` and `prevZ`/`nextZ` fields.

The split is by file only: the functions keep the reference implementation's
names and bodies, so a diff against earcut.js still reads function by
function. Members are `private` where a single file uses them and internal
where another file does; nothing here is public.

## Responsibilities

- Triangulate one polygon with holes, deterministically, without allocating
  beyond the node pool and the index list.
- Keep the reference implementation's function structure and naming so a
  change there can be audited against the port.

## Must Not Contain

- Anything from the engine: no tile types, no `SIMD` vertex formats, no
  winding or coordinate-space conventions. Callers flatten their rings into
  `[Double]` and read indices back; what an index means is theirs.
- Imports beyond the standard library. The target has no dependencies and
  `Foundation` is not one of them.
- A second algorithm. Convex fans and other special cases live with the
  caller that knows its input is convex (`ParsePolygon` has one).
