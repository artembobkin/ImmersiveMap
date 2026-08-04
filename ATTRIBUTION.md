# Attribution

Map data carries license obligations. The most common one — ODbL for OpenStreetMap data — requires visible credit in your app. ImmersiveMap handles that with a small badge over the map; this guide covers what the credit has to say, where it has to appear, what the engine does for you, and what stays with your app.

This is a practical summary written by the project, not legal advice. The authoritative texts are linked at the bottom.

## What has to be shown

The required credit depends on whose tiles you render, not on which parts of the engine you use:

| Tile provider | Required credit | Link |
| --- | --- | --- |
| `ImmersiveMapTilesProvider` (default) | `© OpenStreetMap © OpenMapTiles` | [openstreetmap.org/copyright](https://www.openstreetmap.org/copyright) |
| `MapboxTileProvider` | `© Mapbox © OpenStreetMap` plus an "Improve this map" link | [mapbox.com/about/maps](https://www.mapbox.com/about/maps/) |
| Custom `VectorTileProvider` | whatever your data source requires — the engine cannot know | your source's license page |

The hosted service at `tiles.immersivemap.dev` serves an [OpenFreeMap](https://openfreemap.org) planet build in the [OpenMapTiles](https://openmaptiles.org) schema, which is OpenStreetMap data under ODbL. The credit names the data (OpenStreetMap) and the schema (OpenMapTiles); OpenFreeMap asks for no credit of its own, and the engine never asks for one either. Mapbox's own terms apply in addition to the OSM credit when you render Mapbox tiles.

## Where it has to appear

**On the map, or immediately next to it.** The OSMF attribution guidelines ask for the credit to be visible wherever the map is — not one tap away. A line on an About screen, in a Settings tab, or in the App Store description does not satisfy the license on its own.

Two consequences worth stating plainly, because they are the questions that come up first:

- **A Settings or About page alone is not enough.** It is a fine *additional* place, and a good one for the longer license story, but the map screen still needs its own visible credit.
- **The obligation does not scale with how much map you show.** A globe with no zoom, one city, a single static frame — all of it is rendered from the same licensed data, at every zoom level, so all of it carries the same credit. There is no threshold below which attribution becomes optional.

What the license does *not* dictate is styling. Size, color, corner and background are yours as long as the credit stays legible against the map underneath it, and the badge is adjustable exactly for that reason.

## Who is responsible for what

**The engine gives you a compliant default.** A stock `ImmersiveMapView()` renders the badge for the active provider with no configuration at all — if you write nothing, you are covered.

**The app owns the obligation.** The moment you hide, empty or override the badge, compliance moves to you: the license binds the product that ships the map, not the library that draws it. The engine helps as much as a library can — it warns when a map starts without a visible credit — but it cannot see your other UI, and it does not try to.

A short checklist before shipping:

- The credit for your active provider is visible on every screen that shows a map.
- It is legible over the map content, at every zoom, in light and dark surroundings.
- The link to the source's license page works (the badge does this for you; a custom overlay has to do it itself).
- If you swap providers at runtime, the credit swaps with them.

## What the badge shows

The badge takes its text from the **active tile provider**. With the built-in tiles it renders the one-line credit:

> © OpenStreetMap © OpenMapTiles

A tap (or click on macOS) opens [openstreetmap.org/copyright](https://www.openstreetmap.org/copyright) with the full license story. `MapboxTileProvider` credits Mapbox and OpenStreetMap instead; a custom `VectorTileProvider` shows whatever attribution it declares — and nothing when it declares none (see [the custom tile provider guide](Documentation/docs/custom-tile-provider.md)).

The engine never puts its own name into the badge: a map drawn on OpenStreetMap data credits OpenStreetMap, not the renderer.

## Restyling the badge

Size, position and text color are adjustable without touching the credit itself, and every change applies live:

```swift
ImmersiveMapView()
    .attributionSettings(size: .large,             // .small / .regular / .large
                         position: .topLeading,    // see below
                         textColor: SIMD4<Float>(1, 1, 1, 1))   // RGBA 0...1
```

- **`size`** — presets scale the fonts, paddings, corner radius and the maximum badge width coherently. `.regular` is the default.
- **`position`** — `.bottomTrailing` (default), `.bottomLeading`, `.topTrailing`, `.topLeading`, `.bottomCenter`, `.topCenter`. All positions respect the safe area; leading/trailing follow the layout direction, so RTL apps get the mirrored corner.
- **`textColor`** — RGBA in `0...1`. The second line (when a provider declares one) renders at 76% of the given alpha. `nil` keeps the default white.

Every parameter is optional and `nil` leaves the field unchanged. To replace the whole configuration at once — including resetting `textColor` back to the default or overriding the text — pass a full value:

```swift
ImmersiveMapView()
    .attributionSettings(ImmersiveMapSettings.AttributionSettings(
        size: .small,
        attributionOverride: ImmersiveMapAttribution(
            title: "© OpenStreetMap contributors",
            copyright: "",   // empty second line renders a one-line badge
            linkURL: URL(string: "https://www.openstreetmap.org/copyright")
        )
    ))
```

Overriding the text makes sense only when your app shows the source attribution elsewhere and the source's license permits that.

## Hiding the badge

```swift
ImmersiveMapView()
    .attributionSettings(isVisible: false)
```

Hiding the badge does not remove the license obligation — it moves it to you: the data credit must still be visible somewhere near the map. A map that starts with a hidden (or empty) badge logs a one-time warning to the console (`os.Logger`, subsystem `ImmersiveMap`, category `Attribution`) as a reminder.

Once your app does show the credit on its own — a custom overlay, an about screen — declare it, and the warning goes away:

```swift
ImmersiveMapView()
    .attributionSettings(isVisible: false)
    .attributionProvidedExternally()
```

The declaration changes nothing else; the license obligation stays with the app.

## Drawing the credit yourself

Hiding the built-in badge to render the credit in your own UI is fully supported, and for a design-heavy app it is often the better route: the badge is drawn by the map view and cannot participate in your layout, your safe-area insets or your animated chrome. What the license asks is that the credit ends up on or next to the map, not that it comes from the engine.

```swift
ZStack(alignment: .bottomLeading) {
    ImmersiveMapView()
        .attributionSettings(isVisible: false)
        .attributionProvidedExternally()

    Link("© OpenStreetMap © OpenMapTiles",
         destination: URL(string: "https://www.openstreetmap.org/copyright")!)
        .font(.caption2)
        .padding(8)
}
```

Two things to keep in mind when you take this route. The credit has to travel with the map: if the map appears on three screens, so does the credit — a single line in Settings does not cover the other two. And it has to match the active provider, so if the app can switch tile sources at runtime, read the text from the provider instead of hard-coding it:

```swift
let attribution = ImmersiveMapTilesProvider().attribution
Text(attribution.title)
```

## A wish from the project

Nothing in the license requires crediting ImmersiveMap, and the badge deliberately never mentions it. Still, if the engine is useful in your app, a small user-facing mention of the project somewhere — an about screen, a credits list, a line next to your own attribution — would be genuinely appreciated. It is how other developers find the project, and that is what keeps it alive.

## Sources

- [Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/1-0/) — the license on OpenStreetMap data.
- [OpenStreetMap copyright and license](https://www.openstreetmap.org/copyright) — the user-facing summary the badge links to.
- [OSMF attribution guidelines](https://osmfoundation.org/wiki/Licence/Attribution_Guidelines) — where "visible on or next to the map" comes from.
- [OpenMapTiles license](https://openmaptiles.org/#license) — the schema and planet build terms.
- [OpenFreeMap](https://openfreemap.org) — the data source behind the hosted tiles.
- [Mapbox attribution requirements](https://docs.mapbox.com/help/getting-started/attribution/) — when rendering Mapbox tiles.
