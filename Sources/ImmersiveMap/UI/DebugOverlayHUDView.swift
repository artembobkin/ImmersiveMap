// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import UIKit

final class DebugOverlayHUDView: UIView {
    private enum SelectedTab: Int {
        case stats = 0
        case tiles = 1
        case baseLabels = 2
        case controls = 3
        case relief = 4
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

    private let containerView = UIView()
    private let titleLabel = UILabel()
    private let collapseButton = UIButton(type: .system)
    private let axesLabel = UILabel()
    private let axesSwitch = UISwitch()
    private let tileLayersLabel = UILabel()
    private let tileLayersSwitch = UISwitch()
    private let tileGridLabel = UILabel()
    private let tileGridSwitch = UISwitch()
    private let tileGridDensityControl = UISegmentedControl(items: DebugOverlayHUDTextComposer.tileGridDensityTitles)
    private let wireframeLabel = UILabel()
    private let wireframeSwitch = UISwitch()
    private let surfaceModeButton = UIButton(type: .system)
    private let tabControl = UISegmentedControl(items: ["Stats", "Tiles", "Base labels", "Controls", "Relief"])
    private let tileTraceButton = UIButton(type: .system)
    private let tileTraceStatusLabel = UILabel()
    private let baseLabelTraceButton = UIButton(type: .system)
    private let baseLabelTraceStatusLabel = UILabel()
    private let roadLabelTilesLabel = UILabel()
    private let roadLabelTilesSwitch = UISwitch()
    private let baseLabelBoundsLabel = UILabel()
    private let baseLabelBoundsSwitch = UISwitch()
    private let roadLabelBoundsLabel = UILabel()
    private let roadLabelBoundsSwitch = UISwitch()
    private let zoomLabel = UILabel()
    private let latLonLabel = UILabel()
    private let diagnosticsLabel = UILabel()
    private let tilesStatusLabel = UILabel()
    private let tilesScrollView = UIScrollView()
    private let tilesStatusListView = DebugOverlayTilesStatusListView()
    private let tileCoverageView = DebugOverlayTileCoverageView()
    /// The relief tab: the terrain store's summary, its tiles from above
    /// and as cards, as the tiles' tab shows the map tiles.
    private let reliefStatusLabel = UILabel()
    private let reliefCoverageView = DebugOverlayReliefCoverageView()
    private let reliefScrollView = UIScrollView()
    private let reliefListView = DebugOverlayTilesStatusListView()
    private var snapshot: DebugOverlayHUDSnapshot?
    private var isPanelEnabled = false
    private var isCollapsed = false
    private var selectedTab: SelectedTab = .stats
    private var tileTraceSnapshot = TileTraceRecorderSnapshot(isRecording: false, fileURL: nil)
    private var baseLabelTraceSnapshot = BaseLabelTraceRecorderSnapshot(isRecording: false, fileURL: nil)
    /// The host view's top safe-area inset: the panel stays clear of the status
    /// bar/notch, otherwise the collapse chevron lands in an untappable zone.
    var safeAreaTopInset: CGFloat = 0 {
        didSet {
            guard safeAreaTopInset != oldValue else { return }
            setNeedsLayout()
        }
    }
    #if DEBUG
    private var textUpdateCountForTestingStorage = 0
    #endif

    var onAxesEnabledChanged: ((Bool) -> Void)?
    /// The content the selected tab shows, for the frame to build only
    /// that (`DebugOverlayHUDContentRequest`).
    var onShownContentChanged: ((DebugOverlayHUDContentRequest) -> Void)?

    var shownContent: DebugOverlayHUDContentRequest {
        switch selectedTab {
        case .stats: .stats
        case .tiles: .tiles
        case .relief: .relief
        case .baseLabels, .controls: []
        }
    }
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isOpaque = false
        isUserInteractionEnabled = true

        containerView.isOpaque = false
        containerView.isUserInteractionEnabled = true
        containerView.backgroundColor = UIColor.black.withAlphaComponent(Layout.backgroundAlpha)
        containerView.layer.cornerRadius = Layout.cornerRadius
        containerView.layer.masksToBounds = true
        addSubview(containerView)

        titleLabel.text = "Debug"
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        containerView.addSubview(titleLabel)

