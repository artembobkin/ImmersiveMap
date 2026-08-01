# VideoExport

`VideoExport` owns the AVFoundation side of offline tour video export: the
public export configuration/progress/error types and the QuickTime writer that
encodes rendered frames into a file.

The rendering side of export (offscreen targets, scripted clock, pixel-buffer
textures) lives in `Render`; the public recorder controller and the export
frame loop live in `UI`.

## Responsibilities

- Define the public video export configuration, progress, and error types.
- Encode `CVPixelBuffer` frames into a QuickTime file via `AVAssetWriter`
  (HEVC/H.264, fixed-step presentation times, BT.709 tagging).
- Vend pool pixel buffers for the render side to draw into.

## May Contain

- AVFoundation / CoreVideo / CoreMedia writer code.
- Public value types describing export options and progress.
- Pure helpers for bit-rate and timing math.

## Must Not Contain

- Metal code, render graph code, textures, or GPU resource lifetime.
- UIKit/AppKit/SwiftUI views, controllers, or host-app lifecycle code.
- Camera, tile, label, or avatar state.
- Network clients or credentials.
