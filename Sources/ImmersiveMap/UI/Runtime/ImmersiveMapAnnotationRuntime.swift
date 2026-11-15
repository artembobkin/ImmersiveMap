// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
typealias AnnotationOverlayPlatformView = UIView
#elseif os(macOS)
import AppKit
typealias AnnotationOverlayPlatformView = NSView
#endif

/// Owns SwiftUI annotations on the UI side: diffs the set from `.annotations(...)`
/// by id, so a change of the set costs what changed in it: a new annotation is
/// made and measured once, a gone one is removed, and one that stays is
/// left alone when its element is what it was (`AnnotationViewItem.element`),
/// or handed its content again when it cannot be compared. A annotation's size
/// is never measured again: its content reports it (`AnnotationSizedContent`).
/// Keeps hosting views in a container above the Metal layer, feeds the
/// frame engine the coordinates (`AnnotationRenderSource`), and applies per-frame
/// projection snapshots, mutating only frame/alpha/isHidden (no SwiftUI
/// invalidation at frame rate). The engine reads the source and publishes the
/// snapshot synchronously on the main thread within the frame, so both ends
/// stay on the MainActor.
@MainActor
final class ImmersiveMapAnnotationRuntime: @preconcurrency AnnotationRenderSource {
    private struct Entry {
        let internalID: UInt64
        var coordinate: GeoCoordinate
        var basis: GeoProjectionBasis
        var size: CGSize
        /// The element the annotation's view was last made from.
        var element: AnnotationElement?
        let host: AnnotationOverlayItemHost
    }

    private let viewportRuntime: ImmersiveMapViewportRuntime
    private let renderRuntime: ImmersiveMapRenderRuntime

    private weak var hostView: AnnotationOverlayPlatformView?
    private var container: AnnotationOverlayContainerView?
    private var entriesByID: [AnyHashable: Entry] = [:]
    private var orderedIDs: [AnyHashable] = []
    private var anchor: UnitPoint = .center
    private var nextInternalID: UInt64 = 1
    private var projectionInput: AnnotationProjectionInput = .empty
    private var lastSnapshot: AnnotationProjectionSnapshot?

    init(viewportRuntime: ImmersiveMapViewportRuntime,
         renderRuntime: ImmersiveMapRenderRuntime) {
        self.viewportRuntime = viewportRuntime
        self.renderRuntime = renderRuntime
    }

    /// Host view into which the annotation container is inserted lazily.
    /// The parameter type is the platform view (not ImmersiveMapHostView) so
    /// tests can work with a plain view without a Metal host.
    func attach(hostView: AnnotationOverlayPlatformView) {
        self.hostView = hostView
    }

    /// Container used to exclude map gestures: nil until there have been annotations.
    var annotationContainerViewIfLoaded: AnnotationOverlayPlatformView? {
        container
    }

    var currentAnnotationProjectionInput: AnnotationProjectionInput {
        projectionInput
    }

    // MARK: - Content

    func update(content: AnnotationViewContent?) {
        let items = content?.items ?? []
        let newAnchor = content?.anchor ?? .center
        let anchorChanged = newAnchor != anchor
        anchor = newAnchor

        var seenIDs = Set<AnyHashable>()
        seenIDs.reserveCapacity(items.count)
        var newOrderedIDs: [AnyHashable] = []
        newOrderedIDs.reserveCapacity(items.count)
        var needsFrame = false

        for item in items {
            // Duplicate id in the collection: the first one wins, as in ForEach.
            guard seenIDs.insert(item.id).inserted else {
                continue
            }
            newOrderedIDs.append(item.id)

            if var entry = entriesByID[item.id] {
                // A annotation made from the same element keeps its view as
                // it is. Any other is handed its content, and SwiftUI
                // tells what changed in it, its size included.
                if item.hasSameContent(as: entry.element) == false {
                    entry.host.update(content: item.content)
                    entry.element = item.element
                }
                if item.coordinate != entry.coordinate {
                    entry.coordinate = item.coordinate
                    entry.basis = GeoProjectionBasis(coordinate: item.coordinate)
                    needsFrame = true
                }
                entriesByID[item.id] = entry
            } else {
                let host = AnnotationOverlayItemHost(content: item.content)
                let id = item.id
                host.onSizeChange = { [weak self] size in
                    self?.annotationSizeDidChange(id: id, size: size)
                }
                // Measured once, here, so the annotation is placed right from
                // its first frame.
                let entry = Entry(internalID: nextInternalID,
                                  coordinate: item.coordinate,
                                  basis: GeoProjectionBasis(coordinate: item.coordinate),
                                  size: host.idealSize(),
                                  element: item.element,
                                  host: host)
                nextInternalID &+= 1
                entriesByID[item.id] = entry
                // Its view goes into the container at its place among the
                // others, below (`placeViews`).
                needsFrame = true
            }
        }

        for (id, entry) in entriesByID where seenIDs.contains(id) == false {
            entry.host.removeFromContainer()
            entriesByID.removeValue(forKey: id)
        }

        if newOrderedIDs != orderedIDs {
            let previousIDs = orderedIDs
            orderedIDs = newOrderedIDs
            placeViews(previousIDs: previousIDs)
        }
        rebuildProjectionInput()

        if entriesByID.isEmpty {
            container?.removeFromSuperview()
            container = nil
            lastSnapshot = nil
            return
        }

        // An anchor change is recomputed locally from the last snapshot,
        // while new coordinates need a fresh projection frame.
        if anchorChanged, let lastSnapshot {
            applySnapshotToViews(lastSnapshot)
        }
        if needsFrame {
            renderRuntime.requestFrame()
        }
    }