        collapseButton.tintColor = .white
        collapseButton.addTarget(self, action: #selector(toggleCollapsed), for: .touchUpInside)
        containerView.addSubview(collapseButton)

        configureControlLabel(axesLabel, text: "Axes")
        configureControlLabel(tileLayersLabel, text: "Tile layers")
        configureControlLabel(tileGridLabel, text: "Tile grid")
        configureControlLabel(wireframeLabel, text: "Wireframe")
        configureControlLabel(roadLabelTilesLabel, text: "Road label tiles")
        configureControlLabel(baseLabelBoundsLabel, text: "Base label boxes")
        configureControlLabel(roadLabelBoundsLabel, text: "Road label boxes")
        axesSwitch.addTarget(self, action: #selector(axesSwitchChanged), for: .valueChanged)
        tileLayersSwitch.addTarget(self, action: #selector(tileLayersSwitchChanged), for: .valueChanged)
        tileGridSwitch.addTarget(self, action: #selector(tileGridSwitchChanged), for: .valueChanged)
        tileGridDensityControl.addTarget(self, action: #selector(tileGridDensityControlChanged), for: .valueChanged)
        tileGridDensityControl.selectedSegmentIndex = DebugOverlayHUDTextComposer.tileGridDensityIndex(for: DebugTileGridDensity.standard)
        wireframeSwitch.addTarget(self, action: #selector(wireframeSwitchChanged), for: .valueChanged)
        roadLabelTilesSwitch.addTarget(self, action: #selector(roadLabelTilesSwitchChanged), for: .valueChanged)
        baseLabelBoundsSwitch.addTarget(self, action: #selector(baseLabelBoundsSwitchChanged), for: .valueChanged)
        roadLabelBoundsSwitch.addTarget(self, action: #selector(roadLabelBoundsSwitchChanged), for: .valueChanged)
        containerView.addSubview(axesLabel)
        containerView.addSubview(axesSwitch)
        containerView.addSubview(tileLayersLabel)
        containerView.addSubview(tileLayersSwitch)
        containerView.addSubview(tileGridLabel)
        containerView.addSubview(tileGridSwitch)
        containerView.addSubview(tileGridDensityControl)
        containerView.addSubview(wireframeLabel)
        containerView.addSubview(wireframeSwitch)
        containerView.addSubview(roadLabelTilesLabel)
        containerView.addSubview(roadLabelTilesSwitch)
        containerView.addSubview(baseLabelBoundsLabel)
        containerView.addSubview(baseLabelBoundsSwitch)
        containerView.addSubview(roadLabelBoundsLabel)
        containerView.addSubview(roadLabelBoundsSwitch)
        configureSurfaceModeButton()
        containerView.addSubview(surfaceModeButton)
        tabControl.selectedSegmentIndex = SelectedTab.stats.rawValue
        tabControl.addTarget(self, action: #selector(tabControlChanged), for: .valueChanged)
        containerView.addSubview(tabControl)
        configureTileTraceButton()
        containerView.addSubview(tileTraceButton)
        tileTraceStatusLabel.textColor = .white
        tileTraceStatusLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        tileTraceStatusLabel.lineBreakMode = .byTruncatingMiddle
        containerView.addSubview(tileTraceStatusLabel)

        configureBaseLabelTraceButton()
        containerView.addSubview(baseLabelTraceButton)
        baseLabelTraceStatusLabel.textColor = .white
        baseLabelTraceStatusLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        baseLabelTraceStatusLabel.lineBreakMode = .byTruncatingMiddle
        containerView.addSubview(baseLabelTraceStatusLabel)

        [zoomLabel, latLonLabel, diagnosticsLabel, tilesStatusLabel, reliefStatusLabel].forEach { label in
            label.numberOfLines = 0
            label.lineBreakMode = .byCharWrapping
            label.adjustsFontSizeToFitWidth = false
            containerView.addSubview(label)
        }
        containerView.addSubview(tileCoverageView)
        tilesScrollView.backgroundColor = .clear
        tilesScrollView.alwaysBounceVertical = false
        tilesScrollView.delaysContentTouches = false
        tilesScrollView.showsHorizontalScrollIndicator = false
        tilesScrollView.showsVerticalScrollIndicator = true
        containerView.addSubview(tilesScrollView)
        tilesScrollView.addSubview(tilesStatusListView)
        containerView.addSubview(reliefCoverageView)
        reliefScrollView.backgroundColor = .clear
        reliefScrollView.alwaysBounceVertical = false
        reliefScrollView.delaysContentTouches = false
        reliefScrollView.showsHorizontalScrollIndicator = false
        reliefScrollView.showsVerticalScrollIndicator = true
        containerView.addSubview(reliefScrollView)
        reliefScrollView.addSubview(reliefListView)
        updateCollapseButtonImage()
        updateTileTraceControl()
        updateBaseLabelTraceControl()
        updateVisibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(snapshot: DebugOverlayHUDSnapshot?) {
        guard self.snapshot != snapshot else {
            return
        }

        self.snapshot = snapshot
        updateText()
        updateVisibility()
        setNeedsLayout()
    }

    func apply(isDebugPanelEnabled: Bool,
               controls: DebugOverlayControlSnapshot) {
        isPanelEnabled = isDebugPanelEnabled
        axesSwitch.setOn(controls.axesEnabled, animated: false)
        tileLayersSwitch.setOn(controls.tileLayersEnabled, animated: false)
        tileGridSwitch.setOn(controls.tileGridEnabled, animated: false)
        tileGridDensityControl.selectedSegmentIndex = DebugOverlayHUDTextComposer.tileGridDensityIndex(for: controls.tileGridDensity)
        wireframeSwitch.setOn(controls.wireframeEnabled, animated: false)
        roadLabelTilesSwitch.setOn(controls.roadLabelTilesEnabled, animated: false)
        baseLabelBoundsSwitch.setOn(controls.baseLabelBoundsEnabled, animated: false)
        roadLabelBoundsSwitch.setOn(controls.roadLabelBoundsEnabled, animated: false)
        updateVisibility()
        setNeedsLayout()
    }

    func apply(tileTraceSnapshot: TileTraceRecorderSnapshot) {
        self.tileTraceSnapshot = tileTraceSnapshot
        updateTileTraceControl()
        setNeedsLayout()
    }

    func apply(baseLabelTraceSnapshot: BaseLabelTraceRecorderSnapshot) {
        self.baseLabelTraceSnapshot = baseLabelTraceSnapshot
        updateBaseLabelTraceControl()
        setNeedsLayout()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isHidden == false else { return false }
        return containerView.frame.contains(point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let snapshot else { return }

        let scale = max(window?.screen.scale ?? UIScreen.main.scale, 1.0)
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
        let reliefStatusSize = reliefStatusLabel.sizeThatFits(constrainedSize)
        let reliefListHeight = reliefListView.preferredHeight(forWidth: maxContentWidth)
        let traceBlockHeight = selectedTab == .tiles || selectedTab == .baseLabels
            ? Layout.controlRowHeight + Layout.controlSpacing + Layout.traceStatusHeight + sectionSpacing
            : 0
        let contentWidth = max(Layout.expandedMinimumWidth, maxContentWidth)
        let controlsBodyHeight = Layout.controlRowHeight * 7 + Layout.controlSpacing * 6
        let statsBodyHeight = zoomSize.height
            + latLonSize.height
            + sectionSpacing
            + diagnosticsSize.height
        let coverageSide = min(DebugOverlayTileCoverageLayout.side, contentWidth)
        let tilesBodyHeight = tilesStatusSize.height
            + traceBlockHeight
            + sectionSpacing + coverageSide
            + (tilesListHeight > 0 ? sectionSpacing + tilesListHeight : 0)
        let baseLabelsBodyHeight = Layout.controlRowHeight * 3
            + Layout.controlSpacing * 3
            + traceBlockHeight
        let panelY = top - zoomSize.height - Layout.contentInset
        let chromeHeight = Layout.headerHeight
            + Layout.contentInset
            + Layout.controlRowHeight
            + sectionSpacing
            + Layout.contentInset
        let tilesListSpacing = tilesListHeight > 0 ? sectionSpacing : 0
        let visibleTilesBodyHeight = DebugOverlayPanelLayout.visibleBodyHeight(
            preferredBodyHeight: tilesBodyHeight,
            viewportHeight: bounds.height,
            panelMinY: panelY,
            chromeHeight: chromeHeight,
            minimumBodyHeight: tilesStatusSize.height + tilesListSpacing + 48
        )
        let reliefListSpacing = reliefListHeight > 0 ? sectionSpacing : 0
        let visibleReliefBodyHeight = DebugOverlayPanelLayout.visibleBodyHeight(
            preferredBodyHeight: reliefStatusSize.height + sectionSpacing + coverageSide + reliefListSpacing + reliefListHeight,
            viewportHeight: bounds.height,
            panelMinY: panelY,
            chromeHeight: chromeHeight,
            minimumBodyHeight: reliefStatusSize.height + reliefListSpacing + 48
        )
        let bodyHeight: CGFloat
        switch selectedTab {
        case .stats:
            bodyHeight = statsBodyHeight
        case .tiles:
            bodyHeight = visibleTilesBodyHeight
        case .relief:
            bodyHeight = visibleReliefBodyHeight
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

        let switchSize = axesSwitch.sizeThatFits(.zero)
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
        tileGridLabel.frame = CGRect(x: Layout.contentInset,
                                     y: tileLayersLabel.frame.maxY + Layout.controlSpacing,
                                     width: labelWidth,
                                     height: Layout.controlRowHeight)
        tileGridSwitch.frame = CGRect(x: containerSize.width - Layout.contentInset - switchSize.width,
                                      y: tileGridLabel.frame.minY + (Layout.controlRowHeight - switchSize.height) / 2,
                                      width: switchSize.width,
                                      height: switchSize.height)
        tileGridDensityControl.frame = CGRect(x: Layout.contentInset,
                                              y: tileGridLabel.frame.maxY + Layout.controlSpacing,
                                              width: contentWidth,
                                              height: Layout.controlRowHeight)
        wireframeLabel.frame = CGRect(x: Layout.contentInset,
                                      y: tileGridDensityControl.frame.maxY + Layout.controlSpacing,
                                      width: labelWidth,
                                      height: Layout.controlRowHeight)
        wireframeSwitch.frame = CGRect(x: containerSize.width - Layout.contentInset - switchSize.width,
                                       y: wireframeLabel.frame.minY + (Layout.controlRowHeight - switchSize.height) / 2,
                                       width: switchSize.width,
                                       height: switchSize.height)
        surfaceModeButton.frame = CGRect(x: Layout.contentInset,
                                         y: wireframeLabel.frame.maxY + Layout.controlSpacing,
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
        tilesStatusLabel.frame = CGRect(x: Layout.contentInset,
                                        y: textTop,
                                        width: contentWidth,
                                        height: tilesStatusSize.height)
        tileCoverageView.frame = CGRect(x: Layout.contentInset,
                                        y: tilesStatusLabel.frame.maxY + sectionSpacing,
                                        width: coverageSide,
                                        height: coverageSide)
        let tilesScrollTop = tileCoverageView.frame.maxY + tilesListSpacing
        let tilesScrollHeight = max(0, visibleTilesBodyHeight - tilesStatusSize.height - sectionSpacing - coverageSide - tilesListSpacing)
        tilesScrollView.frame = CGRect(x: Layout.contentInset,
                                       y: tilesScrollTop,
                                       width: contentWidth,
                                       height: tilesScrollHeight)
        tilesStatusListView.frame = CGRect(x: 0,
                                           y: 0,
                                           width: contentWidth,
                                           height: tilesListHeight)
        tilesScrollView.contentSize = CGSize(width: contentWidth,
                                             height: tilesListHeight)
        tilesScrollView.isScrollEnabled = tilesScrollView.contentSize.height > tilesScrollHeight + 0.5
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
        baseLabelBoundsLabel.frame = CGRect(x: Layout.contentInset,
                                            y: roadLabelTilesLabel.frame.maxY + Layout.controlSpacing,
                                            width: labelWidth,
                                            height: Layout.controlRowHeight)
        baseLabelBoundsSwitch.frame = CGRect(x: containerSize.width - Layout.contentInset - switchSize.width,
                                             y: baseLabelBoundsLabel.frame.minY + (Layout.controlRowHeight - switchSize.height) / 2,
                                             width: switchSize.width,
                                             height: switchSize.height)
        roadLabelBoundsLabel.frame = CGRect(x: Layout.contentInset,
                                            y: baseLabelBoundsLabel.frame.maxY + Layout.controlSpacing,
                                            width: labelWidth,
                                            height: Layout.controlRowHeight)
        roadLabelBoundsSwitch.frame = CGRect(x: containerSize.width - Layout.contentInset - switchSize.width,
                                             y: roadLabelBoundsLabel.frame.minY + (Layout.controlRowHeight - switchSize.height) / 2,
                                             width: switchSize.width,
                                             height: switchSize.height)
        baseLabelTraceButton.frame = CGRect(x: Layout.contentInset,
                                            y: roadLabelBoundsLabel.frame.maxY + Layout.controlSpacing,
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
        tileCoverageView.frame = CGRect(x: Layout.contentInset,
                                        y: tilesStatusLabel.frame.maxY + sectionSpacing,
                                        width: coverageSide,
                                        height: coverageSide)
        let updatedTilesScrollTop = tileCoverageView.frame.maxY + tilesListSpacing
        let updatedTilesScrollHeight = max(0, visibleTilesBodyHeight - traceBlockHeight - tilesStatusSize.height
                                               - sectionSpacing - coverageSide - tilesListSpacing)
        tilesScrollView.frame = CGRect(x: Layout.contentInset,
                                       y: updatedTilesScrollTop,
                                       width: contentWidth,
                                       height: updatedTilesScrollHeight)
        tilesScrollView.isScrollEnabled = tilesScrollView.contentSize.height > updatedTilesScrollHeight + 0.5

        reliefStatusLabel.frame = CGRect(x: Layout.contentInset,
                                         y: textTop,
                                         width: contentWidth,
                                         height: reliefStatusSize.height)
        reliefCoverageView.frame = CGRect(x: Layout.contentInset,
                                          y: reliefStatusLabel.frame.maxY + sectionSpacing,
                                          width: coverageSide,
                                          height: coverageSide)
        let reliefScrollHeight = max(0, visibleReliefBodyHeight - reliefStatusSize.height - sectionSpacing
                                         - coverageSide - reliefListSpacing)
        reliefScrollView.frame = CGRect(x: Layout.contentInset,
                                        y: reliefCoverageView.frame.maxY + reliefListSpacing,
                                        width: contentWidth,
                                        height: reliefScrollHeight)
        reliefListView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: reliefListHeight)
        reliefScrollView.contentSize = CGSize(width: contentWidth, height: reliefListHeight)
        reliefScrollView.isScrollEnabled = reliefListHeight > reliefScrollHeight + 0.5
        updateContentVisibility()
    }

    /// Keeps the panel from sliding under the status bar/notch: the container's
    /// top is pinned to the safe area. Inner elements are positioned relative to
    /// the container, so shifting the origin moves them as a whole.
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
                                  y: 0,
                                  width: width - Layout.contentInset * 2 - buttonSide,
                                  height: Layout.headerHeight)
        collapseButton.frame = CGRect(x: width - Layout.contentInset - buttonSide,
                                      y: 0,
                                      width: buttonSide,
                                      height: buttonSide)
        updateContentVisibility()
    }

    private func updateText() {
        #if DEBUG
        textUpdateCountForTestingStorage += 1
        #endif

        guard let snapshot else {
            zoomLabel.attributedText = nil
            latLonLabel.attributedText = nil
            diagnosticsLabel.attributedText = nil
            tilesStatusLabel.attributedText = nil
            tileCoverageView.apply(coverage: nil)
            tilesStatusListView.apply(tiles: [])
            reliefStatusLabel.attributedText = nil
            reliefCoverageView.apply(coverage: nil)
            reliefListView.apply(cards: [])
            return
        }

        let scale = max(window?.screen.scale ?? UIScreen.main.scale, 1.0)
        let coordinateFontSize = max(1, CGFloat(snapshot.coordinateScale) * Layout.coordinateFontScale / scale)
        let diagnosticsFontSize = max(1, CGFloat(snapshot.diagnosticsScale) * Layout.diagnosticsFontScale / scale)
        let color = UIColor.white

        zoomLabel.attributedText = attributedText(snapshot.coordinateLines.zoom,
                                                 fontSize: coordinateFontSize,
                                                 color: color)
        latLonLabel.attributedText = attributedText(snapshot.coordinateLines.latLon,
                                                   fontSize: coordinateFontSize,
                                                   color: color)
        diagnosticsLabel.attributedText = diagnosticsAttributedText(snapshot.diagnosticsLines.joined(separator: "\n"),
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
        tilesStatusLabel.attributedText = tilesStatusText
        tileCoverageView.apply(coverage: snapshot.tileCoverage)
        tilesStatusListView.apply(tiles: snapshot.tileLoadingStatusTiles)

        let reliefText = NSMutableAttributedString(
            attributedString: attributedText(snapshot.reliefStatus?.lines.joined(separator: "\n") ?? "relief: off",
                                             fontSize: diagnosticsFontSize,
                                             color: color)
        )
        if let status = snapshot.reliefStatus {
            reliefText.append(attributedText("\nterrain tiles: \(status.tiles.count)",
                                             fontSize: diagnosticsFontSize,
                                             color: .systemYellow))
        }
        reliefStatusLabel.attributedText = reliefText
        reliefCoverageView.apply(coverage: snapshot.reliefCoverage)
        let reliefCountBefore = reliefListView.rowCount
        reliefListView.apply(cards: snapshot.reliefStatus.map(DebugOverlayTileCard.reliefCards(for:)) ?? [])
        if reliefListView.rowCount != reliefCountBefore {
            setNeedsLayout()
        }
    }

    private func updateVisibility() {
        isHidden = isPanelEnabled == false || snapshot == nil
    }

    private func configureControlLabel(_ label: UILabel, text: String) {
        label.text = text
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 13, weight: .medium)
    }

    private func configureSurfaceModeButton() {
        surfaceModeButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        surfaceModeButton.layer.cornerRadius = 6
        surfaceModeButton.layer.masksToBounds = true
        surfaceModeButton.addTarget(self, action: #selector(surfaceModeButtonTapped), for: .touchUpInside)
        if #available(iOS 15.0, *) {
            var configuration = UIButton.Configuration.plain()
            configuration.title = "Switch globe / flat"
            configuration.image = UIImage(systemName: "arrow.triangle.2.circlepath")
            configuration.imagePadding = 6
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
            configuration.baseForegroundColor = .white
            configuration.background.backgroundColor = UIColor.white.withAlphaComponent(0.12)
            configuration.cornerStyle = .fixed
            surfaceModeButton.configuration = configuration
        } else {
            surfaceModeButton.setTitle("Switch globe / flat", for: .normal)
            surfaceModeButton.setImage(UIImage(systemName: "arrow.triangle.2.circlepath"), for: .normal)
            surfaceModeButton.tintColor = .white
            surfaceModeButton.setTitleColor(.white, for: .normal)
            surfaceModeButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
            surfaceModeButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: -4, bottom: 0, right: 4)
        }
    }

    private func configureTileTraceButton() {
        tileTraceButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        tileTraceButton.layer.cornerRadius = 6
        tileTraceButton.layer.masksToBounds = true
        tileTraceButton.addTarget(self, action: #selector(tileTraceButtonTapped), for: .touchUpInside)
        if #available(iOS 15.0, *) {
            var configuration = UIButton.Configuration.plain()
            configuration.imagePadding = 6
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
            configuration.baseForegroundColor = .white
            configuration.background.backgroundColor = UIColor.white.withAlphaComponent(0.12)
            configuration.cornerStyle = .fixed
            tileTraceButton.configuration = configuration
        } else {
            tileTraceButton.tintColor = .white
            tileTraceButton.setTitleColor(.white, for: .normal)
            tileTraceButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
            tileTraceButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: -4, bottom: 0, right: 4)
        }
    }

    private func configureBaseLabelTraceButton() {
        baseLabelTraceButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        baseLabelTraceButton.layer.cornerRadius = 6
        baseLabelTraceButton.layer.masksToBounds = true
        baseLabelTraceButton.addTarget(self, action: #selector(baseLabelTraceButtonTapped), for: .touchUpInside)
        if #available(iOS 15.0, *) {
            var configuration = UIButton.Configuration.plain()
            configuration.imagePadding = 6
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
            configuration.baseForegroundColor = .white
            configuration.background.backgroundColor = UIColor.white.withAlphaComponent(0.12)
            configuration.cornerStyle = .fixed
            baseLabelTraceButton.configuration = configuration
        } else {
            baseLabelTraceButton.tintColor = .white
            baseLabelTraceButton.setTitleColor(.white, for: .normal)
            baseLabelTraceButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
            baseLabelTraceButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: -4, bottom: 0, right: 4)
        }
    }

    private func updateTileTraceControl() {
        let title = DebugOverlayHUDTextComposer.traceButtonTitle(isRecording: tileTraceSnapshot.isRecording)
        let imageName = DebugOverlayHUDTextComposer.traceButtonImageName(isRecording: tileTraceSnapshot.isRecording)
        if #available(iOS 15.0, *) {
            var configuration = tileTraceButton.configuration ?? UIButton.Configuration.plain()
            configuration.title = title
            configuration.image = UIImage(systemName: imageName)
            configuration.baseForegroundColor = .white
            configuration.background.backgroundColor = tileTraceSnapshot.isRecording
                ? UIColor.systemRed.withAlphaComponent(0.35)
                : UIColor.white.withAlphaComponent(0.12)
            tileTraceButton.configuration = configuration
        } else {
            tileTraceButton.setTitle(title, for: .normal)
            tileTraceButton.setImage(UIImage(systemName: imageName), for: .normal)
            tileTraceButton.backgroundColor = tileTraceSnapshot.isRecording
                ? UIColor.systemRed.withAlphaComponent(0.35)
                : UIColor.white.withAlphaComponent(0.12)
        }
        tileTraceButton.accessibilityLabel = title

        tileTraceStatusLabel.text = DebugOverlayHUDTextComposer.tileTraceStatusText(tileTraceSnapshot)
    }

    private func updateBaseLabelTraceControl() {
        let title = DebugOverlayHUDTextComposer.traceButtonTitle(isRecording: baseLabelTraceSnapshot.isRecording)
        let imageName = DebugOverlayHUDTextComposer.traceButtonImageName(isRecording: baseLabelTraceSnapshot.isRecording)
        if #available(iOS 15.0, *) {
            var configuration = baseLabelTraceButton.configuration ?? UIButton.Configuration.plain()
            configuration.title = title
            configuration.image = UIImage(systemName: imageName)
            configuration.baseForegroundColor = .white
            configuration.background.backgroundColor = baseLabelTraceSnapshot.isRecording
                ? UIColor.systemRed.withAlphaComponent(0.35)
                : UIColor.white.withAlphaComponent(0.12)
            baseLabelTraceButton.configuration = configuration
        } else {
            baseLabelTraceButton.setTitle(title, for: .normal)
            baseLabelTraceButton.setImage(UIImage(systemName: imageName), for: .normal)
            baseLabelTraceButton.backgroundColor = baseLabelTraceSnapshot.isRecording
                ? UIColor.systemRed.withAlphaComponent(0.35)
                : UIColor.white.withAlphaComponent(0.12)
        }
        baseLabelTraceButton.accessibilityLabel = title

        baseLabelTraceStatusLabel.text = DebugOverlayHUDTextComposer.baseLabelTraceStatusText(baseLabelTraceSnapshot)
    }

    private func updateCollapseButtonImage() {
        let imageName = isCollapsed ? "chevron.down" : "chevron.up"
        collapseButton.setImage(UIImage(systemName: imageName), for: .normal)
        collapseButton.accessibilityLabel = isCollapsed ? "Expand debug panel" : "Collapse debug panel"
    }

    private func updateContentVisibility() {
        let isContentHidden = isCollapsed
        let isStatsVisible = selectedTab == .stats && isContentHidden == false
        let isTilesVisible = selectedTab == .tiles && isContentHidden == false
        let isBaseLabelsVisible = selectedTab == .baseLabels && isContentHidden == false
        let isControlsVisible = selectedTab == .controls && isContentHidden == false
        let isReliefVisible = selectedTab == .relief && isContentHidden == false
        [tabControl].forEach {
            $0.isHidden = isContentHidden
        }
        [axesLabel, axesSwitch, tileLayersLabel, tileLayersSwitch,
         tileGridLabel, tileGridSwitch, tileGridDensityControl, wireframeLabel, wireframeSwitch,
         surfaceModeButton].forEach {
            $0.isHidden = isControlsVisible == false
        }
        [zoomLabel, latLonLabel, diagnosticsLabel].forEach {
            $0.isHidden = isStatsVisible == false
        }
        tilesStatusLabel.isHidden = isTilesVisible == false
        tileCoverageView.isHidden = isTilesVisible == false
        tilesScrollView.isHidden = isTilesVisible == false || tilesStatusListView.rowCount == 0
        tileTraceButton.isHidden = isTilesVisible == false
        tileTraceStatusLabel.isHidden = isTilesVisible == false
        baseLabelTraceButton.isHidden = isBaseLabelsVisible == false
        baseLabelTraceStatusLabel.isHidden = isBaseLabelsVisible == false
        roadLabelTilesLabel.isHidden = isBaseLabelsVisible == false
        roadLabelTilesSwitch.isHidden = isBaseLabelsVisible == false
        baseLabelBoundsLabel.isHidden = isBaseLabelsVisible == false
        baseLabelBoundsSwitch.isHidden = isBaseLabelsVisible == false
        roadLabelBoundsLabel.isHidden = isBaseLabelsVisible == false
        roadLabelBoundsSwitch.isHidden = isBaseLabelsVisible == false
        reliefStatusLabel.isHidden = isReliefVisible == false
        reliefCoverageView.isHidden = isReliefVisible == false
        reliefScrollView.isHidden = isReliefVisible == false || reliefListView.rowCount == 0
    }

    @objc private func toggleCollapsed() {
        isCollapsed.toggle()
        updateCollapseButtonImage()
        setNeedsLayout()
    }

    @objc private func axesSwitchChanged() {
        onAxesEnabledChanged?(axesSwitch.isOn)
    }

    @objc private func tileLayersSwitchChanged() {
        onTileLayersEnabledChanged?(tileLayersSwitch.isOn)
    }

    @objc private func tileGridSwitchChanged() {
        onTileGridEnabledChanged?(tileGridSwitch.isOn)
    }

    @objc private func tileGridDensityControlChanged() {
        onTileGridDensityChanged?(DebugOverlayHUDTextComposer.tileGridDensity(atIndex: tileGridDensityControl.selectedSegmentIndex))
    }

    @objc private func wireframeSwitchChanged() {
        onWireframeEnabledChanged?(wireframeSwitch.isOn)
    }

    @objc private func roadLabelTilesSwitchChanged() {
        onRoadLabelTilesEnabledChanged?(roadLabelTilesSwitch.isOn)
    }

    @objc private func baseLabelBoundsSwitchChanged() {
        onBaseLabelBoundsEnabledChanged?(baseLabelBoundsSwitch.isOn)
    }

    @objc private func roadLabelBoundsSwitchChanged() {
        onRoadLabelBoundsEnabledChanged?(roadLabelBoundsSwitch.isOn)
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
        selectedTab = SelectedTab(rawValue: tabControl.selectedSegmentIndex) ?? .stats
        updateContentVisibility()
        setNeedsLayout()
        onShownContentChanged?(shownContent)
    }

    private func attributedText(_ text: String,
                                fontSize: CGFloat,
                                color: UIColor) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: color
            ]
        )
    }

    private func diagnosticsAttributedText(_ text: String,
                                           fontSize: CGFloat,
                                           color: UIColor) -> NSAttributedString {
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

    private func diagnosticsColor(for style: DebugOverlayDiagnosticsTextStyle) -> UIColor {
        switch style {
        case let .section(title):
            return diagnosticsSectionColor(title: title)
        case .key:
            return UIColor.white.withAlphaComponent(0.58)
        case .warningValue:
            return UIColor.systemOrange
        }
    }

    private func diagnosticsSectionColor(title: String) -> UIColor {
        switch title {
        case "Camera":
            return UIColor.systemCyan
        case "Frame":
            return UIColor.systemGreen
        case "Tiles":
            return UIColor.systemYellow
        case "Labels":
            return UIColor.systemPurple
        case "Resources":
            return UIColor.systemBlue
        case "Globe culling":
            return UIColor.systemOrange
        case "Skip":
            return UIColor.systemRed
        default:
            return UIColor.white.withAlphaComponent(0.82)
        }
    }
}

#if DEBUG
/// Where a card's title lands, for the tests: inside its card, in the
/// title's font.
struct DebugOverlayTileCardMetrics {
    let cardRect: CGRect
    let titleRect: CGRect
    let titleFontSize: CGFloat
}
#endif

private final class DebugOverlayTilesStatusListView: UIView {
    private typealias CardLayout = DebugOverlayTileCardLayout

    private var cards: [DebugOverlayTileCard] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var rowCount: Int {
        cards.count
    }

    func apply(tiles: [TileLoadingStatusTileSnapshot]) {
        apply(cards: DebugOverlayTileCard.cards(for: tiles))
    }

    /// The relief tab's cards, already in their order.
    func apply(cards: [DebugOverlayTileCard]) {
        guard self.cards != cards else { return }
        self.cards = cards
        setNeedsDisplay()
    }

    /// The grid's height: the list scrolls, so it holds every card.
    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        DebugOverlayPanelLayout.cardGridHeight(cardCount: cards.count,
                                               columns: Self.columns(forWidth: width),
                                               cardHeight: CardLayout.height,
                                               spacing: CardLayout.spacing)
    }

    private static func columns(forWidth width: CGFloat) -> Int {
        DebugOverlayPanelLayout.cardColumnCount(width: width,
                                                minimumCardWidth: CardLayout.minimumWidth,
                                                spacing: CardLayout.spacing)
    }

    private func cardFrame(at index: Int, width: CGFloat) -> CGRect {
        DebugOverlayPanelLayout.cardFrame(index: index,
                                          columns: Self.columns(forWidth: width),
                                          width: width,
                                          cardHeight: CardLayout.height,
                                          spacing: CardLayout.spacing)
    }

    // The cards are laid out from the bounds, never from the dirty rect: a
    // partial redraw of the list must leave every card whole.
    override func draw(_: CGRect) {
        guard cards.isEmpty == false else {
            return
        }
        for (index, card) in cards.enumerated() {
            draw(card: card, in: cardFrame(at: index, width: bounds.width))
        }
    }

    private func draw(card: DebugOverlayTileCard, in frame: CGRect) {
        let color = Self.statusColor(card.status)
        let shape = UIBezierPath(roundedRect: frame, cornerRadius: CardLayout.cornerRadius)
        UIColor.black.withAlphaComponent(CardLayout.backgroundAlpha).setFill()
        shape.fill()
        color.withAlphaComponent(CardLayout.tintAlpha).setFill()
        shape.fill()
        if let context = UIGraphicsGetCurrentContext() {
            context.saveGState()
            shape.addClip()
            color.setFill()
            UIBezierPath(rect: CardLayout.stripeRect(in: frame)).fill()
            context.restoreGState()
        }

        let radius = CardLayout.progressHeight * 0.5
        UIColor.black.withAlphaComponent(CardLayout.progressTrackAlpha).setFill()
        UIBezierPath(roundedRect: CardLayout.progressTrackRect(in: frame), cornerRadius: radius).fill()
        color.withAlphaComponent(CardLayout.progressAlpha).setFill()
        UIBezierPath(roundedRect: CardLayout.progressRect(in: frame, progress: card.progress), cornerRadius: radius).fill()

        let titleFont = Self.titleFont
        let detailFont = UIFont.monospacedSystemFont(ofSize: CardLayout.detailFontSize, weight: .bold)
        let statusAttributes = Self.attributes(font: detailFont, color: color)
        let statusWidth = (card.statusText as NSString).size(withAttributes: statusAttributes).width
        // The title in its zoom's colour, the one the tile's outline and
        // label on the map take (`DebugTileZoomPalette`).
        let zoomColor = DebugTileZoomPalette.color(forZoom: card.tile.z)
        card.title.draw(in: Self.titleRect(in: frame, statusWidth: statusWidth),
                        withAttributes: Self.attributes(font: titleFont,
                                                        color: UIColor(red: CGFloat(zoomColor.x), green: CGFloat(zoomColor.y),
                                                                       blue: CGFloat(zoomColor.z), alpha: 1)))
        card.statusText.draw(in: CardLayout.statusRect(in: frame,
                                                       titleLineHeight: titleFont.lineHeight,
                                                       lineHeight: detailFont.lineHeight,
                                                       width: statusWidth),
                             withAttributes: statusAttributes)
        card.stagesText.draw(in: CardLayout.stagesRect(in: frame, lineHeight: detailFont.lineHeight),
                             withAttributes: Self.attributes(font: detailFont, color: UIColor.white.withAlphaComponent(0.86)))
        card.layersText.draw(in: CardLayout.layersRect(in: frame, lineHeight: detailFont.lineHeight),
                             withAttributes: Self.attributes(font: detailFont, color: UIColor.white.withAlphaComponent(0.66)))
    }

    private static var titleFont: UIFont {
        UIFont.monospacedSystemFont(ofSize: CardLayout.titleFontSize, weight: .heavy)
    }

    private static func titleRect(in frame: CGRect, statusWidth: CGFloat) -> CGRect {
        CardLayout.titleRect(in: frame, lineHeight: titleFont.lineHeight, statusWidth: statusWidth)
    }

    /// One line, cut with an ellipsis where the card is too narrow for it.
    private static func attributes(font: UIFont, color: UIColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    private static func statusColor(_ status: TileLoadingTileStatus) -> UIColor {
        switch status {
        case .ready:
            return UIColor.systemGreen
        case .failed:
            return UIColor.systemRed
        case .queued, .loading, .parsing:
            return UIColor.systemYellow
        }
    }

    #if DEBUG
    var cardLinesForTesting: [[String]] {
        cards.map(\.lines)
    }

    /// The first card's metrics at the list's width.
    var firstCardMetricsForTesting: DebugOverlayTileCardMetrics? {
        guard let card = cards.first else { return nil }
        let frame = cardFrame(at: 0, width: bounds.width)
        let detailFont = UIFont.monospacedSystemFont(ofSize: CardLayout.detailFontSize, weight: .bold)
        let statusWidth = (card.statusText as NSString).size(withAttributes: [.font: detailFont]).width
        return DebugOverlayTileCardMetrics(cardRect: frame,
                                           titleRect: Self.titleRect(in: frame, statusWidth: statusWidth),
                                           titleFontSize: CardLayout.titleFontSize)
    }
    #endif
}

/// The coverage map of the Tiles tab: the frame's placements from above
/// (`DebugOverlayTileCoverage`), each slot a square filled and outlined
/// in its zoom's colour, the coarse ones under the fine, the view's
/// ground footprint in white over them, a cross at the point the camera
/// looks at and a dot at the eye. North up, nothing stretched.
private final class DebugOverlayTileCoverageView: UIView {
    private typealias CoverageLayout = DebugOverlayTileCoverageLayout

    private var coverage: DebugOverlayTileCoverage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(coverage: DebugOverlayTileCoverage?) {
        guard self.coverage != coverage else { return }
        self.coverage = coverage
        setNeedsDisplay()
    }

    override func draw(_: CGRect) {
        let shape = UIBezierPath(roundedRect: bounds, cornerRadius: CoverageLayout.cornerRadius)
        UIColor.black.withAlphaComponent(0.45).setFill()
        shape.fill()
        guard let coverage, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        shape.addClip()
        let window = CoverageLayout.window(for: coverage)
        let side = bounds.width
        let font = UIFont.monospacedSystemFont(ofSize: CoverageLayout.labelFontSize, weight: .bold)
        for placement in CoverageLayout.drawingOrder(coverage.placements) {
            let rect = CoverageLayout.rect(placement.square, window: window, side: side)
            let color = Self.color(DebugTileZoomPalette.color(forZoom: placement.slot.z))
            color.withAlphaComponent(CoverageLayout.tileFillAlpha).setFill()
            UIBezierPath(rect: rect).fill()
            color.setStroke()
            let outline = UIBezierPath(rect: rect.insetBy(dx: CoverageLayout.tileLineWidth / 2, dy: CoverageLayout.tileLineWidth / 2))
            outline.lineWidth = CoverageLayout.tileLineWidth
            outline.stroke()
            guard rect.width >= CoverageLayout.labelledSquareSide else { continue }
            var lines = [(text: "\(placement.slot.x)/\(placement.slot.y)/\(placement.slot.z)", color: color)]
            if placement.isStandIn, rect.width >= CoverageLayout.sourceLabelledSquareSide {
                lines.append((text: "src \(placement.source.x)/\(placement.source.y)/\(placement.source.z)",
                              color: Self.color(DebugTileZoomPalette.color(forZoom: placement.source.z))))
            }
            var top = rect.minY + 3
            for line in lines {
                line.text.draw(in: CGRect(x: rect.minX + 4, y: top, width: rect.width - 8, height: font.lineHeight),
                               withAttributes: [.font: font, .foregroundColor: line.color,
                                                .strokeColor: UIColor.black.withAlphaComponent(0.8), .strokeWidth: -2.5])
                top += font.lineHeight
            }
        }
        if coverage.footprint.count >= 3 {
            let path = UIBezierPath()
            for (index, vertex) in coverage.footprint.enumerated() {
                let point = CoverageLayout.point(vertex, window: window, side: side)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.close()
            UIColor.white.withAlphaComponent(CoverageLayout.footprintFillAlpha).setFill()
            path.fill()
            UIColor.white.setStroke()
            path.lineWidth = CoverageLayout.footprintLineWidth
            path.stroke()
        }
        let center = CoverageLayout.point(coverage.center, window: window, side: side)
        let cross = UIBezierPath()
        let arm = CoverageLayout.markerRadius * 1.6
        cross.move(to: CGPoint(x: center.x - arm, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + arm, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - arm))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + arm))
        cross.lineWidth = 1.5
        UIColor.white.setStroke()
        cross.stroke()
        if let eye = coverage.eye {
            let point = CoverageLayout.point(eye, window: window, side: side)
            let radius = CoverageLayout.markerRadius
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)).fill()
        }
        context.restoreGState()
    }

    private static func color(_ rgb: SIMD3<Float>) -> UIColor {
        UIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
    }
}

/// The relief tab's map (`DebugOverlayReliefCoverage`): each terrain tile
/// as its square in its zoom's colour, filled once it is in, outlined in
/// yellow while it loads, in grey while it waits for a slot and in red
/// after a failure, the frame's wanted tiles strong and the ones kept from
/// earlier frames faint, under the view's footprint, the point the camera
/// looks at and the eye, as the tiles' map draws them.
private final class DebugOverlayReliefCoverageView: UIView {
    private typealias CoverageLayout = DebugOverlayTileCoverageLayout

