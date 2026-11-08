// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Where the ground relief's heights come from: terrain tiles at a URL
/// template, how their pixels hold a height, and the credit the data asks
/// for. Only the source: how the relief draws is
/// `ImmersiveMapView.groundRelief(...)`.
///
///     ImmersiveMapView()
///         .terrain(ImmersiveMapTerrainSource(tileURLTemplate: "https://terrain.example.com/{z}/{x}/{y}.png",
///                                            encoding: .mapbox,
///                                            credit: "© Example Terrain"))
///         .groundRelief(isEnabled: true)
///
/// The default is `mapterhorn`.
public struct ImmersiveMapTerrainSource: Equatable, Sendable {
    /// The terrain tiles: a URL with `{z}`, `{x}` and `{y}` in it, of square
    /// images (PNG or WebP, of any size) whose pixels hold heights in
    /// `encoding`. A file URL reads a terrain directory on disk. An HTTP 404,
    /// or a file that is not there, is a tile the source does not have.
    public var tileURLTemplate: String
    /// How a pixel of a terrain tile holds its height.
    public var encoding: ImmersiveMapSettings.TileSettings.GroundReliefEncoding
    /// The credit the terrain's license asks for, laid on the attribution
    /// line at the camera zooms the relief stands out of the plane at
    /// (`GroundReliefSettings.appearZoom` up to `collapseZoom`). Nil credits
    /// nothing, for a source whose credit the app states itself with
    /// `attributionSettings`.
    public var credit: String?

    public init(tileURLTemplate: String,
                encoding: ImmersiveMapSettings.TileSettings.GroundReliefEncoding = .terrarium,
                credit: String? = nil) {
        self.tileURLTemplate = tileURLTemplate
        self.encoding = encoding
        self.credit = credit
    }

    /// Mapterhorn's open global terrain, in Terrarium: 30 m everywhere to
    /// zoom 12, and lidar deeper where a country publishes it. Credited as
    /// Mapterhorn asks.
    public static let mapterhorn = ImmersiveMapTerrainSource(tileURLTemplate: "https://tiles.mapterhorn.com/{z}/{x}/{y}.webp",
                                                             encoding: .terrarium,
                                                             credit: "© Mapterhorn")
}
