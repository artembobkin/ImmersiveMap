# Annotations, pins and taps

The map shows three kinds of things you put on it: annotations, pins, and 3D models (see [3D content](3DContent.md)). This page covers the first two, and how to react to taps.

- **Annotations** are live SwiftUI views, for a few rich things: a callout, a button, the selected place.
- **Pins** are pictures the map draws itself, for many things: hundreds or thousands of places, photos, icons.

## Annotations

Any SwiftUI view can stand at a coordinate:

```swift
ImmersiveMapView()
    .annotations(places, coordinate: \.coordinate) { place in
        Label(place.name, systemImage: "mappin")
            .padding(6)
            .background(.thinMaterial, in: Capsule())
    }
```

`places` is a collection of `Identifiable` items. The view follows its coordinate on every frame, on the globe and on the flat map, and fades out behind the globe's horizon. `anchor:` sets which point of the view stands on the coordinate, the centre by default. The last item draws on top.

An annotation handles its own taps, with a `Button` or `.onTapGesture`. Touches outside the annotations go to the map. A later `.annotations(...)` call replaces the earlier set.

Make your items `Equatable` when you can. The map then leaves an annotation's view untouched while its item stays equal, so adding or removing a few annotations costs only those few. The view has to be made from the item alone: state it reads from elsewhere does not reach an annotation whose item did not change.

Use annotations for a few rich views. Each one is a live view, and a map with hundreds of them slows down. For many points, use pins or a [layer](Layers.md).

## Pins

Pins are pictures drawn by the map itself, so many of them stay smooth where SwiftUI views would not. A pin shows its picture in a round frame. Keep an `ImmersiveMapPinsController` and attach it:

```swift
@State private var pins = ImmersiveMapPinsController()

var body: some View {
    ImmersiveMapView()
        .pins(pins)
        .onAppear {
            pins.set([
                ImmersiveMapPin(id: 1,
                                coordinate: GeoCoordinate(latitude: 55.75, longitude: 37.62),
                                image: .remote(photoURL, placeholder: placeholder)),
            ])
        }
}
```

- **The picture.** A `CGImage`, or `.remote(url, placeholder:)`, which the map downloads and shows the placeholder until then.
- **Look.** `borderColor`, `screenSizeScale`, and `drawPriority`, where a higher priority draws on top.
- **Changes.** `add`, `upsert`, `set`, `move(id:to:)`, `update(id:image:borderColor:isSelected:)`, `remove(ids:)` and `clear()`. The controller is thread-safe, so you can update it from any thread.
- **Groups.** `merge(ids:...)` shows several pins as one, with a counter and their pictures in turn, and `unmerge(mergedID:)` splits them again.

The size and the border of every pin are set with `.pinSettings(size:sizeScale:borderWidthPx:...)`.

### Pins that make room

Pins that would overlap push each other apart. A pin pushed off its place stays tied to it by a beam, like a pin on a rubber band, and comes back when there is room. Turn it off when the exact place matters more than seeing every pin whole:

```swift
ImmersiveMapView()
    .pinSettings(spreadsApart: false)
```

Then every pin stands exactly on its coordinate, and pins may cover each other.

## Taps

```swift
ImmersiveMapView()
    .onPinTap { event in
        print("tapped pin \(event.pin.id)")
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

A tap selects a pin, a model or a shape of a layer, and a tap on the empty map clears the selection. `onSelectionChanged` and `onSelectionCleared` report it, and `select(_:)` and `clearSelection()` change it from code:

```swift
selection.select(ImmersiveMapSelection(kind: .pin, objectID: 1))
```

A selection names its object by a `kind` and the object's id: `.pin`, `.sceneModel`, or `.layer("zones")` for a shape of a layer (see [Your own data](Layers.md)). The kinds are an open set, so a `switch` over one needs a `default`.
