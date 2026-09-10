# SwiftUI markers

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