    private var coverage: DebugOverlayReliefCoverage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(coverage: DebugOverlayReliefCoverage?) {
        guard self.coverage != coverage else { return }
        self.coverage = coverage
        setNeedsDisplay()
    }

    override func draw(_: CGRect) {
        let shape = UIBezierPath(roundedRect: bounds, cornerRadius: CoverageLayout.cornerRadius)
        UIColor.black.withAlphaComponent(0.45).setFill()
        shape.fill()
        guard let coverage, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        shape.addClip()
        let window = coverage.window
        let side = bounds.width
        let font = UIFont.monospacedSystemFont(ofSize: CoverageLayout.labelFontSize, weight: .bold)
        for square in coverage.drawingOrder {
            let rect = CoverageLayout.rect(square.square, window: window, side: side)
            let zoomColor = Self.color(DebugTileZoomPalette.color(forZoom: square.tile.z))
            let strength: CGFloat = square.isWanted ? 1 : 0.35
            let stroke: UIColor
            switch square.state {
            case .resident:
                zoomColor.withAlphaComponent(CoverageLayout.tileFillAlpha * strength).setFill()
                UIBezierPath(rect: rect).fill()
                stroke = zoomColor
            case .loading:
                stroke = .systemYellow
            case .queued:
                stroke = .systemGray
            case .failed:
                UIColor.systemRed.withAlphaComponent(0.2 * strength).setFill()
                UIBezierPath(rect: rect).fill()
                stroke = .systemRed
            }
            stroke.withAlphaComponent(strength).setStroke()
            let outline = UIBezierPath(rect: rect.insetBy(dx: CoverageLayout.tileLineWidth / 2, dy: CoverageLayout.tileLineWidth / 2))
            outline.lineWidth = CoverageLayout.tileLineWidth
            outline.stroke()
            guard square.isWanted, rect.width >= CoverageLayout.labelledSquareSide else { continue }
            "\(square.tile.x)/\(square.tile.y)/\(square.tile.z)".draw(
                in: CGRect(x: rect.minX + 4, y: rect.minY + 3, width: rect.width - 8, height: font.lineHeight),
                withAttributes: [.font: font, .foregroundColor: zoomColor,
                                 .strokeColor: UIColor.black.withAlphaComponent(0.8), .strokeWidth: -2.5])
        }
        if coverage.footprint.count >= 3 {
            let path = UIBezierPath()
            for (index, vertex) in coverage.footprint.enumerated() {
                let point = CoverageLayout.point(vertex, window: window, side: side)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.close()
            UIColor.white.withAlphaComponent(CoverageLayout.footprintFillAlpha).setFill()
            path.fill()
            UIColor.white.setStroke()
            path.lineWidth = CoverageLayout.footprintLineWidth
            path.stroke()
        }
        let center = CoverageLayout.point(coverage.center, window: window, side: side)
        let cross = UIBezierPath()
        let arm = CoverageLayout.markerRadius * 1.6
        cross.move(to: CGPoint(x: center.x - arm, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + arm, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - arm))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + arm))
        cross.lineWidth = 1.5
        UIColor.white.setStroke()
        cross.stroke()
        if let eye = coverage.eye {
            let point = CoverageLayout.point(eye, window: window, side: side)
            let radius = CoverageLayout.markerRadius
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)).fill()
        }
        context.restoreGState()
    }

    private static func color(_ rgb: SIMD3<Float>) -> UIColor {
        UIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
    }
}

