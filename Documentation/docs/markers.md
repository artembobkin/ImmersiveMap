# SwiftUI markers

Anchor arbitrary SwiftUI views to geographic coordinates with the `.markers(...)` modifier. The map repositions them every rendered frame: in flat mode, on the globe, and through the globe-to-flat morph. Behind the globe horizon a marker fades out and stops receiving input.

```swift
struct Place: Identifiable {
    let id: Int
    let title: String
    let coordinate: GeoCoordinate
}

struct MapScreen: View {
    let places: [Place]

    var body: some View {
        ImmersiveMapView()
            .markers(places, coordinate: { $0.coordinate }, anchor: .bottom) { place in
                VStack(spacing: 2) {
                    Text(place.title)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                    Image(systemName: "mappin.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
            }
    }
}
```

## API

```swift
func markers<Items: RandomAccessCollection, Content: View>(
    _ items: Items,
    coordinate: (Items.Element) -> GeoCoordinate,
    anchor: UnitPoint = .center,
    @ViewBuilder content: (Items.Element) -> Content
) -> ImmersiveMapView where Items.Element: Identifiable
```

| Parameter | Meaning |
|---|---|
| `items` | Any `RandomAccessCollection` of `Identifiable` elements. Element ids drive diffing: views of surviving ids are updated in place. |
| `coordinate` | Extracts a `GeoCoordinate` (degrees) per element. A key path works: `coordinate: \.coordinate`. |
| `anchor` | The `UnitPoint` inside the marker's bounds that lands exactly on the projected coordinate. Defaults to `.center`. |
| `content` | SwiftUI view builder invoked per element together with your body. |

A repeated `.markers(...)` call replaces the previous set entirely. Z-order follows collection order: the last element draws on top.

## How it works

Marker content is evaluated together with your SwiftUI body and hosted natively (`UIHostingController` on iOS, `NSHostingView` on macOS) in a transparent layer above the Metal map. Each rendered frame the engine projects the coordinates with the exact vertex-shader math (including the globe unfurl wave) and mutates only view frames and alpha. SwiftUI is never invalidated at display rate, and an idle map with idle markers costs nothing (rendering stays on-demand).

## Anchor

`anchor` picks the point of the marker that touches the map:

```swift
.markers(places, coordinate: \.coordinate) { ... }                    // centered on the coordinate
.markers(places, coordinate: \.coordinate, anchor: .bottom) { ... }   // pin tip on the coordinate
```

Use `.center` for badges and dots, `.bottom` for pin-shaped markers whose tip should touch the map.

## Updating and moving markers

Markers are plain SwiftUI data flow: change the `items` collection (or anything your content closure reads) and the set updates on the next body evaluation. Views of surviving ids keep their internal `@State`.

A changed coordinate repositions the marker on the next frame without animation. For live positions that should glide (people, vehicles), either interpolate coordinates yourself before feeding them in, or use [avatar markers](avatars.md): their `move` animates along a great circle out of the box.

## Interactivity

Marker content is fully interactive: `Button`, `onTapGesture`, and other gestures inside a marker work as usual. A touch that starts on a marker belongs to the marker; the map does not pan, zoom, or select from it. Touches outside markers reach the map exactly as before. On macOS, scroll-wheel zoom keeps working over markers (as in MapKit).

For a purely decorative marker that should never intercept map gestures, disable hit testing on its content:

```swift
.markers(places, coordinate: \.coordinate) { place in
    PlaceBadge(place)
        .allowsHitTesting(false)
}
```

## Globe behavior

On the globe a marker rides the surface, including the unfurl wave of the globe-to-flat morph, so it stays glued to its tile through the whole transition. Past the horizon the marker fades out over a narrow band instead of popping, and a marker on the far side of the globe stays hidden until the morph actually unrolls its part of the surface. Hidden and faded-out markers do not receive input.

## SwiftUI markers or avatar markers?

| | SwiftUI markers | [Avatar markers](avatars.md) |
|---|---|---|
| Content | Any SwiftUI view | `CGImage` in a GPU atlas |
| Practical count | Hundreds | Tens of thousands |
| Overlap handling | None, markers overlap | Zenly-style collision layout and clustering |
| Movement | Snaps on data change | Animated glide via `move` |
| Interactivity | Full SwiftUI (buttons, gestures) | `onAvatarTap` event |
| API style | Declarative `.markers(...)` | `ImmersiveMapAvatarsController` |

Rule of thumb: rich, interactive and few means SwiftUI markers; uniform, numerous and live-moving means avatars.

## Limitations

- No collision handling: overlapping markers simply draw over each other.
- Each marker is a hosting view. Hundreds are fine; for thousands of uniform pins use avatar markers, which render through a GPU atlas.
- Marker content is a closed leaf on iOS: navigation and presentation from inside a marker are not supported (the hosting controller has no parent).
- Taps are plain SwiftUI and do not go through [the selection API](selection.md), which covers avatars only.

Running example: [`Examples/ImmersiveMapMarkersMac`](../../Examples/ImmersiveMapMarkersMac) switches the anchor, compares interactive content with `allowsHitTesting(false)`, and mutates the backing collection live.
