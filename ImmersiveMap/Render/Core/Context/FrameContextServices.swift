// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  FrameContextServices.swift
//  ImmersiveMap
//

import Foundation

protocol FrameDiagnosticsService: AnyObject {
    func incrementCounter(_ counter: FrameDiagnostics.Counter, by value: Int)
    func setCounter(_ counter: FrameDiagnostics.Counter, value: Int)
    func setMeasurement(_ measurement: FrameDiagnostics.Measurement, value: Double)
    func recordSkipReason(_ reason: RenderSkipReason)
}

struct FrameContextServices {
    let diagnostics: any FrameDiagnosticsService
    let settings: ImmersiveMapSettings
    let now: Date
}
