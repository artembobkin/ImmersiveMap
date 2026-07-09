// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

typealias LineString = [Point]
typealias MultiLineString = [LineString]

class DecodeLine {
    private func decodeZigZag32(_ value: UInt32) -> Int32 {
        let v = Int64(value >> 1)
        return Int32(v ^ ((value & 1) == 0 ? 0 : -1))
    }
    
    func decode(geometry: [UInt32]) -> MultiLineString {
        guard !geometry.isEmpty else { return [] }
        
        var i = 0
        var cursorX: Int32 = 0
        var cursorY: Int32 = 0
        var result: [LineString] = []
        
        while i < geometry.count {
            // Parse MoveTo (command ID 1, count 1)
            guard i < geometry.count else { return [] }
            let moveCmd = geometry[i]
            i += 1
            let moveId = Int(moveCmd & 0x7)
            let moveCount = Int(moveCmd >> 3)
            guard moveId == 1 && moveCount == 1 else { return [] }
            
            guard i + 1 < geometry.count else { return [] }
            let dxU1 = geometry[i]; i += 1
            let dyU1 = geometry[i]; i += 1
            let dx1 = decodeZigZag32(dxU1)
            let dy1 = decodeZigZag32(dyU1)
            let px1 = cursorX + dx1
            let py1 = cursorY + dy1
            cursorX = px1
            cursorY = py1
            
            var linePoints: [Point] = [Point(x: px1, y: py1)]
            
            // Parse LineTo (command ID 2, count > 0)
            guard i < geometry.count else { return [] }
            let lineCmd = geometry[i]
            i += 1
            let lineId = Int(lineCmd & 0x7)
            let lineCount = Int(lineCmd >> 3)
            guard lineId == 2 && lineCount > 0 else { return [] }
            
            for _ in 0..<lineCount {
                guard i + 1 < geometry.count else { return [] }
                let dxU = geometry[i]; i += 1
                let dyU = geometry[i]; i += 1
                let dx = decodeZigZag32(dxU)
                let dy = decodeZigZag32(dyU)
                let px = cursorX + dx
                let py = cursorY + dy
                cursorX = px
                cursorY = py
                linePoints.append(Point(x: px, y: py))
            }
            
            result.append(linePoints)
        }
        
        guard i == geometry.count else { return [] }
        return result
    }
}
