# Roof rendering: what the first real roof data showed

Status: resolved. The findings are kept below as the record of what was wrong
and why; the [Resolution](#resolution) section at the end states what was built
against each invariant and where it lives. File and line references in the
findings describe the code as it was then; the height field they point at
(`RoofHeightField`) is gone, replaced by `RoofGeometryBuilder`.

## Context

Until now no tile source the engine consumed carried roof tags. OpenMapTiles
ships `render_height`/`render_min_height` only, so the roof code path
(`ImmersiveMap/Tile/Parse/Roof/*`) had never met a real `roof:shape` on a real
footprint. The new ImmersiveMap schema passes OSM roof tags through unchanged
(`roof:shape`, `roof:height`, `roof:levels`, and from now on `roof:orientation`
and `roof:direction`), and it does so for `building:part` features as well as
outlines. The first tile of central Moscow (z14, tile 14/9904/5121 on the dev
server) contains, on building parts alone:

```
round 176   skillion 175   gabled 118   pyramidal 109   hipped 104
flat 61     onion 27       dome 23      gambrel 8       half-dome 4
```

So the roofs on screen are not garbage in the data. They are correctly tagged
gables, hips, pyramids and domes that every previous schema had thrown away,
now reaching a renderer that only ever saw flat tops. What is on screen is what
the current roof code does with them.

## Symptoms observed

- Bolshoi Theatre: skewed wedge shapes on the roof. These are small `gabled`
  parts (skylights, `roof:height=1`) whose ridge runs diagonally to the part.
- Kremlin wall: each merlon is a `building:part` with a small gabled roof; they
  render as thin fins pointing in a direction unrelated to the wall.
- Borovitskaya and Tainitskaya towers: the tent roof (`pyramidal`/`hipped` on
  an octagonal or rotated square footprint) renders as a folded, creased sheet,
  with edges cutting through the tower body.
- Historical Museum: striped z-fighting on the roof. This one was on the tile
  side and is fixed there (heights were rounded to integers, which made
  neighbouring parts exactly coplanar; they now travel as decimals). It is
  listed so nobody chases it in the engine.

## Root causes, with references

### 1. Roof orientation comes from the tile axes, not from the footprint

`RoofHeightField.init` (`ImmersiveMap/Tile/Parse/Roof/RoofHeightField.swift`,
lines 34-60) computes the axis-aligned bounding box of the exterior ring **in
tile coordinates** and puts the ridge along whichever of X or Y is longer:

```swift
let ridgeAlongX = width >= height
let ridgeDir = ridgeAlongX ? SIMD2<Float>(1, 0) : SIMD2<Float>(0, 1)
```

Nothing about a building is aligned with the tile grid. Moscow's street grid is
rotated relative to Web Mercator axes, so every ridge is placed diagonally to
the actual building. Slope direction, ridge length (`longSide - shortSide` of
the AABB) and the centre used for pyramids and domes all inherit the same
frame. This is the single cause behind the wedges on the theatre and the fins
on the wall.

Invariant a fix must satisfy: the roof's frame (ridge line, slope direction,
apex) must be a property of the footprint's own geometry and, where OSM says
so, of `roof:orientation` / `roof:direction`; it must be invariant under
rotation of the tile grid. A rectangle rotated 30 degrees must get exactly the
roof a rectangle rotated 0 degrees gets, rotated 30 degrees.

### 2. The roof surface has no vertices of its own

`TileMvtParser+Helpers.swift`, lines 596-640: the roof mesh is the flat
triangulation of the footprint (`roof.vertices`, i.e. the ring vertices as
earcut left them), with each vertex lifted by `roofField.height(at:)`. **No
vertex is ever inserted at the ridge or the apex.**

Consequences follow directly from `RoofHeightField.height(at:)`
(lines 92-113), which is a height field sampled only at those existing
vertices:

- gabled roof on an axis-aligned rectangle: all four corners are at
  `slopeSpan` from the ridge, so all four get `roofBase`; the roof is a flat
  lid sitting *below* the wall tops, and there is no gable at all;
- pyramid or cone on a square: same, all corners at `maxRadius`, apex never
  exists, flat lid;
- any footprint whose vertices sit at *different* distances from the frame
  (rotated rectangle, octagon, L-shape): vertices get different heights and
  the triangulation becomes a creased sheet. That is the tent roofs on the
  towers.

Note the two causes compound: even with a correct frame, a height field
sampled at ring vertices cannot represent a ridge or an apex. And even with
inserted vertices, a wrong frame puts them in the wrong place.

Invariant a fix must satisfy: the roof mesh must contain the vertices its
shape needs (ridge endpoints, apex, hip lines) and must be watertight between
the eaves (top of the walls at `render_height - roof:height`) and the ridge or
apex at `render_height`. A gable end must be a vertical triangle, not a slope.

