// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import TileFlattening

final class FlattenerTests: XCTestCase {
    private func opaque(_ index: Int) -> FlatColor {
        FlatColor(r: UInt8(40 + index * 23 % 200), g: UInt8(index * 67 % 256), b: UInt8(255 - index * 41 % 256))
    }

    /// Compares the mesh with the brute-force reference at random points and checks that it is closed.
    private func verify(
        _ input: FlattenInput,
        _ options: FlattenOptions,
        samples: Int,
        seed: UInt64,
        _ label: String,
        closed: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let mesh = Flattener.flatten(input, options: options)
        let report = inspect(mesh, options: options)
        // Without a background the mesh has holes, and their outlines are open edges.
        if closed { XCTAssertEqual(report.openEdges, 0, "open edges, \(label)", file: file, line: line) }
        if closed {
            let area = (options.maxX - options.minX) * (options.maxY - options.minY)
            XCTAssertEqual(report.area, area, accuracy: area * 1e-5, "area, \(label)", file: file, line: line)
        }
        XCTAssertEqual(report.mixedColorTriangles, 0, label, file: file, line: line)
        XCTAssertEqual(report.gridCrossingTriangles, 0, label, file: file, line: line)
        XCTAssertEqual(report.flippedTriangles, 0, label, file: file, line: line)

        let reference = Reference(input: input)
        let locator = MeshLocator(mesh: mesh, minX: options.minX, minY: options.minY, maxX: options.maxX, maxY: options.maxY)
        var generator = SeededGenerator(seed: seed)
        var mismatches = 0
        let margin = 1e-3 * max(options.maxX - options.minX, options.maxY - options.minY)
        for _ in 0..<samples {
            let x = Double.random(in: options.minX...options.maxX, using: &generator)
            let y = Double.random(in: options.minY...options.maxY, using: &generator)
            if reference.distanceToEdges(x: x, y: y) < margin { continue }
            let expected = reference.color(x: x, y: y)
            let found = locator.colors(x: x, y: y)
            if expected == 0 {
                if !found.isEmpty { mismatches += 1 }
            } else if found.isEmpty || found.contains(where: { $0 != expected }) {
                mismatches += 1
            }
        }
        XCTAssertEqual(mismatches, 0, "wrong color at sample points, \(label)", file: file, line: line)
    }

    func testSquareOnBackground() {
        var input = FlattenInput()
        let background = input.addPaint(opaque(0))
        let square = input.addPaint(opaque(1))
        input.addRect(minX: 0, minY: 0, maxX: 100, maxY: 100, paint: background)
        input.addRect(minX: 30, minY: 30, maxX: 60, maxY: 70, paint: square)
        var options = FlattenOptions()
        options.maxX = 100
        options.maxY = 100
        for columns in [1, 2, 3, 10] {
            for rows in [1, 4] {
                options.columns = columns
                options.rows = rows
                let mesh = Flattener.flatten(input, options: options)
                let report = inspect(mesh, options: options)
                XCTAssertEqual(report.area, 100 * 100, accuracy: 1e-3)
                XCTAssertEqual(report.openEdges, 0)
                let squareArea = (0..<mesh.triangleCount).reduce(0.0) { sum, t in
                    let v = (0..<3).map { mesh.vertices[Int(mesh.indices[3 * t + $0])] }
                    guard v[0].color == opaque(1).packed else { return sum }
                    return sum + 0.5 * Double((v[1].x - v[0].x) * (v[2].y - v[0].y) - (v[1].y - v[0].y) * (v[2].x - v[0].x))
                }
                XCTAssertEqual(squareArea, 30 * 40, accuracy: 1e-3)
            }
        }
    }

    func testSingleColumnSquareIsMinimal() {
        var input = FlattenInput()
        input.addRect(minX: 0, minY: 0, maxX: 10, maxY: 10, paint: input.addPaint(opaque(0)))
        var options = FlattenOptions()
        options.maxX = 10
        options.maxY = 10
        options.columns = 1
        XCTAssertEqual(Flattener.flatten(input, options: options).triangleCount, 2)
    }

    func testHoleAndSameColorMerge() {
        var input = FlattenInput()
        let ground = input.addPaint(opaque(0))
        let a = input.addPaint(opaque(1))
        let b = input.addPaint(opaque(1))
        input.addRect(minX: 0, minY: 0, maxX: 64, maxY: 64, paint: ground)
        // A ring with a hole: the hole has the opposite orientation.
        input.addRing([SIMD2(8, 8), SIMD2(40, 8), SIMD2(40, 40), SIMD2(8, 40)], paint: a)
        input.addRing([SIMD2(16, 16), SIMD2(16, 32), SIMD2(32, 32), SIMD2(32, 16)], paint: a)
        // A second paint with the same color, overlapping the first.
        input.addRing([SIMD2(24, 24), SIMD2(56, 24), SIMD2(56, 56), SIMD2(24, 56)], paint: b)
        var options = FlattenOptions()
        options.maxX = 64
        options.maxY = 64
        options.columns = 4
        verify(input, options, samples: 4000, seed: 1, "hole")
    }

    func testTranslucentPaintIsBlended() {
        var input = FlattenInput()
        let ground = input.addPaint(FlatColor(r: 0, g: 0, b: 200))
        let glass = input.addPaint(FlatColor(r: 200, g: 0, b: 0, a: 128))
        input.addRect(minX: 0, minY: 0, maxX: 10, maxY: 10, paint: ground)
        input.addRect(minX: 0, minY: 0, maxX: 5, maxY: 10, paint: glass)
        var options = FlattenOptions()
        options.maxX = 10
        options.maxY = 10
        options.columns = 1
        let mesh = Flattener.flatten(input, options: options)
        let colors = Set(mesh.vertices.map(\.color))
        XCTAssertEqual(colors.count, 2)
        let blended = colors.subtracting([FlatColor(r: 0, g: 0, b: 200).packed]).first.map(FlatColor.init(packed:))
        XCTAssertEqual(blended, FlatColor(r: 100, g: 0, b: 100, a: 255))
    }

