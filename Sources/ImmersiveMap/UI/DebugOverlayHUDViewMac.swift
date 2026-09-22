// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if os(macOS)

import AppKit
import simd

/// AppKit port of the debug HUD: a full-height panel flush against the left
/// edge of the map, whose groups are stacked vertically inside one scroll view.
///
/// It used to be a floating card with a tab picker, which meant three quarters
/// of the panel was hidden at any moment and the panel's height was whatever
/// the selected tab happened to need. Debugging a frame usually means watching
/// two groups at once (the stats while a control is toggled, the tile list
/// while the shadow settings move), so every group is laid out at once, the
/// panel takes the full window height, and what does not fit is scrolled to.
/// The one group whose height follows the data, the tile list, is last, so a
/// tile arriving cannot shove a control the pointer is aimed at.
///
/// Layout is manual and top-down (the container and the scrolled content are
/// both flipped): one cursor walks the groups in order, which is why adding a
/// group is a matter of appending to `layoutGroups` rather than of rebalancing
/// a tree of frames.
final class DebugOverlayHUDView: NSView {
    private enum Layout {
        static let coordinateFontScale: CGFloat = 0.56
        static let diagnosticsFontScale: CGFloat = 0.50
        static let contentInset: CGFloat = 10.0
        static let headerHeight: CGFloat = 30.0
        static let groupHeaderHeight: CGFloat = 24.0
        static let controlRowHeight: CGFloat = 28.0
        static let controlSpacing: CGFloat = 6.0
        static let groupSpacing: CGFloat = 16.0
        static let traceStatusHeight: CGFloat = 24.0
        /// Nearly opaque: the panel is read while the map moves under it, and
        /// a translucent one turned every label and building edge behind it
        /// into noise across the text.
        static let backgroundAlpha: CGFloat = 0.9
        /// The panel is a fixed-width rail, not a card that grows with its
        /// text: a width that followed the longest diagnostics line moved the
        /// map every time a number gained a digit. Wide enough that a
        /// diagnostics line does not wrap and a slider has travel worth
        /// aiming with.
        static let panelWidth: CGFloat = 600.0
        static let collapsedWidth: CGFloat = 170.0
        /// Fraction of a control row given to its name; the control takes the
        /// rest.
        static let controlLabelFraction: CGFloat = 0.46
        /// Kept clear on the right for the vertical scroller. An overlay
        /// scroller floats over the content and a legacy one takes width out
        /// of it, and which of the two AppKit uses is a system setting and the
        /// kind of pointing device, not something the panel decides. Reserving
        /// the strip is what keeps a switch from ending up under either.
        static let scrollerGutter: CGFloat = 18.0
    }

    private let containerView = DebugOverlayFlippedView()
    private let titleLabel = NSTextField(labelWithString: "Debug")
    private let collapseButton = NSButton()
    private let scrollView = NSScrollView()
    private let contentView = DebugOverlayFlippedView()

    private let statsGroupLabel = NSTextField(labelWithString: "Stats")
    private let zoomLabel = NSTextField(wrappingLabelWithString: "")
    private let latLonLabel = NSTextField(wrappingLabelWithString: "")
    private let diagnosticsLabel = NSTextField(wrappingLabelWithString: "")

    private let tilesGroupLabel = NSTextField(labelWithString: "Tiles")
    private let tileTraceButton = NSButton()
    private let tileTraceStatusLabel = NSTextField(labelWithString: "")
    private let tilesStatusLabel = NSTextField(wrappingLabelWithString: "")
    /// No scroll view of its own any more: the tile list is one group of the
    /// scrolled column, and a scroll view inside a scroll view takes the wheel
    /// away from whichever one the pointer is not over.
    private let tilesStatusListView = DebugOverlayTilesStatusListView()

    private let baseLabelsGroupLabel = NSTextField(labelWithString: "Base labels")
    private let baseLabelTraceButton = NSButton()
    private let baseLabelTraceStatusLabel = NSTextField(labelWithString: "")
    private let roadLabelTilesLabel = NSTextField(labelWithString: "")
    private let roadLabelTilesSwitch = NSSwitch()
    private let baseLabelBoundsLabel = NSTextField(labelWithString: "")
    private let baseLabelBoundsSwitch = NSSwitch()
    private let roadLabelBoundsLabel = NSTextField(labelWithString: "")
    private let roadLabelBoundsSwitch = NSSwitch()

    private let shadowsGroupLabel = NSTextField(labelWithString: "Shadows")
    private let shadowsEnabledLabel = NSTextField(labelWithString: "")
    private let shadowsEnabledSwitch = NSSwitch()
    private let shadowStrengthLabel = NSTextField(labelWithString: "")
    private let shadowStrengthSlider = NSSlider()
    private let shadowMapResolutionLabel = NSTextField(labelWithString: "")
    private let shadowMapResolutionControl = NSSegmentedControl(
        labels: DebugOverlayShadowSettingsPlanner.mapResolutionTitles,
        trackingMode: .selectOne,
        target: nil,
        action: nil)
    private let shadowCoverageLabel = NSTextField(labelWithString: "")
    private let shadowCoverageSlider = NSSlider()
    private let shadowNormalOffsetLabel = NSTextField(labelWithString: "")
    private let shadowNormalOffsetSlider = NSSlider()
    private let shadowCasterHeightLabel = NSTextField(labelWithString: "")
    private let shadowCasterHeightSlider = NSSlider()
    private let shadowSoftnessLabel = NSTextField(labelWithString: "")
    private let shadowSoftnessSlider = NSSlider()
    private let sunAzimuthLabel = NSTextField(labelWithString: "")
    private let sunAzimuthSlider = NSSlider()
    private let sunElevationLabel = NSTextField(labelWithString: "")
    private let sunElevationSlider = NSSlider()

    private let fogGroupLabel = NSTextField(labelWithString: "Horizon")
    private let fogEnabledLabel = NSTextField(labelWithString: "")
    private let fogEnabledSwitch = NSSwitch()
    private let fogHazeStartLabel = NSTextField(labelWithString: "")
    private let fogHazeStartSlider = NSSlider()
    private let fogHazeEndLabel = NSTextField(labelWithString: "")
    private let fogHazeEndSlider = NSSlider()
    private let fogSkyColorLabel = NSTextField(labelWithString: "")
    private let fogSkyColorWell = NSColorWell(style: .minimal)
    private let fogHorizonColorLabel = NSTextField(labelWithString: "")
    private let fogHorizonColorWell = NSColorWell(style: .minimal)

    private let atmosphereGroupLabel = NSTextField(labelWithString: "Atmosphere")
    private let atmosphereEnabledLabel = NSTextField(labelWithString: "")
    private let atmosphereEnabledSwitch = NSSwitch()
    private let atmosphereColorLabel = NSTextField(labelWithString: "")
    private let atmosphereColorWell = NSColorWell(style: .minimal)
    private let atmosphereIntensityLabel = NSTextField(labelWithString: "")
    private let atmosphereIntensitySlider = NSSlider()
    private let atmosphereThicknessLabel = NSTextField(labelWithString: "")
    private let atmosphereThicknessSlider = NSSlider()
    private let atmosphereSunInfluenceLabel = NSTextField(labelWithString: "")
    private let atmosphereSunInfluenceSlider = NSSlider()