#if DEBUG
extension DebugOverlayHUDView {
    func simulateSurfaceModeSwitchForTesting() {
        surfaceModeButtonTapped()
    }

    func simulateTileTraceRecordingToggleForTesting() {
        tileTraceButtonTapped()
    }

    func simulateBaseLabelsTraceRecordingToggleForTesting() {
        baseLabelTraceButtonTapped()
    }

    func simulateControlsTabSelectionForTesting() {
        tabControl.selectedSegmentIndex = SelectedTab.controls.rawValue
        tabControlChanged()
    }

    func simulateTilesTabSelectionForTesting() {
        tabControl.selectedSegmentIndex = SelectedTab.tiles.rawValue
        tabControlChanged()
    }

    func simulateBaseLabelsTabSelectionForTesting() {
        tabControl.selectedSegmentIndex = SelectedTab.baseLabels.rawValue
        tabControlChanged()
    }


    func simulateRoadLabelTilesSwitchChangeForTesting(_ isOn: Bool) {
        roadLabelTilesSwitch.setOn(isOn, animated: false)
        roadLabelTilesSwitchChanged()
    }

    func simulateTileGridSwitchChangeForTesting(_ isOn: Bool) {
        tileGridSwitch.setOn(isOn, animated: false)
        tileGridSwitchChanged()
    }

