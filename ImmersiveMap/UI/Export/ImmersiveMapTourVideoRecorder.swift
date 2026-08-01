// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal

/// Everything the recorder needs from the host view at export start. Captured
/// once per export — later settings changes on the live map don't affect a
/// running export.
struct ImmersiveMapVideoExportAttachContext {
    let currentSettings: @MainActor () -> ImmersiveMapSettings
    let currentCameraPosition: @MainActor () -> ImmersiveMapCameraPosition?
    let currentAvatarsController: @MainActor () -> ImmersiveMapAvatarsController?
    let currentMarkerContent: @MainActor () -> MarkerViewContent?
}

/// Exports a camera tour to a QuickTime video file by rendering it offline.
///
/// Attach the recorder to a map with the ``ImmersiveMapView/tourVideoRecorder(_:)``
/// modifier — it picks up the view's current configuration (tile provider,
/// style, labels, avatars) — then call ``export(shots:establish:configuration:to:)``
/// with the same shots you would pass to `ImmersiveMapCameraTourController`.
///
/// The export renders frame by frame at a fixed timestep into a second,
/// headless render engine: every frame waits for its tiles, the frame rate is
/// exact, and the on-screen map stays interactive. Avatar markers render
/// normally from a copy of the avatar state taken at export start, and SwiftUI
/// markers are rasterized and composited at their projected positions — both
/// can be excluded via ``ImmersiveMapVideoExportConfiguration``. The
/// attribution badge is host-view chrome and does not appear in the exported
/// video — add attribution before publishing exported footage.
@MainActor
public final class ImmersiveMapTourVideoRecorder {
    /// Reports export progress on the main thread.
    public var onProgress: ((ImmersiveMapVideoExportProgress) -> Void)?

    public private(set) var isExporting = false

    private weak var runtimeOwner: AnyObject?
    private var attachContext: ImmersiveMapVideoExportAttachContext?
    private var activeRuntime: ImmersiveMapVideoExportRuntime?

    public init() {}

    /// Renders the tour into a QuickTime (`.mov`) file at `url`, replacing any
    /// existing file. The tour semantics match
    /// `ImmersiveMapCameraTourController.start`: an instant jump to
    /// `establish` when given, then one flight plus hold per shot. Exports are
    /// a single finite pass — there is no loop mode.
    ///
    /// Throws ``ImmersiveMapVideoExportError`` on failure; a cancelled or
    /// failed export deletes the partial file.
    public func export(shots: [ImmersiveMapCameraTourShot],
                       establish: ImmersiveMapCameraPosition? = nil,
                       configuration: ImmersiveMapVideoExportConfiguration = .default,
                       to url: URL) async throws {
        guard isExporting == false else {
            throw ImmersiveMapVideoExportError.exportAlreadyInProgress
        }
        guard let attachContext else {
            throw ImmersiveMapVideoExportError.notAttached
        }
        guard shots.isEmpty == false else {
            throw ImmersiveMapVideoExportError.emptyShots
        }
        try configuration.validate()
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw ImmersiveMapVideoExportError.metalUnavailable
        }

        // Snapshot of the view's configuration: the export is independent of
        // later settings changes and of live-renderer recreation. The debug
        // panel is host-view chrome and is force-disabled offscreen. Avatars
        // are a detached copy — the live engine and the export engine must not
        // consume snapshot diffs from the same controller.
        let exportSettings = attachContext.currentSettings().debugPanel(false)
        let initialPosition = establish ?? attachContext.currentCameraPosition()
        let avatarsController = configuration.includesAvatars
            ? attachContext.currentAvatarsController()?.makeDetachedCopyForExport()
            : nil
        let markerContent = configuration.includesMarkers
            ? attachContext.currentMarkerContent()
            : nil

        isExporting = true
        defer {
            isExporting = false
            activeRuntime = nil
        }

        let runtime = try ImmersiveMapVideoExportRuntime(settings: exportSettings,
                                                         initialPosition: initialPosition,
                                                         avatarsController: avatarsController,
                                                         markerContent: markerContent,
                                                         configuration: configuration,
                                                         outputURL: url)
        activeRuntime = runtime
        try await runtime.run(shots: shots) { [weak self] progress in
            self?.onProgress?(progress)
        }
    }

    /// Cancels the running export; `export` then throws
    /// ``ImmersiveMapVideoExportError/cancelled`` and deletes the partial file.
    public func cancel() {
        activeRuntime?.requestCancel()
    }

    // MARK: - Runtime attachment (host view wiring)

    func attachRuntime(owner: AnyObject, context: ImmersiveMapVideoExportAttachContext) {
        runtimeOwner = owner
        attachContext = context
    }

    /// Owner-scoped: SwiftUI creates the replacement host view before
    /// dismantling the old one, and a stale detach must not clear the binding
    /// the new view has already installed. A running export is unaffected — it
    /// only depends on the snapshot taken at start.
    func detachRuntime(owner: AnyObject) {
        guard runtimeOwner === owner else {
            return
        }
        runtimeOwner = nil
        attachContext = nil
    }
}
