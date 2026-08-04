// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Parks the platform host view of a dismantled `ImmersiveMapView` so the next
/// map view can adopt it warm — renderer, GPU tile cache, atlas pages, gesture
/// wiring and the Metal layer all survive the screen change instead of being
/// rebuilt from scratch.
///
/// Capacity is one view: the most recently dismantled map replaces an earlier
/// parked one. SwiftUI creates the incoming screen's view before dismantling
/// the outgoing one, so the very first transition between two map screens
/// still builds fresh; every later transition adopts.
///
/// A parked view is dropped after its time-to-live expires or on a memory
/// warning; dropping it releases the renderer through the normal teardown
/// path. Settings of the adopting view are reconciled by the regular
/// settings-apply planner, so parking does not require matching configurations.
@MainActor
final class ImmersiveMapHostViewPool {
    static let shared = ImmersiveMapHostViewPool()

    private var parkedView: ImmersiveMapHostView?
    private var expiryTask: Task<Void, Never>?
    #if canImport(UIKit)
    // Tracked via notifications (UIApplication.shared is unavailable in app
    // extensions): a view parked while the app is already backgrounded would
    // sit under jetsam pressure for the whole stay — the drain has already
    // fired and the TTL task is suspended with the process.
    private var isAppInBackground = false
    #endif

    init() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.drain()
            }
        }
        // A parked view is an expendable cache: while the app is suspended the
        // TTL task cannot fire and memory warnings are not delivered, so the
        // engine's footprint would sit under jetsam pressure for the whole
        // background stay.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAppInBackground = true
                self?.drain()
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAppInBackground = false
            }
        }
        #else
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                             queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.drain()
            }
        }
        source.activate()
        memoryPressureSource = source
        #endif
    }

    #if canImport(UIKit)
    #else
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    #endif

    /// Parks a dismantled view. A previously parked view is released: the
    /// newer one is the warmer one.
    func park(_ view: ImmersiveMapHostView, timeToLive: TimeInterval) {
        guard timeToLive > 0 else {
            return
        }
        #if canImport(UIKit)
        guard isAppInBackground == false else {
            return
        }
        #endif
        // The TTL is a public unclamped TimeInterval: .infinity or NaN would
        // trap the Double-to-UInt64 conversion. One hour is already far beyond
        // any realistic screen-return window.
        let clampedTimeToLive = timeToLive.isFinite ? min(timeToLive, 3600) : 3600
        expiryTask?.cancel()
        parkedView = view
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(clampedTimeToLive * 1_000_000_000))
            guard Task.isCancelled == false else {
                return
            }
            self?.drain()
        }
    }

    /// Hands the parked view to an adopting map view, or nil when the pool is
    /// empty.
    func adopt() -> ImmersiveMapHostView? {
        guard let view = parkedView else {
            return nil
        }
        parkedView = nil
        expiryTask?.cancel()
        expiryTask = nil
        return view
    }

    /// Releases the parked view (TTL expiry or memory pressure).
    func drain() {
        parkedView = nil
        expiryTask?.cancel()
        expiryTask = nil
    }

    var hasParkedViewForTesting: Bool {
        parkedView != nil
    }
}
