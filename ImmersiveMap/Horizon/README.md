# Horizon

`Horizon` owns the CPU-side model of the surface's visible edge and of the
air painted around it: the limb of the sphere the surface currently lives on
(the resting globe, or the growing sphere of the unroll) and the plane's
horizon, which is the same edge at zero curvature.

This folder is the maths and the per-frame decisions. Drawing belongs in
`Render/Horizon` and `Render/Shaders/Horizon`.

## Responsibilities

- Resolve the edge for a frame: the eye's local vertical, the limb's
  depression below it, the distance to the limb, in one formula that needs no
  branch for the plane.
- Mirror the shader's edge angle, bit for bit, so tests and CPU consumers
  agree with the picture.
- Decide, per frame, what the horizon layer paints: the globe's atmosphere
  (optional), the limb feather that hides the tile mesh's staircase (always),
  the flat map's fog band (always), and how the first two hand over to the
  last through the morph.

## May Contain

- Deterministic edge and profile math.
- The per-frame resolver that turns settings, transition and camera into the
  horizon uniform's values and the draw decisions.
- Public-safe constants for the atmosphere's and the fog band's shape.

## Must Not Contain

- Metal pipelines, shader files, render passes, or GPU buffer management.
- Tile loading, parsing, styling, or provider adaptation.
- Camera controllers, UI gestures, or host-app code.

## Intended Flow

```text
Settings, transition, camera
  -> horizon edge and haze schedule
  -> horizon uniform (Render/Horizon)
  -> horizon layer of the world pass
```
