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
        static let backgroundAlpha: CGFloat = 0.46
        /// The panel is a fixed-width rail, not a card that grows with its
        /// text: a width that followed the longest diagnostics line moved the
        /// map every time a number gained a digit. Wide enough that a
        /// diagnostics line does not wrap and a slider has travel worth
        /// aiming with.
        static let panelWidth: CGFloat = 420.0
        static let collapsedWidth: CGFloat = 170.0
        /// Fraction of a control row given to its name; the control takes the
        /// rest.
        static let controlLabelFraction: CGFloat = 0.46
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
    private let sunAzimuthLabel = NSTextField(labelWithString: "")
    private let sunAzimuthSlider = NSSlider()
    private let sunElevationLabel = NSTextField(labelWithString: "")
    private let sunElevationSlider = NSSlider()

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
    private let surfaceModeButton = NSButton()

    private var snapshot: DebugOverlayHUDSnapshot?
    private var isPanelEnabled = false
    private var isCollapsed = false
    private var shadowSettings = ImmersiveMapSettings.ShadowSettings()
    private var sunDirection = ImmersiveMapSettings.SceneLightSettings().direction
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
    var onRoadLabelTilesEnabledChanged: ((Bool) -> Void)?
    var onBaseLabelBoundsEnabledChanged: ((Bool) -> Void)?
    var onRoadLabelBoundsEnabledChanged: ((Bool) -> Void)?
    var onSurfaceModeSwitchRequested: (() -> Void)?
    var onTileTraceRecordingToggle: (() -> Void)?
    var onBaseLabelTraceRecordingToggle: (() -> Void)?
    var onShadowSettingsChanged: ((ImmersiveMapSettings.ShadowSettings) -> Void)?
    var onSunDirectionChanged: ((SIMD3<Float>) -> Void)?

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
         shadowsGroupLabel, controlsGroupLabel].forEach(configureGroupLabel)

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
        configureControlLabel(sunAzimuthLabel, text: "")
        configureControlLabel(sunElevationLabel, text: "")

        configureSwitch(axesSwitch, action: #selector(axesSwitchChanged))
        configureSwitch(tileLayersSwitch, action: #selector(tileLayersSwitchChanged))
        configureSwitch(tileGridSwitch, action: #selector(tileGridSwitchChanged))
        configureSwitch(wireframeSwitch, action: #selector(wireframeSwitchChanged))
        configureSwitch(roadLabelTilesSwitch, action: #selector(roadLabelTilesSwitchChanged))
        configureSwitch(baseLabelBoundsSwitch, action: #selector(baseLabelBoundsSwitchChanged))
        configureSwitch(roadLabelBoundsSwitch, action: #selector(roadLabelBoundsSwitchChanged))
        configureSwitch(shadowsEnabledSwitch, action: #selector(shadowsEnabledSwitchChanged))

        configureSlider(shadowStrengthSlider,
                        range: DebugOverlayShadowSettingsPlanner.strengthRange,
                        action: #selector(shadowStrengthSliderChanged))
        configureSlider(shadowCoverageSlider,
                        range: DebugOverlayShadowSettingsPlanner.coverageRange,
                        action: #selector(shadowCoverageSliderChanged))
        configureSlider(sunAzimuthSlider,
                        range: DebugOverlayShadowSettingsPlanner.azimuthRange,
                        action: #selector(sunAzimuthSliderChanged))
        configureSlider(sunElevationSlider,
                        range: DebugOverlayShadowSettingsPlanner.elevationRange,
                        action: #selector(sunElevationSliderChanged))

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

        tilesStatusListView.onExpansionChanged = { [weak self] in
            self?.needsLayout = true
        }

        updateCollapseButtonImage()
        updateTileTraceControl()
        updateBaseLabelTraceControl()
        updateShadowControls()
        updateVisibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Everything that scrolls, in the order it is laid out.
    private var scrolledSubviews: [NSView] {
        [statsGroupLabel, zoomLabel, latLonLabel, diagnosticsLabel,
         tilesGroupLabel, tileTraceButton, tileTraceStatusLabel, tilesStatusLabel, tilesStatusListView,
         baseLabelsGroupLabel, baseLabelTraceButton, baseLabelTraceStatusLabel,
         roadLabelTilesLabel, roadLabelTilesSwitch,
         baseLabelBoundsLabel, baseLabelBoundsSwitch,
         roadLabelBoundsLabel, roadLabelBoundsSwitch,
         shadowsGroupLabel, shadowsEnabledLabel, shadowsEnabledSwitch,
         shadowStrengthLabel, shadowStrengthSlider,
         shadowMapResolutionLabel, shadowMapResolutionControl,
         shadowCoverageLabel, shadowCoverageSlider,
         sunAzimuthLabel, sunAzimuthSlider,
         sunElevationLabel, sunElevationSlider,
         controlsGroupLabel, axesLabel, axesSwitch, tileLayersLabel, tileLayersSwitch,
         tileGridLabel, tileGridSwitch, tileGridDensityControl,
         wireframeLabel, wireframeSwitch, surfaceModeButton]
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
        roadLabelTilesSwitch.state = controls.roadLabelTilesEnabled ? .on : .off
        baseLabelBoundsSwitch.state = controls.baseLabelBoundsEnabled ? .on : .off
        roadLabelBoundsSwitch.state = controls.roadLabelBoundsEnabled ? .on : .off
        updateVisibility()
        needsLayout = true
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

        let contentWidth = max(1, panelWidth - Layout.contentInset * 2)
        let contentHeight = layoutGroups(contentWidth: contentWidth)
        contentView.frame = CGRect(x: 0,
                                   y: 0,
                                   width: scrollView.contentSize.width,
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

        // Tiles
        cursor = layoutGroupHeader(tilesGroupLabel, at: cursor, contentWidth: contentWidth)
        cursor = layoutFullWidthRow(tileTraceButton, at: cursor, contentWidth: contentWidth, height: Layout.controlRowHeight)
        cursor = layoutFullWidthRow(tileTraceStatusLabel, at: cursor, contentWidth: contentWidth, height: Layout.traceStatusHeight)
        cursor = layoutTextRow(tilesStatusLabel, at: cursor, contentWidth: contentWidth, constrainedSize: constrainedSize)
        let tilesListHeight = tilesStatusListView.preferredHeight(forWidth: contentWidth)
        if tilesListHeight > 0 {
            cursor = layoutFullWidthRow(tilesStatusListView, at: cursor, contentWidth: contentWidth, height: tilesListHeight)
            tilesStatusListView.isHidden = false
        } else {
            tilesStatusListView.isHidden = true
        }
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
        cursor = layoutControlRow(sunAzimuthLabel, sunAzimuthSlider, at: cursor, contentWidth: contentWidth)
        cursor = layoutControlRow(sunElevationLabel, sunElevationSlider, at: cursor, contentWidth: contentWidth)
        cursor += Layout.groupSpacing

        // Controls
        cursor = layoutGroupHeader(controlsGroupLabel, at: cursor, contentWidth: contentWidth)
        cursor = layoutSwitchRow(axesLabel, axesSwitch, at: cursor, contentWidth: contentWidth)
        cursor = layoutSwitchRow(tileLayersLabel, tileLayersSwitch, at: cursor, contentWidth: contentWidth)
        cursor = layoutSwitchRow(tileGridLabel, tileGridSwitch, at: cursor, contentWidth: contentWidth)
        cursor = layoutFullWidthRow(tileGridDensityControl, at: cursor, contentWidth: contentWidth, height: Layout.controlRowHeight)
        cursor = layoutSwitchRow(wireframeLabel, wireframeSwitch, at: cursor, contentWidth: contentWidth)
        cursor = layoutFullWidthRow(surfaceModeButton, at: cursor, contentWidth: contentWidth, height: Layout.controlRowHeight)

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

        let angles = DebugOverlaySunAngles.angles(direction: sunDirection)
        sunAzimuthSlider.doubleValue = angles.azimuthDegrees
        sunAzimuthLabel.stringValue = DebugOverlayShadowSettingsPlanner.azimuthTitle(angles.azimuthDegrees)
        sunElevationSlider.doubleValue = angles.elevationDegrees
        sunElevationLabel.stringValue = DebugOverlayShadowSettingsPlanner.elevationTitle(angles.elevationDegrees)

        // Everything below the switch only means something with shadows on.
        [shadowStrengthSlider, shadowMapResolutionControl, shadowCoverageSlider,
         sunAzimuthSlider, sunElevationSlider].forEach { $0.isEnabled = shadowSettings.isEnabled }
    }

    // MARK: - Configuration

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

    @objc private func sunAzimuthSliderChanged() {
        publishSunDirection(azimuthDegrees: sunAzimuthSlider.doubleValue,
                            elevationDegrees: DebugOverlaySunAngles.angles(direction: sunDirection).elevationDegrees)
    }

    @objc private func sunElevationSliderChanged() {
        publishSunDirection(azimuthDegrees: DebugOverlaySunAngles.angles(direction: sunDirection).azimuthDegrees,
                            elevationDegrees: sunElevationSlider.doubleValue)
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

    func preferredHeight(forWidth _: CGFloat) -> CGFloat {
        let rows = visibleRows()
        guard rows.isEmpty == false else {
            return 0
        }
        let rowsHeight = rows.reduce(CGFloat(0)) { $0 + Self.height(of: $1) }
        return rowsHeight + CGFloat(max(0, rows.count - 1)) * Layout.rowSpacing
    }

    override func draw(_ rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext, tiles.isEmpty == false else {
            return
        }

        var rowTop: CGFloat = 0
        for row in visibleRows() {
            draw(row: row,
                 rowRect: DebugOverlayPanelLayout.rowDrawRect(bounds: bounds,
                                                              dirtyRect: rect,
                                                              rowTop: rowTop,
                                                              rowHeight: Self.height(of: row)),
                 context: context)
            rowTop += Self.height(of: row) + Layout.rowSpacing
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

    private func row(atY y: CGFloat) -> Row? {
        var rowTop: CGFloat = 0
        for row in visibleRows() {
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
