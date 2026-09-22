---
paths:
  - "Sources/ImmersiveMap/UI/**"
  - "Sources/ImmersiveMap/Configuration/**"
  - "Sources/ImmersiveMap/Style/**"
  - "Sources/ImmersiveMap/Schema/**"
---

# Public API and style

The code shows how the pieces are wired. These are the decisions behind it, which the code cannot show.

- Rendering parameters live on the style, never in the engine. The engine reads the feature facts from the schema and the drawing parameters from the style and decides nothing of its own: a road's width, level, class priority, what its surface does to paint, every decoration's dimensions, a colour, a cap, a join. A new drawing knob is a field on the style (`Style/`), not a constant in a shader, a parser or a resolver.
- The schema and the style are two halves and stay separate. The schema (`Schema/`) says what a feature is and answers with facts. The style (`Style/`) says only how it draws, reading the facts from its context. Schema-specific logic never reaches `Render`, `Tile` or `Labels`, which consume only normalized data.
- There is no tile-provider abstraction, on purpose. The tile source is the URL template plus request headers, and everything about interpreting the bytes belongs to the map style. Do not introduce a provider protocol.
- A style's configuration fingerprint is part of the disk-cache identity. A change to what a style's configuration means must change the fingerprint, or a warm cache keeps serving tiles baked under the old configuration.
