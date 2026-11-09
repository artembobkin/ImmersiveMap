# Markers and taps

The map shows three kinds of things you put on it: SwiftUI markers, avatars, and 3D models (see [3D content](3DContent.md)). This page covers the first two, and how to react to taps.

## SwiftUI markers

Any SwiftUI view can stand at a coordinate:

```swift
ImmersiveMapView()
    .markers(places, coordinate: \.coordinate) { place in
        Label(place.name, systemImage: "mappin")
            .padding(6)
            .background(.thinMaterial, in: Capsule())
    }
```

`places` is a collection of `Identifiable` items. The view follows its coordinate on every frame, on the globe and on the flat map, and fades out behind the globe's horizon. `anchor:` sets which point of the view stands on the coordinate, the centre by default. The last item draws on top.

A marker handles its own taps, with a `Button` or `.onTapGesture`. Touches outside the markers go to the map. A later `.markers(...)` call replaces the earlier set.

Use markers for a few rich views: a callout, a label, a pin. For many points, use avatars or a [layer](Layers.md).

## Avatars

Avatars are round pictures drawn by the map itself, so many of them stay smooth where SwiftUI views would not. Keep an `ImmersiveMapAvatarsController` and attach it:

```swift
@State private var avatars = ImmersiveMapAvatarsController()

var body: some View {
    ImmersiveMapView()
        .avatars(avatars)
        .onAppear {
            avatars.set([
                AvatarMarker(id: 1,
                             coordinate: GeoCoordinate(latitude: 55.75, longitude: 37.62),
                             image: .remote(photoURL, placeholder: placeholder),
                             batteryBadge: AvatarBatteryBadge(levelPct: 80)),
            ])
        }
}
```

- **The picture.** A `CGImage`, or `.remote(url, placeholder:)`, which the map downloads and shows the placeholder until then.
- **Badges.** A battery level (`AvatarBatteryBadge`), a speed (`AvatarSpeedBadge`), and a count (`AvatarCountBadge`).
- **Look.** `borderColor`, `screenSizeScale`, and `drawPriority`, where a higher priority draws on top.
- **Changes.** `add`, `upsert`, `set`, `move(id:to:)`, `update(id:image:borderColor:isSelected:)`, `remove(ids:)` and `clear()`. The controller is thread-safe, so you can update it from any thread.
- **Groups.** `merge(ids:...)` shows several avatars as one, with a counter and their pictures in turn, and `unmerge(mergedID:)` splits them again.

The size and the border of every avatar are set with `.avatarSettings(size:sizeScale:borderWidthPx:...)`.

## Taps

```swift
ImmersiveMapView()
    .onAvatarTap { event in
        print("tapped avatar \(event.marker.id)")
    }
    .onSceneModelTap { event in
        print("tapped model \(event.model.id)")
    }
```

Both arrive on every tap, also on an object that is already selected. A tap on the map itself, away from everything, reaches `onMapBackgroundTap` of the camera controller or the selection controller.

## Selection

To have the map remember what is selected, attach an `ImmersiveMapSelectionController`:

```swift
@State private var selection = ImmersiveMapSelectionController()

ImmersiveMapView()
    .selection(selection)
```

A tap selects an avatar or a model, and a tap on the empty map clears the selection. `onSelectionChanged` and `onSelectionCleared` report it, and `select(_:)` and `clearSelection()` change it from code:

```swift
selection.select(ImmersiveMapSelection(kind: .avatar, objectID: 1))
```