### 3. Frame centre and radius are AABB-derived too

For `pyramid`, `cone`, `dome` the centre is the AABB centre and `maxRadius` is
the farthest ring vertex from it. On anything but a regular polygon centred in
its box, the apex lands off the visual centre and the outermost vertices sit
below the eaves. Same family as cause 1; listed separately because pyramids
have no ridge and might be fixed on a different path.

## What is not wrong

- `RoofAttributesParser` reads the tags correctly, including the OSM
  convention that `height` is the total to the top of the roof and
  `roof:height` is the roof's share (`roofBase = topHeight - roofHeight`).
- The guard `roofHeight > 0` is right. What was wrong is that the tiles were
  sending 0 for `roof:height=0.3` because of integer rounding; fixed on the
  tile side.
- Wall extrusion, `building:part` handling and `hide_3d` all behave as
  intended; the parts themselves are placed correctly, only their roofs are
  not.

## Until it is fixed (superseded by the resolution below)

A wrong roof reads worse than a flat one. While the surface generation is
being reworked, the honest interim is to treat every non-flat `roof:shape` as
flat at `render_height`, i.e. return `nil` from `RoofAttributesParser.parse`
for shapes the mesh builder cannot yet produce. That is one condition, it
keeps the data flowing into the tiles, and it turns the towers back into
clean stacked prisms instead of creased ones.

## Resolution

The surface generation was reworked in `RoofGeometryBuilder`
(`ImmersiveMap/Tile/Parse/Roof/RoofGeometryBuilder.swift`), which replaces
`RoofHeightField` and answers each root cause:

1. **The frame comes from the footprint.** The ridge follows the long axis of
   the minimum-area oriented bounding box of the footprint's convex hull, so it
   is invariant under rotation of the tile grid: a rectangle rotated 30 degrees
   gets exactly the roof a rectangle rotated 0 degrees gets, rotated 30 degrees
   (pinned by `RoofGeometryBuilderTests.testGabledRoofIsInvariantUnderTileGridRotation`).
   `RoofAttributesParser` now reads `roof:orientation` (`along`/`across` picks
   the box axis) and `roof:direction` (degrees or compass points; the downslope
   azimuth, which overrides the axis entirely), and both travel on `RoofInfo`.

2. **The mesh contains the vertices the shape needs.** Gabled: the footprint is
   split along the ridge line, so the ridge owns real vertices at
   `render_height`, and the wall ring gains a vertex at every ridge crossing,
   so a gable end closes as a vertical wall triangle instead of a slope.
   Hipped (and `mansard`): the ridge is inset by the slope span from each end,
   eaves stay level, hip faces connect each eave edge to its ridge projection.
   Pyramid and cone: an apex over the area centroid, not the box centre.
   Dome (and `onion`, `half-dome`): latitude bands shrinking toward the
   centroid with a spherical profile. Skillion: still the lifted flat
   triangulation (it is one plane, so ring vertices suffice), but sloping with
   the footprint or the tagged direction, descending toward `roof:direction`.
   `gambrel` renders as gabled. Everything is watertight between the eaves at
   `render_height - roof:height` and the ridge or apex at `render_height`:
   walls take their top height from the roof itself
   (`RoofGeometry.wallTop`), constant at the eaves for level-eave shapes.

3. **No AABB anywhere.** Centre and apex are the polygon area centroid; radius
   is no longer used.

The interim rule above survives as the fallback: a footprint the builder
cannot shape honestly (interior rings under anything but the skillion plane, a
degenerate ring) gets the flat lid at `render_height`
(`TileMvtParserRoofMeshTests.testGabledWithHolesFallsBackToAFlatLidAtFullHeight`).
The Historical Museum z-fighting stays fixed on the tile side, as noted.
Winding and lighting are pinned too: every roof face matches the flat lid's
triangle winding (or back culling would hide whole shapes) and carries an
upward outward normal. The visual review scenario `buildings.roofs.kremlin`
frames tile 14/9904/5121 so the shapes get looked at before a release.

## Where to look while working on it

- Dev tiles: `https://5-39-218-215.sslip.io/tiles/{z}/{x}/{y}.mvt` with the
  bearer key from `LocalSecrets.plist` (`IMMERSIVEMAP_DEV_API_KEY`).
- Tile 14/9904/5121 (Kremlin, Red Square) has all the shapes above in one
  place; the Bolshoi is one tile north. Tags in the tile: `roof:shape`,
  `roof:height` (metres, decimal), `roof:levels`, `roof:orientation`
  (`along`/`across`), `roof:direction` (degrees), `render_height`,
  `render_min_height`, `building:part`, `hide_3d`.
- The tile schema and every field it carries: `SCHEMA.md` in the
  ImmersiveMapTilePipeline repository.
