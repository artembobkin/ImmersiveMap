// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
typealias MarkerOverlayPlatformView = UIView
#elseif os(macOS)
import AppKit
typealias MarkerOverlayPlatformView = NSView
#endif

/// Owns SwiftUI markers on the UI side: diffs the set from `.markers(...)`
/// by id, keeps hosting views in a container above the Metal layer, feeds the
/// frame engine the coordinates (`MarkerRenderSource`), and applies per-frame
/// projection snapshots, mutating only frame/alpha/isHidden (no SwiftUI
/// invalidation at frame rate). The engine reads the source and publishes the
/// snapshot synchronously on the main thread within the frame, so both ends
/// stay on the MainActor.
@MainActor
final class ImmersiveMapMarkerRuntime: @preconcurrency MarkerRenderSource {
    private struct Entry {
        let internalID: UInt64
        var coordinate: GeoCoordinate
        var basis: GeoProjectionBasis
        var size: CGSize
        let host: MarkerOverlayItemHost
    }

    private let viewportRuntime: ImmersiveMapViewportRuntime
    private let renderRuntime: ImmersiveMapRenderRuntime

    private weak var hostView: MarkerOverlayPlatformView?
    private var container: MarkerOverlayContainerView?
    private var entriesByID: [AnyHashable: Entry] = [:]
    private var orderedIDs: [AnyHashable] = []
    private var anchor: UnitPoint = .center
    private var nextInternalID: UInt64 = 1
    private var projectionInput: MarkerProjectionInput = .empty
    private var lastSnapshot: MarkerProjectionSnapshot?

    init(viewportRuntime: ImmersiveMapViewportRuntime,
         renderRuntime: ImmersiveMapRenderRuntime) {
        self.viewportRuntime = viewportRuntime
        self.renderRuntime = renderRuntime
    }

    /// Host view into which the marker container is inserted lazily.
    /// The parameter type is the platform view (not ImmersiveMapHostView) so
    /// tests can work with a plain view without a Metal host.
    func attach(hostView: MarkerOverlayPlatformView) {
        self.hostView = hostView
    }

    /// Container used to exclude map gestures: nil until there have been markers.
    var markerContainerViewIfLoaded: MarkerOverlayPlatformView? {
        container
    }

    var currentMarkerProjectionInput: MarkerProjectionInput {
        projectionInput
    }

    // MARK: - Content

    func update(content: MarkerViewContent?) {
        let items = content?.items ?? []
        let newAnchor = content?.anchor ?? .center
        let anchorChanged = newAnchor != anchor
        anchor = newAnchor

        var seenIDs = Set<AnyHashable>()
        seenIDs.reserveCapacity(items.count)
        var newOrderedIDs: [AnyHashable] = []
        newOrderedIDs.reserveCapacity(items.count)
        var needsFrame = false
        var sizesChanged = false

        for item in items {
            // Duplicate id in the collection: the first one wins, as in ForEach.
            guard seenIDs.insert(item.id).inserted else {
                continue
            }
            newOrderedIDs.append(item.id)

            if var entry = entriesByID[item.id] {
                entry.host.update(content: item.content)
                let newSize = entry.host.idealSize()
                if newSize != entry.size {
                    entry.size = newSize
                    sizesChanged = true
                }
                if item.coordinate != entry.coordinate {
                    entry.coordinate = item.coordinate
                    entry.basis = GeoProjectionBasis(coordinate: item.coordinate)
                    needsFrame = true
                }
                entriesByID[item.id] = entry
            } else {
                let host = MarkerOverlayItemHost(content: item.content)
                let entry = Entry(internalID: nextInternalID,
                                  coordinate: item.coordinate,
                                  basis: GeoProjectionBasis(coordinate: item.coordinate),
                                  size: host.idealSize(),
                                  host: host)
                nextInternalID &+= 1
                entriesByID[item.id] = entry
                ensureContainer()?.addSubview(host.view)
                needsFrame = true
            }
        }

        for (id, entry) in entriesByID where seenIDs.contains(id) == false {
            entry.host.removeFromContainer()
            entriesByID.removeValue(forKey: id)
        }

        if newOrderedIDs != orderedIDs {
            orderedIDs = newOrderedIDs
            reorderSubviews()
        }
        rebuildProjectionInput()

        if entriesByID.isEmpty {
            container?.removeFromSuperview()
            container = nil
            lastSnapshot = nil
            return
        }

        // A size or anchor change is recomputed locally from the last snapshot,
        // while new coordinates need a fresh projection frame.
        if anchorChanged || sizesChanged, let lastSnapshot {
            applySnapshotToViews(lastSnapshot)
        }
        if needsFrame {
            renderRuntime.requestFrame()
        }
    }

    // MARK: - Frame projection

    /// Called by the engine synchronously within the frame (see ImmersiveMapRenderEventSink):
    /// positions land in the same CA transaction as the frame's present.
    func apply(_ snapshot: MarkerProjectionSnapshot) {
        guard entriesByID.isEmpty == false else {
            return
        }
        lastSnapshot = snapshot
        applySnapshotToViews(snapshot)
    }

    func layout(in bounds: CGRect) {
        container?.frame = bounds
    }

    // MARK: - Private

    private func ensureContainer() -> MarkerOverlayContainerView? {
        if let container {
            return container
        }
        guard let hostView else {
            return nil
        }

        let container = MarkerOverlayContainerView(frame: hostView.bounds)
        // Below the attribution badge, control zones, and debug HUD: markers are
        // map content, not a system overlay.
        #if canImport(UIKit)
        hostView.insertSubview(container, at: 0)
        #elseif os(macOS)
        hostView.addSubview(container, positioned: .below, relativeTo: nil)
        #endif
        self.container = container
        return container
    }

    /// Z-order and hit-testing follow the collection order: the last element is on top.
    private func reorderSubviews() {
        guard let container else {
            return
        }
        for id in orderedIDs {
            guard let entry = entriesByID[id] else {
                continue
            }
            container.addSubview(entry.host.view)
        }
    }

    private func rebuildProjectionInput() {
        guard entriesByID.isEmpty == false else {
            projectionInput = .empty
            return
        }

        var entries: [MarkerProjectionEntry] = []
        entries.reserveCapacity(orderedIDs.count)
        for id in orderedIDs {
            guard let entry = entriesByID[id] else {
                continue
            }
            entries.append(MarkerProjectionEntry(id: entry.internalID,
                                                 basis: entry.basis))
        }
        projectionInput = MarkerProjectionInput(entries: entries)
    }

    private func applySnapshotToViews(_ snapshot: MarkerProjectionSnapshot) {
        var projectedByInternalID: [UInt64: MarkerProjectedEntry] = [:]
        projectedByInternalID.reserveCapacity(snapshot.entries.count)
        for projected in snapshot.entries {
            projectedByInternalID[projected.id] = projected
        }

        let contentsScale = viewportRuntime.contentsScale
        for entry in entriesByID.values {
            guard let projected = projectedByInternalID[entry.internalID] else {
                // Not in the snapshot: beyond the globe horizon or behind the camera.
                entry.host.hide()
                continue
            }

            let anchorPoint = MarkerOverlayLayoutMath.pointFromPixel(projected.positionPx,
                                                                     drawSize: snapshot.drawSize,
                                                                     contentsScale: contentsScale)
            entry.host.apply(frame: MarkerOverlayLayoutMath.frame(anchorPoint: anchorPoint,
                                                                  size: entry.size,
                                                                  anchor: anchor),
                             alpha: CGFloat(projected.visibilityAlpha))
        }
    }
}
