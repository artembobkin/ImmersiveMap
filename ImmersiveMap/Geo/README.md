# Geo

`Geo` owns shared geographic projection logic used by the engine.

This folder should stay small and mathematical. It translates between map-space
representations without knowing about providers, rendering passes, or UI
controls.


The tile-geometry y-axis contract (tile space vs render space vs UV vs
world) is stated once, in `Tile/README.md` and `TileCoordinateSpace`.

## Responsibilities

- Define projection behavior used across the map engine.
- Keep coordinate transformation math reusable and deterministic.
- Provide geographic helpers that are independent of runtime ownership.

## May Contain

- Projection enums and projection-specific helper functions.
- Coordinate conversion math shared by camera, tiles, presentation, or render
  code.
- Small value types that describe geographic transformations.
- Great-circle math and path sampling shared by route rendering and scene model
  animation.

## Must Not Contain

- Camera controllers, gesture handlers, or user interaction state.
- Metal resources, render passes, shaders, or GPU buffer ownership.
- Vector tile provider adaptation, tile downloading, or network authorization.
- Label, avatar, or UI runtime logic.
- Host-app configuration, local secrets, or public API unrelated to geography.
