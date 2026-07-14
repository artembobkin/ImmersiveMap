// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

/// Замеры пер-кадровой стоимости аватарного пайплайна на больших объёмах
/// (цель - 30 000 маркеров). Тесты печатают тайминги в стиле `[PERF] ...` и
/// проверяют только очень свободные лимиты: смысл - сравнение до/после
/// оптимизаций через `swift test -c release --filter AvatarPerformanceTests`.
final class AvatarPerformanceTests: XCTestCase {
    private static let geometry = AvatarCollisionGeometry(markerSizePx: 128.0,
                                                          bodyRadiusPx: 64.0,
                                                          circleBodyRadiusPx: 59.0,
                                                          bodyCenterOffsetPx: 70.0)

    // MARK: - Сценарии солвера

    /// Мировой зум: весь город слетелся в одну кучу - критический путь
    /// группировки (все 30k в одной компоненте, один цветок).
    func testSolverPile30k() throws {
        let markers = try Self.makePile(count: 30_000,
                                        center: SIMD2(800, 500),
                                        radius: 150.0)
        Self.measureSolver(label: "solver.pile30k", markers: markers, frames: 4)
    }

    /// Средний зум: маркеры разбросаны по 4K-экрану плотнее порога касания,
    /// но реже порога группировки - худший случай свободных кружков.
    func testSolverSpread2k() throws {
        let markers = try Self.makeSpread(count: 2_000,
                                          size: SIMD2(3840, 2160),
                                          spacing: 78.0)
        Self.measureSolver(label: "solver.spread2k", markers: markers, frames: 8)
    }

    /// Смешанная сцена: 200 «домов» по ~50 человек на FHD-экране - много
    /// цветков + свободные кружки между ними.
    func testSolverClusters10k() throws {
        let markers = try Self.makeClusters(total: 10_000,
                                            clusterCount: 200,
                                            clusterRadius: 60.0,
                                            size: SIMD2(1920, 1080))
        Self.measureSolver(label: "solver.clusters10k", markers: markers, frames: 4)
    }

    // MARK: - Стор презентации

    /// Статичные 30k маркеров: пер-кадровая цена выдачи presented-списка
    /// (без мутаций и анимаций - самый частый случай).
    func testPresentationStore30kStatic() throws {
        let store = AvatarPresentationStateStore()
        let image = try Self.sharedImage()
        var markers: [AvatarMarker] = []
        markers.reserveCapacity(30_000)
        for id in 1...30_000 {
            markers.append(AvatarMarker(id: UInt64(id),
                                        coordinate: GeoCoordinate(latitude: Double(id % 170) - 85.0,
                                                                  longitude: Double(id % 360) - 180.0),
                                        image: image))
        }
        store.apply(snapshot: AvatarsSnapshot(markers: markers,
                                              removedIds: [],
                                              imageUpdateIds: [],
                                              version: 1),
                    time: 0)

        var time: TimeInterval = 0
        var sink = 0
        let stats = Self.measureFrames(frames: 60) {
            time += 1.0 / 60.0
            sink &+= store.presentedEntries(at: time).count
        }
        XCTAssertEqual(sink % 30_000, 0)
        Self.report(label: "presentationStore.static30k", stats: stats)
    }

    // MARK: - Прогон солвера

    private static func measureSolver(label: String,
                                      markers: [AvatarProjectedMarker],
                                      frames: Int) {
        let solver = AvatarCollisionLayoutSolver()
        let config = Self.makeConfig()
        var time: TimeInterval = 0

        // Холодный кадр: включает первичную раскладку и создание состояний.
        let coldStart = DispatchTime.now().uptimeNanoseconds
        _ = solver.solve(projectedMarkers: markers, geometry: geometry, config: config, time: time)
        let coldMs = Double(DispatchTime.now().uptimeNanoseconds - coldStart) / 1e6

        // Прогрев до установившегося состояния.
        for _ in 0..<12 {
            time += 1.0 / 60.0
            _ = solver.solve(projectedMarkers: markers, geometry: geometry, config: config, time: time)
        }

        let stats = measureFrames(frames: frames) {
            time += 1.0 / 60.0
            _ = solver.solve(projectedMarkers: markers, geometry: geometry, config: config, time: time)
        }
        report(label: label, stats: stats, coldMs: coldMs)
    }

