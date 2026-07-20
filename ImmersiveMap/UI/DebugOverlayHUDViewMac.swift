// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if os(macOS)

import AppKit

/// AppKit-порт debug HUD. Геометрия и тексты совпадают с UIKit-версией:
/// view flipped, layout ручной, контент собирает `DebugOverlayHUDTextComposer`.
final class DebugOverlayHUDView: NSView {
    private enum SelectedTab: Int {
        case stats = 0
        case atlas = 1
        case tiles = 2
        case baseLabels = 3
        case controls = 4
    }

    private enum Layout {
        static let coordinateFontScale: CGFloat = 0.56
        static let diagnosticsFontScale: CGFloat = 0.50
        static let contentInset: CGFloat = 8.0
        static let headerHeight: CGFloat = 30.0
        static let controlRowHeight: CGFloat = 30.0
        static let controlSpacing: CGFloat = 6.0
        static let traceStatusHeight: CGFloat = 24.0
        static let cornerRadius: CGFloat = 8.0
        static let backgroundAlpha: CGFloat = 0.46
        static let expandedMinimumWidth: CGFloat = 260.0
        static let collapsedWidth: CGFloat = 136.0
        static let maximumWidth: CGFloat = 720.0
    }

    private let containerView = DebugOverlayFlippedView()
    private let titleLabel = NSTextField(labelWithString: "Debug")
    private let collapseButton = NSButton()
    private let axesLabel = NSTextField(labelWithString: "")
    private let axesSwitch = NSSwitch()
    private let tileLayersLabel = NSTextField(labelWithString: "")
    private let tileLayersSwitch = NSSwitch()
    private let wireframeLabel = NSTextField(labelWithString: "")
    private let wireframeSwitch = NSSwitch()
    private let earthSceneLabel = NSTextField(labelWithString: "")
    private let earthSceneSwitch = NSSwitch()
    private let surfaceModeButton = NSButton()
    private let tabControl = NSSegmentedControl(labels: ["Stats", "Atlas", "Tiles", "Base labels", "Controls"],
                                                trackingMode: .selectOne,
                                                target: nil,
                                                action: nil)
    private let tileTraceButton = NSButton()
    private let tileTraceStatusLabel = NSTextField(labelWithString: "")
    private let baseLabelTraceButton = NSButton()
    private let baseLabelTraceStatusLabel = NSTextField(labelWithString: "")
    private let roadLabelTilesLabel = NSTextField(labelWithString: "")
    private let roadLabelTilesSwitch = NSSwitch()
    private let zoomLabel = NSTextField(wrappingLabelWithString: "")
    private let latLonLabel = NSTextField(wrappingLabelWithString: "")
    private let diagnosticsLabel = NSTextField(wrappingLabelWithString: "")
    private let tilesStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let tilesScrollView = NSScrollView()
    private let tilesStatusListView = DebugOverlayTilesStatusListView()
    private let atlasScrollView = NSScrollView()
    private let atlasDocumentView = DebugOverlayFlippedView()
    private let atlasLayoutView = DebugOverlayAtlasLayoutView()
    private let atlasDetailsLabel = NSTextField(wrappingLabelWithString: "")
    private var snapshot: DebugOverlayHUDSnapshot?
    private var isPanelEnabled = false
    private var isCollapsed = false
    private var selectedTab: SelectedTab = .stats
    /// Верхний safe-area inset host view; на macOS с обычным заголовком окна это 0.
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
    var onWireframeEnabledChanged: ((Bool) -> Void)?
    var onRoadLabelTilesEnabledChanged: ((Bool) -> Void)?
    var onEarthSceneEnabledChanged: ((Bool) -> Void)?
    var onSurfaceModeSwitchRequested: (() -> Void)?
    var onTileTraceRecordingToggle: (() -> Void)?
    var onBaseLabelTraceRecordingToggle: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true

        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.black.withAlphaComponent(Layout.backgroundAlpha).cgColor
        containerView.layer?.cornerRadius = Layout.cornerRadius
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

