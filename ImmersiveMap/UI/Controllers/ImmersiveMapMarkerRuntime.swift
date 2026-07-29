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

/// Владеет SwiftUI-маркерами на стороне UI: диффит набор из `.markers(...)`
/// по id, держит hosting-вью в контейнере поверх Metal-слоя, отдаёт движку
/// кадра координаты (`MarkerRenderSource`) и применяет пер-кадровые снапшоты
/// проекции, мутируя только frame/alpha/isHidden (без инвалидации SwiftUI
/// на частоте кадров). Движок читает источник и публикует снапшот синхронно
/// на main thread внутри кадра, поэтому оба конца остаются на MainActor.
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

    /// Host view, в который лениво вставляется контейнер маркеров.
    /// Тип параметра платформенный (не ImmersiveMapHostView), чтобы тесты
    /// работали с обычным view без Metal-хоста.
    func attach(hostView: MarkerOverlayPlatformView) {
        self.hostView = hostView
    }

    /// Контейнер для исключения жестов карты: nil, пока маркеров не было.
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
            // Дубликат id в коллекции: первый выигрывает, как в ForEach.
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

        // Смена размера или якоря пересчитывается локально по последнему
        // снапшоту, новым координатам нужен свежий кадр проекции.
        if anchorChanged || sizesChanged, let lastSnapshot {
            applySnapshotToViews(lastSnapshot)
        }
        if needsFrame {
            renderRuntime.requestFrame()
        }
    }

    // MARK: - Frame projection

    /// Зовётся движком синхронно внутри кадра (см. ImmersiveMapRenderEventSink):
    /// позиции попадают в ту же CA-транзакцию, что и present кадра.
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
        // Ниже attribution badge, control zones и debug HUD: маркеры это
        // контент карты, а не системный оверлей.
        #if canImport(UIKit)
        hostView.insertSubview(container, at: 0)
        #elseif os(macOS)
        hostView.addSubview(container, positioned: .below, relativeTo: nil)
        #endif
        self.container = container
        return container
    }

    /// Z-порядок и hit-test следуют порядку коллекции: последний элемент сверху.
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
                // Нет в снапшоте: за горизонтом глобуса или позади камеры.
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
