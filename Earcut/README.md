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
