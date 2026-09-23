// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The archive addresses tiles by one integer: every tile of every zoom
/// below comes first, then the tiles of the zoom on a Hilbert curve, so
/// neighbours on the map are neighbours in the file and one range request
/// fetches a cluster.
package enum PMTilesTileID {
    /// The highest zoom the id fits in 64 bits for.
    package static let maximumZoom = 31

    /// The id of tile z/x/y, or `nil` when the coordinates lie outside the
    /// zoom's grid.
    package static func id(z: Int, x: Int, y: Int) -> UInt64? {
        guard z >= 0, z <= maximumZoom else {
            return nil
        }
        let side = UInt64(1) << UInt64(z)
        guard x >= 0, y >= 0, UInt64(x) < side, UInt64(y) < side else {
            return nil
        }
        // Tiles at all lower zooms: (4^z - 1) / 3.
        var accumulator = ((UInt64(1) << (2 * UInt64(z))) - 1) / 3
        var tx = UInt64(x)
        var ty = UInt64(y)
        var s = side / 2
        while s > 0 {
            let rx = tx & s
            let ry = ty & s
            accumulator += ((3 * rx) ^ ry) * s
            if ry == 0 {
                if rx != 0 {
                    tx = side - 1 - tx
                    ty = side - 1 - ty
                }
                swap(&tx, &ty)
            }
            s /= 2
        }
        return accumulator
    }
}
