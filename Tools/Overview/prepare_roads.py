"""usage: prepare_roads.py ne_10m_roads.json roads_ne10m.json

The Natural Earth 1:10m roads for the overview's road layer: the ferries
and the tracks dropped, kind (the type) and rank (the scalerank) kept, and
the rank deciding the first tile zoom of a road, so the globe shows the
continental network and zoom 5 the regional one. Zoom 5 is the last: the
basemap's own trunks arrive at 6.
"""
import json, sys
source, out = sys.argv[1], sys.argv[2]
minzoom = {3: 2, 4: 3, 5: 4, 6: 5, 7: 5}
features = []
for feature in json.load(open(source))['features']:
    props = feature['properties']
    rank = props.get('scalerank')
    kind = props.get('type')
    if rank not in minzoom or kind in ('Ferry Route', 'Ferry, seasonal', 'Track'):
        continue
    features.append({'type': 'Feature', 'geometry': feature['geometry'],
                     'properties': {'kind': kind, 'rank': rank},
                     'tippecanoe': {'minzoom': minzoom[rank], 'maxzoom': 5}})
json.dump({'type': 'FeatureCollection', 'features': features}, open(out, 'w'))
print('roads kept:', len(features))