    // MARK: - Генерация сцен (детерминированный LCG)

    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private static func makePile(count: Int,
                                 center: SIMD2<Float>,
                                 radius: Float) throws -> [AvatarProjectedMarker] {
        var generator = SplitMix(state: 42)
        return try (1...count).map { id in
            let angle = Float.random(in: 0..<(2 * .pi), using: &generator)
            let distance = radius * Float.random(in: 0...1, using: &generator).squareRoot()
            return try makeProjected(id: UInt64(id),
                                     position: center + SIMD2(cos(angle), sin(angle)) * distance)
        }
    }

    private static func makeSpread(count: Int,
                                   size: SIMD2<Float>,
                                   spacing: Float) throws -> [AvatarProjectedMarker] {
        var generator = SplitMix(state: 7)
        let columns = Int((size.x / spacing).rounded(.down))
        return try (1...count).map { id in
            let column = (id - 1) % columns
            let row = (id - 1) / columns
            let jitter = SIMD2(Float.random(in: -8...8, using: &generator),
                               Float.random(in: -8...8, using: &generator))
            return try makeProjected(id: UInt64(id),
                                     position: SIMD2(Float(column) * spacing + spacing * 0.5,
                                                     Float(row) * spacing + spacing * 0.5) + jitter)
        }
    }

    private static func makeClusters(total: Int,
                                     clusterCount: Int,
                                     clusterRadius: Float,
                                     size: SIMD2<Float>) throws -> [AvatarProjectedMarker] {
        var generator = SplitMix(state: 1234)
        let centers = (0..<clusterCount).map { _ in
            SIMD2(Float.random(in: 0...size.x, using: &generator),
                  Float.random(in: 0...size.y, using: &generator))
        }
        return try (1...total).map { id in
            let center = centers[(id - 1) % clusterCount]
            let angle = Float.random(in: 0..<(2 * .pi), using: &generator)
            let distance = clusterRadius * Float.random(in: 0...1, using: &generator)
            return try makeProjected(id: UInt64(id),
                                     position: center + SIMD2(cos(angle), sin(angle)) * distance)
        }
    }

    // MARK: - Замер и отчёт

    private struct FrameStats {
        let minMs: Double
        let medianMs: Double
        let maxMs: Double
    }

    private static func measureFrames(frames: Int, _ body: () -> Void) -> FrameStats {
        var samples: [Double] = []
        samples.reserveCapacity(frames)
        for _ in 0..<frames {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        samples.sort()
        return FrameStats(minMs: samples[0],
                          medianMs: samples[samples.count / 2],
                          maxMs: samples[samples.count - 1])
    }

    private static func report(label: String, stats: FrameStats, coldMs: Double? = nil) {
        let cold = coldMs.map { String(format: " cold=%.2fms", $0) } ?? ""
        let line = String(format: "[PERF] %@%@ warm(min=%.2f median=%.2f max=%.2f)ms",
                          label, cold, stats.minMs, stats.medianMs, stats.maxMs)
        print(line)
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    // MARK: - Хелперы входа

    private static func makeConfig() -> ImmersiveMapSettings.AvatarSettings {
        var config = ImmersiveMapSettings.default.avatars
        config.smoothing = 0.35
        return config
    }

    private static func makeProjected(id: UInt64,
                                      position: SIMD2<Float>) throws -> AvatarProjectedMarker {
        AvatarProjectedMarker(marker: AvatarMarker(id: id,
                                                   coordinate: GeoCoordinate(latitude: 0, longitude: 0),
                                                   image: try sharedImage()),
                              squashScale: SIMD2<Float>(repeating: 1),
                              screenPoint: ScreenPointOutput(position: position,
                                                             depth: 0.5,
                                                             visible: 1,
                                                             visibilityAlpha: 1.0),
                              drawOrder: Int(id))
    }

    private static var cachedImage: CGImage?

    private static func sharedImage() throws -> CGImage {
        if let cachedImage {
            return cachedImage
        }
        let bytesPerRow = 4
        var data = Data(repeating: 0xff, count: bytesPerRow)
        let image = data.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(data: baseAddress,
                                          width: 1,
                                          height: 1,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return nil
            }
            return context.makeImage()
        }
        let unwrapped = try XCTUnwrap(image)
        cachedImage = unwrapped
        return unwrapped
    }
}
