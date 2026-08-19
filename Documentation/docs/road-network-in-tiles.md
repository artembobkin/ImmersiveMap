# The road network in ImmersiveMap tiles

What the tiles have to carry for the engine to draw a street network that
reads as one surface: continuous carriageways, junctions that merge, and a
kerb that runs along the outside of the network and nowhere inside it. Written
from the engine side against the live test tiles; the tile schema itself is
`SCHEMA.md` in the ImmersiveMapTilePipeline repository.

## The rule

**One way on the ground is one feature in the tile, as long as the tile can
see it.** A street is not cut at every OSM way boundary, and its width does not
step where an OSM editor happened to split a way. The engine draws each feature
at its own carriageway width, so every cut the tiles make is a seam it has to
hide, and every width step is an edge it cannot.

## What is wrong today, with the tile that shows it

Tile 16/39615/20486 (Mokhovaya / Tverskaya / Okhotny Ryad, central Moscow).
The `transportation` layer carries the keys `lanes`, `class`, `subclass`,
`service`, `brunnel` and nothing else, and 15 line features, of which the
one junction in the frame is made of seven:

```
primary  lanes=8   13 pts  2714u  (2074,2004) -> (1113,-64)    id=283997850
primary  lanes=8   12 pts  2468u  (933,-64)   -> (2757,1422)   id=283997850
primary  lanes=12   9 pts  2326u  (809,3953)  -> (2074,2004)   id=840565670
primary  lanes=12   5 pts  2015u  (2757,1422) -> (4116,-64)    id=840565670
primary  lanes=4    3 pts   528u  (2074,2004) -> (2476,1663)   id=4161480692
primary  lanes=6    2 pts   370u  (2476,1663) -> (2757,1422)   id=11763129492
primary  lanes=10   2 pts   246u  (676,4160)  -> (809,3953)    id=11763129512
```

Drawn at their real widths (a lane is 4 m on this tier), that is a 32 m
ribbon butting against a 48 m ribbon, a 16 m and a 24 m connector laid across
the junction, and a 40 m stub: wherever a wide ribbon meets a narrower one,
the wide ribbon's kerb shows through the narrow one's fill, and the junction
reads as a tangle of grey ribs. The engine draws fills over casings across the
whole network, which makes two fills of the same width merge seamlessly, but
it cannot make a 48 m kerb disappear under a 16 m fill. That is not a
rendering flaw; it is a faithful drawing of seven ribbons of five widths.

Across the whole tile the picture is the same: 41 drive-tier features with
67 distinct endpoints, of which only 12 are shared by two or more features.
Streets arrive cut into pieces that do not even meet at the same integer
coordinate, so every piece is its own ribbon with its own ends.

## What the tiles should carry

### 1. Merge a street into one feature

Concatenate consecutive OSM ways into one feature when, and only when, all of
these are equal: `class`, `subclass`, `brunnel`, `layer` (see 4), `oneway`
(see 3), and the street identity (`name`, or `ref` where there is no name).
Merge at exact shared endpoints; do not merge across a node that a third
drive-tier way also uses (that is a junction, and the feature must end or pass
through it as geometry, not be glued across it). Merging must happen before
simplification and before tile clipping, so the merged line is simplified as
one and clipped as one.

The test: in tile 16/39615/20486 the two halves of `id=283997850` (both
`primary`, 8 lanes, the same street) are today two features that meet at
`(2074,2004)` and `(2757,1422)` only through other features; after the merge,
Tverskaya and Okhotny Ryad are each one feature through the frame.

### 2. Do not step the width inside one street

OSM tags `lanes` per way, and at junctions the count routinely includes turn
lanes: the 12-lane pieces of `id=840565670` above are the same street as the
8-lane pieces of `id=283997850`, with the four extra lanes being the turn
pockets at this junction. A width that steps 8 to 12 and back over thirty
metres is not the street getting wider; it is a pocket.

Carry, per merged feature, the lane count of the through carriageway: the
**minimum** `lanes` over the merged ways, or `lanes` minus `turn:lanes`
pockets where the source has them. A feature that genuinely changes width
(a boulevard narrowing past a square) is two features under rule 1 only if
the OSM data splits it there *and* the width change survives the minimum;
that is rare and correct.

Short connectors whose `lanes` exceeds the streets they connect (the 10-lane
246-unit stub `id=11763129512` above, the 4- and 6-lane links across the
junction) are turn pockets by construction: carry them at the narrower of
the two streets they join, or drop them entirely at z<=15 where they are
shorter than the junction they sit in.

### 3. Carry `oneway` and `name` in the geometry layer

Today the geometry layer (`transportation`) has no `name` and no `oneway`;
the name travels only in `transportation_name`. The engine needs both on the
geometry:

- `oneway` (1 / -1 / 0): a dual carriageway is two parallel one-way features,
  and the engine must not draw a lane divider down a one-way carriageway the
  way it does down a two-way street, nor try to centre markings between two
  parallel features. Today every automobile road gets a centre divider.
- `name` (or the `transportation_name` feature's identity): the engine merges
  the *rendering* of pieces that still arrive cut (tile seams cannot be merged
  away) by street identity. Without it, two pieces of one street are as
  unrelated as two different streets.

`layer` should travel too when it is non-zero (it drives the bridge/tunnel
stack; today `brunnel` alone carries it).

### 4. Junctions as area geometry where OSM has them

Where OSM maps the junction as `area:highway=*` (common in central Moscow),
ship the polygon in `transportation` with `class` of the highest road that
enters it and a `subclass=junction_area`. A junction drawn as one polygon has
one outline and no internal ribs at all, whatever the ribbons entering it do.
The engine will draw such a polygon as the carriageway surface with a kerb
on its outline and suppress casings of ribbons inside it. This is the only
way to get a truly clean multi-lane junction; rules 1 and 2 make the common
case good, rule 4 makes the hard case right.

### 5. Snap shared endpoints

Two ways that share a node must arrive with bit-identical endpoint
coordinates after quantization (the 12-of-67 figure above says they often do
not: simplification or clipping moves one end and not the other). A shared
node that no longer matches is a junction the engine cannot see, so it caps
both ends instead of merging them.

## What the engine does with it

- Draws each feature at its lane-derived width, with the kerb a fixed margin
  on each side, the automobile network above the pedestrian one, and a lane
  divider down two-way carriageways only once `oneway` travels.
- Merges the rendering of pieces with the same street identity where they
  meet, so a tile-seam cut is invisible.
- Draws a `junction_area` polygon as the carriageway and suppresses ribbon
  casings inside it.

Engine status: the width, the kerb, the tiering and the divider exist today.
The identity-based render merge and the junction-area surface are built
against the fields in rules 3 and 4 and ship when the tiles carry them; until
then the engine has nothing to merge on, and a junction stays the sum of its
ribbons.

## Where to look

- Tiles: `https://immersivemap.dev/tiles/test/{z}/{x}/{y}.mvt`, key in
  `LocalSecrets.plist` (`IMMERSIVEMAP_API_KEY`).
- 16/39615/20486: the seven-feature junction above, the 41 / 67 / 12 figures.
- 16/39614/20488: a z16 neighbour with primaries of 2 to 6 lanes to check
  rule 2 (turn pockets versus the through count).
