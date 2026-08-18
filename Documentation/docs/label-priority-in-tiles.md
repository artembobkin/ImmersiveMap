# Label priority in ImmersiveMap tiles

How the hosted tiles tell the engine what is important, and the one rule the
engine is asked to follow. Written from the tile side; the tile schema itself
is `SCHEMA.md` in the ImmersiveMapTilePipeline repository.

## The rule

**One number per feature: `rank`. Lower is more important. If `rank` is
absent, the feature is the least important thing in its layer.**

That is the whole contract. There is no `population`, no `capital`, no second
signal to reconcile. `class` still travels, but it answers a different
question (how to draw: size, weight, icon), not which label wins.

The reason it is one number: there used to be two mechanisms. The engine
sorted by `rank` when present and fell back to `capital`/`population` when it
was not; the tiles sent a constant `rank` per class and relied on
`population`. Result: every region name outranked every city, and Moscow
(13 M) tied with Kaluga (334 k). One number cannot disagree with itself.

## What `rank` means per layer

The engine already reads `rank` in two places, and the tiles now honour both
conventions exactly:

### `place`: global importance, 1..10

Computed from population and capital status at build time and baked in. The
scale as of this writing:

| rank | what |
|---|---|
| 1 | continent; country capital; city over 5 M; country over 50 M |
| 2 | city over 1 M; country over 10 M |
| 3 | city over 500 k; other countries |
| 4 | city over 250 k |
| 5 | city over 100 k; region (state/province) over 3 M |
| 6 | other cities; other regions |
| 7-8 | towns (over 30 k / under) |
| 9 | villages |
| 10 | everything smaller |

A region deliberately sits below a large city and above a small town: the
name of an oblast matters more than a district centre and less than a city of
a million.

`capital` and `population` are gone from the tiles. Bold treatment for
capitals, if wanted, is `class == "city" && rank == 1`. Any code path reading
`population` will simply never fire.

### `poi`: local grid rank, 1..N

Same convention as OpenMapTiles and what `poiLabelStyle` already assumes: the
tile is divided into 64 px cells, POIs in a cell are sorted by class
importance (hospital, station, university first; school, pharmacy, bank next;
ordinary shops and food; playgrounds late; parking and ATMs last), and
`rank` is the position in that order, starting at 1. So `rank == 1` means
"the most important POI in this 64 px cell", not "important in the world",
and the engine's overzoom budget (`poiNativeCellBudget`, log4 reveal) is
exactly the right consumer for it. Every POI carries a `rank`.

The class-importance order lives in the tiles (`Poi.importance` in the
profile) and mirrors the engine's own class sets (`poiMajorClasses` and
neighbours). Keeping the engine's bias on top is harmless (monotone), but it
is now redundant and can go whenever convenient.

### Other point layers

`mountain_peak` sends `rank` (1 for now). `housenumber`, `water_name`,
`aerodrome_label` send none, and by the rule above that means least
important, which is right for them.

## What this asks of the engine

1. **Absent `rank` = least important, uniformly.** Today `place` falls
   through to 1000 (fine), but `poi` falls through to a "middle of the tail"
   default (`poiDefaultRank = 15`). With every POI now ranked, this is moot in
   practice; making it uniform keeps the contract honest for any future layer.
2. Drop the `capital` and `population` fallbacks in
   `ImmersiveMapTilesVectorTileLabelProviderProfile.sortKey` and the
   `isCapital` size bump in `placeLabelStyle`, or re-express the latter as
   `rank == 1`. Nothing else in the label path needs to change.

Engine status: both are done. `sortKey` is `rank` or 1000, uniformly across
layers; the capital treatment is `class == "city" && rank == 1`; an unranked
POI sits at the rank cap (64), the tail of the reveal schedule. The one
remaining `capital` read is the low-zoom place gate in
`includesPlaceLabel`, kept deliberately for the rollout window: it still
fires on pre-contract tiles and never fires on tiles that follow this
document, and can go once the rollout is complete. Priorities are baked into
prepared tiles, so the prepared format version was bumped
(`ImmersiveMapTilesLabelPriorityContractTests` pins the contract).

## Where to look

- Tiles: `https://5-39-218-215.sslip.io/tiles/{z}/{x}/{y}.mvt`, key in
  `LocalSecrets.plist` (`IMMERSIVEMAP_DEV_API_KEY`).
- A z5 tile over Moscow (5/19/10) shows the place ranks; any z14 tile in the
  centre shows POI grid ranks.
