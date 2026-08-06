# Tap selection

Two APIs report taps on map content. `.onAvatarTap(_:)` is the raw event: every tap on an [avatar marker](avatars.md), including a repeated tap on one that is already selected. `ImmersiveMapSelectionController` is the state: what is selected now, changed by the user or by the app, with events for both.

```swift
struct MapScreen: View {
    @State private var avatars = ImmersiveMapAvatarsController()
    @State private var selection = ImmersiveMapSelectionController()

    var body: some View {
        ImmersiveMapView()
            .avatars(avatars)
            .selection(selection)
            .onAvatarTap { event in
                print("tapped \(event.marker.id) at \(event.screenPoint)")
            }
            .onAppear {
                selection.onSelectionChanged = { event in
                    print("selected \(event.selection.objectID) via \(event.source)")
                }
                selection.onSelectionCleared = { _ in
                    print("nothing selected")
                }
                selection.onMapBackgroundTap = { point in
                    print("tapped empty map at \(point)")
                }
            }
    }
}
```

Use `onAvatarTap` when a tap is a command ("open this person's card"). Use the selection controller when the tap changes state the rest of the UI reads ("this marker is the current one").

## Controller

```swift
@MainActor
public final class ImmersiveMapSelectionController {
    public var onSelectionChanged: ((ImmersiveMapSelectionChangeEvent) -> Void)?
    public var onSelectionCleared: ((ImmersiveMapSelectionClearEvent) -> Void)?
    public var onMapBackgroundTap: ((CGPoint) -> Void)?

    public func currentSelection() -> ImmersiveMapSelection?
    @discardableResult public func select(_ selection: ImmersiveMapSelection) -> Bool
    @discardableResult public func clearSelection() -> Bool
}
```

`select` and `clearSelection` return `false` when the controller is not attached to a live map view, so a command issued before the view exists is reported rather than silently dropped.

## Types

```swift
public struct ImmersiveMapSelection: Equatable {
    public enum Kind: String { case avatar }
    public let kind: Kind
    public let objectID: UInt64
}

public enum ImmersiveMapSelectionSource: String {
    case tap            // the user
    case programmatic   // select(_:) / clearSelection()
    case system         // the engine, e.g. the selected object went away
}

public struct ImmersiveMapSelectionChangeEvent: Equatable {
    public let selection: ImmersiveMapSelection
    public let source: ImmersiveMapSelectionSource
    public let screenPoint: CGPoint?
}

public struct ImmersiveMapSelectionClearEvent: Equatable {
    public let previousSelection: ImmersiveMapSelection
    public let source: ImmersiveMapSelectionSource
    public let screenPoint: CGPoint?
}
```

`source` is what lets a handler avoid a feedback loop: a UI that calls `select` in response to its own list tap will see the resulting event with `.programmatic` and can ignore it. `screenPoint` is present for taps and `nil` for everything else, which is what a popover anchored to the marker needs.

Selection state and avatar appearance are separate. To make a selected marker look selected, tell the avatars controller:

```swift
selection.onSelectionChanged = { event in
    avatars.update(id: event.selection.objectID,
                   borderColor: SIMD4<Float>(0.2, 0.6, 1.0, 1.0),
                   isSelected: true)
}
```

## Tapping SwiftUI markers

[SwiftUI markers](markers.md) do not go through this API at all. They are real platform views above the map, so a `Button` or `onTapGesture` inside a marker works as usual and a touch that starts on a marker belongs to the marker: the map does not pan, zoom or select from it. `onMapBackgroundTap` therefore does not fire for a tap that landed on a marker view.

## Limitations

- **Avatars only.** `ImmersiveMapSelection.Kind` has a single case today. [Routes](routes.md) and [3D scene models](scene-models.md) are not tappable, and neither are vector tile features (roads, buildings, POIs).
- One selection at a time; there is no multi-select.
- A merged avatar cluster is selectable as itself. Selecting a member that is currently hidden inside a group is not.

Running example: [`Examples/ImmersiveMapAvatarsMac`](../../Examples/ImmersiveMapAvatarsMac) shows the tap event and the selection state side by side, and drives selection from buttons as well as from the map.