    func simulateTileGridDensitySelectionForTesting(_ density: Int) {
        tileGridDensityControl.selectedSegmentIndex = DebugOverlayHUDTextComposer.tileGridDensityIndex(for: density)
        tileGridDensityControlChanged()
    }

    var isTileGridSwitchOnForTesting: Bool {
        tileGridSwitch.isOn
    }

    var tileGridDensityForTesting: Int {
        DebugOverlayHUDTextComposer.tileGridDensity(atIndex: tileGridDensityControl.selectedSegmentIndex)
    }

    var isControlsTabSelectedForTesting: Bool {
        selectedTab == .controls
    }

    var isTilesTabSelectedForTesting: Bool {
        selectedTab == .tiles
    }

    var isBaseLabelsTabSelectedForTesting: Bool {
        selectedTab == .baseLabels
    }

    var areDebugControlsVisibleForTesting: Bool {
        [axesLabel, axesSwitch, tileLayersLabel, tileLayersSwitch,
         tileGridLabel, tileGridSwitch, tileGridDensityControl, wireframeLabel, wireframeSwitch,
         surfaceModeButton]
            .allSatisfy { $0.isHidden == false }
    }

    var isRoadLabelTilesSwitchOnForTesting: Bool {
        roadLabelTilesSwitch.isOn
    }

