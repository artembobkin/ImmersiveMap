// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
@testable import ImmersiveMap

extension TileMvtParser {
    /// A parser wired the way `TileRenderStore` wires it, from one settings
    /// value: the runtime map style and the label profile the settings'
    /// style makes, the parse options picked out of the settings, and the
    /// legacy atlas coverage. A test hands its own style or coverage when
    /// that is what it exercises.
    static func forTests(settings: ImmersiveMapSettings,
                         mapStyle: (any ImmersiveMapVectorTileStyle)? = nil,
                         schema: (any ImmersiveMapTileSchema)? = nil,
                         glyphCoverage: VectorTileLabelGlyphCoverage = .legacyAtlasForTests) -> TileMvtParser {
        let runtimeContext = MapStyleRuntime(mapStyle: settings.mapStyle, settings: settings, style: mapStyle, schema: schema)
        return TileMvtParser(mapStyle: runtimeContext,
                             labelDecisions: TileLabelDecisions(schema: runtimeContext.schema,
                                                                style: runtimeContext.style,
                                                                glyphCoverage: glyphCoverage,
                                                                language: settings.labels.language,
                                                                fallbackPolicy: settings.labels.fallbackPolicy),
                             options: TileParseOptions(settings: settings))
    }
}