        configureControlLabel(axesLabel, text: "Axes")
        configureControlLabel(tileLayersLabel, text: "Tile layers")
        configureControlLabel(wireframeLabel, text: "Wireframe")
        configureControlLabel(earthSceneLabel, text: "Earth scene")
        configureControlLabel(roadLabelTilesLabel, text: "Road label tiles")
        configureSwitch(axesSwitch, action: #selector(axesSwitchChanged))
        configureSwitch(tileLayersSwitch, action: #selector(tileLayersSwitchChanged))
        configureSwitch(wireframeSwitch, action: #selector(wireframeSwitchChanged))
        configureSwitch(earthSceneSwitch, action: #selector(earthSceneSwitchChanged))
        configureSwitch(roadLabelTilesSwitch, action: #selector(roadLabelTilesSwitchChanged))
        containerView.addSubview(axesLabel)
        containerView.addSubview(axesSwitch)
        containerView.addSubview(tileLayersLabel)
        containerView.addSubview(tileLayersSwitch)
        containerView.addSubview(wireframeLabel)
        containerView.addSubview(wireframeSwitch)
        containerView.addSubview(earthSceneLabel)
        containerView.addSubview(earthSceneSwitch)
        containerView.addSubview(roadLabelTilesLabel)
        containerView.addSubview(roadLabelTilesSwitch)

        configureActionButton(surfaceModeButton,
                              title: "Switch globe / flat",
                              symbolName: "arrow.triangle.2.circlepath",
                              action: #selector(surfaceModeButtonTapped))
        containerView.addSubview(surfaceModeButton)

        tabControl.target = self
        tabControl.action = #selector(tabControlChanged)
        tabControl.selectedSegment = SelectedTab.stats.rawValue
        containerView.addSubview(tabControl)

        configureActionButton(tileTraceButton,
                              title: "",
                              symbolName: nil,
                              action: #selector(tileTraceButtonTapped))
        containerView.addSubview(tileTraceButton)
        configureStatusLabel(tileTraceStatusLabel)
        containerView.addSubview(tileTraceStatusLabel)

        configureActionButton(baseLabelTraceButton,
                              title: "",
                              symbolName: nil,
                              action: #selector(baseLabelTraceButtonTapped))
        containerView.addSubview(baseLabelTraceButton)
        configureStatusLabel(baseLabelTraceStatusLabel)
        containerView.addSubview(baseLabelTraceStatusLabel)

        [zoomLabel, latLonLabel, diagnosticsLabel, tilesStatusLabel].forEach { label in
            label.textColor = .white
            containerView.addSubview(label)
        }

        configureScrollView(tilesScrollView,
                            documentView: tilesStatusListView)
        containerView.addSubview(tilesScrollView)
        tilesStatusListView.onExpansionChanged = { [weak self] in
            self?.needsLayout = true
        }

        atlasDocumentView.addSubview(atlasLayoutView)
        atlasDocumentView.addSubview(atlasDetailsLabel)
        configureScrollView(atlasScrollView,
                            documentView: atlasDocumentView)
        containerView.addSubview(atlasScrollView)

        updateCollapseButtonImage()
        updateTileTraceControl()
        updateBaseLabelTraceControl()
        updateVisibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public API (совпадает с UIKit-версией)

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
               controls: DebugOverlayControlSnapshot,
               earthSceneEnabled: Bool) {
        isPanelEnabled = isDebugPanelEnabled
        axesSwitch.state = controls.axesEnabled ? .on : .off
        tileLayersSwitch.state = controls.tileLayersEnabled ? .on : .off
        wireframeSwitch.state = controls.wireframeEnabled ? .on : .off
        roadLabelTilesSwitch.state = controls.roadLabelTilesEnabled ? .on : .off
        earthSceneSwitch.state = earthSceneEnabled ? .on : .off
        updateVisibility()
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

    /// Клики вне панели уходят карте.
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
        guard let snapshot else { return }

        let scale = max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0, 1.0)
        let left = CGFloat(snapshot.leftPadding) / scale
        let top = CGFloat(snapshot.topPadding) / scale
        let sectionSpacing = CGFloat(snapshot.sectionSpacing) / scale
        let maxPanelWidth = min(Layout.maximumWidth, max(bounds.width - left - Layout.contentInset, Layout.collapsedWidth))

        if isCollapsed {
            containerView.frame = containerFrameClampedToSafeArea(
                CGRect(x: left - Layout.contentInset,
                       y: top - Layout.headerHeight - Layout.contentInset,
                       width: Layout.collapsedWidth,
                       height: Layout.headerHeight))
            layoutHeader(width: Layout.collapsedWidth)
            return
        }

        let maxContentWidth = max(maxPanelWidth - Layout.contentInset * 2, 1)
        let constrainedSize = CGSize(width: maxContentWidth,
                                     height: CGFloat.greatestFiniteMagnitude)

        let zoomSize = zoomLabel.sizeThatFits(constrainedSize)
        let latLonSize = latLonLabel.sizeThatFits(constrainedSize)
        let diagnosticsSize = diagnosticsLabel.sizeThatFits(constrainedSize)
        let tilesStatusSize = tilesStatusLabel.sizeThatFits(constrainedSize)
        let tilesListHeight = tilesStatusListView.preferredHeight(forWidth: maxContentWidth)
        let atlasDetailsSize = atlasDetailsLabel.sizeThatFits(constrainedSize)
        let atlasPreviewHeight = atlasLayoutView.preferredHeight(forWidth: maxContentWidth)
        let traceBlockHeight = selectedTab == .tiles || selectedTab == .baseLabels
            ? Layout.controlRowHeight + Layout.controlSpacing + Layout.traceStatusHeight + sectionSpacing
            : 0
        let contentWidth = max(Layout.expandedMinimumWidth, maxContentWidth)
        let controlsBodyHeight = Layout.controlRowHeight * 5 + Layout.controlSpacing * 4
        let statsBodyHeight = zoomSize.height
            + latLonSize.height
            + sectionSpacing
            + diagnosticsSize.height
        let atlasBodyHeight = atlasPreviewHeight
            + sectionSpacing
            + atlasDetailsSize.height
        let tilesBodyHeight = tilesStatusSize.height
            + traceBlockHeight
            + (tilesListHeight > 0 ? sectionSpacing + tilesListHeight : 0)
        let baseLabelsBodyHeight = Layout.controlRowHeight
            + Layout.controlSpacing
            + traceBlockHeight
        let panelY = top - zoomSize.height - Layout.contentInset
        let chromeHeight = Layout.headerHeight
            + Layout.contentInset
            + Layout.controlRowHeight
            + sectionSpacing
            + Layout.contentInset
        let visibleAtlasBodyHeight = DebugOverlayPanelLayout.visibleBodyHeight(
            preferredBodyHeight: atlasBodyHeight,
            viewportHeight: bounds.height,
            panelMinY: panelY,
            chromeHeight: chromeHeight,
            minimumBodyHeight: 48 + traceBlockHeight
        )
        let tilesListSpacing = tilesListHeight > 0 ? sectionSpacing : 0
        let visibleTilesBodyHeight = DebugOverlayPanelLayout.visibleBodyHeight(
            preferredBodyHeight: tilesBodyHeight,
            viewportHeight: bounds.height,
            panelMinY: panelY,
            chromeHeight: chromeHeight,
            minimumBodyHeight: tilesStatusSize.height + tilesListSpacing + 48
        )
        let bodyHeight: CGFloat
        switch selectedTab {
        case .stats:
            bodyHeight = statsBodyHeight
        case .atlas:
            bodyHeight = visibleAtlasBodyHeight
        case .tiles:
            bodyHeight = visibleTilesBodyHeight
        case .baseLabels:
            bodyHeight = baseLabelsBodyHeight
        case .controls:
            bodyHeight = controlsBodyHeight
        }
        let contentHeight = Layout.headerHeight
            + Layout.contentInset
            + Layout.controlRowHeight
            + sectionSpacing
            + bodyHeight
            + Layout.contentInset
        let containerSize = CGSize(width: contentWidth + Layout.contentInset * 2,
                                   height: contentHeight)

        containerView.frame = containerFrameClampedToSafeArea(
            CGRect(x: left - Layout.contentInset,
                   y: panelY,
                   width: containerSize.width,
                   height: containerSize.height))
        layoutHeader(width: containerSize.width)

        let switchSize = axesSwitch.intrinsicContentSize
        let labelWidth = contentWidth - switchSize.width - Layout.controlSpacing
        let tabTop = Layout.headerHeight + Layout.contentInset
        tabControl.frame = CGRect(x: Layout.contentInset,
                                  y: tabTop,
                                  width: contentWidth,
                                  height: Layout.controlRowHeight)

        let bodyTop = tabControl.frame.maxY + sectionSpacing
        let controlsTop = bodyTop
        axesLabel.frame = CGRect(x: Layout.contentInset,
                                 y: controlsTop,
                                 width: labelWidth,
                                 height: Layout.controlRowHeight)
        axesSwitch.frame = CGRect(x: containerSize.width - Layout.contentInset - switchSize.width,
                                  y: controlsTop + (Layout.controlRowHeight - switchSize.height) / 2,
                                  width: switchSize.width,
                                  height: switchSize.height)
        tileLayersLabel.frame = CGRect(x: Layout.contentInset,
                                       y: axesLabel.frame.maxY + Layout.controlSpacing,
                                       width: labelWidth,
                                       height: Layout.controlRowHeight)
        tileLayersSwitch.frame = CGRect(x: containerSize.width - Layout.contentInset - switchSize.width,
                                        y: tileLayersLabel.frame.minY + (Layout.controlRowHeight - switchSize.height) / 2,
                                        width: switchSize.width,
                                        height: switchSize.height)
        wireframeLabel.frame = CGRect(x: Layout.contentInset,
                                      y: tileLayersLabel.frame.maxY + Layout.controlSpacing,
                                      width: labelWidth,
                                      height: Layout.controlRowHeight)
        wireframeSwitch.frame = CGRect(x: containerSize.width - Layout.contentInset - switchSize.width,
                                       y: wireframeLabel.frame.minY + (Layout.controlRowHeight - switchSize.height) / 2,
                                       width: switchSize.width,
                                       height: switchSize.height)
        earthSceneLabel.frame = CGRect(x: Layout.contentInset,
                                       y: wireframeLabel.frame.maxY + Layout.controlSpacing,
                                       width: labelWidth,
                                       height: Layout.controlRowHeight)
        earthSceneSwitch.frame = CGRect(x: containerSize.width - Layout.contentInset - switchSize.width,
                                        y: earthSceneLabel.frame.minY + (Layout.controlRowHeight - switchSize.height) / 2,
                                        width: switchSize.width,
                                        height: switchSize.height)
        surfaceModeButton.frame = CGRect(x: Layout.contentInset,
                                         y: earthSceneLabel.frame.maxY + Layout.controlSpacing,
                                         width: contentWidth,
                                         height: Layout.controlRowHeight)

        let textTop = bodyTop
        zoomLabel.frame = CGRect(x: Layout.contentInset,
                                 y: textTop,
                                 width: contentWidth,
                                 height: zoomSize.height)
        latLonLabel.frame = CGRect(x: Layout.contentInset,
                                   y: zoomLabel.frame.maxY,
                                   width: contentWidth,
                                   height: latLonSize.height)
        diagnosticsLabel.frame = CGRect(x: Layout.contentInset,
                                        y: latLonLabel.frame.maxY + sectionSpacing,
                                        width: contentWidth,
                                        height: diagnosticsSize.height)
        tileTraceButton.frame = CGRect(x: Layout.contentInset,
                                       y: textTop,
                                       width: contentWidth,
                                       height: Layout.controlRowHeight)
        tileTraceStatusLabel.frame = CGRect(x: Layout.contentInset,
                                            y: tileTraceButton.frame.maxY + Layout.controlSpacing,
                                            width: contentWidth,
                                            height: Layout.traceStatusHeight)
        roadLabelTilesLabel.frame = CGRect(x: Layout.contentInset,
                                           y: textTop,
                                           width: labelWidth,
                                           height: Layout.controlRowHeight)
        roadLabelTilesSwitch.frame = CGRect(x: containerSize.width - Layout.contentInset - switchSize.width,
                                            y: roadLabelTilesLabel.frame.minY + (Layout.controlRowHeight - switchSize.height) / 2,
                                            width: switchSize.width,
                                            height: switchSize.height)
        baseLabelTraceButton.frame = CGRect(x: Layout.contentInset,
                                            y: roadLabelTilesLabel.frame.maxY + Layout.controlSpacing,
                                            width: contentWidth,
                                            height: Layout.controlRowHeight)
        baseLabelTraceStatusLabel.frame = CGRect(x: Layout.contentInset,
                                                 y: baseLabelTraceButton.frame.maxY + Layout.controlSpacing,
                                                 width: contentWidth,
                                                 height: Layout.traceStatusHeight)
        let tilesStatusTop = selectedTab == .tiles
            ? tileTraceStatusLabel.frame.maxY + sectionSpacing
            : textTop
        tilesStatusLabel.frame = CGRect(x: Layout.contentInset,
                                        y: tilesStatusTop,
                                        width: contentWidth,
                                        height: tilesStatusSize.height)
        let tilesScrollTop = tilesStatusLabel.frame.maxY + tilesListSpacing
        let tilesScrollHeight = max(0, visibleTilesBodyHeight - traceBlockHeight - tilesStatusSize.height - tilesListSpacing)
        tilesScrollView.frame = CGRect(x: Layout.contentInset,
                                       y: tilesScrollTop,
                                       width: contentWidth,
                                       height: tilesScrollHeight)
        tilesStatusListView.frame = CGRect(x: 0,
                                           y: 0,
                                           width: contentWidth,
                                           height: tilesListHeight)
        let atlasScrollTop = textTop
        let atlasScrollHeight = max(0, visibleAtlasBodyHeight)
        atlasScrollView.frame = CGRect(x: Layout.contentInset,
                                       y: atlasScrollTop,
                                       width: contentWidth,
                                       height: atlasScrollHeight)
        atlasLayoutView.frame = CGRect(x: 0,
                                       y: 0,
                                       width: contentWidth,
                                       height: atlasPreviewHeight)
        atlasDetailsLabel.frame = CGRect(x: 0,
                                         y: atlasLayoutView.frame.maxY + sectionSpacing,
                                         width: contentWidth,
                                         height: atlasDetailsSize.height)
        atlasDocumentView.frame = CGRect(x: 0,
                                         y: 0,
                                         width: contentWidth,
                                         height: atlasPreviewHeight + sectionSpacing + atlasDetailsSize.height)
        updateContentVisibility()
    }

    /// Прижимает верх панели к safe area. Внутренние элементы позиционируются
    /// относительно контейнера, поэтому сдвиг origin переносит их целиком.
    private func containerFrameClampedToSafeArea(_ frame: CGRect) -> CGRect {
        var clamped = frame
        let minimumY = safeAreaTopInset + Layout.contentInset
        if clamped.origin.y < minimumY {
            clamped.origin.y = minimumY
        }
        return clamped
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
        updateContentVisibility()
    }

    // MARK: - Content

    private func updateText() {
        guard let snapshot else {
            zoomLabel.attributedStringValue = NSAttributedString(string: "")
            latLonLabel.attributedStringValue = NSAttributedString(string: "")
            diagnosticsLabel.attributedStringValue = NSAttributedString(string: "")
            tilesStatusLabel.attributedStringValue = NSAttributedString(string: "")
            tilesStatusListView.apply(tiles: [])
            atlasDetailsLabel.attributedStringValue = NSAttributedString(string: "")
            atlasLayoutView.apply(pages: [])
            return
        }

        let scale = max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0, 1.0)
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
        tilesStatusLabel.attributedStringValue = attributedText(DebugOverlayHUDTextComposer.tilesStatusText(lines: snapshot.tileLoadingStatusLines),
                                                                fontSize: diagnosticsFontSize,
                                                                color: color)
        tilesStatusListView.apply(tiles: snapshot.tileLoadingStatusTiles)
        atlasLayoutView.apply(pages: snapshot.atlasPages)
        atlasDetailsLabel.attributedStringValue = attributedText(DebugOverlayHUDTextComposer.atlasDetailsText(pages: snapshot.atlasPages),
                                                                 fontSize: diagnosticsFontSize,
                                                                 color: color)
    }

    private func updateVisibility() {
        isHidden = isPanelEnabled == false || snapshot == nil
    }

    // MARK: - Configuration

    private func configureControlLabel(_ label: NSTextField, text: String) {
        label.stringValue = text
        label.textColor = .white
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
    }

    private func configureStatusLabel(_ label: NSTextField) {
        label.textColor = .white
        label.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
    }

    private func configureSwitch(_ switchControl: NSSwitch, action: Selector) {
        switchControl.target = self
        switchControl.action = action
        switchControl.controlSize = .small
    }

    private func configureBorderlessButton(_ button: NSButton) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.title = ""
    }

    private func configureActionButton(_ button: NSButton,
                                       title: String,
                                       symbolName: String?,
                                       action: Selector) {
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
        scrollView.verticalScrollElasticity = .none
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

    private func updateContentVisibility() {
        let isContentHidden = isCollapsed
        let isAtlasVisible = selectedTab == .atlas && isContentHidden == false
        let isStatsVisible = selectedTab == .stats && isContentHidden == false
        let isTilesVisible = selectedTab == .tiles && isContentHidden == false
        let isBaseLabelsVisible = selectedTab == .baseLabels && isContentHidden == false
        let isControlsVisible = selectedTab == .controls && isContentHidden == false
        tabControl.isHidden = isContentHidden
        [axesLabel, axesSwitch, tileLayersLabel, tileLayersSwitch, wireframeLabel, wireframeSwitch,
         earthSceneLabel, earthSceneSwitch, surfaceModeButton].forEach {
            $0.isHidden = isControlsVisible == false
        }
        [zoomLabel, latLonLabel, diagnosticsLabel].forEach {
            $0.isHidden = isStatsVisible == false
        }
        tilesStatusLabel.isHidden = isTilesVisible == false
        tilesScrollView.isHidden = isTilesVisible == false || tilesStatusListView.rowCount == 0
        tileTraceButton.isHidden = isTilesVisible == false
        tileTraceStatusLabel.isHidden = isTilesVisible == false
        baseLabelTraceButton.isHidden = isBaseLabelsVisible == false
        baseLabelTraceStatusLabel.isHidden = isBaseLabelsVisible == false
        roadLabelTilesLabel.isHidden = isBaseLabelsVisible == false
        roadLabelTilesSwitch.isHidden = isBaseLabelsVisible == false
        atlasScrollView.isHidden = isAtlasVisible == false
    }

    // MARK: - Actions

    @objc private func toggleCollapsed() {
        isCollapsed.toggle()
        updateCollapseButtonImage()
        needsLayout = true
    }

    @objc private func axesSwitchChanged() {
        onAxesEnabledChanged?(axesSwitch.state == .on)
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

    @objc private func earthSceneSwitchChanged() {
        onEarthSceneEnabledChanged?(earthSceneSwitch.state == .on)
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

    @objc private func tabControlChanged() {
        selectedTab = SelectedTab(rawValue: tabControl.selectedSegment) ?? .stats
        updateContentVisibility()
        needsLayout = true
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

/// Пустой flipped-контейнер: subview-раскладка сверху вниз, как в UIKit.
private final class DebugOverlayFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class DebugOverlayAtlasLayoutView: NSView {
    private enum Layout {
        static let pageLabelHeight: CGFloat = 16
        static let pageSpacing: CGFloat = 10
        static let minimumPageSide: CGFloat = 180
        static let maximumPageSide: CGFloat = 260
        static let borderWidth: CGFloat = 1
    }

    private var pages: [TileAtlasDebugPage] = []

    override var isFlipped: Bool { true }

    var pageCount: Int {
        pages.count
    }

    func apply(pages: [TileAtlasDebugPage]) {
        self.pages = pages
        needsDisplay = true
    }

    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        guard pages.isEmpty == false else {
            return 48
        }

        return atlasGridLayout(forWidth: width).height
    }

    override func draw(_ rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard pages.isEmpty == false else {
            drawEmptyState(in: rect)
            return
        }

        let gridLayout = atlasGridLayout(forWidth: bounds.width)
        for (index, page) in pages.enumerated() {
            let frame = gridLayout.pageFrames[index]
            drawPageLabel(page: page, in: frame.labelRect)
            drawPage(page, in: frame.pageRect, context: context)
        }
    }

    private func atlasGridLayout(forWidth width: CGFloat) -> DebugOverlayAtlasGridLayout {
        DebugOverlayPanelLayout.atlasGridLayout(pageCount: pages.count,
                                                width: width,
                                                pageLabelHeight: Layout.pageLabelHeight,
                                                pageSpacing: Layout.pageSpacing,
                                                minimumPageSide: Layout.minimumPageSide,
                                                maximumPageSide: Layout.maximumPageSide)
    }

    private func drawEmptyState(in rect: CGRect) {
        let text = "No globe atlas pages"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.72)
        ]
        text.draw(in: rect.insetBy(dx: 2, dy: 14), withAttributes: attributes)
    }

    private func drawPageLabel(page: TileAtlasDebugPage, in rect: CGRect) {
        let text = "page \(page.pageIndex) slots \(page.allocations.count)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        text.draw(in: rect, withAttributes: attributes)
    }

    private func drawPage(_ page: TileAtlasDebugPage,
                          in pageRect: CGRect,
                          context: CGContext) {
        context.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
        context.fill(pageRect)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
        context.setLineWidth(Layout.borderWidth)
        context.stroke(pageRect)

        for allocation in page.allocations {
            drawAllocation(allocation, pageRect: pageRect, context: context)
        }
    }

    private func drawAllocation(_ allocation: TileAtlasDebugAllocation,
                                pageRect: CGRect,
                                context: CGContext) {
        let slots = CGFloat(max(allocation.slotsPerSide, 1))
        let cell = pageRect.width / slots
        let displayRow = CGFloat(max(0, allocation.slotsPerSide - 1 - allocation.slotRow))
        let allocationRect = CGRect(x: pageRect.minX + CGFloat(allocation.slotColumn) * cell,
                                    y: pageRect.minY + displayRow * cell,
                                    width: cell,
                                    height: cell)
        let color = color(for: allocation)
        context.setFillColor(color.withAlphaComponent(0.26).cgColor)
        context.fill(allocationRect)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(allocation.isFallback ? 2 : 1)
        context.stroke(allocationRect.insetBy(dx: 0.5, dy: 0.5))
        drawAllocationLabel(allocation, in: allocationRect)
    }

    private func drawAllocationLabel(_ allocation: TileAtlasDebugAllocation,
                                     in allocationRect: CGRect) {
        let inset = min(max(allocationRect.width * 0.08, 2), 5)
        let labelRect = allocationRect.insetBy(dx: inset, dy: inset)
        guard labelRect.width >= 10, labelRect.height >= 8 else { return }

        let fontSize = min(10, max(6, labelRect.height * 0.28))
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.82)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = CGSize(width: 0, height: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
            .shadow: shadow
        ]
        allocation.atlasPreviewLabel.draw(in: labelRect, withAttributes: attributes)
    }

    private func color(for allocation: TileAtlasDebugAllocation) -> NSColor {
        if allocation.isFallback {
            return NSColor.systemOrange
        }

        switch allocation.atlasDepth {
        case .depth0:
            return NSColor.systemRed
        case .depth1:
            return NSColor.systemYellow
        case .depth2:
            return NSColor.systemGreen
        case .depth3:
            return NSColor.systemTeal
        case .depth4:
            return NSColor.systemBlue
        }
    }
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
