#!/usr/bin/env bash
# Bakes the overview archive the engine ships,
# Sources/ImmersiveMap/Tile/Overview/Resources/overview.pmtiles: the biomes of
# RESOLVE Ecoregions 2017 (CC BY 4.0) fitted to the Natural Earth 1:50m coast
# at tile zooms 0 to 7, the Natural Earth 1:110m lakes at zoom 0 and the
# Natural Earth 1:10m roads at zooms 2 to 5 (Natural Earth is public domain).
# Not part of the SwiftPM build: the archive is committed, and this is how it
# is made again when the data or the recipe changes. The archive is a contract
# with the built-in style (its layer names, kinds and ranks are the style's
# rules, see OverviewTileSource), so a new archive bumps
# PreparedTileDiskCaching.preparedFormatVersion.
#
# Usage:
#   Tools/Overview/bake_overview.sh <work dir> <output overview.pmtiles>
#
# Requires: mapshaper (npm, with mapshaper-xl), tippecanoe (brew), python3
# with shapely, curl and unzip. Downloads about 250 MB of sources into the
# work directory and takes a few minutes, most of them in the fit of the
# biomes to the coast.
set -euo pipefail
WORK=$1; OUT=$(cd "$(dirname "$2")" && pwd)/$(basename "$2"); HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$WORK" && cd "$WORK"
# 1. The sources.
curl -sL -o Ecoregions2017.zip https://storage.googleapis.com/teow2016/Ecoregions2017.zip && unzip -qo Ecoregions2017.zip
curl -sL -o ne_50m_land.zip https://naciscdn.org/naturalearth/50m/physical/ne_50m_land.zip && unzip -qo ne_50m_land.zip -d ne_50m_land
curl -sL -o ne_110m_lakes.zip https://naciscdn.org/naturalearth/110m/physical/ne_110m_lakes.zip && unzip -qo ne_110m_lakes.zip -d ne_110m_lakes
curl -sL -o ne_10m_roads.zip https://naciscdn.org/naturalearth/10m/cultural/ne_10m_roads.zip && unzip -qo ne_10m_roads.zip -d ne_10m_roads
# 2. The 846 ecoregions dissolved into 14 biomes, simplified to 20% of their
#    vertices (tippecanoe thins them per zoom), islands and slivers under 200 km2 dropped.
mapshaper-xl 8gb Ecoregions2017.shp -dissolve BIOME_NUM copy-fields=BIOME_NAME -o format=geojson precision=0.0001 biomes_full.json
mapshaper-xl 8gb biomes_full.json -simplify weighted 20% keep-shapes -filter-islands min-area=200km2 remove-empty -filter-slivers min-area=200km2 -o format=geojson precision=0.0001 biomes_simplified.json
mapshaper ne_50m_land/ne_50m_land.shp -o format=geojson precision=0.001 ne_50m_land.json
mapshaper ne_110m_lakes/ne_110m_lakes.shp -each 'kind="lake"' -filter-fields kind -o format=geojson precision=0.001 lakes_110m.json
# 3. The biomes fitted to the Natural Earth 1:50m coast: every piece of land no
#    biome covers goes to the biome it touches most, or the nearest one, so the
#    land is tiled without a rim or a bare island. The polar interiors stay bare.
python3 -I "$HERE/fit_biomes_to_coast.py" biomes_simplified.json ne_50m_land.json biomes_fitted.json
# 4. The lakes are for tile zoom 0 alone: the basemap ships its own from zoom 1.
python3 -I "$HERE/limit_lakes_to_zoom_zero.py" lakes_110m.json
# 5. The roads: the Natural Earth 1:10m network at tile zooms 2 to 5 by rank,
#    the basemap's own trunks arriving at 6.
mapshaper ne_10m_roads/ne_10m_roads.shp -filter-fields type,scalerank -o format=geojson precision=0.0001 ne_10m_roads.json
python3 -I "$HERE/prepare_roads.py" ne_10m_roads.json roads_ne10m.json
# 6. The archive: the biomes at tile zooms 0 to 7, the lakes at zoom 0, the roads at 2 to 5.
tippecanoe -q -o "$OUT" -Z0 -z7 --force --no-tile-size-limit --no-feature-limit --detect-shared-borders -S 4 \
  -L biome:biomes_fitted.json -L lake:lakes_110m.json -L road:roads_ne10m.json
ls -la "$OUT"
