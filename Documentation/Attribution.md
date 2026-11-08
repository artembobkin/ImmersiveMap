# Attribution

The licenses of map data ask for a credit on or next to the map. The map shows it as a badge: one line of credits along its edge.

## What the badge shows

By default the line reads:

- "Powered by ImmersiveMap": the engine's own credit, a courtesy rather than a license term.
- "© OpenStreetMap": the hosted tiles. A tap opens the OpenStreetMap copyright page.
- "Biomes © RESOLVE, CC BY 4.0": the biomes the engine paints on the globe, shown up to zoom 8.
- "© Mapterhorn": the terrain, only while the ground relief is raised.

Each credit shows only at the zooms where its data is on screen.

## Your own data

If you draw your own tiles (see [Setting up the tile source](TileSource.md)), state their credit. It takes the place of "© OpenStreetMap":

```swift
ImmersiveMapView()
    .tileArchive(url)
    .attributionSettings(.init(attributionOverride: ImmersiveMapAttribution("© My City",
                                                                            linkURL: URL(string: "https://mycity.example/license"))))
```

`linkURL` is where a tap on the badge leads. Data that is on screen only at some zooms gets a credit with a zoom range:

```swift
ImmersiveMapAttribution(credits: [
    .init("© My City"),
    .init("Aerial © Survey Office", zoomRange: 14..<22),
])
```

The engine still adds the credits of the biomes and the terrain after yours. An empty override removes the whole line.

## The badge's look

```swift
ImmersiveMapView()
    .attributionSettings(size: .small,
                         position: .bottomLeading,
                         margin: 8,
                         respectsBottomSafeArea: true,
                         textColor: SIMD4(0, 0, 0, 0.8),
                         emphasizesLeadingCredit: true,
                         showsEngineCredit: false)
```

- `size`: `.small`, `.regular` or `.large`.
- `position`: a corner or the middle of the top or bottom edge.
- `margin`: points between the badge and the edges.
- `respectsBottomSafeArea`: keeps a bottom badge above the home indicator.
- `textColor`: RGBA from 0 to 1. White by default.
- `emphasizesLeadingCredit`: sets the first credit in bold.
- `showsEngineCredit`: drops "Powered by ImmersiveMap".

Every value is optional, and the ones you leave out stay as they are.

## Showing the credit yourself

To credit the data in your own UI, an overlay or an about screen, hide the badge and say so:

```swift
ImmersiveMapView()
    .attributionSettings(isVisible: false)
    .attributionProvidedExternally()
```

Without `attributionProvidedExternally()`, a hidden badge logs a warning. The obligation stays yours: the credit has to be visible on every screen that shows the map.
