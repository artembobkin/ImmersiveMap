// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

typealias MultiPoint = [Point]

class DecodePoint {
    private func decodeZigZag32(_ value: UInt32) -> Int32 {
        let v = Int64(value >> 1)
        return Int32(v ^ ((value & 1) == 0 ? 0 : -1))
    }

    func decode(geometry: [UInt32]) -> MultiPoint {
        guard !geometry.isEmpty else { return [] }

        var points: [Point] = []
        var cursorX: Int32 = 0
        var cursorY: Int32 = 0
        var index = 0

        while index < geometry.count {
            let cmdInteger = geometry[index]
            index += 1
            let cmd = cmdInteger & 0x7
            let count = Int(cmdInteger >> 3)

            if cmd == 1 || cmd == 2 {
                for _ in 0..<count {
                    guard index + 1 < geometry.count else { break }
                    let dx = decodeZigZag32(geometry[index])
                    let dy = decodeZigZag32(geometry[index + 1])
                    index += 2
                    cursorX += dx
                    cursorY += dy
                    points.append(Point(x: cursorX, y: cursorY))
                }
            } else if cmd == 7 {
                continue
            } else {
                break
            }
        }

        return points
    }
}
