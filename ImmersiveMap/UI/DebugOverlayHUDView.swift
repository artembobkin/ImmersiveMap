// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import UIKit

final class DebugOverlayHUDView: UIView {
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

    private let containerView = UIView()
    private let titleLabel = UILabel()
    private let collapseButton = UIButton(type: .system)
    private let axesLabel = UILabel()
    private let axesSwitch = UISwitch()
    private let tileLayersLabel = UILabel()
    private let tileLayersSwitch = UISwitch()
    private let wireframeLabel = UILabel()
    private let wireframeSwitch = UISwitch()
    private let earthSceneLabel = UILabel()
    private let earthSceneSwitch = UISwitch()
    private let surfaceModeButton = UIButton(type: .system)
    private let tabControl = UISegmentedControl(items: ["Stats", "Atlas", "Tiles", "Base labels", "Controls"])
    private let tileTraceButton = UIButton(type: .system)
    private let tileTraceStatusLabel = UILabel()
    private let baseLabelTraceButton = UIButton(type: .system)
    private let baseLabelTraceStatusLabel = UILabel()
    private let roadLabelTilesLabel = UILabel()
    private let roadLabelTilesSwitch = UISwitch()
    private let zoomLabel = UILabel()
    private let latLonLabel = UILabel()
    private let diagnosticsLabel = UILabel()
    private let tilesStatusLabel = UILabel()
    private let tilesScrollView = UIScrollView()
    private let tilesStatusListView = DebugOverlayTilesStatusListView()
    private let atlasScrollView = UIScrollView()
    private let atlasLayoutView = DebugOverlayAtlasLayoutView()
    private let atlasDetailsLabel = UILabel()
    private var snapshot: DebugOverlayHUDSnapshot?
    private var isPanelEnabled = false
    private var isCollapsed = false
    private var selectedTab: SelectedTab = .stats
    private var tileTraceSnapshot = TileTraceRecorderSnapshot(isRecording: false, fileURL: nil)
    private var baseLabelTraceSnapshot = BaseLabelTraceRecorderSnapshot(isRecording: false, fileURL: nil)
    /// Верхний safe-area inset host view: панель не заходит под статус-бар/вырез,
    /// иначе шеврон сворачивания попадает в непрожимаемую зону.
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
    var onTileLayersEnabledChanged: ((Bool) -> Void)?
    var onWireframeEnabledChanged: ((Bool) -> Void)?
    var onRoadLabelTilesEnabledChanged: ((Bool) -> Void)?
    var onEarthSceneEnabledChanged: ((Bool) -> Void)?
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
        configureControlLabel(wireframeLabel, text: "Wireframe")
        configureControlLabel(earthSceneLabel, text: "Earth scene")
        configureControlLabel(roadLabelTilesLabel, text: "Road label tiles")
        axesSwitch.addTarget(self, action: #selector(axesSwitchChanged), for: .valueChanged)
        tileLayersSwitch.addTarget(self, action: #selector(tileLayersSwitchChanged), for: .valueChanged)
        wireframeSwitch.addTarget(self, action: #selector(wireframeSwitchChanged), for: .valueChanged)
        earthSceneSwitch.addTarget(self, action: #selector(earthSceneSwitchChanged), for: .valueChanged)
        roadLabelTilesSwitch.addTarget(self, action: #selector(roadLabelTilesSwitchChanged), for: .valueChanged)
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

        [zoomLabel, latLonLabel, diagnosticsLabel, tilesStatusLabel].forEach { label in
            label.numberOfLines = 0
            label.lineBreakMode = .byCharWrapping
            label.adjustsFontSizeToFitWidth = false
            containerView.addSubview(label)
        }
        tilesScrollView.backgroundColor = .clear
        tilesScrollView.alwaysBounceVertical = false
        tilesScrollView.delaysContentTouches = false
        tilesScrollView.showsHorizontalScrollIndicator = false
        tilesScrollView.showsVerticalScrollIndicator = true
        containerView.addSubview(tilesScrollView)
        tilesScrollView.addSubview(tilesStatusListView)
        tilesStatusListView.onExpansionChanged = { [weak self] in
            self?.setNeedsLayout()
        }
        atlasDetailsLabel.numberOfLines = 0
        atlasDetailsLabel.lineBreakMode = .byWordWrapping
        atlasDetailsLabel.adjustsFontSizeToFitWidth = false
        atlasScrollView.backgroundColor = .clear
        atlasScrollView.alwaysBounceVertical = false
        atlasScrollView.showsHorizontalScrollIndicator = false
        atlasScrollView.showsVerticalScrollIndicator = true
        containerView.addSubview(atlasScrollView)
        atlasScrollView.addSubview(atlasLayoutView)
        atlasScrollView.addSubview(atlasDetailsLabel)
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
               controls: DebugOverlayControlSnapshot,
               earthSceneEnabled: Bool) {
        isPanelEnabled = isDebugPanelEnabled
        axesSwitch.setOn(controls.axesEnabled, animated: false)
        tileLayersSwitch.setOn(controls.tileLayersEnabled, animated: false)
        wireframeSwitch.setOn(controls.wireframeEnabled, animated: false)
        roadLabelTilesSwitch.setOn(controls.roadLabelTilesEnabled, animated: false)
        earthSceneSwitch.setOn(earthSceneEnabled, animated: false)
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
        tilesStatusLabel.frame = CGRect(x: Layout.contentInset,
                                        y: textTop,
                                        width: contentWidth,
                                        height: tilesStatusSize.height)
        let tilesScrollTop = tilesStatusLabel.frame.maxY + tilesListSpacing
        let tilesScrollHeight = max(0, visibleTilesBodyHeight - tilesStatusSize.height - tilesListSpacing)
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
        let updatedTilesScrollTop = tilesStatusLabel.frame.maxY + tilesListSpacing
        let updatedTilesScrollHeight = max(0, visibleTilesBodyHeight - traceBlockHeight - tilesStatusSize.height - tilesListSpacing)
        tilesScrollView.frame = CGRect(x: Layout.contentInset,
                                       y: updatedTilesScrollTop,
                                       width: contentWidth,
                                       height: updatedTilesScrollHeight)
        tilesScrollView.isScrollEnabled = tilesScrollView.contentSize.height > updatedTilesScrollHeight + 0.5
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
        atlasScrollView.contentSize = CGSize(width: contentWidth,
                                             height: atlasPreviewHeight + sectionSpacing + atlasDetailsSize.height)
        atlasScrollView.isScrollEnabled = atlasScrollView.contentSize.height > atlasScrollHeight + 0.5
        updateContentVisibility()
    }

    /// Не даёт панели уехать под статус-бар/вырез: верх контейнера прижимается
    /// к safe area. Внутренние элементы позиционируются относительно контейнера,
    /// поэтому сдвиг origin переносит их целиком.
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
            tilesStatusListView.apply(tiles: [])
            atlasDetailsLabel.attributedText = nil
            atlasLayoutView.apply(pages: [])
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
        tilesStatusLabel.attributedText = attributedText(DebugOverlayHUDTextComposer.tilesStatusText(lines: snapshot.tileLoadingStatusLines),
                                                        fontSize: diagnosticsFontSize,
                                                        color: color)
        tilesStatusListView.apply(tiles: snapshot.tileLoadingStatusTiles)
        atlasLayoutView.apply(pages: snapshot.atlasPages)
        atlasDetailsLabel.attributedText = attributedText(DebugOverlayHUDTextComposer.atlasDetailsText(pages: snapshot.atlasPages),
                                                         fontSize: diagnosticsFontSize,
                                                         color: color)
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
        let isAtlasVisible = selectedTab == .atlas && isContentHidden == false
        let isStatsVisible = selectedTab == .stats && isContentHidden == false
        let isTilesVisible = selectedTab == .tiles && isContentHidden == false
        let isBaseLabelsVisible = selectedTab == .baseLabels && isContentHidden == false
        let isControlsVisible = selectedTab == .controls && isContentHidden == false
        [tabControl].forEach {
            $0.isHidden = isContentHidden
        }
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

    @objc private func wireframeSwitchChanged() {
        onWireframeEnabledChanged?(wireframeSwitch.isOn)
    }

    @objc private func roadLabelTilesSwitchChanged() {
        onRoadLabelTilesEnabledChanged?(roadLabelTilesSwitch.isOn)
    }

    @objc private func earthSceneSwitchChanged() {
        onEarthSceneEnabledChanged?(earthSceneSwitch.isOn)
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

private final class DebugOverlayAtlasLayoutView: UIView {
    private enum Layout {
        static let pageLabelHeight: CGFloat = 16
        static let pageSpacing: CGFloat = 10
        static let minimumPageSide: CGFloat = 180
        static let maximumPageSide: CGFloat = 260
        static let borderWidth: CGFloat = 1
    }

    private var pages: [TileAtlasDebugPage] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var pageCount: Int {
        pages.count
    }

    func apply(pages: [TileAtlasDebugPage]) {
        self.pages = pages
        setNeedsDisplay()
    }

    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        guard pages.isEmpty == false else {
            return 48
        }

        return atlasGridLayout(forWidth: width).height
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
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
            .font: UIFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: UIColor.white.withAlphaComponent(0.72)
        ]
        text.draw(in: rect.insetBy(dx: 2, dy: 14), withAttributes: attributes)
    }

    private func drawPageLabel(page: TileAtlasDebugPage, in rect: CGRect) {
        let text = "page \(page.pageIndex) slots \(page.allocations.count)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.9)
        ]
        text.draw(in: rect, withAttributes: attributes)
    }

    private func drawPage(_ page: TileAtlasDebugPage,
                          in pageRect: CGRect,
                          context: CGContext) {
        context.setFillColor(UIColor.white.withAlphaComponent(0.06).cgColor)
        context.fill(pageRect)
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.28).cgColor)
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
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.82)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = CGSize(width: 0, height: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.95),
            .shadow: shadow
        ]
        allocation.atlasPreviewLabel.draw(in: labelRect, withAttributes: attributes)
    }

    private func color(for allocation: TileAtlasDebugAllocation) -> UIColor {
        if allocation.isFallback {
            return UIColor.systemOrange
        }

        switch allocation.atlasDepth {
        case .depth0:
            return UIColor.systemRed
        case .depth1:
            return UIColor.systemYellow
        case .depth2:
            return UIColor.systemGreen
        case .depth3:
            return UIColor.systemTeal
        case .depth4:
            return UIColor.systemBlue
        }
    }
}

