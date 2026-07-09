// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  FrameDiagnostics.swift
//  ImmersiveMap
//

import Foundation

final class FrameDiagnostics: FrameDiagnosticsService {
    enum Counter: String, CaseIterable {
        case visibleTiles
        case requestedTiles
        case readyTiles
        case renderedTiles
        case retainedTiles
        case baseLabelCount
        case baseLabelFullTileCount
        case baseLabelReducedTileCount
        case baseLabelMinimalTileCount
        case roadLabelGlyphCount
        case roadLabelInstanceCount
        case roadLabelNearCameraCulledPathCount
        case roadLabelNearCameraCulledAnchorCount
        case resourceBufferCount
        case resourceTextureCount
        case resourcePipelineCount
        case encodedPasses
        case globeCullingVisitedNodes
        case globeCullingFrustumRejects
        case globeCullingHorizonRejects
        case globeCullingAcceptedLeafTiles
        case globeCullingAcceptedWholeSubtrees
    }

    enum Measurement: String, CaseIterable {
        case globeCullingDurationMs
    }

    private(set) var frameIndex: UInt64
    private(set) var frameTime: TimeInterval
    private(set) var stageDurations: [FrameStage: TimeInterval] = [:]
    private(set) var metalPassDurations: [RenderPassName: TimeInterval] = [:]
    private(set) var layerDurations: [RenderLayer: TimeInterval] = [:]
    private(set) var counters: [Counter: Int] = [:]
    private(set) var measurements: [Measurement: Double] = [:]
    private(set) var skipReasons: Set<RenderSkipReason> = []

    init(frameIndex: UInt64, frameTime: TimeInterval) {
        self.frameIndex = frameIndex
        self.frameTime = frameTime
        for counter in Counter.allCases {
            counters[counter] = 0
        }
        for measurement in Measurement.allCases {
            measurements[measurement] = 0
        }
    }

    func recordStage(_ stage: FrameStage, duration: TimeInterval) {
        stageDurations[stage] = duration
    }

    func recordLayer(_ layer: RenderLayer, duration: TimeInterval) {
        layerDurations[layer] = duration
    }

    func recordMetalPass(_ pass: RenderPassName, duration: TimeInterval) {
        metalPassDurations[pass] = duration
        incrementCounter(.encodedPasses, by: 1)
    }

    func incrementCounter(_ counter: Counter, by value: Int = 1) {
        counters[counter, default: 0] += value
    }

    func setCounter(_ counter: Counter, value: Int) {
        counters[counter] = value
    }

    func counterValue(_ counter: Counter) -> Int {
        counters[counter, default: 0]
    }

    func setMeasurement(_ measurement: Measurement, value: Double) {
        measurements[measurement] = value
    }

    func measurementValue(_ measurement: Measurement) -> Double {
        measurements[measurement, default: 0]
    }

    func recordSkipReason(_ reason: RenderSkipReason) {
        skipReasons.insert(reason)
    }

    func summaryLine() -> String {
        let updateMs = (stageDurations[.updateScene] ?? 0) * 1000.0
        let prepareMs = (stageDurations[.prepareGPU] ?? 0) * 1000.0
        let encodeMs = (stageDurations[.encodePasses] ?? 0) * 1000.0
        let presentMs = (stageDurations[.presentFrame] ?? 0) * 1000.0
        let tileSummary = "tiles v:\(counterValue(.visibleTiles)) r:\(counterValue(.readyTiles)) q:\(counterValue(.requestedTiles))"
        let labelSummary = "labels b:\(counterValue(.baseLabelCount)) rg:\(counterValue(.roadLabelGlyphCount)) rc:\(counterValue(.roadLabelNearCameraCulledPathCount))/\(counterValue(.roadLabelNearCameraCulledAnchorCount))"
        let globeSummary = "globeCull ms:\(String(format: "%.2f", measurementValue(.globeCullingDurationMs))) n:\(counterValue(.globeCullingVisitedNodes)) f:\(counterValue(.globeCullingFrustumRejects)) h:\(counterValue(.globeCullingHorizonRejects)) l:\(counterValue(.globeCullingAcceptedLeafTiles)) a:\(counterValue(.globeCullingAcceptedWholeSubtrees))"
        let metalPassSummary = metalPassDurations
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue):\(String(format: "%.2f", $0.value * 1000.0))" }
            .joined(separator: ",")
        let layerSummary = layerDurations
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue):\(String(format: "%.2f", $0.value * 1000.0))" }
            .joined(separator: ",")
        return "frame=\(frameIndex) \(tileSummary) \(labelSummary) \(globeSummary) stageMs[u:\(String(format: "%.2f", updateMs)) p:\(String(format: "%.2f", prepareMs)) e:\(String(format: "%.2f", encodeMs)) pr:\(String(format: "%.2f", presentMs))] metalPassMs[\(metalPassSummary)] layerMs[\(layerSummary)]"
    }
}
