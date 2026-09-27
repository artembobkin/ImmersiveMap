// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// One numbered route a road carries, as the schema reading states it: the
/// network the route belongs to and what its sign reads. A road that is
/// part of several routes (a national road that is also a European one)
/// carries one of these per route, in the order the source lists them.
///
/// The network is the source's own vocabulary (OpenStreetMap's `network`
/// tag: `ru:national`, `e-road`, `US:I`, `BAB`), passed through as it is.
/// The engine never reads it: the style decides from it what sign a route
/// is drawn on, or whether it is drawn at all.
public struct ImmersiveMapRouteFacts: Equatable, Sendable {
    /// The route's network, empty when the source names none (a road
    /// that states its number but belongs to no route the source knows).
    public var network: String
    /// What the route's sign reads: `М-9`, `E22`, `95`, `A3`.
    public var text: String

    public init(network: String = "", text: String) {
        self.network = network
        self.text = text
    }
}
