# Markers

Markers (avatars) are owned by an `ImmersiveMapAvatarsController`. The controller is thread-safe - call its methods from any thread and the map redraws itself (rendering is on-demand, so idle markers cost nothing). Attach it with `.avatars(_:)`:

```swift
struct MapScreen: View {
    @State private var avatars = ImmersiveMapAvatarsController()

    var body: some View {
        ImmersiveMapView()
            .avatars(avatars)
            .avatarSettings(size: .px128)          // optional marker size
            .onMarkerTap { event in                // tap handling (native SwiftUI)
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

Every marker has a `UInt64` `id`, unique within the controller; all operations address it by `id`.

## Add, remove, move

```swift
avatars.add(marker)                 // add one (or add([m1, m2]) for several)
avatars.upsert([m1, m2])            // add or replace by id
avatars.set([m1, m2])               // replace the entire marker set

avatars.remove(id: 1)               // remove one (or remove(ids: [1, 2]))
avatars.clear()                     // remove all

avatars.move(id: 1, latitude: 55.76, longitude: 37.62)
```

`move` is animated automatically: the marker glides to the new coordinate (duration scales with distance). For live tracks, just push new coordinates and the engine smooths the motion.

## Images

A marker always has an image. Set it several ways:

```swift
// Ready-made image (CGImage, or UIImage on iOS / NSImage on macOS)
AvatarMarker(id: 1, coordinate: coord, image: cgImage)

// Remote image loaded in the background, with an optional placeholder
AvatarMarker(id: 1, latitude: 55.75, longitude: 37.61,
             imageURL: url, placeholder: placeholderCGImage)

// Generated placeholder: a square with a number
AvatarMarker(id: 1, coordinate: coord, image: AvatarMarkerImageFactory.number(1))
```

Change the image (and optionally border color / selection) later:

```swift
avatars.update(id: 1, image: newImage)
avatars.update(id: 1, borderColor: SIMD4<Float>(0.2, 0.6, 1.0, 1.0), isSelected: true)
```

Reuse a single `CGImage` instance across markers that share a picture - the GPU atlas caches images by object identity, so thousands of markers with the same image occupy one atlas slot.

## Merging markers

Collapse several markers into one clustered marker:

```swift
avatars.merge(ids: [1, 2, 3], mergedID: 100, imageCycleInterval: 2.0)
```

- Members are hidden; a single marker (`100`) is drawn in their place.
- Its coordinate is the **live average** of the members - moving a member glides the merged marker.
- Its image **cycles** through the members' avatars every `imageCycleInterval` seconds (`0` disables cycling).
- A round **count badge** shows how many avatars are merged.

```swift
avatars.mergedMemberIDs(mergedID: 100)     // [1, 2, 3]
avatars.unmerge(mergedID: 100)             // restore members onto the map
```

Members stay addressable (`move`/`update`) while hidden. `remove(id: 100)` deletes the group with its members; removing a member shrinks the count and dissolves an emptied group.
