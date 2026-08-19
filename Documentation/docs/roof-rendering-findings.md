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

- Dev tiles: `https://immersivemap.dev/tiles/test/{z}/{x}/{y}.mvt` with the
  bearer key from `LocalSecrets.plist` (`IMMERSIVEMAP_API_KEY`).
- Tile 14/9904/5121 (Kremlin, Red Square) has all the shapes above in one
  place; the Bolshoi is one tile north. Tags in the tile: `roof:shape`,
  `roof:height` (metres, decimal), `roof:levels`, `roof:orientation`
  (`along`/`across`), `roof:direction` (degrees), `render_height`,
  `render_min_height`, `building:part`, `hide_3d`.
- The tile schema and every field it carries: `SCHEMA.md` in the
  ImmersiveMapTilePipeline repository.

## Second round (after the resolution)

The rebuilt roofs were checked against the same tiles. What was still wrong
splits into a tile-format limit (handled on the tile side as far as it can
be), and one engine item.

### Tile side: MVT grid resolution at z14

At z14 in Moscow one tile unit is 0.34 m (4096 units per tile). Building parts
in this area go down to 0.2-0.8 m (window ledges, pilasters, the slabs the
Armoury roof is assembled from). Snapping such a part to the integer grid
turns a quad into a triangle or a sliver: in tile 14/9903/5122, 624 of the
2183 building parts were triangles, against roughly 5% triangles in the source
data for the same area. Extruded with a roof, a sliver is a fin and a
degenerate quad is a wedge; that is most of what was still visible on the
Kremlin wall and on the Armoury.

The tiles now drop parts under 2 units (0.125 px, ~0.7 m) because they cannot
be represented at this zoom, keep everything above that with a 0.02 px
simplification tolerance, and carry a 16 px buffer for parts (see below).
Sub-metre detail is out of reach for z14/4096 tiles by construction; the
engine will not see it and should not be blamed for it.

For the record, an earlier line in this note claimed that 40 of 64 parts of
the Armoury were being dropped. That count was wrong (it counted a truncated
listing); the parts were arriving, degraded by quantisation, not missing.

### Engine item: roofs are built on the clipped footprint

The parser clips a polygon to the tile before the roof is built
(`clippedExterior` in `TileMvtParser+Helpers.swift`), so a building that
crosses a tile edge gets its roof computed on each half separately. A ridge
placed from the half's oriented box is not the ridge of the whole building,
and the two halves do not meet. The Kremlin's south wall runs along the
9903/9904 tile boundary (x = 37.6172), which is why the merlons there looked
worse than elsewhere.

The tiles help as much as a tile can: parts now come with a 16 px buffer, so a
part within 16 px of an edge arrives whole in both tiles. What the engine has
to do with that is its call; the invariant is that a roof must be built from
the whole footprint the tile carries and only then clipped, never built from
a clipped footprint. Where the footprint is genuinely cut (larger than the
buffer), a flat lid on the cut piece reads better than a wrong ridge.

### Checked and found right

- Skillion: `roof:direction` is treated as the downslope azimuth with
  north = (0, -1) in tile coordinates. The Armoury slabs point their
  directions outward from the roof centre in the data, as they should.
- `roof:orientation` `along`/`across` is read with the OSM meaning
  (`along` = ridge parallel to the long side).

### Still open on the engine side

`gabled`/`hipped` with a real `roof:height` on a **non-convex** footprint.
They exist in this tile (an outline at 55.75177, 37.61450: `gabled`,
`roof:height=3`, 7 vertices, non-convex; a part at 55.75271, 37.61013:
`gabled`, 14 vertices, non-convex). A ridge inset from the ends of an oriented
box is only meaningful for convex, roughly rectangular footprints. Not
separately verified in this round; the first-round invariant stands.

## Second round: engine follow-up

The engine item above is done. `BuildingExtrusionCandidate` now carries the
exterior ring as the tile delivered it (`rawExterior`, before the engine's
clip to the tile square), and `RoofGeometryBuilder` builds the frame and the
whole roof surface from that footprint, then clips the finished surface to the
tile in plan view, interpolating positions and normals along the cut. Both
halves of a building on a tile edge therefore compute the same frame from the
same buffered footprint and meet exactly at the boundary
(`TileMvtParserRoofMeshTests.testRoofAcrossATileEdgeIsFramedByTheRawFootprint`).
Walls stay on the clipped ring, which is what actually gets extruded.

Where the footprint is genuinely cut by the tiler, the flat lid applies, as
prescribed. Detection is a heuristic, since the engine does not know the
tiler's buffer: a cut leaves an axis-aligned edge along the buffer rectangle,
so an axis-aligned edge lying deeper than `extent / 32` (128 units, half the
16 px buffer) outside the tile square reads as a cut. A grid-aligned building
wall protruding less than that stays a whole footprint; a giant that
protrudes further with a wall exactly parallel to the tile edge is flattened
even if it was never cut, which is the honest side to err on.

One correction to "Checked and found right" above: `roof:direction` with
north = (0, -1) is the right convention **in raw MVT tile coordinates**, but
the rings never reach the roof builder in that space. `ParsePolygon` flips y
(`tileExtent - y`) during conversion and the flat world mapping keeps that
direction, so where the builder works, north is (0, 1). The first
implementation used (0, -1) there, which mirrored every tagged direction
north-to-south; it now maps compass azimuths into the flipped space
(`RoofGeometryBuilderTests.testSkillionCompassIsNorthUpInTheParsedTileSpace`).

Still open, unchanged: `gabled`/`hipped` on non-convex footprints. The gabled
split handles a non-convex ring (each ridge-line piece is triangulated on its
own), but the hipped fan and a single straight ridge are approximations there;
a straight-skeleton roof is the real answer if those footprints turn out to
matter on screen.
