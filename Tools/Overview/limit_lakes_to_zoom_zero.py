"""Marks every lake feature for tile zoom 0 alone (tippecanoe reads the
`tippecanoe` member of a feature): the basemap ships its own lakes from z1."""
import json, sys
path = sys.argv[1]
data = json.load(open(path))
for feature in data['features']:
    feature['tippecanoe'] = {'minzoom': 0, 'maxzoom': 0}
json.dump(data, open(path, 'w'))
