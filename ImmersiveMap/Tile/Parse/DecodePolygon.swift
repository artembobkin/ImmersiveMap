// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct Point {
    let x: Int32
    let y: Int32
}

struct Polygon {
    let exteriorRing: [Point]
    let interiorRings: [[Point]]
}

typealias MultiPolygon = [Polygon]

class DecodePolygon {
    private func decodeZigZag32(_ value: UInt32) -> Int32 {
        let v = Int64(value >> 1)
        return Int32(v ^ ((value & 1) == 0 ? 0 : -1))
    }
    
    private func computeShoelace(_ points: [Point]) -> Int64 {
        guard points.count >= 3 else { return 0 }
        var sum: Int64 = 0
        let n = points.count
        for idx in 0..<n {
            let jdx = (idx + 1) % n
            let xi = Int64(points[idx].x)
            let yi = Int64(points[idx].y)
            let xj = Int64(points[jdx].x)
            let yj = Int64(points[jdx].y)
            sum += xi * yj - xj * yi
        }
        return sum
    }
    
    func decode(geometry: [UInt32]) -> MultiPolygon {
        guard !geometry.isEmpty else { return [] }
        
        var i = 0
        var cursorX: Int32 = 0
        var cursorY: Int32 = 0
        var result: [Polygon] = []
        var currentExterior: [Point]? = nil
        var currentInteriors: [[Point]] = []
        
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
            
            var ringPoints: [Point] = [Point(x: px1, y: py1)]
            
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
                ringPoints.append(Point(x: px, y: py))
            }
            
            // Parse ClosePath (command ID 7, count 1)
            guard i < geometry.count else { return [] }
            let closeCmd = geometry[i]
            i += 1
            let closeId = Int(closeCmd & 0x7)
            let closeCount = Int(closeCmd >> 3)
            guard closeId == 7 && closeCount == 1 else { return [] }
            
            // Compute signed area
            let signedSum = computeShoelace(ringPoints)
            let isExterior = signedSum > 0
            
            if isExterior {
                // Finish previous polygon if exists
                if let prevExterior = currentExterior {
                    let poly = Polygon(exteriorRing: prevExterior, interiorRings: currentInteriors)
                    result.append(poly)
                    currentInteriors = []
                }
                // Start new polygon
                currentExterior = ringPoints
            } else {
                // Interior ring
                guard currentExterior != nil else { return [] }
                currentInteriors.append(ringPoints)
            }
        }
        
        // Add the last polygon
        if let lastExterior = currentExterior {
            let lastPoly = Polygon(exteriorRing: lastExterior, interiorRings: currentInteriors)
            result.append(lastPoly)
        }
        
        // For valid input, all geometry should be consumed
        guard i == geometry.count else { return [] }
        
        return result
    }
}
