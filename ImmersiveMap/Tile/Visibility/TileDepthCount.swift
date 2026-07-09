// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

class TileDepthCount {
    // depth = 0 -> cover the whole texture. Capacity: 0 tiles
    // depth = 1 -> cover 1/4 of the texture. Capacity: 1 tile
    // depth = 2 -> cover 1/8 of the texture.
    // depth = 3 -> cover 1/16 of the texture
    
    var depth1Count = 0
    var depth2Count = 0
    var depth3Count = 0
    var depth4Count = 0
    
    let depth1Capacity = 1
    let depth2Capacity = 8
    let depth3Capacity = 5
    let depth4Capacity = 16 + 28
    
    func getTexturePlaceDepth() -> UInt8? {
        if depth1Count < depth1Capacity {
            depth1Count += 1
            return 1
        } else if depth2Count < depth2Capacity {
            depth2Count += 1
            return 2
        } else if depth3Count < depth3Capacity {
            depth3Count += 1
            return 3
        } else if depth4Count < depth4Capacity {
            depth4Count += 1
            return 4
        }
        
        return nil
    }
    
    func getFullCapacity() -> Int {
        return depth1Capacity + depth2Capacity + depth3Capacity + depth4Capacity
    }
    
    func getOccupedCount() -> Int {
        return depth1Count + depth2Count + depth3Count + depth4Count
    }
}