    // MARK: - Frame projection

    /// Called by the engine synchronously within the frame (see ImmersiveMapRenderEventSink):
    /// positions land in the same CA transaction as the frame's present.
    func apply(_ snapshot: AnnotationProjectionSnapshot) {
        guard entriesByID.isEmpty == false else {
            return
        }
        lastSnapshot = snapshot
        applySnapshotToViews(snapshot)
    }

    /// SwiftUI laid a annotation's content out at another size. The size is
    /// kept, and the next frame places the view by it: this is called from
    /// inside SwiftUI's layout, where moving views is not allowed.
    private func annotationSizeDidChange(id: AnyHashable, size: CGSize) {
        guard var entry = entriesByID[id],
              abs(entry.size.width - size.width) > 0.5 || abs(entry.size.height - size.height) > 0.5 else {
            return
        }
        entry.size = size
        entriesByID[id] = entry
        renderRuntime.requestFrame()
    }

    func layout(in bounds: CGRect) {
        container?.frame = bounds
    }

    // MARK: - Private

    private func ensureContainer() -> AnnotationOverlayContainerView? {
        if let container {
            return container
        }
        guard let hostView else {
            return nil
        }

        let container = AnnotationOverlayContainerView(frame: hostView.bounds)
        // Below the attribution badge, control zones, and debug HUD: annotations are
        // map content, not a system overlay.
        #if canImport(UIKit)
        hostView.insertSubview(container, at: 0)
        #elseif os(macOS)
        hostView.addSubview(container, positioned: .below, relativeTo: nil)
        #endif
        self.container = container
        return container
    }

    /// Z-order and hit-testing follow the collection order: the last element
    /// is on top. Only the views that have to move are touched: taking a
    /// view out and putting it back makes the system lay its content out
    /// again, so re-adding every annotation for one new one cost a layout of
    /// them all. The usual change keeps the annotations that stay in the order
    /// they were, and then only the new ones are inserted, each over the
    /// annotation before it. All are put in order again only when the app
    /// reordered the ones that stay.
    private func placeViews(previousIDs: [AnyHashable]) {
        guard orderedIDs.isEmpty == false, let container = ensureContainer() else {
            return
        }
        let previous = Set(previousIDs)
        let staying = Set(orderedIDs).intersection(previous)
        let keepsOrder = previousIDs.filter(staying.contains) == orderedIDs.filter(staying.contains)

        var below: AnnotationOverlayPlatformView?
        for id in orderedIDs {
            guard let entry = entriesByID[id] else {
                continue
            }
            let view = entry.host.view
            if keepsOrder == false || previous.contains(id) == false {
                Self.place(view, over: below, in: container)
            }
            below = view
        }
    }

    /// Puts `view` right over `below` in the container, or under every
    /// view when there is none.
    private static func place(_ view: AnnotationOverlayPlatformView,
                              over below: AnnotationOverlayPlatformView?,
                              in container: AnnotationOverlayPlatformView) {
        #if canImport(UIKit)
        if let below {
            container.insertSubview(view, aboveSubview: below)
        } else {
            container.insertSubview(view, at: 0)
        }
        #elseif os(macOS)
        if let below {
            container.addSubview(view, positioned: .above, relativeTo: below)
        } else {
            container.addSubview(view, positioned: .below, relativeTo: nil)
        }
        #endif
    }

    private func rebuildProjectionInput() {
        guard entriesByID.isEmpty == false else {
            projectionInput = .empty
            return
        }

        var entries: [AnnotationProjectionEntry] = []
        entries.reserveCapacity(orderedIDs.count)
        for id in orderedIDs {
            guard let entry = entriesByID[id] else {
                continue
            }
            entries.append(AnnotationProjectionEntry(id: entry.internalID,
                                                 basis: entry.basis))
        }
        projectionInput = AnnotationProjectionInput(entries: entries)
    }

    private func applySnapshotToViews(_ snapshot: AnnotationProjectionSnapshot) {
        var projectedByInternalID: [UInt64: AnnotationProjectedEntry] = [:]
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

            let anchorPoint = AnnotationOverlayLayoutMath.pointFromPixel(projected.positionPx,
                                                                     drawSize: snapshot.drawSize,
                                                                     contentsScale: contentsScale)
            entry.host.apply(frame: AnnotationOverlayLayoutMath.frame(anchorPoint: anchorPoint,
                                                                  size: entry.size,
                                                                  anchor: anchor),
                             alpha: CGFloat(projected.visibilityAlpha))
        }
    }
}
