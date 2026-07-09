// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

struct TextureValue {
    
}

class GlobeTileTextureTree {
    var root: TextureNode
    var values: [TextureValue] = []
    
    init() {
        self.root = TextureNode(depth: 0, x: 0, y: 0)
    }
    
    func addNewValue(value: TextureValue, depth: UInt8) -> PlacedPos? {
        let placed = root.insertNew(depth: depth)
        return placed
    }
}

struct PlacedPos: Hashable {
    let depth: UInt8
    let x: UInt8
    let y: UInt8
}

class TextureNode {
    let depth: UInt8
    let x: UInt8
    let y: UInt8
    
    init(depth: UInt8, x: UInt8, y: UInt8) {
        self.depth = depth
        self.x = x
        self.y = y
    }
    
    var placedHere: Bool = false
    var lb: TextureNode? // left bottom
    var lt: TextureNode? // left top
    var rt: TextureNode? // right top
    var rb: TextureNode? // right bottom

    private var hasChildren: Bool {
        lb != nil || lt != nil || rt != nil || rb != nil
    }
    
    func insertNew(depth: UInt8) -> PlacedPos? {
        // Place the texture in a slot
        if depth == self.depth && self.placedHere == false && hasChildren == false {
            self.placedHere = true
            return PlacedPos(depth: self.depth, x: self.x, y: self.y)
        }
        
        // Slot already occupied, exit
        if depth == self.depth || placedHere {
            return nil
        }
        
        
        if lb == nil {
            lb = TextureNode(depth: self.depth + 1, x: self.x * 2, y: self.y * 2)
        }
        if lb!.placedHere == false {
            let placed = lb!.insertNew(depth: depth)
            if placed != nil { return placed }
        }
        
        if lt == nil {
            lt = TextureNode(depth: self.depth + 1, x: self.x * 2, y: self.y * 2 + 1)
        }
        if lt!.placedHere == false {
            let placed = lt!.insertNew(depth: depth)
            if placed != nil { return placed }
        }
        
        if rt == nil {
            rt = TextureNode(depth: self.depth + 1, x: self.x * 2 + 1, y: self.y * 2 + 1)
        }
        if rt!.placedHere == false {
            let placed = rt!.insertNew(depth: depth)
            if placed != nil { return placed }
        }
        
        if rb == nil {
            rb = TextureNode(depth: self.depth + 1, x: self.x * 2 + 1, y: self.y * 2)
        }
        if rb!.placedHere == false {
            let placed = rb!.insertNew(depth: depth)
            if placed != nil { return placed }
        }
        
        return nil
    }
}