    var isStatsContentVisibleForTesting: Bool {
        [zoomLabel, latLonLabel, diagnosticsLabel].allSatisfy { $0.isHidden == false }
    }

    var isTilesContentVisibleForTesting: Bool {
        tilesStatusLabel.isHidden == false
    }

    var isTileTraceControlVisibleForTesting: Bool {
        tileTraceButton.isHidden == false
            && tileTraceStatusLabel.isHidden == false
    }

    var isBaseLabelTraceControlVisibleForTesting: Bool {
        baseLabelTraceButton.isHidden == false
            && baseLabelTraceStatusLabel.isHidden == false
    }

    var isRoadLabelTilesControlVisibleForTesting: Bool {
        roadLabelTilesLabel.isHidden == false
            && roadLabelTilesSwitch.isHidden == false
    }

    var baseLabelTraceButtonTitleForTesting: String? {
        if #available(iOS 15.0, *) {
            return baseLabelTraceButton.configuration?.title
        }
        return baseLabelTraceButton.title(for: .normal)
    }

    var baseLabelTraceStatusTextForTesting: String? {
        baseLabelTraceStatusLabel.text
    }

    var baseLabelTraceStatusTextColorForTesting: UIColor? {
        baseLabelTraceStatusLabel.textColor
    }

    var baseLabelTraceStatusFontPointSizeForTesting: CGFloat {
        baseLabelTraceStatusLabel.font.pointSize
    }

    var tilesStatusTextForTesting: String? {
        tilesStatusLabel.text
    }

    var tilesStatusRowCountForTesting: Int {
        tilesStatusListView.rowCount
    }

    var tilesStatusCardLinesForTesting: [[String]] {
        tilesStatusListView.cardLinesForTesting
    }

    var tilesStatusFirstCardMetricsForTesting: DebugOverlayTileCardMetrics? {
        tilesStatusListView.firstCardMetricsForTesting
    }

    var isTilesScrollEnabledForTesting: Bool {
        tilesScrollView.isScrollEnabled
    }

    var debugPanelFrameForTesting: CGRect {
        containerView.frame
    }

    var tileTraceButtonTitleForTesting: String? {
        if #available(iOS 15.0, *) {
            return tileTraceButton.configuration?.title
        }
        return tileTraceButton.title(for: .normal)
    }

    var tileTraceStatusTextForTesting: String? {
        tileTraceStatusLabel.text
    }

    var textUpdateCountForTesting: Int {
        textUpdateCountForTestingStorage
    }
}
#endif

#endif