    func testStrokeCoversItsCenterLine() {
        var input = FlattenInput()
        let ground = input.addPaint(opaque(0))
        let road = input.addPaint(opaque(1))
        input.addRect(minX: 0, minY: 0, maxX: 100, maxY: 100, paint: ground)
        let line: [SIMD2<Double>] = [SIMD2(10, 10), SIMD2(50, 12), SIMD2(52, 60), SIMD2(20, 40), SIMD2(90, 90), SIMD2(88, 86)]
        var options = FlattenOptions()
        options.maxX = 100
        options.maxY = 100
        options.columns = 5
        for join in [LineJoin.bevel, .miter, .round] {
            for cap in [LineCap.butt, .square, .round] {
                var stroked = input
                stroked.addLine(line, width: 6, paint: road, join: join, cap: cap)
                let mesh = Flattener.flatten(stroked, options: options)
                XCTAssertEqual(inspect(mesh, options: options).openEdges, 0)
                let locator = MeshLocator(mesh: mesh, minX: 0, minY: 0, maxX: 100, maxY: 100)
                for segment in 0..<(line.count - 1) {
                    // Stay clear of the vertices: a bevel cuts the corner of a sharp turn.
                    for step in 1..<20 {
                        let p = line[segment] + (line[segment + 1] - line[segment]) * (Double(step) / 20)
                        for offset in [SIMD2(0.05, 0.03), SIMD2(-0.04, 0.05)] {
                            let found = locator.colors(x: p.x + offset.x, y: p.y + offset.y)
                            XCTAssertEqual(found, [opaque(1).packed], "join \(join), cap \(cap), segment \(segment)")
                        }
                    }
                }
            }
        }
    }

    /// Random polygons with real coordinates.
    func testRandomPolygons() {
        for seed in 0..<120 as Range<UInt64> {
            var generator = SeededGenerator(seed: seed)
            var input = FlattenInput()
            // Paint 0 is kept for the background: a shape of the same paint could cut a hole in it.
            let paintCount = Int.random(in: 2...7, using: &generator)
            for p in 0..<paintCount { input.addPaint(opaque(p)) }
            let hasBackground = Bool.random(using: &generator)
            if hasBackground { input.addRect(minX: -10, minY: -10, maxX: 110, maxY: 110, paint: 0) }
            for _ in 0..<Int.random(in: 1...25, using: &generator) {
                let paint = Int.random(in: 1..<paintCount, using: &generator)
                let cx = Double.random(in: -20...120, using: &generator)
                let cy = Double.random(in: -20...120, using: &generator)
                let radius = Double.random(in: 2...60, using: &generator)
                let points = (0..<Int.random(in: 3...9, using: &generator)).map { _ in
                    // Arbitrary point order: the rings cross themselves.
                    SIMD2(cx + Double.random(in: -radius...radius, using: &generator), cy + Double.random(in: -radius...radius, using: &generator))
                }
                if Int.random(in: 0..<4, using: &generator) == 0 {
                    input.addLine(points, width: Double.random(in: 0.5...12, using: &generator), paint: paint,
                                  join: [.bevel, .miter, .round].randomElement(using: &generator)!,
                                  cap: [.butt, .square, .round].randomElement(using: &generator)!)
                } else {
                    input.addRing(points, paint: paint)
                }
            }
            var options = FlattenOptions()
            options.maxX = 100
            options.maxY = 100
            options.columns = Int.random(in: 1...9, using: &generator)
            options.rows = Int.random(in: 1...5, using: &generator)
            options.parallel = Bool.random(using: &generator)
            verify(input, options, samples: 600, seed: seed, "seed \(seed)", closed: hasBackground)
        }
    }

    /// Polygons on a coarse integer grid: shared vertices, overlapping collinear edges, horizontal
    /// edges, and vertices exactly on strip walls and grid rows.
    func testDegenerateGridPolygons() {
        for seed in 0..<250 as Range<UInt64> {
            var generator = SeededGenerator(seed: seed &+ 10_000)
            var input = FlattenInput()
            let paintCount = Int.random(in: 2...6, using: &generator)
            for p in 0..<paintCount { input.addPaint(opaque(p)) }
            let hasBackground = Bool.random(using: &generator)
            if hasBackground { input.addRect(minX: 0, minY: 0, maxX: 16, maxY: 16, paint: 0) }
            for _ in 0..<Int.random(in: 1...20, using: &generator) {
                let paint = Int.random(in: 1..<paintCount, using: &generator)
                let points = (0..<Int.random(in: 3...7, using: &generator)).map { _ in
                    SIMD2(Double(Int.random(in: -2...18, using: &generator)), Double(Int.random(in: -2...18, using: &generator)))
                }
                input.addRing(points, paint: paint)
            }
            var options = FlattenOptions()
            options.maxX = 16
            options.maxY = 16
            options.columns = [1, 2, 4, 8, 16].randomElement(using: &generator)!
            options.rows = [1, 2, 4, 8].randomElement(using: &generator)!
            options.parallel = false
            verify(input, options, samples: 600, seed: seed, "grid seed \(seed)", closed: hasBackground)
        }
    }
}
