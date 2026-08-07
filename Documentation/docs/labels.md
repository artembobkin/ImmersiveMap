# Labels

Map labels are MSDF text: glyphs are stored as multi-channel signed distance fields in a bundled atlas, so a name stays crisp at any size and any zoom without re-rasterizing. Placement and collision run on the GPU every frame, so labels fight for space, fade in and out, and follow curved roads without the CPU laying out a single line of text. Labels also never paint over a 3D scene model: a depth-only replay of the models opens the overlay pass, and every label fragment depth-tests against it, clipping to the model silhouettes.

Everything an app configures lives on `ImmersiveMapSettings.LabelSettings` and is attached with `.labelSettings(_:)`. The idiomatic pattern is to take the current settings, change what you need, and hand them back:

```swift
struct MapScreen: View {
    var body: some View {
        ImmersiveMapView()
            .labelSettings(labelSettings)
    }

    private var labelSettings: ImmersiveMapSettings.LabelSettings {
        var labels = ImmersiveMapSettings.default.labels
        labels.language = .french
        labels.fallbackPolicy = .localFirst
        labels.houseNumbers.enabled = false
        return labels
    }
}
```

## Language

```swift
public struct LabelLanguage: Hashable, Codable, Sendable {
    public init(_ code: String)
    public static let english, russian, french, german, spanish, italian, portuguese, turkish
}

public enum LabelFallbackPolicy: String, Codable, Sendable {
    case international
    case localFirst
}
```

`LabelLanguage` is a normalized language code, not a closed set: the eight presets are a convenience and `LabelLanguage("ja")` is equally valid. The code selects which name field of the vector tile is read (`name:ja` for the example above), so what you actually get depends on what the tile source carries for that place.

`fallbackPolicy` decides what happens when the requested field is missing:

| Policy | Behavior |
|---|---|
| `.international` | Falls back to the international name. Consistent for a global audience, which is why it is the default. |
| `.localFirst` | Falls back to the local name, the endonym. Reads the way a paper map of that country would. |

**Language is part of the prepared-tile cache identity.** `LabelLanguage.preparedTileCacheNamespaceKey` goes into the disk cache namespace, so switching languages re-prepares tiles rather than re-drawing the ones already in memory. That is a correctness property, not an oversight: prepared tiles carry laid-out text. Expect a visible reload on the switch, and do not drive the language from a control the user is likely to scrub.

## Visibility

| Field | Default | Meaning |
|---|---|---|
| `houseNumbers.enabled` | `true` | Whether house numbers are drawn at all. |
| `houseNumbers.minimumZoom` | 15 | The zoom they start appearing at. |
| `settlementVisibility.capitalMaximumZoom` | 12 | The zoom past which a national capital label stops being drawn. |
| `settlementVisibility.cityMaximumZoom` | 12 | Same, for cities. |
| `settlementVisibility.smallSettlementMaximumZoom` | 12 | Same, for towns and villages. |
| `landmarks.minimumZoom` | 15 | The zoom landmark labels start appearing at. |

The settlement ceilings exist because a city name is noise once the street grid is on screen: past the ceiling the label gives its space to roads and landmarks. Raising them keeps place names around at street level; lowering them clears the map sooner.

## Collision and fades

| Field | Default | Meaning |
|---|---|---|
| `base.gridCellSizePx` | 32 | Cell size of the collision grid for point labels, in pixels. Bigger cells mean fewer labels survive and cheaper collision. |
| `base.fadeInSeconds` | 0.15 | How long a label takes to appear once it wins its space. |
| `base.fadeOutSeconds` | 0.25 | How long it takes to disappear once it loses it. |
| `road.gridCellSizePx` | 32 | The same grid for labels placed along roads. |
| `road.maxGlyphTurnRadians` | `pi / 6` | How sharply a road label may bend between consecutive glyphs before the placement is rejected. Lower keeps text readable on winding roads by dropping more candidates. |

Fades are why labels do not flicker while panning: a label that loses its cell for one frame fades rather than vanishing. The fade also drives the render loop, which is why label activity keeps the display link running for its duration, see [render loop](performance-and-debug.md).

## Fonts and atlases

The bundled atlases are Noto Sans in two weights, generated offline by `Tools/TextAtlas/generate_text_atlas.sh` and committed under `ImmersiveMap/Text/Resources/`. They are the bulk of the package's resource weight (about 2.2 MB of a 6.7 MB demo app), because they cover a wide range of scripts.

If an app only needs a subset, regenerate smaller atlases with that script: it is a build-time asset, not a runtime setting, and shrinking it is the single biggest saving available on app size.

Label colors and sizes are not part of `LabelSettings`: they belong to the map style, see [map styling](styling.md).

## Limitations

- Label sizes are defined in pixels by the style, so their apparent size scales with the drawable resolution. A 4K [video export](tour-video-export.md) therefore shows relatively smaller labels than a 1080p one.
- Which names exist at all is a property of the tile source, not the engine. A source that carries no `name:ja` will fall back however the policy says, in every language you ask for.
- Changing the language reloads prepared tiles.

Running example: the **Labels** section of [`Examples/macOS/ImmersiveMapSettingsMac`](../../Examples/macOS/ImmersiveMapSettingsMac) switches language, fallback policy, house numbers, settlement ceilings and fade timings, and shows what each of those changes costs: every field here re-prepares the tiles.
