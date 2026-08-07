# Tap selection

Two kinds of API report taps on map content.

- The **per-kind events** are raw: `.onAvatarTap(_:)` fires for every tap on an [avatar marker](avatars.md), `.onSceneModelTap(_:)` for every tap on a [3D scene model](scene-models.md), including a repeated tap on something already selected.
- `ImmersiveMapSelectionController` is the **state**: what is selected now, changed by the user or by the app, with events for both.

```swift
struct MapScreen: View {
    @State private var avatars = ImmersiveMapAvatarsController()
    @State private var sceneModels = ImmersiveMapSceneModelsController()
    @State private var selection = ImmersiveMapSelectionController()

    var body: some View {
        ImmersiveMapView()
            .avatars(avatars)
            .sceneModels(sceneModels)
            .selection(selection)
            .onAvatarTap { event in
                print("tapped avatar \(event.marker.id) at \(event.screenPoint)")
            }
            .onSceneModelTap { event in
                print("tapped model \(event.model.id) at \(event.coordinate)")
            }
            .onAppear {
                selection.onSelectionChanged = { event in
                    print("selected \(event.selection.kind) \(event.selection.objectID)")
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

Use the per-kind events when a tap is a command ("open this person's card"). Use the selection controller when the tap changes state the rest of the UI reads ("this one is the current one").

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
    public enum Kind: String { case avatar, sceneModel }
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

`objectID` is only unique within its `kind`: an avatar and a scene model may both be id 1, so always switch on `kind` before looking the object up.

`source` is what lets a handler avoid a feedback loop: a UI that calls `select` in response to its own list tap will see the resulting event with `.programmatic` and can ignore it. `screenPoint` is present for taps and `nil` for everything else, which is what a popover anchored to the marker needs.

## Appearance is the app's

Selection state carries no appearance of its own. For avatars the controller can draw one for you, but the highlight is yours to move: the controller holds one selection, and nothing clears the previous marker unless you do.

```swift
@State private var highlightedAvatarID: UInt64?

selection.onSelectionChanged = { event in
    clearAvatarHighlight()
    guard event.selection.kind == .avatar else { return }
    avatars.update(id: event.selection.objectID,
                   borderColor: SIMD4<Float>(0.2, 0.6, 1.0, 1.0),
                   isSelected: true)
    highlightedAvatarID = event.selection.objectID
}

selection.onSelectionCleared = { _ in
    clearAvatarHighlight()
}

func clearAvatarHighlight() {
    guard let id = highlightedAvatarID else { return }
    avatars.update(id: id, isSelected: false)
    highlightedAvatarID = nil
}
```

For scene models there is no equivalent: the engine draws the asset as authored, so highlighting a selected model is the app's job (swap the source, nudge the scale, or put a [SwiftUI marker](markers.md) over it).

## Resolution order

When several things overlap a tap:

- **Avatars beat models.** Avatar markers are screen-space overlays drawn over the world pass, so one covering a model takes the tap. An unhandled avatar tap falls through to the model underneath.
- **Nearest model wins.** Overlapping scene models resolve to the one closest to the camera.
- Anything past the globe horizon is not tappable at all, because it is not drawn.

## Tapping SwiftUI markers

[SwiftUI markers](markers.md) do not go through this API at all. They are real platform views above the map, so a `Button` or `onTapGesture` inside a marker works as usual and a touch that starts on a marker belongs to the marker: the map does not pan, zoom or select from it. `onMapBackgroundTap` therefore does not fire for a tap that landed on a marker view.

## Limitations

- **Avatars and scene models only.** [Routes](routes.md) are not tappable, and neither are vector tile features (roads, buildings, POIs).
- One selection at a time; there is no multi-select.
- A merged avatar cluster is selectable as itself. Selecting a member that is currently hidden inside a group is not.
- Model hit-testing uses the asset's bounding box rather than its triangles, and does not consult depth, see [3D scene models](scene-models.md).

Running examples: [`Examples/ImmersiveMapAvatarsMac`](../../Examples/ImmersiveMapAvatarsMac) shows the tap event and the selection state side by side, and drives selection from buttons as well as from the map; [`Examples/ImmersiveMapRoutesMac`](../../Examples/ImmersiveMapRoutesMac) taps a model in mid-flight.
