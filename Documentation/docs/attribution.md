# Attribution

Map data carries license obligations. The most common one — ODbL for OpenStreetMap data — requires visible credit in your app. ImmersiveMap handles that with a small badge over the map; this guide covers what it shows, how to restyle or move it, and what happens if you hide it.

## What the badge shows

The badge takes its text from the **active tile provider**. With the built-in tiles it renders the one-line credit:

> © OpenStreetMap © OpenMapTiles

A tap (or click on macOS) opens [openstreetmap.org/copyright](https://www.openstreetmap.org/copyright) with the full license story. `MapboxTileProvider` credits Mapbox and OpenStreetMap instead; a custom `VectorTileProvider` shows whatever attribution it declares — and nothing when it declares none (see [the custom tile provider guide](custom-tile-provider.md)).

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

## A wish from the project

Nothing in the license requires crediting ImmersiveMap, and the badge deliberately never mentions it. Still, if the engine is useful in your app, a small user-facing mention of the project somewhere — an about screen, a credits list, a line next to your own attribution — would be genuinely appreciated. It is how other developers find the project, and that is what keeps it alive.
