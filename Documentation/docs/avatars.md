# Avatars

```swift
struct MapScreen: View {
    @State private var avatars = ImmersiveMapAvatarsController()

    var body: some View {
        ImmersiveMapView()
            .avatars(avatars)
            .avatarSettings(size: .px128)          // optional marker size
            .onAvatarTap { event in                // tap handling (native SwiftUI)
                print("tapped marker \(event.marker.id) at \(event.screenPoint)")
            }
            .task {
                avatars.add(AvatarMarker(
                    id: 1,
                    latitude: 55.7558,
                    longitude: 37.6173,
                    image: AvatarMarkerImageFactory.number(1)
                ))
            }
    }
}
```