    private let controlsGroupLabel = NSTextField(labelWithString: "Controls")
    private let axesLabel = NSTextField(labelWithString: "")
    private let axesSwitch = NSSwitch()
    private let tileLayersLabel = NSTextField(labelWithString: "")
    private let tileLayersSwitch = NSSwitch()
    private let tileGridLabel = NSTextField(labelWithString: "")
    private let tileGridSwitch = NSSwitch()
    private let tileGridDensityControl = NSSegmentedControl(labels: DebugOverlayHUDTextComposer.tileGridDensityTitles,
                                                            trackingMode: .selectOne,
                                                            target: nil,
                                                            action: nil)
    private let wireframeLabel = NSTextField(labelWithString: "")
    private let wireframeSwitch = NSSwitch()
    /// The flat building fills' footprint fade, two footprint areas on
    /// screen in square pixels (`BuildingFootprintFade`): gone under the
    /// first, opaque from the second.
    private let buildingCutLabel = NSTextField(labelWithString: "")
    private let buildingCutSlider = NSSlider()
    private let buildingFadeLabel = NSTextField(labelWithString: "")
    private let buildingFadeSlider = NSSlider()
    /// The roads' thinness fade, two widths on screen in pixels
    /// (`RoadThinnessFade`).
    private let roadFadeOpaqueLabel = NSTextField(labelWithString: "")
    private let roadFadeOpaqueSlider = NSSlider()
    /// The raster zone (`RasterZone`): whether the far ground turns into
    /// pictures, where the turn starts and how long it takes in camera
    /// distances, and which ground families the pictures hold.
    private let rasterZoneLabel = NSTextField(labelWithString: "")
    private let rasterZoneSwitch = NSSwitch()
    private let rasterZoneStartLabel = NSTextField(labelWithString: "")
    private let rasterZoneStartSlider = NSSlider()
    private let rasterZoneTransitionLabel = NSTextField(labelWithString: "")
    private let rasterZoneTransitionSlider = NSSlider()
    private let rasterZoneFootprintsLabel = NSTextField(labelWithString: "")
    private let rasterZoneFootprintsSwitch = NSSwitch()
    private let rasterZoneLinesLabel = NSTextField(labelWithString: "")
    private let rasterZoneLinesSwitch = NSSwitch()
    /// One ring rule's editor: the drop picker, the distance slider, the
    /// picture switch and the line switch, each with its named
    /// row. Rebuilt when the number of rules changes.
    private struct RingRuleRow {
        let dropLabel: NSTextField
        let dropControl: NSSegmentedControl
        let distanceLabel: NSTextField
        let distanceSlider: NSSlider
        let rasterLabel: NSTextField
        let rasterSwitch: NSSwitch
        let linesLabel: NSTextField
        let linesSwitch: NSSwitch
        var views: [NSView] {
            [dropLabel, dropControl, distanceLabel, distanceSlider, rasterLabel, rasterSwitch, linesLabel, linesSwitch]
        }
    }
    private var ringRuleRows: [RingRuleRow] = []
    private let ringRulesAddButton = NSButton()
    private let ringRulesRemoveButton = NSButton()
    /// The rule sets by target zoom (`RingRuleSets`): the picker names
    /// each set by its zooms and chooses the one the rule rows edit, the
    /// slider moves the chosen set's first zoom between its neighbours.
    private let ringRuleSetControl = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: nil, action: nil)
    private let ringRuleSetFirstZoomLabel = NSTextField(labelWithString: "")
    private let ringRuleSetFirstZoomSlider = NSSlider()
    private let ringRuleSetsAddButton = NSButton()
    private let ringRuleSetsRemoveButton = NSButton()
    /// The sets as the editor shows them: any moved control emits the
    /// whole list.
    private var ringRuleSets = RingRuleSets.default
    private var selectedRingRuleSetIndex = 0
    /// The rules of the chosen set, which the rule rows edit.
    private var flatRingRules: FlatRingRules {
        get { ringRuleSets.sets[min(selectedRingRuleSetIndex, ringRuleSets.sets.count - 1)].rules }
        set { ringRuleSets.sets[min(selectedRingRuleSetIndex, ringRuleSets.sets.count - 1)].rules = newValue }
    }
    private let surfaceModeButton = NSButton()

    private var snapshot: DebugOverlayHUDSnapshot?
    private var isPanelEnabled = false
    private var isCollapsed = false
    private var shadowSettings = ImmersiveMapSettings.ShadowSettings()
    private var sunDirection = ImmersiveMapSettings.SceneLightSettings().direction
    private var fogSettings = ImmersiveMapSettings.FogSettings()
    private var atmosphereSettings = ImmersiveMapSettings.AtmosphereSettings()
    /// The host view's top safe-area inset; on macOS with a regular window title bar this is 0.
    var safeAreaTopInset: CGFloat = 0 {
        didSet {
            guard safeAreaTopInset != oldValue else { return }
            needsLayout = true
        }
    }
    private var tileTraceSnapshot = TileTraceRecorderSnapshot(isRecording: false, fileURL: nil)
    private var baseLabelTraceSnapshot = BaseLabelTraceRecorderSnapshot(isRecording: false, fileURL: nil)

    var onAxesEnabledChanged: ((Bool) -> Void)?
    var onTileLayersEnabledChanged: ((Bool) -> Void)?
    var onTileGridEnabledChanged: ((Bool) -> Void)?
    var onTileGridDensityChanged: ((Int) -> Void)?
    var onWireframeEnabledChanged: ((Bool) -> Void)?
    /// The plane's ring rules, whole, on every edit.
    var onRingRuleSetsChanged: ((RingRuleSets) -> Void)?
    /// The building level of detail thresholds: the cut and the fade, in pixels.
    var onRoadLabelTilesEnabledChanged: ((Bool) -> Void)?
    var onBaseLabelBoundsEnabledChanged: ((Bool) -> Void)?
    var onRoadLabelBoundsEnabledChanged: ((Bool) -> Void)?
    var onSurfaceModeSwitchRequested: (() -> Void)?
    var onTileTraceRecordingToggle: (() -> Void)?
    var onBaseLabelTraceRecordingToggle: (() -> Void)?
    var onShadowSettingsChanged: ((ImmersiveMapSettings.ShadowSettings) -> Void)?
    var onSunDirectionChanged: ((SIMD3<Float>) -> Void)?
    var onFogSettingsChanged: ((ImmersiveMapSettings.FogSettings) -> Void)?
    var onAtmosphereSettingsChanged: ((ImmersiveMapSettings.AtmosphereSettings) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true

        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.black.withAlphaComponent(Layout.backgroundAlpha).cgColor
        // Square corners: the panel is a rail attached to the window edge, and
        // a rounded corner there reads as a card that missed its margin.
        // masksToBounds stays, it is what keeps the scrolled column inside.
        containerView.layer?.masksToBounds = true
        addSubview(containerView)

        titleLabel.textColor = .white
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        containerView.addSubview(titleLabel)

        configureBorderlessButton(collapseButton)
        collapseButton.contentTintColor = .white
        collapseButton.target = self
        collapseButton.action = #selector(toggleCollapsed)
        containerView.addSubview(collapseButton)

        configureScrollView(scrollView, documentView: contentView)
        containerView.addSubview(scrollView)

        [statsGroupLabel, tilesGroupLabel, baseLabelsGroupLabel,
         shadowsGroupLabel, fogGroupLabel, atmosphereGroupLabel, controlsGroupLabel].forEach(configureGroupLabel)

        configureControlLabel(axesLabel, text: "Axes")
        configureControlLabel(tileLayersLabel, text: "Tile layers")
        configureControlLabel(tileGridLabel, text: "Tile grid")
        configureControlLabel(wireframeLabel, text: "Wireframe")
        configureControlLabel(roadLabelTilesLabel, text: "Road label tiles")
        configureControlLabel(baseLabelBoundsLabel, text: "Base label boxes")
        configureControlLabel(roadLabelBoundsLabel, text: "Road label boxes")
        configureControlLabel(shadowsEnabledLabel, text: "Enabled")
        configureControlLabel(shadowStrengthLabel, text: "")
        configureControlLabel(shadowMapResolutionLabel, text: "Map px")
        configureControlLabel(shadowCoverageLabel, text: "")
        configureControlLabel(shadowNormalOffsetLabel, text: "")
        configureControlLabel(shadowCasterHeightLabel, text: "")
        configureControlLabel(shadowSoftnessLabel, text: "")
        configureControlLabel(sunAzimuthLabel, text: "")
        configureControlLabel(sunElevationLabel, text: "")
        configureControlLabel(fogEnabledLabel, text: "Enabled")
        configureControlLabel(fogHazeStartLabel, text: "")
        configureControlLabel(fogHazeEndLabel, text: "")
        configureControlLabel(fogSkyColorLabel, text: "Sky colour")
        configureControlLabel(fogHorizonColorLabel, text: "Horizon colour")
        configureControlLabel(atmosphereEnabledLabel, text: "Enabled")
        configureControlLabel(atmosphereColorLabel, text: "Colour")
        configureControlLabel(atmosphereIntensityLabel, text: "")
        configureControlLabel(atmosphereThicknessLabel, text: "")
        configureControlLabel(atmosphereSunInfluenceLabel, text: "")

        configureSwitch(axesSwitch, action: #selector(axesSwitchChanged))
        configureSwitch(tileLayersSwitch, action: #selector(tileLayersSwitchChanged))
        configureSwitch(tileGridSwitch, action: #selector(tileGridSwitchChanged))
        configureSwitch(wireframeSwitch, action: #selector(wireframeSwitchChanged))
        configureControlLabel(buildingCutLabel, text: "")
        configureControlLabel(buildingFadeLabel, text: "")
        configureSlider(buildingCutSlider, range: BuildingFootprintFade.goneAreaRange, action: #selector(buildingLODSliderChanged))
        configureSlider(buildingFadeSlider, range: BuildingFootprintFade.opaqueAreaRange, action: #selector(buildingLODSliderChanged))
        configureControlLabel(roadFadeOpaqueLabel, text: "")
        configureSlider(roadFadeOpaqueSlider, range: RoadThinnessFade.opaqueRange, action: #selector(roadThinnessFadeSliderChanged))
        configureControlLabel(rasterZoneLabel, text: "Raster zone: far ground as pictures")
        configureControlLabel(rasterZoneStartLabel, text: "")
        configureControlLabel(rasterZoneTransitionLabel, text: "")
        configureControlLabel(rasterZoneFootprintsLabel, text: "Raster zone: building footprints in pictures")
        configureControlLabel(rasterZoneLinesLabel, text: "Raster zone: rivers and borders in pictures")
        configureSwitch(rasterZoneSwitch, action: #selector(rasterZoneChanged))
        configureSwitch(rasterZoneFootprintsSwitch, action: #selector(rasterZoneChanged))
        configureSwitch(rasterZoneLinesSwitch, action: #selector(rasterZoneChanged))
        configureSlider(rasterZoneStartSlider, range: RasterZone.startRange, action: #selector(rasterZoneChanged))
        configureSlider(rasterZoneTransitionSlider, range: RasterZone.transitionRange, action: #selector(rasterZoneChanged))
        configureSwitch(roadLabelTilesSwitch, action: #selector(roadLabelTilesSwitchChanged))
        configureSwitch(baseLabelBoundsSwitch, action: #selector(baseLabelBoundsSwitchChanged))
        configureSwitch(roadLabelBoundsSwitch, action: #selector(roadLabelBoundsSwitchChanged))
        configureSwitch(shadowsEnabledSwitch, action: #selector(shadowsEnabledSwitchChanged))
        configureSwitch(fogEnabledSwitch, action: #selector(fogEnabledSwitchChanged))
        configureSwitch(atmosphereEnabledSwitch, action: #selector(atmosphereEnabledSwitchChanged))

        configureSlider(shadowStrengthSlider,
                        range: DebugOverlayShadowSettingsPlanner.strengthRange,
                        action: #selector(shadowStrengthSliderChanged))
        configureSlider(shadowCoverageSlider,
                        range: DebugOverlayShadowSettingsPlanner.coverageRange,
                        action: #selector(shadowCoverageSliderChanged))
        configureSlider(shadowNormalOffsetSlider,
                        range: DebugOverlayShadowSettingsPlanner.normalOffsetRange,
                        action: #selector(shadowNormalOffsetSliderChanged))
        configureSlider(shadowCasterHeightSlider,
                        range: DebugOverlayShadowSettingsPlanner.casterHeightRange,
                        action: #selector(shadowCasterHeightSliderChanged))
        configureSlider(shadowSoftnessSlider,
                        range: DebugOverlayShadowSettingsPlanner.softnessRange,
                        action: #selector(shadowSoftnessSliderChanged))
        configureSlider(sunAzimuthSlider,
                        range: DebugOverlayShadowSettingsPlanner.azimuthRange,
                        action: #selector(sunAzimuthSliderChanged))
        configureSlider(sunElevationSlider,
                        range: DebugOverlayShadowSettingsPlanner.elevationRange,
                        action: #selector(sunElevationSliderChanged))
        configureSlider(fogHazeStartSlider,
                        range: DebugOverlayFogSettingsPlanner.hazeStartRange,
                        action: #selector(fogHazeStartSliderChanged))
        configureSlider(fogHazeEndSlider,
                        range: DebugOverlayFogSettingsPlanner.hazeEndRange,
                        action: #selector(fogHazeEndSliderChanged))
        configureColorWell(fogSkyColorWell, action: #selector(fogSkyColorWellChanged))
        configureColorWell(fogHorizonColorWell, action: #selector(fogHorizonColorWellChanged))
        configureSlider(atmosphereIntensitySlider,
                        range: DebugOverlayAtmosphereSettingsPlanner.intensityRange,
                        action: #selector(atmosphereIntensitySliderChanged))
        configureSlider(atmosphereThicknessSlider,
                        range: DebugOverlayAtmosphereSettingsPlanner.thicknessRange,
                        action: #selector(atmosphereThicknessSliderChanged))
        configureSlider(atmosphereSunInfluenceSlider,
                        range: DebugOverlayAtmosphereSettingsPlanner.sunInfluenceRange,
                        action: #selector(atmosphereSunInfluenceSliderChanged))
        configureColorWell(atmosphereColorWell, action: #selector(atmosphereColorWellChanged))

        refuseFocus(tileGridDensityControl)
        refuseFocus(shadowMapResolutionControl)
        tileGridDensityControl.target = self
        tileGridDensityControl.action = #selector(tileGridDensityControlChanged)
        tileGridDensityControl.selectedSegment = DebugOverlayHUDTextComposer.tileGridDensityIndex(for: DebugTileGridDensity.standard)
        shadowMapResolutionControl.target = self
        shadowMapResolutionControl.action = #selector(shadowMapResolutionControlChanged)

        configureActionButton(surfaceModeButton,
                              title: "Switch globe / flat",
                              symbolName: "arrow.triangle.2.circlepath",
                              action: #selector(surfaceModeButtonTapped))
        ringRuleSetControl.segmentStyle = .rounded
        ringRuleSetControl.target = self
        ringRuleSetControl.action = #selector(ringRuleSetControlChanged)
        configureControlLabel(ringRuleSetFirstZoomLabel, text: "")
        configureSlider(ringRuleSetFirstZoomSlider,
                        range: Double(RingRuleSets.zoomRange.lowerBound) ... Double(RingRuleSets.zoomRange.upperBound),
                        action: #selector(ringRuleSetFirstZoomSliderChanged))
        configureActionButton(ringRuleSetsAddButton,
                              title: "Split the rule set at a zoom",
                              symbolName: "plus.square.on.square",
                              action: #selector(ringRuleSetsAddButtonTapped))
        configureActionButton(ringRuleSetsRemoveButton,
                              title: "Remove this rule set",
                              symbolName: "minus.square",
                              action: #selector(ringRuleSetsRemoveButtonTapped))
        configureActionButton(ringRulesAddButton,
                              title: "Add ring rule",
                              symbolName: "plus.circle",
                              action: #selector(ringRulesAddButtonTapped))
        configureActionButton(ringRulesRemoveButton,
                              title: "Remove last ring rule",
                              symbolName: "minus.circle",
                              action: #selector(ringRulesRemoveButtonTapped))
        configureActionButton(tileTraceButton,
                              title: "",
                              symbolName: nil,
                              action: #selector(tileTraceButtonTapped))
        configureStatusLabel(tileTraceStatusLabel)
        configureActionButton(baseLabelTraceButton,
                              title: "",
                              symbolName: nil,
                              action: #selector(baseLabelTraceButtonTapped))
        configureStatusLabel(baseLabelTraceStatusLabel)

        [zoomLabel, latLonLabel, diagnosticsLabel, tilesStatusLabel].forEach { label in
            label.textColor = .white
        }

        scrolledSubviews.forEach(contentView.addSubview)
        rebuildRingRuleRows()

        tilesStatusListView.onExpansionChanged = { [weak self] in
            self?.needsLayout = true
        }

        updateCollapseButtonImage()
        updateTileTraceControl()
        updateBaseLabelTraceControl()
        updateShadowControls()
        updateFogControls()
        updateAtmosphereControls()
        updateVisibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Everything that scrolls, in the order it is laid out.
    private var scrolledSubviews: [NSView] {
        [statsGroupLabel, zoomLabel, latLonLabel, diagnosticsLabel,
         baseLabelsGroupLabel, baseLabelTraceButton, baseLabelTraceStatusLabel,
         roadLabelTilesLabel, roadLabelTilesSwitch,
         baseLabelBoundsLabel, baseLabelBoundsSwitch,
         roadLabelBoundsLabel, roadLabelBoundsSwitch,
         shadowsGroupLabel, shadowsEnabledLabel, shadowsEnabledSwitch,
         shadowStrengthLabel, shadowStrengthSlider,
         shadowMapResolutionLabel, shadowMapResolutionControl,
         shadowCoverageLabel, shadowCoverageSlider,
         shadowNormalOffsetLabel, shadowNormalOffsetSlider,
         shadowCasterHeightLabel, shadowCasterHeightSlider,
         shadowSoftnessLabel, shadowSoftnessSlider,
         sunAzimuthLabel, sunAzimuthSlider,
         sunElevationLabel, sunElevationSlider,
         fogGroupLabel, fogEnabledLabel, fogEnabledSwitch,
         fogHazeStartLabel, fogHazeStartSlider,
         fogHazeEndLabel, fogHazeEndSlider,
         fogSkyColorLabel, fogSkyColorWell,
         fogHorizonColorLabel, fogHorizonColorWell,
         atmosphereGroupLabel, atmosphereEnabledLabel, atmosphereEnabledSwitch,
         atmosphereColorLabel, atmosphereColorWell,
         atmosphereIntensityLabel, atmosphereIntensitySlider,
         atmosphereThicknessLabel, atmosphereThicknessSlider,
         atmosphereSunInfluenceLabel, atmosphereSunInfluenceSlider,
         controlsGroupLabel, axesLabel, axesSwitch, tileLayersLabel, tileLayersSwitch,
         tileGridLabel, tileGridSwitch, tileGridDensityControl,
         wireframeLabel, wireframeSwitch,
         buildingCutLabel, buildingCutSlider, buildingFadeLabel, buildingFadeSlider,
         roadFadeOpaqueLabel, roadFadeOpaqueSlider,
         rasterZoneLabel, rasterZoneSwitch, rasterZoneStartLabel, rasterZoneStartSlider,
         rasterZoneTransitionLabel, rasterZoneTransitionSlider,
         rasterZoneFootprintsLabel, rasterZoneFootprintsSwitch, rasterZoneLinesLabel, rasterZoneLinesSwitch,
         ringRuleSetControl, ringRuleSetFirstZoomLabel, ringRuleSetFirstZoomSlider,
         ringRuleSetsAddButton, ringRuleSetsRemoveButton,
         ringRulesAddButton, ringRulesRemoveButton,
         surfaceModeButton,
         tilesGroupLabel, tileTraceButton, tileTraceStatusLabel, tilesStatusLabel, tilesStatusListView]
    }

    // MARK: - Public API (matches the UIKit version)

    func apply(snapshot: DebugOverlayHUDSnapshot?) {
        guard self.snapshot != snapshot else {
            return
        }

        self.snapshot = snapshot
        updateText()
        updateVisibility()
        needsLayout = true
    }

    func apply(isDebugPanelEnabled: Bool,
               controls: DebugOverlayControlSnapshot) {
        isPanelEnabled = isDebugPanelEnabled
        axesSwitch.state = controls.axesEnabled ? .on : .off
        tileLayersSwitch.state = controls.tileLayersEnabled ? .on : .off
        tileGridSwitch.state = controls.tileGridEnabled ? .on : .off
        tileGridDensityControl.selectedSegment = DebugOverlayHUDTextComposer.tileGridDensityIndex(for: controls.tileGridDensity)
        wireframeSwitch.state = controls.wireframeEnabled ? .on : .off
        ringRuleSets = controls.ringRuleSets
        selectedRingRuleSetIndex = min(selectedRingRuleSetIndex, ringRuleSets.sets.count - 1)
        updateRingRuleSetControls()
        showSelectedRingRuleSetTuning()
        if ringRuleRows.count != flatRingRules.rules.count {
            rebuildRingRuleRows()
        }
        updateRingRuleRows()
        roadLabelTilesSwitch.state = controls.roadLabelTilesEnabled ? .on : .off
        baseLabelBoundsSwitch.state = controls.baseLabelBoundsEnabled ? .on : .off
        roadLabelBoundsSwitch.state = controls.roadLabelBoundsEnabled ? .on : .off
        updateVisibility()
        needsLayout = true
    }

    // MARK: - Ring rules

    /// One editor row per rule, in the scrolled content next to the other
    /// controls. The old rows leave the view; the values follow in
    /// `updateRingRuleRows`.
    private func rebuildRingRuleRows() {
        for row in ringRuleRows {
            row.views.forEach { $0.removeFromSuperview() }
        }
        ringRuleRows = flatRingRules.rules.indices.map { _ in
            let dropLabel = NSTextField(labelWithString: "")
            configureControlLabel(dropLabel, text: "")
            let dropControl = NSSegmentedControl(labels: FlatRingRules.zoomDropRange.map(String.init),
                                                 trackingMode: .selectOne,
                                                 target: self,
                                                 action: #selector(ringRuleDropControlChanged(_:)))
            refuseFocus(dropControl)
            let distanceLabel = NSTextField(labelWithString: "")
            configureControlLabel(distanceLabel, text: "")
            let distanceSlider = NSSlider()
            configureSlider(distanceSlider, range: Self.ringRuleSliderRange, action: #selector(ringRuleDistanceSliderChanged(_:)))
            let rasterLabel = NSTextField(labelWithString: "")
            configureControlLabel(rasterLabel, text: "")
            let rasterSwitch = NSSwitch()
            rasterSwitch.target = self
            rasterSwitch.action = #selector(ringRuleRasterSwitchChanged(_:))
            refuseFocus(rasterSwitch)
            let linesLabel = NSTextField(labelWithString: "")
            configureControlLabel(linesLabel, text: "")
            let linesSwitch = NSSwitch()
            linesSwitch.target = self
            linesSwitch.action = #selector(ringRuleLinesSwitchChanged(_:))
            refuseFocus(linesSwitch)
            return RingRuleRow(dropLabel: dropLabel, dropControl: dropControl,
                                distanceLabel: distanceLabel, distanceSlider: distanceSlider,
                                rasterLabel: rasterLabel, rasterSwitch: rasterSwitch,
                                linesLabel: linesLabel, linesSwitch: linesSwitch)
        }
        for row in ringRuleRows {
            row.views.forEach(contentView.addSubview)
        }
        needsLayout = true
    }

    private func updateRingRuleRows() {
        for (index, (row, rule)) in zip(ringRuleRows, flatRingRules.rules).enumerated() {
            row.dropLabel.stringValue = Self.ringRuleDropTitle(index: index)
            row.dropControl.selectedSegment = rule.zoomDrop - FlatRingRules.zoomDropRange.lowerBound
            row.distanceSlider.doubleValue = Self.ringRuleSliderValue(distance: rule.distance)
            row.distanceLabel.stringValue = Self.ringRuleDistanceTitle(index: index, distance: rule.distance)
            row.rasterLabel.stringValue = Self.ringRuleRasterTitle(index: index)
            row.rasterSwitch.state = rule.rasterized ? .on : .off
            row.linesLabel.stringValue = Self.ringRuleLinesTitle(index: index)
            row.linesSwitch.state = rule.drawsLines ? .on : .off
        }
        ringRulesRemoveButton.isEnabled = flatRingRules.rules.count > 1
    }

    static func ringRuleDropTitle(index: Int) -> String {
        "Rule \(index + 1): zoom drop"
    }

    static func ringRuleDistanceTitle(index: Int, distance: Int) -> String {
        "Rule \(index + 1): to ring \(distance) from the look-at tile"
    }

    /// The distance slider runs on the square root of the ring number, so
    /// the first rings, where one step matters, take most of its travel.
    static let ringRuleSliderRange: ClosedRange<Double> = 0 ... Double(FlatRingRules.distanceRange.upperBound).squareRoot()

    static func ringRuleSliderValue(distance: Int) -> Double {
        Double(max(distance, 0)).squareRoot()
    }

    static func ringRuleDistance(sliderValue: Double) -> Int {
        let distance = Int((sliderValue * sliderValue).rounded())
        return min(max(distance, FlatRingRules.distanceRange.lowerBound), FlatRingRules.distanceRange.upperBound)
    }

    static func ringRuleRasterTitle(index: Int) -> String {
        "Rule \(index + 1): pictures in the raster zone"
    }

    static func ringRuleLinesTitle(index: Int) -> String {
        "Rule \(index + 1): draw lines"
    }

    @objc private func ringRuleLinesSwitchChanged(_ sender: NSSwitch) {
        guard let index = ringRuleRows.firstIndex(where: { $0.linesSwitch === sender }),
              index < flatRingRules.rules.count else { return }
        flatRingRules.rules[index].drawsLines = sender.state == .on
        onRingRuleSetsChanged?(ringRuleSets)
    }

    @objc private func ringRuleRasterSwitchChanged(_ sender: NSSwitch) {
        guard let index = ringRuleRows.firstIndex(where: { $0.rasterSwitch === sender }),
              index < flatRingRules.rules.count else { return }
        flatRingRules.rules[index].rasterized = sender.state == .on
        onRingRuleSetsChanged?(ringRuleSets)
    }

    @objc private func ringRuleDropControlChanged(_ sender: NSSegmentedControl) {
        guard let index = ringRuleRows.firstIndex(where: { $0.dropControl === sender }),
              index < flatRingRules.rules.count else { return }
        flatRingRules.rules[index].zoomDrop = sender.selectedSegment + FlatRingRules.zoomDropRange.lowerBound
        onRingRuleSetsChanged?(ringRuleSets)
    }

    @objc private func ringRuleDistanceSliderChanged(_ sender: NSSlider) {
        guard let index = ringRuleRows.firstIndex(where: { $0.distanceSlider === sender }),
              index < flatRingRules.rules.count else { return }
        let distance = Self.ringRuleDistance(sliderValue: sender.doubleValue)
        guard flatRingRules.rules[index].distance != distance else { return }
        flatRingRules.rules[index].distance = distance
        ringRuleRows[index].distanceLabel.stringValue = Self.ringRuleDistanceTitle(index: index, distance: distance)
        onRingRuleSetsChanged?(ringRuleSets)
    }

    // MARK: - Rule sets

    /// A set's name in the picker: its zooms.
    static func ringRuleSetTitle(sets: RingRuleSets, index: Int) -> String {
        let first = sets.sets[index].firstZoom
        guard let last = sets.lastZoom(ofSetAt: index) else { return "z\(first)+" }
        return last == first ? "z\(first)" : "z\(first)\u{2013}\(last)"
    }

    static func ringRuleSetFirstZoomTitle(firstZoom: Int) -> String {
        "Rule set: starts at zoom \(firstZoom)"
    }

    /// The first zooms the set at `index` can take without passing a
    /// neighbour. The first set always starts at zoom 0.
    static func ringRuleSetFirstZoomLimits(sets: RingRuleSets, index: Int) -> ClosedRange<Int>? {
        guard index > 0, sets.sets.indices.contains(index) else { return nil }
        let lower = sets.sets[index - 1].firstZoom + 1
        let upper = sets.sets.indices.contains(index + 1) ? sets.sets[index + 1].firstZoom - 1 : RingRuleSets.zoomRange.upperBound
        return lower <= upper ? lower ... upper : nil
    }

    private func updateRingRuleSetControls() {
        ringRuleSetControl.segmentCount = ringRuleSets.sets.count
        for index in ringRuleSets.sets.indices {
            ringRuleSetControl.setLabel(Self.ringRuleSetTitle(sets: ringRuleSets, index: index), forSegment: index)
        }
        ringRuleSetControl.selectedSegment = selectedRingRuleSetIndex
        let firstZoom = ringRuleSets.sets[selectedRingRuleSetIndex].firstZoom
        ringRuleSetFirstZoomSlider.doubleValue = Double(firstZoom)
        ringRuleSetFirstZoomSlider.isEnabled = Self.ringRuleSetFirstZoomLimits(sets: ringRuleSets, index: selectedRingRuleSetIndex) != nil
        ringRuleSetFirstZoomLabel.stringValue = Self.ringRuleSetFirstZoomTitle(firstZoom: firstZoom)
        ringRuleSetsRemoveButton.isEnabled = ringRuleSets.sets.count > 1
        needsLayout = true
    }

    /// The chosen set's tuning (`RingRuleSetTuning`), which the building,
    /// road and raster zone rows edit.
    private var selectedTuning: RingRuleSetTuning {
        get { ringRuleSets.sets[min(selectedRingRuleSetIndex, ringRuleSets.sets.count - 1)].tuning }
        set { ringRuleSets.sets[min(selectedRingRuleSetIndex, ringRuleSets.sets.count - 1)].tuning = newValue }
    }

    private func showSelectedRingRuleSetTuning() {
        let tuning = selectedTuning
        buildingCutSlider.doubleValue = Double(tuning.buildingGoneAreaPixels)
        buildingFadeSlider.doubleValue = Double(tuning.buildingOpaqueAreaPixels)
        updateBuildingLODLabels()
        roadFadeOpaqueSlider.doubleValue = Double(tuning.roadThinnessFade.opaqueWidthPixels)
        updateRoadThinnessFadeLabels()
        rasterZoneSwitch.state = tuning.rasterZone.isEnabled ? .on : .off
        rasterZoneStartSlider.doubleValue = Double(tuning.rasterZone.startCameraDistances)
        rasterZoneTransitionSlider.doubleValue = Double(tuning.rasterZone.transitionCameraDistances)
        rasterZoneFootprintsSwitch.state = tuning.rasterZone.rasterizesBuildingFootprints ? .on : .off
        rasterZoneLinesSwitch.state = tuning.rasterZone.rasterizesGroundLines ? .on : .off
        updateRasterZoneControls()
    }

    private func showSelectedRingRuleSet() {
        updateRingRuleSetControls()
        showSelectedRingRuleSetTuning()
        if ringRuleRows.count != flatRingRules.rules.count {
            rebuildRingRuleRows()
        }
        updateRingRuleRows()
    }

    @objc private func ringRuleSetControlChanged() {
        guard ringRuleSets.sets.indices.contains(ringRuleSetControl.selectedSegment) else { return }
        selectedRingRuleSetIndex = ringRuleSetControl.selectedSegment
        showSelectedRingRuleSet()
    }

    @objc private func ringRuleSetFirstZoomSliderChanged() {
        guard let limits = Self.ringRuleSetFirstZoomLimits(sets: ringRuleSets, index: selectedRingRuleSetIndex) else {
            updateRingRuleSetControls()
            return
        }
        let wanted = Int(ringRuleSetFirstZoomSlider.doubleValue.rounded())
        let firstZoom = min(max(wanted, limits.lowerBound), limits.upperBound)
        guard ringRuleSets.sets[selectedRingRuleSetIndex].firstZoom != firstZoom else {
            updateRingRuleSetControls()
            return
        }
        ringRuleSets.sets[selectedRingRuleSetIndex].firstZoom = firstZoom
        updateRingRuleSetControls()
        onRingRuleSetsChanged?(ringRuleSets)
    }

    /// Splits the chosen set: a new set with the same rules and tuning takes the upper
    /// half of its zooms and becomes the chosen one.
    @objc private func ringRuleSetsAddButtonTapped() {
        let index = selectedRingRuleSetIndex
        let first = ringRuleSets.sets[index].firstZoom
        let last = ringRuleSets.lastZoom(ofSetAt: index) ?? RingRuleSets.zoomRange.upperBound
        guard last > first else { return }
        let split = first + (last - first + 1) / 2
        var upper = ringRuleSets.sets[index]
        upper.firstZoom = split
        ringRuleSets.sets.insert(upper, at: index + 1)
        selectedRingRuleSetIndex = index + 1
        showSelectedRingRuleSet()
        onRingRuleSetsChanged?(ringRuleSets)
    }

    /// Removes the chosen set: its zooms go to the set before it, or, for
    /// the first set, to the one after.
    @objc private func ringRuleSetsRemoveButtonTapped() {
        guard ringRuleSets.sets.count > 1 else { return }
        ringRuleSets.sets.remove(at: selectedRingRuleSetIndex)
        ringRuleSets.sets[0].firstZoom = RingRuleSets.zoomRange.lowerBound
        selectedRingRuleSetIndex = max(selectedRingRuleSetIndex - 1, 0)
        showSelectedRingRuleSet()
        onRingRuleSetsChanged?(ringRuleSets)
    }

    /// A new last rule: two levels coarser than the last and reaching
    /// twice as many rings (at least one more), inside the ranges.
    @objc private func ringRulesAddButtonTapped() {
        let last = flatRingRules.rules.last ?? FlatRingRules.default.rules[0]
        let rule = FlatRingRule(zoomDrop: min(last.zoomDrop + 2, FlatRingRules.zoomDropRange.upperBound),
                                 distance: min(max(last.distance * 2, last.distance + 1), FlatRingRules.distanceRange.upperBound))
        guard rule.distance > last.distance else { return }
        flatRingRules.rules.append(rule)
        rebuildRingRuleRows()
        updateRingRuleRows()
        onRingRuleSetsChanged?(ringRuleSets)
    }

    @objc private func ringRulesRemoveButtonTapped() {
        guard flatRingRules.rules.count > 1 else { return }
        flatRingRules.rules.removeLast()
        rebuildRingRuleRows()
        updateRingRuleRows()
        onRingRuleSetsChanged?(ringRuleSets)
    }

    /// The shadow group reflects the live settings, so a change made anywhere
    /// else (a modifier, another panel) shows up here rather than leaving the
    /// sliders lying about what the renderer is doing.
    func apply(shadowSettings: ImmersiveMapSettings.ShadowSettings,
               sunDirection: SIMD3<Float>) {
        guard self.shadowSettings != shadowSettings || self.sunDirection != sunDirection else {
            return
        }

        self.shadowSettings = shadowSettings
        self.sunDirection = sunDirection
        updateShadowControls()
        needsLayout = true
    }

    /// The horizon group reflects the live settings, like the shadow group.
    func apply(fogSettings: ImmersiveMapSettings.FogSettings) {
        guard self.fogSettings != fogSettings else {
            return
        }

        self.fogSettings = fogSettings
        updateFogControls()
        needsLayout = true
    }

    /// The atmosphere group reflects the live settings, like the others.
    func apply(atmosphereSettings: ImmersiveMapSettings.AtmosphereSettings) {
        guard self.atmosphereSettings != atmosphereSettings else {
            return
        }

        self.atmosphereSettings = atmosphereSettings
        updateAtmosphereControls()
        needsLayout = true
    }

    func apply(tileTraceSnapshot: TileTraceRecorderSnapshot) {
        self.tileTraceSnapshot = tileTraceSnapshot
        updateTileTraceControl()
        needsLayout = true
    }

    func apply(baseLabelTraceSnapshot: BaseLabelTraceRecorderSnapshot) {
        self.baseLabelTraceSnapshot = baseLabelTraceSnapshot
        updateBaseLabelTraceControl()
        needsLayout = true
    }

    /// Clicks outside the panel go to the map.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isHidden == false, let superview else {
            return nil
        }

        let localPoint = convert(point, from: superview)
        guard containerView.frame.contains(localPoint) else {
            return nil
        }

        return super.hitTest(point)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        guard snapshot != nil else { return }

        let panelTop = safeAreaTopInset
        let panelWidth = min(Layout.panelWidth, max(bounds.width, Layout.collapsedWidth))

        if isCollapsed {
            containerView.frame = CGRect(x: 0,
                                         y: panelTop,
                                         width: Layout.collapsedWidth,
                                         height: Layout.headerHeight)
            layoutHeader(width: Layout.collapsedWidth)
            scrollView.isHidden = true
            return
        }

        // Flush left, and as tall as the window allows.
        let panelHeight = max(Layout.headerHeight, bounds.height - panelTop)
        containerView.frame = CGRect(x: 0, y: panelTop, width: panelWidth, height: panelHeight)
        layoutHeader(width: panelWidth)

        let scrollTop = Layout.headerHeight
        scrollView.isHidden = false
        scrollView.frame = CGRect(x: 0,
                                  y: scrollTop,
                                  width: panelWidth,
                                  height: max(0, panelHeight - scrollTop))

        // The scrolled width is the scroll view's, not the panel's: a legacy
        // scroller takes its width out of the content, and laying out to the
        // panel width instead pushed every switch out past the right edge.
        let scrolledWidth = scrollView.contentSize.width
        let contentWidth = DebugOverlayPanelLayout.scrolledContentWidth(scrollWidth: scrolledWidth,
                                                                        leadingInset: Layout.contentInset,
                                                                        scrollerGutter: Layout.scrollerGutter)
        let contentHeight = layoutGroups(contentWidth: contentWidth)
        contentView.frame = CGRect(x: 0,
                                   y: 0,
                                   width: scrolledWidth,
                                   height: max(contentHeight, scrollView.contentSize.height))
    }

    /// Walks the groups top-down with one cursor and returns the total height.
    /// Every group is laid out; nothing is hidden by a tab any more, so the
    /// only thing that can shorten the column is a group with no content
    /// (an empty tile list).
    private func layoutGroups(contentWidth: CGFloat) -> CGFloat {
        let sectionSpacing = CGFloat(snapshot?.sectionSpacing ?? 8) / backingScale
        let constrainedSize = CGSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        var cursor = Layout.contentInset

        // Stats
        cursor = layoutGroupHeader(statsGroupLabel, at: cursor, contentWidth: contentWidth)
        cursor = layoutTextRow(zoomLabel, at: cursor, contentWidth: contentWidth, constrainedSize: constrainedSize)
        cursor = layoutTextRow(latLonLabel, at: cursor, contentWidth: contentWidth, constrainedSize: constrainedSize)
        cursor += sectionSpacing
        cursor = layoutTextRow(diagnosticsLabel, at: cursor, contentWidth: contentWidth, constrainedSize: constrainedSize)
        cursor += Layout.groupSpacing

        // Base labels
        cursor = layoutGroupHeader(baseLabelsGroupLabel, at: cursor, contentWidth: contentWidth)
        cursor = layoutSwitchRow(roadLabelTilesLabel, roadLabelTilesSwitch, at: cursor, contentWidth: contentWidth)
        cursor = layoutSwitchRow(baseLabelBoundsLabel, baseLabelBoundsSwitch, at: cursor, contentWidth: contentWidth)
        cursor = layoutSwitchRow(roadLabelBoundsLabel, roadLabelBoundsSwitch, at: cursor, contentWidth: contentWidth)
        cursor = layoutFullWidthRow(baseLabelTraceButton, at: cursor, contentWidth: contentWidth, height: Layout.controlRowHeight)
        cursor = layoutFullWidthRow(baseLabelTraceStatusLabel, at: cursor, contentWidth: contentWidth, height: Layout.traceStatusHeight)
        cursor += Layout.groupSpacing

        // Shadows
        cursor = layoutGroupHeader(shadowsGroupLabel, at: cursor, contentWidth: contentWidth)
        cursor = layoutSwitchRow(shadowsEnabledLabel, shadowsEnabledSwitch, at: cursor, contentWidth: contentWidth)
        cursor = layoutControlRow(shadowStrengthLabel, shadowStrengthSlider, at: cursor, contentWidth: contentWidth)
        cursor = layoutControlRow(shadowMapResolutionLabel, shadowMapResolutionControl, at: cursor, contentWidth: contentWidth)
        cursor = layoutControlRow(shadowCoverageLabel, shadowCoverageSlider, at: cursor, contentWidth: contentWidth)
        cursor = layoutControlRow(shadowNormalOffsetLabel, shadowNormalOffsetSlider, at: cursor, contentWidth: contentWidth)
        cursor = layoutControlRow(shadowCasterHeightLabel, shadowCasterHeightSlider, at: cursor, contentWidth: contentWidth)
        cursor = layoutControlRow(shadowSoftnessLabel, shadowSoftnessSlider, at: cursor, contentWidth: contentWidth)
        cursor = layoutControlRow(sunAzimuthLabel, sunAzimuthSlider, at: cursor, contentWidth: contentWidth)
        cursor = layoutControlRow(sunElevationLabel, sunElevationSlider, at: cursor, contentWidth: contentWidth)
        cursor += Layout.groupSpacing

        // Horizon
        cursor = layoutGroupHeader(fogGroupLabel, at: cursor, contentWidth: contentWidth)
        cursor = layoutSwitchRow(fogEnabledLabel, fogEnabledSwitch, at: cursor, contentWidth: contentWidth)
        cursor = layoutControlRow(fogHazeStartLabel, fogHazeStartSlider, at: cursor, contentWidth: contentWidth)
        cursor = layoutControlRow(fogHazeEndLabel, fogHazeEndSlider, at: cursor, contentWidth: contentWidth)
        cursor = layoutControlRow(fogSkyColorLabel, fogSkyColorWell, at: cursor, contentWidth: contentWidth)
        cursor = layoutControlRow(fogHorizonColorLabel, fogHorizonColorWell, at: cursor, contentWidth: contentWidth)
        cursor += Layout.groupSpacing

        // Atmosphere
        cursor = layoutGroupHeader(atmosphereGroupLabel, at: cursor, contentWidth: contentWidth)
        cursor = layoutSwitchRow(atmosphereEnabledLabel, atmosphereEnabledSwitch, at: cursor, contentWidth: contentWidth)
        cursor = layoutControlRow(atmosphereColorLabel, atmosphereColorWell, at: cursor, contentWidth: contentWidth)
        cursor = layoutControlRow(atmosphereIntensityLabel, atmosphereIntensitySlider, at: cursor, contentWidth: contentWidth)
        cursor = layoutControlRow(atmosphereThicknessLabel, atmosphereThicknessSlider, at: cursor, contentWidth: contentWidth)
        cursor = layoutControlRow(atmosphereSunInfluenceLabel, atmosphereSunInfluenceSlider, at: cursor, contentWidth: contentWidth)
        cursor += Layout.groupSpacing

        // Controls
        cursor = layoutGroupHeader(controlsGroupLabel, at: cursor, contentWidth: contentWidth)
        cursor = layoutSwitchRow(axesLabel, axesSwitch, at: cursor, contentWidth: contentWidth)
        cursor = layoutSwitchRow(tileLayersLabel, tileLayersSwitch, at: cursor, contentWidth: contentWidth)
        cursor = layoutSwitchRow(tileGridLabel, tileGridSwitch, at: cursor, contentWidth: contentWidth)
        cursor = layoutFullWidthRow(tileGridDensityControl, at: cursor, contentWidth: contentWidth, height: Layout.controlRowHeight)
        cursor = layoutSwitchRow(wireframeLabel, wireframeSwitch, at: cursor, contentWidth: contentWidth)
        // The rule set picker first: everything from here to the rule rows
        // edits the chosen set.
        cursor = layoutFullWidthRow(ringRuleSetControl, at: cursor, contentWidth: contentWidth, height: Layout.controlRowHeight)
        cursor = layoutControlRow(ringRuleSetFirstZoomLabel, ringRuleSetFirstZoomSlider, at: cursor, contentWidth: contentWidth)
        cursor = layoutFullWidthRow(ringRuleSetsAddButton, at: cursor, contentWidth: contentWidth, height: Layout.controlRowHeight)
        cursor = layoutFullWidthRow(ringRuleSetsRemoveButton, at: cursor, contentWidth: contentWidth, height: Layout.controlRowHeight)
        cursor = layoutControlRow(buildingCutLabel, buildingCutSlider, at: cursor, contentWidth: contentWidth)
        cursor = layoutControlRow(buildingFadeLabel, buildingFadeSlider, at: cursor, contentWidth: contentWidth)
        cursor = layoutControlRow(roadFadeOpaqueLabel, roadFadeOpaqueSlider, at: cursor, contentWidth: contentWidth)
        cursor = layoutSwitchRow(rasterZoneLabel, rasterZoneSwitch, at: cursor, contentWidth: contentWidth)
        cursor = layoutControlRow(rasterZoneStartLabel, rasterZoneStartSlider, at: cursor, contentWidth: contentWidth)
        cursor = layoutControlRow(rasterZoneTransitionLabel, rasterZoneTransitionSlider, at: cursor, contentWidth: contentWidth)
        cursor = layoutSwitchRow(rasterZoneFootprintsLabel, rasterZoneFootprintsSwitch, at: cursor, contentWidth: contentWidth)
        cursor = layoutSwitchRow(rasterZoneLinesLabel, rasterZoneLinesSwitch, at: cursor, contentWidth: contentWidth)
        for row in ringRuleRows {
            cursor = layoutControlRow(row.dropLabel, row.dropControl, at: cursor, contentWidth: contentWidth)
            cursor = layoutControlRow(row.distanceLabel, row.distanceSlider, at: cursor, contentWidth: contentWidth)
            cursor = layoutSwitchRow(row.rasterLabel, row.rasterSwitch, at: cursor, contentWidth: contentWidth)
            cursor = layoutSwitchRow(row.linesLabel, row.linesSwitch, at: cursor, contentWidth: contentWidth)
        }
        cursor = layoutFullWidthRow(ringRulesAddButton, at: cursor, contentWidth: contentWidth, height: Layout.controlRowHeight)
        cursor = layoutFullWidthRow(ringRulesRemoveButton, at: cursor, contentWidth: contentWidth, height: Layout.controlRowHeight)
        cursor = layoutFullWidthRow(surfaceModeButton, at: cursor, contentWidth: contentWidth, height: Layout.controlRowHeight)
        cursor += Layout.groupSpacing

        // Tiles last, and deliberately so: the list is the only thing in the
        // panel whose height follows the data (seventeen tiles while a zoom
        // settles, three once it has), and anything under it was shoved up and
        // down every time a tile arrived. Nothing is under it now.
        cursor = layoutGroupHeader(tilesGroupLabel, at: cursor, contentWidth: contentWidth)
        cursor = layoutFullWidthRow(tileTraceButton, at: cursor, contentWidth: contentWidth, height: Layout.controlRowHeight)
        cursor = layoutFullWidthRow(tileTraceStatusLabel, at: cursor, contentWidth: contentWidth, height: Layout.traceStatusHeight)
        cursor = layoutTextRow(tilesStatusLabel, at: cursor, contentWidth: contentWidth, constrainedSize: constrainedSize)
        // Always laid out, always the same height, empty or not: a reserved
        // height that disappears when the map has no tiles is not reserved.
        cursor = layoutFullWidthRow(tilesStatusListView,
                                    at: cursor,
                                    contentWidth: contentWidth,
                                    height: tilesStatusListView.preferredHeight(forWidth: contentWidth))

        return cursor + Layout.contentInset
    }

    private func layoutGroupHeader(_ label: NSTextField, at top: CGFloat, contentWidth: CGFloat) -> CGFloat {
        label.frame = CGRect(x: Layout.contentInset,
                             y: top,
                             width: contentWidth,
                             height: Layout.groupHeaderHeight)
        return top + Layout.groupHeaderHeight + Layout.controlSpacing
    }

    private func layoutTextRow(_ label: NSTextField,
                               at top: CGFloat,
                               contentWidth: CGFloat,
                               constrainedSize: CGSize) -> CGFloat {
        let height = label.sizeThatFits(constrainedSize).height
        label.frame = CGRect(x: Layout.contentInset, y: top, width: contentWidth, height: height)
        return top + height
    }

    private func layoutFullWidthRow(_ view: NSView,
                                    at top: CGFloat,
                                    contentWidth: CGFloat,
                                    height: CGFloat) -> CGFloat {
        view.frame = CGRect(x: Layout.contentInset, y: top, width: contentWidth, height: height)
        return top + height + Layout.controlSpacing
    }

    private func layoutSwitchRow(_ label: NSTextField,
                                 _ control: NSSwitch,
                                 at top: CGFloat,
                                 contentWidth: CGFloat) -> CGFloat {
        let switchSize = control.intrinsicContentSize
        label.frame = CGRect(x: Layout.contentInset,
                             y: top,
                             width: max(0, contentWidth - switchSize.width - Layout.controlSpacing),
                             height: Layout.controlRowHeight)
        control.frame = CGRect(x: Layout.contentInset + contentWidth - switchSize.width,
                               y: top + (Layout.controlRowHeight - switchSize.height) / 2,
                               width: switchSize.width,
                               height: switchSize.height)
        return top + Layout.controlRowHeight + Layout.controlSpacing
    }

    /// A named row whose control (a slider, a segmented picker) takes the
    /// right-hand side. The name carries the current value, so no third column
    /// of numbers is needed and the row stays one line tall.
    private func layoutControlRow(_ label: NSTextField,
                                  _ control: NSView,
                                  at top: CGFloat,
                                  contentWidth: CGFloat) -> CGFloat {
        let labelWidth = (contentWidth * Layout.controlLabelFraction).rounded()
        let controlWidth = max(0, contentWidth - labelWidth - Layout.controlSpacing)
        label.frame = CGRect(x: Layout.contentInset,
                             y: top,
                             width: labelWidth,
                             height: Layout.controlRowHeight)
        control.frame = CGRect(x: Layout.contentInset + labelWidth + Layout.controlSpacing,
                               y: top,
                               width: controlWidth,
                               height: Layout.controlRowHeight)
        return top + Layout.controlRowHeight + Layout.controlSpacing
    }

    private func layoutHeader(width: CGFloat) {
        let buttonSide = Layout.headerHeight
        titleLabel.frame = CGRect(x: Layout.contentInset,
                                  y: (Layout.headerHeight - titleLabel.intrinsicContentSize.height) / 2,
                                  width: width - Layout.contentInset * 2 - buttonSide,
                                  height: titleLabel.intrinsicContentSize.height)
        collapseButton.frame = CGRect(x: width - Layout.contentInset - buttonSide,
                                      y: 0,
                                      width: buttonSide,
                                      height: buttonSide)
    }

    private var backingScale: CGFloat {
        max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0, 1.0)
    }

    // MARK: - Content

    private func updateText() {
        guard let snapshot else {
            zoomLabel.attributedStringValue = NSAttributedString(string: "")
            latLonLabel.attributedStringValue = NSAttributedString(string: "")
            diagnosticsLabel.attributedStringValue = NSAttributedString(string: "")
            tilesStatusLabel.attributedStringValue = NSAttributedString(string: "")
            tilesStatusListView.apply(tiles: [])
            return
        }

        let scale = backingScale
        let coordinateFontSize = max(1, CGFloat(snapshot.coordinateScale) * Layout.coordinateFontScale / scale)
        let diagnosticsFontSize = max(1, CGFloat(snapshot.diagnosticsScale) * Layout.diagnosticsFontScale / scale)
        let color = NSColor.white

        zoomLabel.attributedStringValue = attributedText(snapshot.coordinateLines.zoom,
                                                         fontSize: coordinateFontSize,
                                                         color: color)
        latLonLabel.attributedStringValue = attributedText(snapshot.coordinateLines.latLon,
                                                           fontSize: coordinateFontSize,
                                                           color: color)
        diagnosticsLabel.attributedStringValue = diagnosticsAttributedText(snapshot.diagnosticsLines.joined(separator: "\n"),
                                                                           fontSize: diagnosticsFontSize,
                                                                           color: color)
        let tilesStatusText = NSMutableAttributedString(
            attributedString: attributedText(DebugOverlayHUDTextComposer.tilesStatusText(lines: snapshot.tileLoadingStatusLines),
                                             fontSize: diagnosticsFontSize,
                                             color: color)
        )
        tilesStatusText.append(attributedText("\n" + DebugOverlayHUDTextComposer.tilesTotalText(count: snapshot.tileLoadingStatusTiles.count),
                                              fontSize: diagnosticsFontSize,
                                              color: .systemYellow))
        tilesStatusLabel.attributedStringValue = tilesStatusText
        tilesStatusListView.apply(tiles: snapshot.tileLoadingStatusTiles)
    }

    private func updateVisibility() {
        isHidden = isPanelEnabled == false || snapshot == nil
        scrollView.isHidden = isCollapsed
    }

    private func updateShadowControls() {
        shadowsEnabledSwitch.state = shadowSettings.isEnabled ? .on : .off
        shadowStrengthSlider.doubleValue = Double(shadowSettings.strength)
        shadowStrengthLabel.stringValue = DebugOverlayShadowSettingsPlanner.strengthTitle(shadowSettings.strength)
        shadowMapResolutionControl.selectedSegment =
            DebugOverlayShadowSettingsPlanner.mapResolutionIndex(for: shadowSettings.mapResolution)
        shadowCoverageSlider.doubleValue = Double(shadowSettings.coverageCameraDistances)
        shadowCoverageLabel.stringValue = DebugOverlayShadowSettingsPlanner.coverageTitle(shadowSettings.coverageCameraDistances)
        shadowNormalOffsetSlider.doubleValue = Double(shadowSettings.normalOffsetTexels)
        shadowNormalOffsetLabel.stringValue = DebugOverlayShadowSettingsPlanner.normalOffsetTitle(shadowSettings.normalOffsetTexels)
        shadowCasterHeightSlider.doubleValue = Double(shadowSettings.maxCasterHeightMeters)
        shadowCasterHeightLabel.stringValue = DebugOverlayShadowSettingsPlanner.casterHeightTitle(shadowSettings.maxCasterHeightMeters)
        shadowSoftnessSlider.doubleValue = Double(shadowSettings.softness)
        shadowSoftnessLabel.stringValue = DebugOverlayShadowSettingsPlanner.softnessTitle(shadowSettings.softness)

        let angles = DebugOverlaySunAngles.angles(direction: sunDirection)
        sunAzimuthSlider.doubleValue = angles.azimuthDegrees
        sunAzimuthLabel.stringValue = DebugOverlayShadowSettingsPlanner.azimuthTitle(angles.azimuthDegrees)
        sunElevationSlider.doubleValue = angles.elevationDegrees
        sunElevationLabel.stringValue = DebugOverlayShadowSettingsPlanner.elevationTitle(angles.elevationDegrees)

        // Everything below the switch only means something with shadows on.
        [shadowStrengthSlider, shadowMapResolutionControl, shadowCoverageSlider,
         shadowNormalOffsetSlider, shadowCasterHeightSlider, shadowSoftnessSlider,
         sunAzimuthSlider,
         sunElevationSlider].forEach { $0.isEnabled = shadowSettings.isEnabled }
    }

    // MARK: - Configuration

    private func updateFogControls() {
        fogEnabledSwitch.state = fogSettings.isEnabled ? .on : .off
        fogHazeStartSlider.doubleValue = Double(fogSettings.hazeRange.lowerBound)
        fogHazeStartLabel.stringValue = DebugOverlayFogSettingsPlanner.hazeStartTitle(fogSettings.hazeRange.lowerBound)
        fogHazeEndSlider.doubleValue = Double(fogSettings.hazeRange.upperBound)
        fogHazeEndLabel.stringValue = DebugOverlayFogSettingsPlanner.hazeEndTitle(fogSettings.hazeRange.upperBound)
        fogSkyColorWell.color = Self.color(fogSettings.skyColor)
        fogHorizonColorWell.color = Self.color(fogSettings.horizonColor)

        // Everything below the switch only means something with the fog on.
        [fogHazeStartSlider, fogHazeEndSlider, fogSkyColorWell, fogHorizonColorWell]
            .forEach { $0.isEnabled = fogSettings.isEnabled }
    }

    private func updateAtmosphereControls() {
        atmosphereEnabledSwitch.state = atmosphereSettings.isEnabled ? .on : .off
        atmosphereColorWell.color = Self.color(atmosphereSettings.color)
        atmosphereIntensitySlider.doubleValue = Double(atmosphereSettings.intensity)
        atmosphereIntensityLabel.stringValue = DebugOverlayAtmosphereSettingsPlanner.intensityTitle(atmosphereSettings.intensity)
        atmosphereThicknessSlider.doubleValue = Double(atmosphereSettings.thickness)
        atmosphereThicknessLabel.stringValue = DebugOverlayAtmosphereSettingsPlanner.thicknessTitle(atmosphereSettings.thickness)
        atmosphereSunInfluenceSlider.doubleValue = Double(atmosphereSettings.sunInfluence)
        atmosphereSunInfluenceLabel.stringValue = DebugOverlayAtmosphereSettingsPlanner.sunInfluenceTitle(atmosphereSettings.sunInfluence)

        // Off keeps only the limb feather; the rest means nothing then.
        [atmosphereColorWell, atmosphereIntensitySlider, atmosphereThicknessSlider, atmosphereSunInfluenceSlider]
            .forEach { $0.isEnabled = atmosphereSettings.isEnabled }
    }

    /// The settings state their colours in sRGB; the well shows and hands
    /// back the same.
    private static func color(_ rgb: SIMD3<Float>) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
    }

    private static func rgb(_ color: NSColor) -> SIMD3<Float>? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        return SIMD3<Float>(Float(srgb.redComponent), Float(srgb.greenComponent), Float(srgb.blueComponent))
    }

    private func configureColorWell(_ well: NSColorWell, action: Selector) {
        well.target = self
        well.action = action
        refuseFocus(well)
    }

    private func configureGroupLabel(_ label: NSTextField) {
        label.textColor = NSColor.white.withAlphaComponent(0.62)
        label.font = NSFont.systemFont(ofSize: 11, weight: .heavy)
        label.stringValue = label.stringValue.uppercased()
    }

    private func configureControlLabel(_ label: NSTextField, text: String) {
        label.stringValue = text
        label.textColor = .white
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
    }

    private func configureStatusLabel(_ label: NSTextField) {
        label.textColor = .white
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
    }

    private func configureSwitch(_ switchControl: NSSwitch, action: Selector) {
        switchControl.target = self
        switchControl.action = action
        switchControl.controlSize = .small
        refuseFocus(switchControl)
    }

    /// Keeps a control out of the responder chain.
    ///
    /// AppKit reveals whatever just became first responder by scrolling its
    /// enclosing scroll view, so clicking a switch halfway down the column
    /// scrolled the panel under the pointer. Nothing here is driven by the
    /// keyboard, and the map must keep key focus anyway, so no control in the
    /// panel accepts it.
    private func refuseFocus(_ control: NSControl) {
        control.refusesFirstResponder = true
    }

    private func configureSlider(_ slider: NSSlider,
                                 range: ClosedRange<Double>,
                                 action: Selector) {
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = action
        refuseFocus(slider)
    }

    private func configureBorderlessButton(_ button: NSButton) {
        refuseFocus(button)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.title = ""
    }

    private func configureActionButton(_ button: NSButton,
                                       title: String,
                                       symbolName: String?,
                                       action: Selector) {
        refuseFocus(button)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        button.layer?.cornerRadius = 6
        button.layer?.masksToBounds = true
        button.contentTintColor = .white
        button.imagePosition = .imageLeading
        button.target = self
        button.action = action
        applyActionButtonTitle(button,
                               title: title,
                               symbolName: symbolName)
    }

    private func applyActionButtonTitle(_ button: NSButton,
                                        title: String,
                                        symbolName: String?) {
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
        if let symbolName {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        } else {
            button.image = nil
        }
    }

    private func configureScrollView(_ scrollView: NSScrollView,
                                     documentView: NSView) {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed
        scrollView.documentView = documentView
    }

    private func updateTileTraceControl() {
        let title = DebugOverlayHUDTextComposer.traceButtonTitle(isRecording: tileTraceSnapshot.isRecording)
        applyActionButtonTitle(tileTraceButton,
                               title: title,
                               symbolName: DebugOverlayHUDTextComposer.traceButtonImageName(isRecording: tileTraceSnapshot.isRecording))
        tileTraceButton.layer?.backgroundColor = tileTraceSnapshot.isRecording
            ? NSColor.systemRed.withAlphaComponent(0.35).cgColor
            : NSColor.white.withAlphaComponent(0.12).cgColor
        tileTraceStatusLabel.stringValue = DebugOverlayHUDTextComposer.tileTraceStatusText(tileTraceSnapshot)
    }

    private func updateBaseLabelTraceControl() {
        let title = DebugOverlayHUDTextComposer.traceButtonTitle(isRecording: baseLabelTraceSnapshot.isRecording)
        applyActionButtonTitle(baseLabelTraceButton,
                               title: title,
                               symbolName: DebugOverlayHUDTextComposer.traceButtonImageName(isRecording: baseLabelTraceSnapshot.isRecording))
        baseLabelTraceButton.layer?.backgroundColor = baseLabelTraceSnapshot.isRecording
            ? NSColor.systemRed.withAlphaComponent(0.35).cgColor
            : NSColor.white.withAlphaComponent(0.12).cgColor
        baseLabelTraceStatusLabel.stringValue = DebugOverlayHUDTextComposer.baseLabelTraceStatusText(baseLabelTraceSnapshot)
    }

    private func updateCollapseButtonImage() {
        let imageName = isCollapsed ? "chevron.down" : "chevron.up"
        collapseButton.image = NSImage(systemSymbolName: imageName,
                                       accessibilityDescription: isCollapsed ? "Expand debug panel" : "Collapse debug panel")
    }

    // MARK: - Actions

    @objc private func toggleCollapsed() {
        isCollapsed.toggle()
        updateCollapseButtonImage()
        scrollView.isHidden = isCollapsed
        needsLayout = true
    }

    @objc private func axesSwitchChanged() {
        onAxesEnabledChanged?(axesSwitch.state == .on)
    }

    @objc private func tileGridSwitchChanged() {
        onTileGridEnabledChanged?(tileGridSwitch.state == .on)
    }

    @objc private func tileGridDensityControlChanged() {
        onTileGridDensityChanged?(DebugOverlayHUDTextComposer.tileGridDensity(atIndex: tileGridDensityControl.selectedSegment))
    }

    @objc private func tileLayersSwitchChanged() {
        onTileLayersEnabledChanged?(tileLayersSwitch.state == .on)
    }



    @objc private func wireframeSwitchChanged() {
        onWireframeEnabledChanged?(wireframeSwitch.state == .on)
    }

    static func buildingCutTitle(pixels: Float) -> String {
        String(format: "Building fills: gone under %.0f sq px", pixels)
    }

    static func buildingFadeTitle(pixels: Float) -> String {
        String(format: "Building fills: opaque from %.0f sq px", pixels)
    }

    private func updateBuildingLODLabels() {
        buildingCutLabel.stringValue = Self.buildingCutTitle(pixels: Float(buildingCutSlider.doubleValue))
        buildingFadeLabel.stringValue = Self.buildingFadeTitle(pixels: Float(buildingFadeSlider.doubleValue))
    }

    @objc private func buildingLODSliderChanged() {
        // The opaque area never sits under the gone area: the moved slider
        // pushes the other.
        if buildingFadeSlider.doubleValue < buildingCutSlider.doubleValue {
            buildingFadeSlider.doubleValue = buildingCutSlider.doubleValue
        }
        updateBuildingLODLabels()
        selectedTuning.buildingGoneAreaPixels = Float(buildingCutSlider.doubleValue)
        selectedTuning.buildingOpaqueAreaPixels = Float(buildingFadeSlider.doubleValue)
        onRingRuleSetsChanged?(ringRuleSets)
    }

    static func roadFadeOpaqueTitle(pixels: Float) -> String {
        pixels > 0
            ? String(format: "Roads: opaque from %.1f px wide", pixels)
            : "Roads: thinness fade off"
    }

    private func updateRoadThinnessFadeLabels() {
        roadFadeOpaqueLabel.stringValue = Self.roadFadeOpaqueTitle(pixels: Float(roadFadeOpaqueSlider.doubleValue))
    }

    @objc private func roadThinnessFadeSliderChanged() {
        updateRoadThinnessFadeLabels()
        selectedTuning.roadThinnessFade = RoadThinnessFade(opaqueWidthPixels: Float(roadFadeOpaqueSlider.doubleValue))
        onRingRuleSetsChanged?(ringRuleSets)
    }

    static func rasterZoneStartTitle(cameraDistances: Float) -> String {
        String(format: "Raster zone: vector up to %.2f camera distances", cameraDistances)
    }

    static func rasterZoneTransitionTitle(cameraDistances: Float) -> String {
        String(format: "Raster zone: pictures fade in over %.2f", cameraDistances)
    }

    private func updateRasterZoneControls() {
        rasterZoneStartLabel.stringValue = Self.rasterZoneStartTitle(cameraDistances: Float(rasterZoneStartSlider.doubleValue))
        rasterZoneTransitionLabel.stringValue = Self.rasterZoneTransitionTitle(
            cameraDistances: Float(rasterZoneTransitionSlider.doubleValue))
        let isEnabled = rasterZoneSwitch.state == .on
        for control in [rasterZoneStartSlider, rasterZoneTransitionSlider,
                        rasterZoneFootprintsSwitch, rasterZoneLinesSwitch] as [NSControl] {
            control.isEnabled = isEnabled
        }
    }

    @objc private func rasterZoneChanged() {
        updateRasterZoneControls()
        selectedTuning.rasterZone = RasterZone(isEnabled: rasterZoneSwitch.state == .on,
                                               startCameraDistances: Float(rasterZoneStartSlider.doubleValue),
                                               transitionCameraDistances: Float(rasterZoneTransitionSlider.doubleValue),
                                               rasterizesBuildingFootprints: rasterZoneFootprintsSwitch.state == .on,
                                               rasterizesGroundLines: rasterZoneLinesSwitch.state == .on)
        onRingRuleSetsChanged?(ringRuleSets)
    }

    @objc private func roadLabelTilesSwitchChanged() {
        onRoadLabelTilesEnabledChanged?(roadLabelTilesSwitch.state == .on)
    }

    @objc private func baseLabelBoundsSwitchChanged() {
        onBaseLabelBoundsEnabledChanged?(baseLabelBoundsSwitch.state == .on)
    }

    @objc private func roadLabelBoundsSwitchChanged() {
        onRoadLabelBoundsEnabledChanged?(roadLabelBoundsSwitch.state == .on)
    }

    @objc private func surfaceModeButtonTapped() {
        onSurfaceModeSwitchRequested?()
    }

    @objc private func tileTraceButtonTapped() {
        onTileTraceRecordingToggle?()
    }

    @objc private func baseLabelTraceButtonTapped() {
        onBaseLabelTraceRecordingToggle?()
    }

    @objc private func shadowsEnabledSwitchChanged() {
        var settings = shadowSettings
        settings.isEnabled = shadowsEnabledSwitch.state == .on
        publish(shadowSettings: settings)
    }

    @objc private func shadowStrengthSliderChanged() {
        var settings = shadowSettings
        settings.strength = Float(shadowStrengthSlider.doubleValue)
        publish(shadowSettings: settings)
    }

    @objc private func shadowMapResolutionControlChanged() {
        var settings = shadowSettings
        settings.mapResolution = DebugOverlayShadowSettingsPlanner.mapResolution(atIndex: shadowMapResolutionControl.selectedSegment)
        publish(shadowSettings: settings)
    }

    @objc private func shadowCoverageSliderChanged() {
        var settings = shadowSettings
        settings.coverageCameraDistances = Float(shadowCoverageSlider.doubleValue)
        publish(shadowSettings: settings)
    }

    @objc private func shadowNormalOffsetSliderChanged() {
        var settings = shadowSettings
        settings.normalOffsetTexels = Float(shadowNormalOffsetSlider.doubleValue)
        publish(shadowSettings: settings)
    }

    @objc private func shadowCasterHeightSliderChanged() {
        var settings = shadowSettings
        settings.maxCasterHeightMeters = Float(shadowCasterHeightSlider.doubleValue)
        publish(shadowSettings: settings)
    }

    @objc private func shadowSoftnessSliderChanged() {
        var settings = shadowSettings
        settings.softness = Float(shadowSoftnessSlider.doubleValue)
        publish(shadowSettings: settings)
    }

    @objc private func sunAzimuthSliderChanged() {
        publishSunDirection(azimuthDegrees: sunAzimuthSlider.doubleValue,
                            elevationDegrees: DebugOverlaySunAngles.angles(direction: sunDirection).elevationDegrees)
    }

    @objc private func sunElevationSliderChanged() {
        publishSunDirection(azimuthDegrees: DebugOverlaySunAngles.angles(direction: sunDirection).azimuthDegrees,
                            elevationDegrees: sunElevationSlider.doubleValue)
    }

    @objc private func fogEnabledSwitchChanged() {
        var settings = fogSettings
        settings.isEnabled = fogEnabledSwitch.state == .on
        publish(fogSettings: settings)
    }

    @objc private func fogHazeStartSliderChanged() {
        var settings = fogSettings
        settings.hazeRange = DebugOverlayFogSettingsPlanner.hazeRange(settings.hazeRange,
                                                                      start: Float(fogHazeStartSlider.doubleValue))
        publish(fogSettings: settings)
    }

    @objc private func fogHazeEndSliderChanged() {
        var settings = fogSettings
        settings.hazeRange = DebugOverlayFogSettingsPlanner.hazeRange(settings.hazeRange,
                                                                      end: Float(fogHazeEndSlider.doubleValue))
        publish(fogSettings: settings)
    }

    @objc private func fogSkyColorWellChanged() {
        guard let rgb = Self.rgb(fogSkyColorWell.color) else { return }
        var settings = fogSettings
        settings.skyColor = rgb
        publish(fogSettings: settings)
    }

    @objc private func fogHorizonColorWellChanged() {
        guard let rgb = Self.rgb(fogHorizonColorWell.color) else { return }
        var settings = fogSettings
        settings.horizonColor = rgb
        publish(fogSettings: settings)
    }

    private func publish(fogSettings settings: ImmersiveMapSettings.FogSettings) {
        fogSettings = settings
        updateFogControls()
        needsLayout = true
        onFogSettingsChanged?(settings)
    }

    @objc private func atmosphereEnabledSwitchChanged() {
        var settings = atmosphereSettings
        settings.isEnabled = atmosphereEnabledSwitch.state == .on
        publish(atmosphereSettings: settings)
    }

    @objc private func atmosphereColorWellChanged() {
        guard let rgb = Self.rgb(atmosphereColorWell.color) else { return }
        var settings = atmosphereSettings
        settings.color = rgb
        publish(atmosphereSettings: settings)
    }

    @objc private func atmosphereIntensitySliderChanged() {
        var settings = atmosphereSettings
        settings.intensity = Float(atmosphereIntensitySlider.doubleValue)
        publish(atmosphereSettings: settings)
    }

    @objc private func atmosphereThicknessSliderChanged() {
        var settings = atmosphereSettings
        settings.thickness = Float(atmosphereThicknessSlider.doubleValue)
        publish(atmosphereSettings: settings)
    }

    @objc private func atmosphereSunInfluenceSliderChanged() {
        var settings = atmosphereSettings
        settings.sunInfluence = Float(atmosphereSunInfluenceSlider.doubleValue)
        publish(atmosphereSettings: settings)
    }

    private func publish(atmosphereSettings settings: ImmersiveMapSettings.AtmosphereSettings) {
        atmosphereSettings = settings
        updateAtmosphereControls()
        needsLayout = true
        onAtmosphereSettingsChanged?(settings)
    }

    /// The panel owns the value while a slider is dragged: the labels update
    /// immediately, and the settings round trip back through
    /// `apply(shadowSettings:sunDirection:)` on the next frame, which is a
    /// no-op when nothing else changed it.
    private func publish(shadowSettings settings: ImmersiveMapSettings.ShadowSettings) {
        shadowSettings = settings
        updateShadowControls()
        needsLayout = true
        onShadowSettingsChanged?(settings)
    }

    private func publishSunDirection(azimuthDegrees: Double, elevationDegrees: Double) {
        let direction = DebugOverlaySunAngles.direction(azimuthDegrees: azimuthDegrees,
                                                        elevationDegrees: elevationDegrees)
        sunDirection = direction
        updateShadowControls()
        onSunDirectionChanged?(direction)
    }

    // MARK: - Text styling

    private func attributedText(_ text: String,
                                fontSize: CGFloat,
                                color: NSColor) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: color
            ]
        )
    }

    private func diagnosticsAttributedText(_ text: String,
                                           fontSize: CGFloat,
                                           color: NSColor) -> NSAttributedString {
        let attributedText = NSMutableAttributedString(attributedString: attributedText(text,
                                                                                        fontSize: fontSize,
                                                                                        color: color))
        for run in DebugOverlayDiagnosticsTextStylePlanner.makeRuns(for: text) {
            attributedText.addAttribute(.foregroundColor,
                                        value: diagnosticsColor(for: run.style),
                                        range: run.range)
        }
        return attributedText
    }

    private func diagnosticsColor(for style: DebugOverlayDiagnosticsTextStyle) -> NSColor {
        switch style {
        case let .section(title):
            return diagnosticsSectionColor(title: title)
        case .key:
            return NSColor.white.withAlphaComponent(0.58)
        case .warningValue:
            return NSColor.systemOrange
        }
    }

    private func diagnosticsSectionColor(title: String) -> NSColor {
        switch title {
        case "Camera":
            return NSColor.systemCyan
        case "Frame":
            return NSColor.systemGreen
        case "Tiles":
            return NSColor.systemYellow
        case "Labels":
            return NSColor.systemPurple
        case "Resources":
            return NSColor.systemBlue
        case "Globe culling":
            return NSColor.systemOrange
        case "Skip":
            return NSColor.systemRed
        default:
            return NSColor.white.withAlphaComponent(0.82)
        }
    }
}

/// Empty flipped container: subviews lay out top-down, as in UIKit.
private final class DebugOverlayFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class DebugOverlayTilesStatusListView: NSView {
    private enum Layout {
        static let rowHeight: CGFloat = 28
        static let childRowHeight: CGFloat = 22
        static let rowSpacing: CGFloat = 4
        static let textInset: CGFloat = 10
        static let cornerRadius: CGFloat = 6
        static let progressVerticalInset: CGFloat = 2
        static let primaryFontSize: CGFloat = 13.5
        static let childFontSize: CGFloat = 12
        /// The list reserves this many tile rows and never grows or shrinks
        /// with the data. Twelve covers an ordinary street-zoom working set;
        /// what does not fit is counted on the last line instead of pushing
        /// the panel around.
        static let slotCount = 12
    }

    private typealias Row = DebugOverlayTilesStatusRow

    private var tiles: [TileLoadingStatusTileSnapshot] = []
    private var expandedTiles: Set<Tile> = []
    private var expandedParseStageTiles: Set<Tile> = []

    var onExpansionChanged: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleClickGesture(_:)))
        addGestureRecognizer(clickGesture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var rowCount: Int {
        tiles.count
    }

    func apply(tiles: [TileLoadingStatusTileSnapshot]) {
        self.tiles = tiles
        let tileSet = Set(tiles.map(\.tile))
        expandedTiles = expandedTiles.intersection(tileSet)
        expandedParseStageTiles = expandedParseStageTiles.intersection(tileSet)
        needsDisplay = true
    }

    private static func height(of row: Row) -> CGFloat {
        switch row {
        case .tile:
            return Layout.rowHeight
        case .stage, .layer:
            return Layout.childRowHeight
        }
    }

    /// Always the same: `slotCount` rows, empty or not. This is the whole
    /// point of the fixed slots, so nothing laid out after the list moves when
    /// a tile arrives, leaves, or is expanded.
    func preferredHeight(forWidth _: CGFloat) -> CGFloat {
        DebugOverlayPanelLayout.fixedListHeight(slotCount: Layout.slotCount,
                                                slotHeight: Layout.rowHeight,
                                                spacing: Layout.rowSpacing)
    }

    /// The rows that fit in the reserved height, and how many were left over.
    /// Expanding a tile spends slots on its children, so the tail of the list
    /// is what gets dropped.
    private func windowedRows() -> (rows: [Row], overflow: Int) {
        let rows = visibleRows()
        let available = preferredHeight(forWidth: bounds.width)
        let count = DebugOverlayPanelLayout.visibleRowCount(rowHeights: rows.map(Self.height(of:)),
                                                            spacing: Layout.rowSpacing,
                                                            availableHeight: available)
        guard count < rows.count else {
            return (rows, 0)
        }
        // Give the last slot back to the "+N more" line, so a dropped tile is
        // stated rather than silently missing.
        let shown = max(0, count - 1)
        return (Array(rows.prefix(shown)), rows.count - shown)
    }

    override func draw(_ rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext, tiles.isEmpty == false else {
            return
        }

        let window = windowedRows()
        var rowTop: CGFloat = 0
        for row in window.rows {
            draw(row: row,
                 rowRect: DebugOverlayPanelLayout.rowDrawRect(bounds: bounds,
                                                              dirtyRect: rect,
                                                              rowTop: rowTop,
                                                              rowHeight: Self.height(of: row)),
                 context: context)
            rowTop += Self.height(of: row) + Layout.rowSpacing
        }

        if window.overflow > 0 {
            drawChildText(DebugOverlayHUDTextComposer.tilesOverflowText(count: window.overflow),
                          rowRect: DebugOverlayPanelLayout.rowDrawRect(bounds: bounds,
                                                                       dirtyRect: rect,
                                                                       rowTop: rowTop,
                                                                       rowHeight: Layout.childRowHeight))
        }
    }

    @objc private func handleClickGesture(_ gesture: NSClickGestureRecognizer) {
        guard gesture.state == .ended else {
            return
        }

        let point = gesture.location(in: self)
        guard let row = row(atY: point.y) else {
            return
        }

        switch row {
        case let .tile(tile, _, true):
            toggleTileExpansion(tile.tile)
        case .tile:
            break
        case let .stage(tile, stage, _) where stage.name == "parse" && stage.layerTimings.isEmpty == false:
            toggleParseExpansion(tile)
        case .stage, .layer:
            break
        }
    }

    private func draw(row: Row,
                      rowRect: CGRect,
                      context _: CGContext) {
        switch row {
        case let .tile(tile, _, _):
            drawTile(tile, rowRect: rowRect)
        case .stage, .layer:
            drawChildText(row.text, rowRect: rowRect)
        }
    }

    private func drawTile(_ tile: TileLoadingStatusTileSnapshot,
                          rowRect: CGRect) {
        let color = statusColor(tile.status)
        let backgroundRect = rowRect.insetBy(dx: 0, dy: Layout.progressVerticalInset)
        NSColor.black.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: backgroundRect, cornerRadius: Layout.cornerRadius).fill()

        let progressWidth = max(Layout.cornerRadius * 2, backgroundRect.width * CGFloat(tile.progress))
        let progressRect = CGRect(x: backgroundRect.minX,
                                  y: backgroundRect.minY,
                                  width: progressWidth,
                                  height: backgroundRect.height)
            .intersection(backgroundRect)
        color.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: progressRect, cornerRadius: Layout.cornerRadius).fill()

        let font = NSFont.monospacedSystemFont(ofSize: Layout.primaryFontSize, weight: .heavy)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.98)
        ]
        let lineHeight = font.ascender - font.descender + font.leading
        let textRect = CGRect(x: rowRect.minX + Layout.textInset,
                              y: backgroundRect.midY - lineHeight * 0.5,
                              width: max(0, rowRect.width - Layout.textInset * 2),
                              height: lineHeight)
        let isExpanded = expandedTiles.contains(tile.tile)
        Row.tile(tile, isExpanded: isExpanded, canExpand: tile.preparationStages.isEmpty == false)
            .text
            .draw(in: textRect, withAttributes: attributes)
    }

    private func drawChildText(_ text: String, rowRect: CGRect) {
        let font = NSFont.monospacedSystemFont(ofSize: Layout.childFontSize, weight: .bold)
        let lineHeight = font.ascender - font.descender + font.leading
        let textRect = CGRect(x: Layout.textInset,
                              y: rowRect.midY - lineHeight * 0.5,
                              width: max(0, rowRect.width - Layout.textInset * 2),
                              height: lineHeight)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.94)
        ]
        text.draw(in: textRect, withAttributes: attributes)
    }

    /// Only the drawn rows are clickable: below the last one is reserved
    /// space, not a row whose tile happens to be off the end.
    private func row(atY y: CGFloat) -> Row? {
        var rowTop: CGFloat = 0
        for row in windowedRows().rows {
            let rowBottom = rowTop + Self.height(of: row)
            if y >= rowTop, y <= rowBottom {
                return row
            }
            rowTop = rowBottom + Layout.rowSpacing
        }
        return nil
    }

    private func toggleTileExpansion(_ tile: Tile) {
        if expandedTiles.contains(tile) {
            expandedTiles.remove(tile)
            expandedParseStageTiles.remove(tile)
        } else {
            expandedTiles.insert(tile)
        }
        needsDisplay = true
        onExpansionChanged?()
    }

    private func toggleParseExpansion(_ tile: Tile) {
        if expandedParseStageTiles.contains(tile) {
            expandedParseStageTiles.remove(tile)
        } else {
            expandedParseStageTiles.insert(tile)
        }
        needsDisplay = true
        onExpansionChanged?()
    }

    private func visibleRows() -> [Row] {
        DebugOverlayTilesStatusRow.visibleRows(tiles: tiles,
                                               expandedTiles: expandedTiles,
                                               expandedParseStageTiles: expandedParseStageTiles)
    }

    private func statusColor(_ status: TileLoadingTileStatus) -> NSColor {
        switch status {
        case .ready:
            return NSColor.systemGreen
        case .failed:
            return NSColor.systemRed
        case .queued, .loading, .parsing:
            return NSColor.systemYellow
        }
    }
}

#endif
