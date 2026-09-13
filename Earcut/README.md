# Earcut

`Earcut` is the ear-clipping polygon triangulator, a Swift port of
[mapbox/earcut](https://github.com/mapbox/earcut) v3.2.3 (ISC license, notice
in `THIRD-PARTY-NOTICES.md` at the repository root). The port is the
triangulator, `earcut` and `deviation`. The optional `refine` post-pass that
release added (Lawson flips toward a constrained Delaunay triangulation) is
not ported, because nothing in the engine reads triangle shape: fills are
flat-shaded and the globe subdivides them on a grid regardless. It is its own SwiftPM target
so that the algorithm depends on nothing in the engine and the engine reaches
it through one entry point. That entry point is `package` access, not
`public`: every target of this package can call it, and an app that links the
`ImmersiveMap` product cannot.

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
concave fills of a tile) and `RoofGeometryBuilder` (the sloped roof surfaces).
The tests are `Earcut/Tests`, which import the module the way a client
would, without `@testable`. They live inside this folder, next to the code
they cover, so the target is one thing to read and to move. `Package.swift`
excludes `Tests` from the `Earcut` target's sources and points the
`EarcutTests` test target at it.

## Files

`Earcut.swift` is the `package` enum and nothing else: the two static entry
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
- `EarcutHoleBridgeIndex.swift`: the block index over the merged ring's edges
  (one bounding box per sixteen edges) that lets the bridge search skip
  whole runs instead of walking the ring once per hole, which is what keeps
  an ocean tile with hundreds of islands linear rather than quadratic.
- `EarcutZOrder.swift`: the Morton curve and the radix sort over it, which is
  what makes the ear test on a large polygon a local scan.
- `EarcutGeometry.swift`: the predicates, from triangle area to whether a
  diagonal stays inside the polygon.
- `EarcutNodePool.swift`: allocating and relinking nodes, the only code that
  writes the `prev`/`next` and `prevZ`/`nextZ` fields.
- `Tests/`: the `EarcutTests` target, kept here rather than under the
  repository's `Tests/` so the whole triangulator is one folder. `Fixtures/`
  is the reference implementation's own corpus (`test/fixtures` and
  `test/expected.json` of the ported release, copied verbatim). The test
  runs every fixture at four rotations and requires the triangle count to
  match the reference exactly, so a port that merely covers the area still
  fails. Bringing the port up to a new upstream release means copying the
  new corpus in with it.

The split is by file only: the functions keep the reference implementation's
names and bodies, so a diff against earcut.js still reads function by
function. Members are `private` where a single file uses them and internal
where another file does. Nothing here is `package` or public.

## Responsibilities

- Triangulate one polygon with holes, deterministically, without allocating
  beyond the node pool and the index list.
- Keep the reference implementation's function structure and naming so a
  change there can be audited against the port.

## Must Not Contain

- Anything from the engine: no tile types, no `SIMD` vertex formats, no
  winding or coordinate-space conventions. Callers flatten their rings into
  `[Double]` and read indices back. What an index means is theirs.
- Imports beyond the standard library. The target has no dependencies and
  `Foundation` is not one of them. (The test target reads its fixtures
  through `Foundation`, which is the tests' business, not the module's.)
- A second algorithm. Convex fans and other special cases live with the
  caller that knows its input is convex (`ParsePolygon` has one).
