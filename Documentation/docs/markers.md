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

`items` is any `RandomAccessCollection` of `Identifiable` elements, `coordinate` extracts a `GeoCoordinate` per element (a key path like `\.coordinate` works too).

## How it works

Marker content is evaluated together with your SwiftUI body and hosted natively (`UIHostingController` on iOS, `NSHostingView` on macOS) in a transparent layer above the Metal map. Each rendered frame the engine projects the coordinates with the exact vertex-shader math (including the globe unfurl wave) and mutates only view frames and alpha. SwiftUI is never invalidated at display rate, and an idle map with idle markers costs nothing (rendering stays on-demand).

## Anchor

`anchor` is a SwiftUI `UnitPoint` inside the marker's bounds that lands on the projected coordinate. The default `.center` centers the view on the coordinate; use `.bottom` for pin-shaped markers whose tip should touch the map.

## Updating markers

Markers are plain SwiftUI data flow: change the `items` collection (or anything your content closure reads) and the set updates on the next body evaluation. Diffing is by `id`: views of surviving ids are updated in place and keep their `@State`. A repeated `.markers(...)` call replaces the previous set entirely. Z-order follows collection order, the last element is on top.

## Interactivity

Marker content is fully interactive: `Button`, `onTapGesture`, and other gestures inside a marker work as usual. A touch that starts on a marker belongs to the marker; the map does not pan, zoom, or select from it. Touches outside markers reach the map exactly as before. On macOS, scroll-wheel zoom keeps working over markers (as in MapKit).

## Limitations

- No collision handling: overlapping markers simply draw over each other.
- Each marker is a hosting view. Hundreds are fine; for thousands of uniform pins use [avatar markers](avatars.md), which render through a GPU atlas.
- Marker content is a closed leaf on iOS: navigation and presentation from inside a marker are not supported (the hosting controller has no parent).
