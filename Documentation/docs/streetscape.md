# The Streetscape

The streetscape is the measured street: the carriageway surfaces, reconstructed from the road graph with [osm2streets](https://github.com/a-b-street/osm2streets), and the paint on them, lane lines, centre dividers, crossings, bus lanes.

It is data, not a setting. Where a tile's road layer carries it, the map draws the roads as carriageways at their real width, flush with the surfaces, with the paint on top. Where a tile carries none, the same style draws a street map: strokes by class, a casing, nothing painted on the asphalt. There is nothing to switch on and no second request: one tile, drawn for what it contains.

A custom style reads the same fact through `ImmersiveMapFeatureStyleContext.layerCarriesStreetscape` and decides its own look for either case.
