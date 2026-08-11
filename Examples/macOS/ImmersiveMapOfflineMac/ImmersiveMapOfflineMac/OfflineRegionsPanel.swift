// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

/// The sidebar: preset city regions to download, a "current view" region, the
/// live download list with progress and sizes, and the offline mode switch
/// that drives the map on the right.
struct OfflineRegionsPanel: View {
    struct Preset: Identifiable {
        let region: ImmersiveMapOfflineRegion
        let title: String
        let cameraPosition: ImmersiveMapCameraPosition

        var id: String { region.id }
    }

    /// City boxes small enough to download in a coffee break. Zoom starts at
    /// 0 on purpose: the low levels cost a handful of tiles and keep the map
    /// usable while zooming out over the downloaded area.
    static let presets: [Preset] = [
        Preset(region: ImmersiveMapOfflineRegion(
                   id: "london",
                   southWest: GeoCoordinate(latitude: 51.42, longitude: -0.25),
                   northEast: GeoCoordinate(latitude: 51.60, longitude: 0.05),
                   zoomLevels: 0...14),
               title: "London",
               cameraPosition: ImmersiveMapCameraPosition(latitudeDegrees: 51.5074,
                                                          longitudeDegrees: -0.1278,
                                                          zoom: 12.5)),
        Preset(region: ImmersiveMapOfflineRegion(
                   id: "paris",
                   southWest: GeoCoordinate(latitude: 48.78, longitude: 2.20),
                   northEast: GeoCoordinate(latitude: 48.93, longitude: 2.47),
                   zoomLevels: 0...14),
               title: "Paris",
               cameraPosition: ImmersiveMapCameraPosition(latitudeDegrees: 48.8566,
                                                          longitudeDegrees: 2.3522,
                                                          zoom: 12.5)),
        Preset(region: ImmersiveMapOfflineRegion(
                   id: "manhattan",
                   southWest: GeoCoordinate(latitude: 40.68, longitude: -74.05),
                   northEast: GeoCoordinate(latitude: 40.88, longitude: -73.90),
                   zoomLevels: 0...14),
               title: "Manhattan",
               cameraPosition: ImmersiveMapCameraPosition(latitudeDegrees: 40.7484,
                                                          longitudeDegrees: -73.9857,
                                                          zoom: 12.5)),
    ]

    let offlineController: ImmersiveMapOfflineController
    let camera: ImmersiveMapCameraController
    @Binding var regionStatuses: [ImmersiveMapOfflineRegionStatus]
    @Binding var offlineMode: ImmersiveMapSettings.TileSettings.OfflineSettings.Mode
    @Binding var lastErrorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                modeSection
                presetSection
                currentViewSection
                regionsSection
                if let lastErrorText {
                    Text(lastErrorText)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Map mode").font(.headline)
            Picker("Map mode", selection: $offlineMode) {
                Text("Automatic").tag(ImmersiveMapSettings.TileSettings.OfflineSettings.Mode.automatic)
                Text("Offline only").tag(ImmersiveMapSettings.TileSettings.OfflineSettings.Mode.offlineOnly)
                Text("Disabled").tag(ImmersiveMapSettings.TileSettings.OfflineSettings.Mode.disabled)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Automatic falls back to downloaded regions when the network fails. Offline only never touches the network: after downloading a city, switch here and pan around it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preset regions").font(.headline)
            ForEach(Self.presets) { preset in
                HStack {
                    Button(preset.title) {
                        camera.fly(to: preset.cameraPosition, options: CameraFlightOptions(duration: 1.4))
                    }
                    .buttonStyle(.link)
                    Spacer()
                    Text("\(preset.region.tileCount) tiles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Download") {
                        download(preset.region)
                    }
                    .disabled(isDownloading(preset.region.id))
                }
            }
        }
    }

    private var currentViewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Current view").font(.headline)
            Button("Download around the map center") {
                guard let position = camera.currentCameraPosition() else {
                    return
                }
                let region = ImmersiveMapOfflineRegion(
                    id: "current-view",
                    southWest: GeoCoordinate(latitude: position.latitudeDegrees - 0.12,
                                             longitude: position.longitudeDegrees - 0.18),
                    northEast: GeoCoordinate(latitude: position.latitudeDegrees + 0.12,
                                             longitude: position.longitudeDegrees + 0.18),
                    zoomLevels: 0...14)
                download(region)
            }
            .disabled(isDownloading("current-view"))
        }
    }

    private var regionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Downloaded regions").font(.headline)
                Spacer()
                if regionStatuses.isEmpty == false {
                    Button("Remove all") {
                        offlineController.removeAllRegions()
                    }
                }
            }
            if regionStatuses.isEmpty {
                Text("Nothing downloaded yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(regionStatuses) { status in
                regionRow(status)
            }
        }
    }

    private func regionRow(_ status: ImmersiveMapOfflineRegionStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(status.region.id).fontWeight(.medium)
                Spacer()
                Text(phaseText(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: status.fractionCompleted)
            HStack {
                Text("\(status.storedTileCount) of \(status.expectedTileCount) tiles, \(byteText(status.byteCount))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if status.failedTileCount > 0 {
                    Text("\(status.failedTileCount) failed")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                if status.phase == .downloading {
                    Button("Cancel") {
                        offlineController.cancelDownload(regionID: status.id)
                    }
                } else {
                    if status.phase == .incomplete {
                        Button("Resume") {
                            download(status.region)
                        }
                    }
                    Button("Delete") {
                        offlineController.removeRegion(regionID: status.id)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    private func download(_ region: ImmersiveMapOfflineRegion) {
        do {
            lastErrorText = nil
            try offlineController.download(region)
        } catch {
            lastErrorText = "Download failed to start: \(error)"
        }
    }

    private func isDownloading(_ regionID: String) -> Bool {
        offlineController.status(forRegionID: regionID)?.phase == .downloading
    }

    private func phaseText(_ status: ImmersiveMapOfflineRegionStatus) -> String {
        switch status.phase {
        case .downloading:
            return "downloading"
        case .complete:
            return "complete"
        case .incomplete:
            return "incomplete"
        }
    }

    private func byteText(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}
