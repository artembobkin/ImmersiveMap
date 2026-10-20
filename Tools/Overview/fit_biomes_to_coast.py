"""Fit the simplified biomes to the Natural Earth 50m coast.

Every piece of NE land that no biome covers is given to the biome it shares
the longest boundary with, unless the piece is larger than LIMIT_KM2 (the
Antarctic and Greenland interiors stay uncovered, the map's glacier draws
there). The result tiles the NE land exactly, with no overlaps.
"""
import sys, json, math
from shapely.geometry import shape, mapping, Polygon, MultiPolygon
from shapely.ops import unary_union
from shapely.strtree import STRtree
biomes_path, land_path, out_path = sys.argv[1:4]
LIMIT_KM2 = 60000.0
KINDS = {1:'tropical_moist_forest',2:'tropical_dry_forest',3:'tropical_conifer_forest',4:'temperate_broadleaf_forest',
         5:'temperate_conifer_forest',6:'boreal_forest',7:'tropical_grassland',8:'temperate_grassland',9:'flooded_grassland',
         10:'montane_grassland',11:'tundra',12:'mediterranean_scrub',13:'desert',14:'mangrove'}
def area_km2(g):
    c = g.centroid
    return g.area * (111.0 ** 2) * math.cos(math.radians(max(-89, min(89, c.y))))
biomes = {}
for f in json.load(open(biomes_path))['features']:
    g = shape(f['geometry']).buffer(0)
    biomes[int(f['properties']['BIOME_NUM'])] = g
land = unary_union([shape(f['geometry']).buffer(0) for f in json.load(open(land_path))['features'] if f.get('geometry')])
cover = unary_union(list(biomes.values()))
print("clipping biomes to land", file=sys.stderr)
for k in biomes: biomes[k] = biomes[k].intersection(land)
gap = land.difference(cover)
pieces = list(gap.geoms) if gap.geom_type == 'MultiPolygon' else [gap]
print(f"gap pieces: {len(pieces)}", file=sys.stderr)
keys = list(biomes.keys())
tree = STRtree([biomes[k] for k in keys])
additions = {k: [] for k in keys}
skipped = 0
for p in pieces:
    if area_km2(p) > LIMIT_KM2:
        skipped += 1; continue
    best, best_len = None, 0.0
    for i in tree.query(p.buffer(0.01)):
        shared = p.exterior.buffer(0.02).intersection(biomes[keys[i]]).area
        if shared > best_len: best, best_len = keys[i], shared
    if best is None:
        # An island no biome reaches: the nearest biome's, so no island
        # stays a bare speck among painted land.
        best = keys[int(tree.nearest(p))]
    additions[best].append(p)
print(f"large pieces left uncovered: {skipped}", file=sys.stderr)
features = []
for k in keys:
    g = unary_union([biomes[k]] + additions[k]).buffer(0)
    polys = list(g.geoms) if g.geom_type == 'MultiPolygon' else [g]
    features.append({"type": "Feature", "properties": {"kind": KINDS[k], "biome": k},
                     "geometry": mapping(MultiPolygon([q for q in polys if not q.is_empty]))})
json.dump({"type": "FeatureCollection", "features": features}, open(out_path, 'w'))
print("done", file=sys.stderr)
