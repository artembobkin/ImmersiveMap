// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// macOS only: the probe's whole point is the drawable's actual presented
// time, and `addPresentedHandler` is absent from the iOS SDK's MTLDrawable
// (the macOS header declares it as available on iOS, but the iOS one does not
// declare it at all).
#if DEBUG && os(macOS)

import Foundation
import Metal
import QuartzCore

/// Measures where the two halves of a frame actually land on screen.
///
/// A frame is drawn by the GPU into a display-link drawable, while anything
/// positioned by the main thread in the same turn (the SwiftUI marker views)
/// reaches the screen through the CATransaction that commits at the end of
/// that turn. Those are two different paths, and the gap between them is what
/// makes markers drift from their geo points while the camera moves. The size
/// of that gap cannot be reasoned out: `CAMetalDisplayLink` owns presentation
/// timing, so it has to be read from a running app.
///
/// Enabled by setting `IMMERSIVE_MAP_PRESENT_TIMING` in the environment,
/// optionally to the number of frames to collect (default 240). While
/// collecting, the probe holds an interaction activity so the display link
/// runs continuously, the way it does during a gesture, and prints one
/// summary to stdout when it has enough samples.
@MainActor
final class RenderPresentTimingProbe {
    private struct Sample {
        let index: Int
        let target: CFTimeInterval
        let cpuEnd: CFTimeInterval
        /// Camera state the frame was drawn from, sampled after its
        /// main-thread work. A judder that shows in the picture but not here
        /// is a delivery problem; one that shows in both is a camera problem.
        let zoom: Double
        let centerX: Double
        let centerY: Double
        /// Whether the engine actually scheduled a frame for this tick, and
        /// the reason it did not. A tick can fail to reach the screen two
        /// ways, and they need different fixes: the engine refused to render
        /// it, or it rendered and the drawable's presented callback never
        /// came.
        let didSchedule: Bool
        let skipReason: String?
        var presented: CFTimeInterval?
    }