#if DEBUG
struct DebugOverlayTilesPrimaryRowMetrics {
    let progressBackgroundRect: CGRect
    let textRect: CGRect
    let fontSize: CGFloat
}
#endif

private final class DebugOverlayTilesStatusListView: UIView {
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

    private static func height(of row: Row) -> CGFloat {
        switch row {
        case .tile:
            return Layout.rowHeight
        case .stage, .layer:
            return Layout.childRowHeight
        }
    }

    private var tiles: [TileLoadingStatusTileSnapshot] = []
    private var expandedTiles: Set<Tile> = []
    private var expandedParseStageTiles: Set<Tile> = []

    var onExpansionChanged: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = true
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTapGesture(_:)))
        tapGesture.cancelsTouchesInView = true
        addGestureRecognizer(tapGesture)
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
        setNeedsDisplay()
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
        guard let context = UIGraphicsGetCurrentContext(), tiles.isEmpty == false else {
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

    @objc private func handleTapGesture(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else {
            return
        }

        let point = gesture.location(in: self)
        guard
              let row = row(atY: point.y) else {
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
        let backgroundRect = Self.progressBackgroundRect(for: rowRect)
        UIColor.black.withAlphaComponent(0.16).setFill()
        UIBezierPath(roundedRect: backgroundRect, cornerRadius: Layout.cornerRadius).fill()

        let progressWidth = max(Layout.cornerRadius * 2, backgroundRect.width * CGFloat(tile.progress))
        let progressRect = CGRect(x: backgroundRect.minX,
                                  y: backgroundRect.minY,
                                  width: progressWidth,
                                  height: backgroundRect.height)
            .intersection(backgroundRect)
        color.withAlphaComponent(0.82).setFill()
        UIBezierPath(roundedRect: progressRect, cornerRadius: Layout.cornerRadius).fill()

        let font = UIFont.monospacedSystemFont(ofSize: Layout.primaryFontSize, weight: .heavy)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white.withAlphaComponent(0.98)
        ]
        let textRect = Self.centeredTextRect(rowRect: rowRect,
                                             backgroundRect: backgroundRect,
                                             font: font)
        let isExpanded = expandedTiles.contains(tile.tile)
        Row.tile(tile, isExpanded: isExpanded, canExpand: tile.preparationStages.isEmpty == false)
            .text
            .draw(in: textRect, withAttributes: attributes)
    }

    private func drawChildText(_ text: String, rowRect: CGRect) {
        let font = UIFont.monospacedSystemFont(ofSize: Layout.childFontSize, weight: .bold)
        let textRect = CGRect(x: Layout.textInset,
                              y: rowRect.midY - font.lineHeight * 0.5,
                              width: max(0, rowRect.width - Layout.textInset * 2),
                              height: font.lineHeight)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white.withAlphaComponent(0.94)
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
        setNeedsDisplay()
        onExpansionChanged?()
    }

    private func toggleParseExpansion(_ tile: Tile) {
        if expandedParseStageTiles.contains(tile) {
            expandedParseStageTiles.remove(tile)
        } else {
            expandedParseStageTiles.insert(tile)
        }
        setNeedsDisplay()
        onExpansionChanged?()
    }

    private func visibleRows() -> [Row] {
        DebugOverlayTilesStatusRow.visibleRows(tiles: tiles,
                                               expandedTiles: expandedTiles,
                                               expandedParseStageTiles: expandedParseStageTiles)
    }

    private func statusColor(_ status: TileLoadingTileStatus) -> UIColor {
        switch status {
        case .ready:
            return UIColor.systemGreen
        case .failed:
            return UIColor.systemRed
        case .queued, .loading, .parsing:
            return UIColor.systemYellow
        }
    }

    private static func progressBackgroundRect(for rowRect: CGRect) -> CGRect {
        rowRect.insetBy(dx: 0, dy: Layout.progressVerticalInset)
    }

    private static func centeredTextRect(rowRect: CGRect,
                                         backgroundRect: CGRect,
                                         font: UIFont) -> CGRect {
        CGRect(x: rowRect.minX + Layout.textInset,
               y: backgroundRect.midY - font.lineHeight * 0.5,
               width: max(0, rowRect.width - Layout.textInset * 2),
               height: font.lineHeight)
    }

    #if DEBUG
    var visibleRowTextsForTesting: [String] {
        visibleRows().map(\.text)
    }

    var primaryRowMetricsForTesting: DebugOverlayTilesPrimaryRowMetrics? {
        guard visibleRows().contains(where: {
            if case .tile = $0 {
                return true
            }
            return false
        }) else {
            return nil
        }

        let rowRect = CGRect(x: 0, y: 0, width: bounds.width, height: Layout.rowHeight)
        let backgroundRect = Self.progressBackgroundRect(for: rowRect)
        let font = UIFont.monospacedSystemFont(ofSize: Layout.primaryFontSize, weight: .heavy)
        return DebugOverlayTilesPrimaryRowMetrics(
            progressBackgroundRect: backgroundRect,
            textRect: Self.centeredTextRect(rowRect: rowRect,
                                            backgroundRect: backgroundRect,
                                            font: font),
            fontSize: Layout.primaryFontSize)
    }

    func simulateTileRowTapForTesting(at index: Int) {
        guard tiles.indices.contains(index) else { return }
        toggleTileExpansion(tiles[index].tile)
    }

    func simulateParseStageTapForTesting(tile: Tile) {
        toggleParseExpansion(tile)
    }
    #endif
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

    func simulateAtlasTabSelectionForTesting() {
        tabControl.selectedSegmentIndex = SelectedTab.atlas.rawValue
        tabControlChanged()
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

    func simulateEarthSceneSwitchForTesting(_ isEnabled: Bool) {
        earthSceneSwitch.setOn(isEnabled, animated: false)
        earthSceneSwitchChanged()
    }

    func simulateRoadLabelTilesSwitchChangeForTesting(_ isOn: Bool) {
        roadLabelTilesSwitch.setOn(isOn, animated: false)
        roadLabelTilesSwitchChanged()
    }

    var isAtlasTabSelectedForTesting: Bool {
        selectedTab == .atlas
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
        [axesLabel, axesSwitch, tileLayersLabel, tileLayersSwitch, wireframeLabel, wireframeSwitch,
         earthSceneLabel, earthSceneSwitch, surfaceModeButton]
            .allSatisfy { $0.isHidden == false }
    }

    var isEarthSceneSwitchOnForTesting: Bool {
        earthSceneSwitch.isOn
    }

    var isRoadLabelTilesSwitchOnForTesting: Bool {
        roadLabelTilesSwitch.isOn
    }

    var isStatsContentVisibleForTesting: Bool {
        [zoomLabel, latLonLabel, diagnosticsLabel].allSatisfy { $0.isHidden == false }
    }

    var isAtlasContentVisibleForTesting: Bool {
        atlasScrollView.isHidden == false
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

    var tilesStatusVisibleRowTextsForTesting: [String] {
        tilesStatusListView.visibleRowTextsForTesting
    }

    var tilesStatusPrimaryRowMetricsForTesting: DebugOverlayTilesPrimaryRowMetrics? {
        tilesStatusListView.primaryRowMetricsForTesting
    }

    func simulateTilesStatusRowTapForTesting(at index: Int) {
        tilesStatusListView.simulateTileRowTapForTesting(at: index)
        setNeedsLayout()
        layoutIfNeeded()
    }

    func simulateTilesStatusParseStageTapForTesting(tile: Tile) {
        tilesStatusListView.simulateParseStageTapForTesting(tile: tile)
        setNeedsLayout()
        layoutIfNeeded()
    }

    var isTilesScrollEnabledForTesting: Bool {
        tilesScrollView.isScrollEnabled
    }

    var atlasPreviewPageCountForTesting: Int {
        atlasLayoutView.pageCount
    }

    var debugPanelFrameForTesting: CGRect {
        containerView.frame
    }

    var isAtlasScrollEnabledForTesting: Bool {
        atlasScrollView.isScrollEnabled
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