    /// Written from the Metal presentation thread and read on the main
    /// thread, so every access is behind the lock.
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Sample] = []
        private var isFinished = false

        func append(_ sample: Sample) {
            lock.lock()
            samples.append(sample)
            lock.unlock()
        }

        func recordPresented(index: Int, time: CFTimeInterval) {
            lock.lock()
            if let position = samples.firstIndex(where: { $0.index == index }) {
                samples[position].presented = time
            }
            lock.unlock()
        }

        /// Returns the samples once, the first time the collected count is
        /// reached; later calls return nil so the summary prints exactly once.
        func takeIfComplete(minimumCount: Int) -> [Sample]? {
            lock.lock()
            defer { lock.unlock() }
            guard isFinished == false, samples.count >= minimumCount else {
                return nil
            }
            isFinished = true
            return samples
        }
    }

    private let storage = Storage()
    private let sampleCount: Int
    private let isPassive: Bool
    private var tickIndex = 0
    private var isCollecting = false
    private weak var driver: ImmersiveMapRenderDriver?

    private init(sampleCount: Int, isPassive: Bool) {
        self.sampleCount = sampleCount
        self.isPassive = isPassive
    }

    /// Enabled either by `IMMERSIVE_MAP_PRESENT_TIMING` in the environment or
    /// by the `-immersiveMapPresentTiming <frames>` launch argument. The
    /// argument exists because a GUI app has to be started through `open` to
    /// get a window and a running display link, and `open` forwards arguments
    /// more reliably than it forwards environment.
    static func makeIfEnabled() -> RenderPresentTimingProbe? {
        let environment = ProcessInfo.processInfo.environment["IMMERSIVE_MAP_PRESENT_TIMING"]
        let argument = UserDefaults.standard.string(forKey: "immersiveMapPresentTiming")
        guard let value = environment ?? argument else {
            return nil
        }
        let requested = Int(value) ?? 0
        let isPassive = ProcessInfo.processInfo.environment["IMMERSIVE_MAP_PRESENT_TIMING_PASSIVE"] != nil
            || UserDefaults.standard.bool(forKey: "immersiveMapPresentTimingPassive")
        return RenderPresentTimingProbe(sampleCount: requested > 0 ? requested : 240,
                                        isPassive: isPassive)
    }

    private static var summaryPath: String? {
        ProcessInfo.processInfo.environment["IMMERSIVE_MAP_PRESENT_TIMING_PATH"]
            ?? UserDefaults.standard.string(forKey: "immersiveMapPresentTimingPath")
    }

    /// Rendering is on demand, so the loop is asleep unless something asks
    /// for frames. The probe stands in for the gesture it is measuring and
    /// holds an interaction activity from the moment it is created, which is
    /// before the first tick: waiting for one would be waiting for the thing
    /// that only happens because of this call.
    func begin(driver: ImmersiveMapRenderDriver) {
        self.driver = driver
        guard isCollecting == false else {
            return
        }
        isCollecting = true
        // Holding the activity is what makes an unattended run produce frames
        // at all, but it also forces the continuous mode, which hides how the
        // loop behaves when it is left on demand. Passive mode measures the
        // app's own pacing and therefore only collects while something else
        // drives frames (a gesture).
        if isPassive == false {
            driver.setActivity(.interaction, active: true)
        }
        print("=== ImmersiveMap present timing: collecting \(sampleCount) frames"
            + (isPassive ? " (passive: the app's own pacing)" : "") + " ===")
        fflush(stdout)
    }

    /// Called on every display-link update, around the frame's main-thread
    /// work. `drawable` is the one the update delivered; a frame the engine
    /// skips never presents it, which the summary reports as a dropped tick.
    func recordTick(target: CFTimeInterval,
                    drawable: any CAMetalDrawable,
                    driver: ImmersiveMapRenderDriver,
                    frameWork: () -> Void) {
        begin(driver: driver)

        // Engine counters are read either side of the frame, so this tick's
        // outcome is the difference rather than a snapshot of whatever the
        // last frame happened to leave behind.
        let countersBefore = driver.debugFrameCounters

        frameWork()

        let countersAfter = driver.debugFrameCounters
        let didSchedule = countersAfter.scheduled > countersBefore.scheduled
        let skipReason = countersAfter.skips.first { reason, count in
            count > (countersBefore.skips[reason] ?? 0)
        }?.key

        let index = tickIndex
        tickIndex += 1
        let camera = driver.debugCameraSample ?? (zoom: .nan, centerX: .nan, centerY: .nan)
        storage.append(Sample(index: index,
                              target: target,
                              cpuEnd: CACurrentMediaTime(),
                              zoom: camera.zoom,
                              centerX: camera.centerX,
                              centerY: camera.centerY,
                              didSchedule: didSchedule,
                              skipReason: skipReason,
                              presented: nil))
        let storage = self.storage
        // Through MTLDrawable: the presentation callback is declared there,
        // and the iOS SDK does not surface it on the CAMetalDrawable
        // existential.
        let presentable: any MTLDrawable = drawable
        presentable.addPresentedHandler { presentedDrawable in
            storage.recordPresented(index: index, time: presentedDrawable.presentedTime)
        }

        if let samples = storage.takeIfComplete(minimumCount: sampleCount) {
            finish(samples: samples)
        }
    }

    private func finish(samples: [Sample]) {
        driver?.setActivity(.interaction, active: false)
        isCollecting = false
        let summary = Self.summary(samples: samples)
        // stdout is block-buffered when it is not a terminal, and the run that
        // reads this is expected to be killed right after the summary appears,
        // so the buffer is flushed and the text is also written to the path in
        // IMMERSIVE_MAP_PRESENT_TIMING_PATH when one is given.
        print(summary)
        fflush(stdout)
        if let path = Self.summaryPath {
            try? summary.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static func summary(samples: [Sample]) -> String {
        let targets = samples.map(\.target).sorted()
        var intervals: [CFTimeInterval] = []
        for index in 1..<max(targets.count, 1) where targets[index] > targets[index - 1] {
            intervals.append(targets[index] - targets[index - 1])
        }
        let refreshInterval = median(intervals) ?? (1.0 / 60.0)

        let presentedSamples = samples.filter { ($0.presented ?? 0) > 0 }
        let droppedCount = samples.count - presentedSamples.count

        // How far the pixels land from the vsync the frame was computed for,
        // and how far the intended vsync is from the end of the main-thread
        // turn (the CATransaction with the marker positions commits there and
        // is composited at the first vsync after it).
        let presentedMinusTarget = presentedSamples.map { ($0.presented! - $0.target) / refreshInterval }
        let targetMinusCPU = samples.map { ($0.target - $0.cpuEnd) / refreshInterval }

        var outOfOrderCount = 0
        let ordered = presentedSamples.sorted { $0.index < $1.index }
        for index in 1..<max(ordered.count, 1) where ordered[index].presented! < ordered[index - 1].presented! {
            outOfOrderCount += 1
        }

        var lines: [String] = []
        lines.append("=== ImmersiveMap present timing ===")
        lines.append(String(format: "ticks: %d, presented: %d, dropped: %d (%.1f%%)",
                            samples.count, presentedSamples.count, droppedCount,
                            samples.isEmpty ? 0 : 100.0 * Double(droppedCount) / Double(samples.count)))
        lines.append(String(format: "refresh interval: %.3f ms (%.1f Hz)",
                            refreshInterval * 1000, 1.0 / refreshInterval))
        lines.append(describe("presented - target (refreshes)", values: presentedMinusTarget))
        lines.append(describe("target - cpuEnd  (refreshes)", values: targetMinusCPU))
        lines.append("presented out of render order: \(outOfOrderCount)")

        // The two ways a tick fails to reach the screen, kept apart: the
        // engine refused the frame (with its reason), or it scheduled one
        // whose presented callback never came.
        let notScheduled = samples.filter { $0.didSchedule == false }
        let scheduledButUnpresented = samples.filter { $0.didSchedule && ($0.presented ?? 0) <= 0 }
        var reasonCounts: [String: Int] = [:]
        for sample in notScheduled {
            reasonCounts[sample.skipReason ?? "(no reason recorded)", default: 0] += 1
        }
        let reasonSummary = reasonCounts.isEmpty
            ? "none"
            : reasonCounts.sorted { $0.value > $1.value }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        lines.append("engine refused the frame: \(notScheduled.count) (\(reasonSummary))")
        lines.append("scheduled but never reported presented: \(scheduledButUnpresented.count)")

        // How evenly ticks arrive. A loop rendering continuously ticks once
        // per refresh; one that has fallen back to one-shot requests (the
        // display link paused and unpaused per frame) shows gaps of several
        // refreshes, which is the stutter.
        let orderedByIndex = samples.sorted { $0.index < $1.index }
        var gaps: [Double] = []
        for index in 1..<max(orderedByIndex.count, 1) {
            gaps.append((orderedByIndex[index].cpuEnd - orderedByIndex[index - 1].cpuEnd) / refreshInterval)
        }
        lines.append(describe("tick gap (refreshes)", values: gaps))
        lines.append("gaps over 1.5 refreshes: \(gaps.filter { $0 > 1.5 }.count) of \(gaps.count)")
        lines.append(cameraMotionSummary(samples: samples))
        lines.append("Reading: markers reach the screen at the first vsync after cpuEnd. "
            + "If 'presented - target' is ~0 and 'target - cpuEnd' is in (0, 1], both halves "
            + "share a vsync and nothing needs to change. A 'presented - target' of ~1 means "
            + "the map trails the markers by that many refreshes.")
        return lines.joined(separator: "\n")
    }

    /// Whether the camera state the frames were drawn from moved steadily.
    /// A reversal here means the camera itself stepped backwards between two
    /// rendered frames; a picture that jumps while this stays monotone means
    /// the states are fine and the frames carrying them are not.
    private static func cameraMotionSummary(samples: [Sample]) -> String {
        let ordered = samples.sorted { $0.index < $1.index }.filter { $0.zoom.isNaN == false }
        guard ordered.count > 2 else {
            return "camera: no samples"
        }
        var zoomReversals: [String] = []
        var movingFrameCount = 0
        var previousDirection = 0
        for index in 1..<ordered.count {
            let delta = ordered[index].zoom - ordered[index - 1].zoom
            guard abs(delta) > 1e-9 else {
                continue
            }
            movingFrameCount += 1
            let direction = delta > 0 ? 1 : -1
            if previousDirection != 0, direction != previousDirection, zoomReversals.count < 12 {
                zoomReversals.append(String(format: "frame %d: %.5f -> %.5f (%+.5f)",
                                            ordered[index].index,
                                            ordered[index - 1].zoom,
                                            ordered[index].zoom,
                                            delta))
            }
            previousDirection = direction
        }
        var lines = ["camera: \(movingFrameCount) of \(ordered.count) frames moved the zoom, "
            + "\(zoomReversals.count) direction reversals"]
        lines.append(contentsOf: zoomReversals.map { "  " + $0 })
        return lines.joined(separator: "\n")
    }

    private static func describe(_ label: String, values: [Double]) -> String {
        guard values.isEmpty == false else {
            return "\(label): no samples"
        }
        let sorted = values.sorted()
        let mean = values.reduce(0, +) / Double(values.count)
        return String(format: "%@: min %.2f  p50 %.2f  p90 %.2f  max %.2f  mean %.2f",
                      label,
                      sorted.first ?? 0,
                      sorted[sorted.count / 2],
                      sorted[min(sorted.count - 1, (sorted.count * 9) / 10)],
                      sorted.last ?? 0,
                      mean)
    }

    private static func median(_ values: [CFTimeInterval]) -> CFTimeInterval? {
        guard values.isEmpty == false else {
            return nil
        }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

#endif
