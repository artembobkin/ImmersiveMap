// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  AvatarCollisionLayoutSolver.swift
//  ImmersiveMap
//

import CoreGraphics
import Foundation
import simd

/// Проекция маркера на экран до разрешения коллизий.
struct AvatarProjectedMarker {
    let marker: AvatarMarker
    let squashScale: SIMD2<Float>
    let screenPoint: ScreenPointOutput
    /// Мировая (нормализованная меркаторная) позиция якоря: стабильная при
    /// пане основа для разреза размазанных куч мировой сеткой.
    let worldPosition: SIMD2<Double>
    let drawOrder: Int

    init(marker: AvatarMarker,
         squashScale: SIMD2<Float>,
         screenPoint: ScreenPointOutput,
         worldPosition: SIMD2<Double>? = nil,
         drawOrder: Int) {
        self.marker = marker
        self.squashScale = squashScale
        self.screenPoint = screenPoint
        // Запасной вариант для синтетических вызовов (тесты): любое линейное
        // отображение экрана в «мир» согласовано с разрезом по сетке.
        self.worldPosition = worldPosition
            ?? SIMD2<Double>(Double(screenPoint.position.x) * 0.001,
                             Double(screenPoint.position.y) * 0.001)
        self.drawOrder = drawOrder
    }
}

/// Итог размещения одного маркера: смещённая экранная точка, истинный якорь
/// (проекция геопозиции) и текущая форма (пин на месте или сдвинутый кружок).
struct AvatarCollisionMarkerItem {
    let marker: AvatarMarker
    let squashScale: SIMD2<Float>
    let screenPoint: ScreenPointOutput
    let anchorScreenPoint: ScreenPointOutput
    let displayScale: Float
    let morph: Float
    /// Лепесток цветка: стоит в слоте кольца и не двигается коррекциями.
    let isFlowerPetal: Bool
    let drawOrder: Int
}

/// Метаданные цветка-кластера: состав кучи и видимые лепестки. Рендерится
/// цветок обычными marker item-ами; структура нужна интроспекции и тестам.
struct AvatarFlowerGroup {
    let memberIDs: [UInt64]
    let visibleMemberIDs: [UInt64]
    let center: SIMD2<Float>
}

/// Экранная геометрия маркера, нужная солверу: тело маркера смещено вверх от
/// якоря (низ пина стоит на геоточке), поэтому коллизии решаются по центрам
/// тел, а не по якорям - иначе маркеры разного масштаба наезжают друг на друга.
struct AvatarCollisionGeometry {
    /// Полный размер маркера (для порогов группировки).
    let markerSizePx: Float
    /// Радиус тела пина при масштабе 1 (полуширина скруглённого квадрата).
    let bodyRadiusPx: Float
    /// Видимый радиус кружка (морф 1) при масштабе 1: вписанный круг тела.
    let circleBodyRadiusPx: Float
    /// Вертикальный сдвиг центра тела от якоря при масштабе 1.
    let bodyCenterOffsetPx: Float

    /// Номинальный радиус тела для текущей формы: пин шире кружка, и расчёт
    /// по пиновому радиусу оставлял бы видимую щель между кружками.
    func bodyRadius(morph: Float) -> Float {
        bodyRadiusPx + (circleBodyRadiusPx - bodyRadiusPx) * simd_clamp(morph, 0.0, 1.0)
    }
}

struct AvatarCollisionLayout {
    static let empty = AvatarCollisionLayout(markerItems: [],
                                             flowerGroups: [],
                                             hasActiveAnimations: false)

    let markerItems: [AvatarCollisionMarkerItem]
    let flowerGroups: [AvatarFlowerGroup]
    let hasActiveAnimations: Bool
}

/// Zenly-подобное размещение аватаров: маркеры расталкиваются кругами в
/// screen-space (Gauss-Seidel с пружиной к якорю); форма пина - только у
/// маркера, стоящего ровно на геоточке, сдвинутый маркер - уменьшенный кружок
/// с конусом к геоточке; плотные кучи раскладываются «цветком» из лепестков,
/// не вместившиеся участники скрываются. Держит межкадровое состояние для
/// плавных, независимых от fps переходов.
final class AvatarCollisionLayoutSolver {

    private struct MarkerMotionState {
        var offset: SIMD2<Float>
        var scale: Float
        var morph: Float
        var clusterBlend: Float
        var lastClusterKey: UInt64?
    }

    private struct ClusterMotionState {
        var presence: Float
        var memberIDs: [UInt64]
    }

    private struct ClusterSeed {
        let stateKey: UInt64
        /// Индексы участников во входе кадра, по возрастанию (id-порядок).
        /// Состав хранится индексами: копирование массивов маркеров с их
        /// ссылками на картинки было заметной статьёй расходов мега-кучи.
        let memberIndexes: [Int]
        let memberIDs: [UInt64]
        /// Центроид экранных якорей участников.
        let anchor: SIMD2<Float>
        /// Габариты экранных якорей: лимит компактности слияний.
        let boundsMin: SIMD2<Float>
        let boundsMax: SIMD2<Float>
        /// Позиция кольца: центроид якорей, при разведении пересекающихся
        /// несливаемых колец может быть смещена.
        var center: SIMD2<Float>
    }

    private struct SolverNode {
        let anchor: SIMD2<Float>
        var position: SIMD2<Float>
        let radius: Float
        let inverseMass: Float
        let directionKey: UInt64
    }

    private var markerStates: [UInt64: MarkerMotionState] = [:]
    /// Ключ - минимальный id участника: сохраняет состояние при смене состава.
    private var clusterStates: [UInt64: ClusterMotionState] = [:]
    private var previouslyGroupedMarkerIDs: Set<UInt64> = []
    private var lastTime: TimeInterval?

    func solve(projectedMarkers: [AvatarProjectedMarker],
               geometry: AvatarCollisionGeometry,
               config: ImmersiveMapSettings.AvatarSettings,
               time: TimeInterval) -> AvatarCollisionLayout {
        defer { lastTime = time }
        guard projectedMarkers.isEmpty == false else {
            markerStates.removeAll(keepingCapacity: true)
            clusterStates.removeAll(keepingCapacity: true)
            previouslyGroupedMarkerIDs.removeAll(keepingCapacity: true)
            return .empty
        }

        let deltaSeconds = min(max(time - (lastTime ?? time), 0.0),
                               AvatarCollisionMath.maxFrameDeltaSeconds)
        let smoothingK = AvatarCollisionMath.smoothingFactor(smoothing: config.smoothing,
                                                             deltaSeconds: deltaSeconds)
        let blendStep = Float(deltaSeconds) / max(AvatarCollisionMath.clusterCrossfadeSeconds, 0.001)
        let markerSizePx = geometry.markerSizePx
        let compressedScale = min(config.compressedScale, 1.0)
        let petalBodyRadius = geometry.circleBodyRadiusPx * compressedScale

        // Вход почти всегда уже упорядочен по id; сортировка - страховка для
        // произвольных вызовов (полная сортировка 30k каждый кадр заметна).
        var inputIsSorted = true
        for index in 1..<projectedMarkers.count
        where projectedMarkers[index - 1].marker.id >= projectedMarkers[index].marker.id {
            inputIsSorted = false
            break
        }
        let input = inputIsSorted
            ? projectedMarkers
            : projectedMarkers.sorted { $0.marker.id < $1.marker.id }
        var unsettled = false

        // Прошлокадровый состав групп: гистерезис группировки и распознавание
        // стационарно скрытых участников, чьё состояние уже сброшено.
        let groupedLastFrame = previouslyGroupedMarkerIDs

        // Кластер обязан быть локальным: лимит разброса экранных якорей
        // одного цветка режет перколяцию цепочек и каскады слияний.
        let compactnessLimit = markerSizePx * AvatarCollisionMath.flowerCompactnessLimitScale

        // Группировка: legacy event-кластеры + overflow-кучи с гистерезисом.
        let eventSeeds = eventClusterSeeds(input: input, markerSizePx: markerSizePx, config: config)
        let eventClusteredIDs = Set(eventSeeds.flatMap(\.memberIDs))
        let overflowSeeds = overflowClusterSeeds(input: input,
                                                 excluded: eventClusteredIDs,
                                                 markerSizePx: markerSizePx,
                                                 compactnessLimit: compactnessLimit,
                                                 config: config)

        // Цветки и жёсткие тела не могут уступать друг другу, поэтому
        // конфликты между ними разрешаются составом: пересекающиеся кольцами
        // цветки сливаются; выбранный маркер, касающийся цветка телом, входит
        // в него лепестком; маркер с якорем внутри кольца поглощается.
        var clusterSeeds = mergeIntersectingFlowers((eventSeeds + overflowSeeds),
                                                    input: input,
                                                    petalBodyRadius: petalBodyRadius,
                                                    compactnessLimit: compactnessLimit)
        var clusteredFlags = [Bool](repeating: false, count: input.count)
        for seed in clusterSeeds {
            for memberIndex in seed.memberIndexes {
                clusteredFlags[memberIndex] = true
            }
        }
        var standaloneIndexes = input.indices.filter { clusteredFlags[$0] == false }
        absorbMarkersIntoFlowers(seeds: &clusterSeeds,
                                 standaloneIndexes: &standaloneIndexes,
                                 input: input,
                                 geometry: geometry,
                                 petalBodyRadius: petalBodyRadius,
                                 config: config)
        clusterSeeds = mergeIntersectingFlowers(clusterSeeds,
                                                input: input,
                                                petalBodyRadius: petalBodyRadius,
                                                compactnessLimit: compactnessLimit)
            .sorted { $0.stateKey < $1.stateKey }

        // Кольца несливаемых соседей (лимит компактности) разводятся до
        // непересечения: лепестки разных цветков не накладываются.
        separateFlowerRings(&clusterSeeds, petalBodyRadius: petalBodyRadius)

        // Гистерезис следующего кадра держит расширенный радиус для всех
        // участников цветков (поглощённые и слитые - тоже часть кучи).
        var groupedThisFrame = Set<UInt64>(minimumCapacity: input.count)
        for seed in clusterSeeds {
            groupedThisFrame.formUnion(seed.memberIDs)
        }
        previouslyGroupedMarkerIDs = groupedThisFrame

        let standaloneMarkers = standaloneIndexes.map { input[$0] }

        // В каждой куче касающихся маркеров есть доминант: он сохраняет форму
        // пина и не сдвигается, уступают (кружками) только остальные.
        let dominantIDs = dominantMarkerIDs(standaloneMarkers: standaloneMarkers,
                                            clusterSeeds: clusterSeeds,
                                            geometry: geometry,
                                            config: config)

        // Двухпрогонная схема без межкадровой обратной связи (радиус узла от
        // сглаженного морфа осциллировал на границе контакта): прогон A с
        // полноразмерными телами решает, кто сдвинут; прогон B с радиусами по
        // морф-целям A даёт финальные позиции. Обе цели - чистые непрерывные
        // функции якорей, поэтому размер и форма не дёргаются.
        var probeNodes = makeNodes(standaloneMarkers: standaloneMarkers,
                                   clusterSeeds: clusterSeeds,
                                   dominantIDs: dominantIDs,
                                   geometry: geometry,
                                   config: config,
                                   nodeShapeForMarker: { _, _ in (scale: 1.0, bodyRadius: geometry.bodyRadiusPx) })
        relax(nodes: &probeNodes, config: config)
        var fullBodyMorphs: [Float] = []
        fullBodyMorphs.reserveCapacity(standaloneMarkers.count)
        for index in standaloneMarkers.indices {
            let probeOffset = probeNodes[index].position - probeNodes[index].anchor
            fullBodyMorphs.append(AvatarCollisionMath.displacedMorph(offsetLength: simd_length(probeOffset)))
        }

        // Промежуточный прогон с формами по A1 определяет фактические позиции
        // и размеры соседей для статической проверки касания.
        var shapedProbeNodes = makeNodes(standaloneMarkers: standaloneMarkers,
                                         clusterSeeds: clusterSeeds,
                                         dominantIDs: dominantIDs,
                                         geometry: geometry,
                                         config: config,
                                         nodeShapeForMarker: { _, index in
                                             (scale: AvatarCollisionMath.scaleCap(morph: fullBodyMorphs[index]),
                                              bodyRadius: geometry.bodyRadius(morph: fullBodyMorphs[index]))
                                         })
        relax(nodes: &shapedProbeNodes, config: config)

        // Физичность формы: маркер становится кружком, только если его
        // полноразмерное тело на якоре фактически касается уже уменьшенных
        // тел соседей. Сосед-кружок не «давит» с дистанции своего полного
        // радиуса. Кандидаты - через сетку: вклад в глубину дают только тела
        // ближе суммы максимальных радиусов, дальние дают отрицательную
        // глубину и на максимум не влияют.
        var maxStandaloneSizeScale: Float = 0.0
        for projected in standaloneMarkers {
            maxStandaloneSizeScale = max(maxStandaloneSizeScale, projected.marker.screenSizeScale)
        }
        var morphTargets: [Float] = []
        morphTargets.reserveCapacity(standaloneMarkers.count)
        if standaloneMarkers.isEmpty == false {
            var maxProbeRadius: Float = 1.0
            var shapedPositions = [SIMD2<Float>](repeating: .zero, count: shapedProbeNodes.count)
            for index in shapedProbeNodes.indices {
                maxProbeRadius = max(maxProbeRadius, shapedProbeNodes[index].radius)
                shapedPositions[index] = shapedProbeNodes[index].position
            }
            let touchCellSize = geometry.bodyRadiusPx * max(maxStandaloneSizeScale, 1.0) + maxProbeRadius
            let touchGrid = AvatarScreenHashGrid(positions: shapedPositions, cellSize: touchCellSize)
            var touchCandidates: [Int] = []

            for (index, projected) in standaloneMarkers.enumerated() {
                guard fullBodyMorphs[index] > 0.0 else {
                    morphTargets.append(0.0)
                    continue
                }
                let screenSizeScale = projected.marker.screenSizeScale
                let fullBodyCenter = projected.screenPoint.position
                    + SIMD2<Float>(0.0, geometry.bodyCenterOffsetPx * screenSizeScale)
                let fullBodyRadius = geometry.bodyRadiusPx * screenSizeScale
                var maxOverlapDepth: Float = 0.0
                touchGrid.collectCandidates(around: fullBodyCenter, into: &touchCandidates)
                for otherIndex in touchCandidates where otherIndex != index {
                    let otherBodyRadius = shapedProbeNodes[otherIndex].radius - config.collisionPaddingPx
                    let distance = simd_length(fullBodyCenter - shapedProbeNodes[otherIndex].position)
                    maxOverlapDepth = max(maxOverlapDepth, fullBodyRadius + otherBodyRadius - distance)
                }
                let touchMorph = AvatarCollisionMath.staticTouchMorph(overlapDepth: maxOverlapDepth)
                morphTargets.append(min(fullBodyMorphs[index], touchMorph))
            }
        }

        var nodes = makeNodes(standaloneMarkers: standaloneMarkers,
                              clusterSeeds: clusterSeeds,
                              dominantIDs: dominantIDs,
                              geometry: geometry,
                              config: config,
                              nodeShapeForMarker: { _, index in
                                  (scale: AvatarCollisionMath.scaleCap(morph: morphTargets[index]),
                                   bodyRadius: geometry.bodyRadius(morph: morphTargets[index]))
                              })
        relax(nodes: &nodes, config: config)

        // Сжатие кружков вынужденное и переменное: базовый сдвинутый кружок -
        // displacedCircleScale, при тесноте сжимается по финальным дистанциям
        // прогона B, но не ниже лимита compressedScale. Соседи - через сетку:
        // на требуемый масштаб влияют только тела в пределах суммы радиусов.
        var targetScales: [Float] = []
        targetScales.reserveCapacity(standaloneMarkers.count)
        if standaloneMarkers.isEmpty == false {
            var maxNodeRadius: Float = 1.0
            var nodePositions = [SIMD2<Float>](repeating: .zero, count: nodes.count)
            for index in nodes.indices {
                maxNodeRadius = max(maxNodeRadius, nodes[index].radius)
                nodePositions[index] = nodes[index].position
            }
            let scaleCellSize = max(geometry.bodyRadiusPx * max(maxStandaloneSizeScale, 1.0), maxNodeRadius)
                * 2.0 + 2.0 * config.collisionPaddingPx
            let scaleGrid = AvatarScreenHashGrid(positions: nodePositions, cellSize: scaleCellSize)
            var scaleCandidates: [Int] = []

            for (index, projected) in standaloneMarkers.enumerated() {
                // Форма определяется прогоном A: пин - только когда полноразмерному
                // маркеру хватает места стоять на геоточке. Иначе в пограничной
                // зоне (полные тела толкаются, кружки - нет) пины пересекались бы.
                let morphTarget = morphTargets[index]
                let capScale = AvatarCollisionMath.scaleCap(morph: morphTarget)
                var scale = capScale
                let isRigid = projected.marker.isSelected || dominantIDs.contains(projected.marker.id)
                if isRigid == false, morphTarget > 0.0 {
                    let bodyRadius = geometry.bodyRadius(morph: morphTarget) * projected.marker.screenSizeScale
                    var required: Float = 1.0
                    scaleGrid.collectNeighbors(ofPointAt: index, greaterThan: Int.min, into: &scaleCandidates)
                    for otherIndex in scaleCandidates where otherIndex != index {
                        let distance = simd_length(nodes[index].position - nodes[otherIndex].position)
                        let otherIsMarker = otherIndex < standaloneMarkers.count
                        let otherBodyRadius = otherIsMarker
                            ? geometry.bodyRadius(morph: morphTargets[otherIndex]) * standaloneMarkers[otherIndex].marker.screenSizeScale
                            : nodes[otherIndex].radius - config.collisionPaddingPx
                        let otherIsRigid = otherIsMarker
                            ? (standaloneMarkers[otherIndex].marker.isSelected
                                || dominantIDs.contains(standaloneMarkers[otherIndex].marker.id))
                            : true
                        guard distance < bodyRadius + otherBodyRadius + 2.0 * config.collisionPaddingPx else {
                            continue
                        }
                        required = min(required, AvatarCollisionMath.requiredScale(distance: distance,
                                                                                   bodyRadius: bodyRadius,
                                                                                   otherBodyRadius: otherBodyRadius,
                                                                                   padding: config.collisionPaddingPx,
                                                                                   otherIsRigid: otherIsRigid))
                    }
                    let lowerLimit = min(compressedScale, capScale)
                    scale = max(min(required, capScale), lowerLimit)
                } else if projected.marker.isSelected {
                    scale = 1.0
                }
                targetScales.append(scale)
            }
        }

        var markerItems: [AvatarCollisionMarkerItem] = []
        markerItems.reserveCapacity(input.count)
        var flowerGroups: [AvatarFlowerGroup] = []
        flowerGroups.reserveCapacity(clusterSeeds.count)
        var clusterCentersByKey: [UInt64: SIMD2<Float>] = [:]
        var seenClusterKeys = Set<UInt64>()
        var seenMarkerIDs = Set<UInt64>()

        // Принадлежность кластеру по индексу входа: выбор лепестков и
        // продвижение скрытых участников без полного скана мега-состава.
        var seedIndexByInputIndex = [Int](repeating: -1, count: input.count)
        for (seedIndex, seed) in clusterSeeds.enumerated() {
            for memberIndex in seed.memberIndexes {
                seedIndexByInputIndex[memberIndex] = seedIndex
            }
        }
        var selectedIndexesBySeed = [[Int]](repeating: [], count: clusterSeeds.count)
        for index in input.indices where input[index].marker.isSelected {
            let seedIndex = seedIndexByInputIndex[index]
            if seedIndex >= 0 {
                selectedIndexesBySeed[seedIndex].append(index)
            }
        }

        // Живые цветки: кольцо на центре кучи (центроид якорей, возможно
        // разведённый от соседних колец), раскладка лепестков.
        for (seedIndex, seed) in clusterSeeds.enumerated() {
            seenClusterKeys.insert(seed.stateKey)
            var state = clusterStates[seed.stateKey] ?? ClusterMotionState(presence: 1.0,
                                                                           memberIDs: seed.memberIDs)
            let presenceActive = advanceBlend(&state.presence, target: 1.0, step: blendStep)
            state.memberIDs = seed.memberIDs
            unsettled = unsettled || presenceActive
            clusterStates[seed.stateKey] = state

            let flowerCenter = seed.center
            clusterCentersByKey[seed.stateKey] = flowerCenter

            let petalCount = min(seed.memberIndexes.count, AvatarCollisionMath.maxFlowerPetals)
            let ringRadius = AvatarCollisionMath.flowerRingRadius(petalBodyRadius: petalBodyRadius,
                                                                  petalCount: petalCount)
            // Выбранные участники гарантированно среди видимых лепестков и
            // первыми; добор - младшие id (состав отсортирован, добор
            // обходит только префикс, а не весь мега-состав).
            var visibleMemberIndexes: [Int] = []
            visibleMemberIndexes.reserveCapacity(petalCount)
            for selectedIndex in selectedIndexesBySeed[seedIndex] {
                visibleMemberIndexes.append(selectedIndex)
                if visibleMemberIndexes.count == petalCount { break }
            }
            if visibleMemberIndexes.count < petalCount {
                for memberIndex in seed.memberIndexes where input[memberIndex].marker.isSelected == false {
                    visibleMemberIndexes.append(memberIndex)
                    if visibleMemberIndexes.count == petalCount { break }
                }
            }
            flowerGroups.append(AvatarFlowerGroup(memberIDs: seed.memberIDs,
                                                  visibleMemberIDs: visibleMemberIndexes.map { input[$0].marker.id },
                                                  center: flowerCenter))

            for (slotIndex, memberIndex) in visibleMemberIndexes.enumerated() {
                let member = input[memberIndex]
                let slotCenter = flowerCenter
                    + AvatarCollisionMath.flowerPetalOffset(index: slotIndex,
                                                            petalCount: petalCount,
                                                            ringRadius: ringRadius)
                emitPetal(member: member,
                          slotCenter: slotCenter,
                          stateKey: seed.stateKey,
                          wasGroupedLastFrame: groupedLastFrame.contains(member.marker.id),
                          geometry: geometry,
                          compressedScale: compressedScale,
                          smoothingK: smoothingK,
                          blendStep: blendStep,
                          unsettled: &unsettled,
                          seenMarkerIDs: &seenMarkerIDs,
                          markerItems: &markerItems)
            }
        }

        // Скрытые участники цветков: стационарные состояния не имеют и не
        // требуют работы, поэтому продвигаются только живые межкадровые
        // состояния (единицы), а не весь мега-состав. Лепестки уже учтены
        // и пропускаются по seenMarkerIDs.
        if markerStates.isEmpty == false, clusterSeeds.isEmpty == false {
            for id in markerStates.keys.sorted() where seenMarkerIDs.contains(id) == false {
                guard let inputIndex = Self.inputIndex(ofID: id, in: input) else { continue }
                let seedIndex = seedIndexByInputIndex[inputIndex]
                guard seedIndex >= 0 else { continue }
                emitHiddenMember(member: input[inputIndex],
                                 flowerCenter: clusterSeeds[seedIndex].center,
                                 stateKey: clusterSeeds[seedIndex].stateKey,
                                 geometry: geometry,
                                 compressedScale: compressedScale,
                                 smoothingK: smoothingK,
                                 blendStep: blendStep,
                                 unsettled: &unsettled,
                                 seenMarkerIDs: &seenMarkerIDs,
                                 markerItems: &markerItems)
            }
        }

        // Распавшиеся цветки: центр ещё нужен вылетающим участникам, пока
        // гаснет presence. Карта участник -> ключ позволяет стационарно
        // скрытым (без состояния) начать вылет из центра распавшейся кучи.
        var dissolvedKeyByMemberID: [UInt64: UInt64] = [:]
        for key in clusterStates.keys.sorted() where seenClusterKeys.contains(key) == false {
            guard var state = clusterStates[key] else { continue }
            var anchor = SIMD2<Float>.zero
            var memberCount = 0
            for memberID in state.memberIDs {
                guard let member = Self.projectedMarker(withID: memberID, in: input) else { continue }
                anchor += member.screenPoint.position
                memberCount += 1
            }
            guard memberCount > 0 else {
                clusterStates.removeValue(forKey: key)
                continue
            }
            let presenceActive = advanceBlend(&state.presence, target: 0.0, step: blendStep)
            guard state.presence > 0.0 else {
                clusterStates.removeValue(forKey: key)
                continue
            }
            unsettled = unsettled || presenceActive
            clusterStates[key] = state

            clusterCentersByKey[key] = anchor / Float(memberCount)
            for memberID in state.memberIDs where dissolvedKeyByMemberID[memberID] == nil {
                dissolvedKeyByMemberID[memberID] = key
            }
        }

        // Одиночные маркеры: сглаживание смещения/масштаба/морфа, вылет из
        // цветка.
        for (index, projected) in standaloneMarkers.enumerated() {
            let id = projected.marker.id
            seenMarkerIDs.insert(id)
            let targetOffset = nodes[index].position - nodes[index].anchor
            // Форму пина маркер имеет только когда полноразмерному телу
            // хватает места на геоточке (морф-цель прогона A).
            let targetMorph = morphTargets[index]
            var state: MarkerMotionState
            if let existing = markerStates[id] {
                state = existing
            } else if groupedLastFrame.contains(id),
                      let dissolvedKey = dissolvedKeyByMemberID[id] {
                // Стационарно скрытый участник распавшейся кучи (состояние
                // сброшено): проявляется вылетом из гаснущего центра цветка.
                state = MarkerMotionState(offset: targetOffset,
                                          scale: targetScales[index],
                                          morph: targetMorph,
                                          clusterBlend: 1.0,
                                          lastClusterKey: dissolvedKey)
            } else {
                state = MarkerMotionState(offset: targetOffset,
                                          scale: targetScales[index],
                                          morph: targetMorph,
                                          clusterBlend: 0.0,
                                          lastClusterKey: nil)
            }
            let offsetActive = smoothToward(&state.offset,
                                            target: targetOffset,
                                            factor: smoothingK,
                                            epsilon: AvatarCollisionMath.offsetSnapEpsilonPx)
            let scaleActive = smoothToward(&state.scale,
                                           target: targetScales[index],
                                           factor: smoothingK,
                                           epsilon: AvatarCollisionMath.scaleSnapEpsilon)
            let morphActive = smoothToward(&state.morph,
                                           target: targetMorph,
                                           factor: smoothingK,
                                           epsilon: AvatarCollisionMath.scaleSnapEpsilon)
            let blendActive = advanceBlend(&state.clusterBlend, target: 0.0, step: blendStep)
            unsettled = unsettled || offsetActive || scaleActive || morphActive || blendActive

            // Поправка якоря: центр фактического (сжатого) тела остаётся в
            // точке, решённой прогоном B для тела масштаба scaleCap(morph A).
            let nodeScale = AvatarCollisionMath.scaleCap(morph: morphTargets[index])
            let bodyCenterLift = geometry.bodyCenterOffsetPx * projected.marker.screenSizeScale
                * (nodeScale - state.scale)
            var position = projected.screenPoint.position + state.offset
                + SIMD2<Float>(0.0, bodyCenterLift)
            var alphaFactor: Float = 1.0
            if state.clusterBlend > 0.0 {
                if let clusterKey = state.lastClusterKey,
                   let center = clusterCentersByKey[clusterKey] {
                    let ease = AvatarCollisionMath.smoothstep(edge0: 0.0, edge1: 1.0, x: state.clusterBlend)
                    position += (center - position) * ease
                    alphaFactor = 1.0 - state.clusterBlend
                } else {
                    state.clusterBlend = 0.0
                }
            }
            if state.clusterBlend <= 0.0 {
                state.lastClusterKey = nil
            }
            markerStates[id] = state

            var screenPoint = projected.screenPoint
            screenPoint.position = position
            screenPoint.visibilityAlpha *= alphaFactor
            markerItems.append(AvatarCollisionMarkerItem(marker: projected.marker,
                                                         squashScale: projected.squashScale,
                                                         screenPoint: screenPoint,
                                                         anchorScreenPoint: projected.screenPoint,
                                                         displayScale: state.scale,
                                                         morph: state.morph,
                                                         isFlowerPetal: false,
                                                         drawOrder: projected.drawOrder))
        }

        for id in Array(markerStates.keys) where seenMarkerIDs.contains(id) == false {
            markerStates.removeValue(forKey: id)
        }

        // Жёсткая гарантия кадра: сглаживание отстаёт от целей, и в переходных
        // кадрах тела могут наложиться. Финальный проход разрешает перекрытия
        // отображаемых тел напрямую; в сошедшемся состоянии он нулевой и не
        // трогает межкадровое состояние.
        resolveDisplayedOverlaps(markerItems: &markerItems,
                                 geometry: geometry,
                                 compressedScale: compressedScale)

        markerItems.sort {
            if $0.drawOrder != $1.drawOrder {
                return $0.drawOrder < $1.drawOrder
            }
            return $0.marker.id < $1.marker.id
        }

        return AvatarCollisionLayout(markerItems: markerItems,
                                     flowerGroups: flowerGroups,
                                     hasActiveAnimations: unsettled)
    }

    /// Микрокоррекция отображаемых позиций: устраняет краткие наложения
    /// фактических тел во время анимаций. Работает поверх сглаженного
    /// состояния и не пишет в него, поэтому не влияет на сходимость.
    private func resolveDisplayedOverlaps(markerItems: inout [AvatarCollisionMarkerItem],
                                          geometry: AvatarCollisionGeometry,
                                          compressedScale: Float) {
        guard markerItems.count > 1 else { return }

        var centers: [SIMD2<Float>] = []
        var radii: [Float] = []
        var inverseMasses: [Float] = []
        centers.reserveCapacity(markerItems.count)
        radii.reserveCapacity(markerItems.count)
        inverseMasses.reserveCapacity(markerItems.count)
        for item in markerItems {
            let bodyScale = item.displayScale * item.marker.screenSizeScale
            centers.append(item.screenPoint.position
                + SIMD2<Float>(0.0, geometry.bodyCenterOffsetPx * bodyScale))
            // Тающие участники кластерного кроссфейда пролетают сквозь
            // остальных: нулевой радиус исключает их из коррекции.
            let isFadingThrough = item.screenPoint.visibilityAlpha
                < item.anchorScreenPoint.visibilityAlpha * 0.99
            radii.append(isFadingThrough ? 0.0 : geometry.bodyRadius(morph: item.morph) * bodyScale)
            // Пины (morph 0) и лепестки цветка стоят на месте, уступают
            // только свободные кружки.
            let isImmovable = item.marker.isSelected || item.isFlowerPetal
            inverseMasses.append(isImmovable ? 0.0 : item.morph)
        }

        // Пары ищутся через сетку по твёрдым (ненулевой радиус) телам. Пары
        // тающих между собой невозможны (minDistance 0), тающие против
        // твёрдых проверяются точечными запросами - иначе транзиент
        // схлопывания большой кучи (тысячи тающих в одной точке) снова
        // давал бы квадратичный перебор.
        var solidIndices: [Int] = []
        var fadingIndices: [Int] = []
        var maxSolidRadius: Float = 1.0
        for index in radii.indices {
            if radii[index] > 0.0 {
                solidIndices.append(index)
                maxSolidRadius = max(maxSolidRadius, radii[index])
            } else {
                fadingIndices.append(index)
            }
        }
        let cellSize = 2.0 * maxSolidRadius
        var solidPositions = [SIMD2<Float>](repeating: .zero, count: solidIndices.count)
        var candidates: [Int] = []

        func resolvePair(_ lhsIndex: Int, _ rhsIndex: Int) {
            var lhsInverseMass = inverseMasses[lhsIndex]
            var rhsInverseMass = inverseMasses[rhsIndex]
            let bothPetals = markerItems[lhsIndex].isFlowerPetal && markerItems[rhsIndex].isFlowerPetal
            if bothPetals {
                // Лепестки неподвижны только для одиночных кружков. Пара
                // лепестков разных цветков - два «неподвижных» тела: в
                // сверхплотной мозаике колец сепарация центров развести их
                // не может, и без взаимной уступки наложение замерзало бы.
                lhsInverseMass = markerItems[lhsIndex].marker.isSelected ? 0.0 : 1.0
                rhsInverseMass = markerItems[rhsIndex].marker.isSelected ? 0.0 : 1.0
            }
            let inverseMassSum = lhsInverseMass + rhsInverseMass
            guard inverseMassSum > 0 else { return }
            let minDistance = radii[lhsIndex] + radii[rhsIndex]
            let delta = centers[rhsIndex] - centers[lhsIndex]
            let distanceSquared = simd_length_squared(delta)
            guard distanceSquared < minDistance * minDistance else { return }
            let distance = distanceSquared.squareRoot()
            let overlap = minDistance - distance
            // Слоты одного кольца касаются впритык: микрошум флоатов не
            // должен расталкивать собственные лепестки цветка.
            if bothPetals, overlap <= 1.0 { return }
            let direction = distance > 1e-4
                ? delta / distance
                : AvatarCollisionMath.stableUnitDirection(idA: markerItems[lhsIndex].marker.id,
                                                          idB: markerItems[rhsIndex].marker.id)
            centers[lhsIndex] -= direction * overlap * (lhsInverseMass / inverseMassSum)
            centers[rhsIndex] += direction * overlap * (rhsInverseMass / inverseMassSum)
        }

        // Кандидатные пары собираются один раз: за итерации коррекции тела
        // смещаются в пределах радиуса, радиусный запас это покрывает.
        for (localIndex, itemIndex) in solidIndices.enumerated() {
            solidPositions[localIndex] = centers[itemIndex]
        }
        let grid = AvatarScreenHashGrid(positions: solidPositions, cellSize: cellSize)
        var pairs: [(Int, Int)] = []
        for fadingIndex in fadingIndices {
            grid.collectCandidates(around: centers[fadingIndex], into: &candidates)
            for localIndex in candidates {
                let solidIndex = solidIndices[localIndex]
                let reach = radii[fadingIndex] + radii[solidIndex] + maxSolidRadius
                if simd_length_squared(centers[fadingIndex] - centers[solidIndex]) < reach * reach {
                    pairs.append((min(fadingIndex, solidIndex), max(fadingIndex, solidIndex)))
                }
            }
        }
        for (localIndex, itemIndex) in solidIndices.enumerated() {
            grid.collectNeighbors(ofPointAt: localIndex,
                                  greaterThan: localIndex,
                                  into: &candidates)
            for otherLocalIndex in candidates {
                let otherIndex = solidIndices[otherLocalIndex]
                let reach = radii[itemIndex] + radii[otherIndex] + maxSolidRadius
                if simd_length_squared(centers[itemIndex] - centers[otherIndex]) < reach * reach {
                    pairs.append((itemIndex, otherIndex))
                }
            }
        }

        // Плотная мозаика колец сходится медленно: пара, разведённая на
        // первой итерации, создаёт наложение со следующим соседом.
        for _ in 0..<20 {
            for pair in pairs {
                resolvePair(pair.0, pair.1)
            }
        }

        // Рассинхрон мозаики: солвер сжимал кружки по слотам колец, а
        // фактические лепестки сдвинуты коррекцией. Кружок, зажатый между
        // неподвижными для него телами, дожимается по фактическим дистанциям
        // (в пределах лимита сжатия), после чего позиции доразглаживаются.
        var scaleAdjusted = false
        for pair in pairs {
            let residualMinDistance = radii[pair.0] + radii[pair.1]
            let delta = centers[pair.1] - centers[pair.0]
            let distanceSquared = simd_length_squared(delta)
            guard residualMinDistance > 0.5,
                  distanceSquared < (residualMinDistance - 0.5) * (residualMinDistance - 0.5) else {
                continue
            }
            let distance = distanceSquared.squareRoot()
            for (candidateIndex, otherIndex) in [(pair.0, pair.1), (pair.1, pair.0)] {
                let item = markerItems[candidateIndex]
                guard item.isFlowerPetal == false,
                      item.marker.isSelected == false,
                      item.morph > 0.5,
                      radii[candidateIndex] > 0 else {
                    continue
                }
                let unitBodyRadius = geometry.bodyRadius(morph: item.morph) * item.marker.screenSizeScale
                guard unitBodyRadius > 0 else { continue }
                let required = (distance - radii[otherIndex]) / unitBodyRadius
                let lowerLimit = min(compressedScale, item.displayScale)
                let newScale = max(min(required, item.displayScale), lowerLimit)
                guard newScale < item.displayScale - 0.005 else { continue }
                markerItems[candidateIndex] = AvatarCollisionMarkerItem(marker: item.marker,
                                                                        squashScale: item.squashScale,
                                                                        screenPoint: item.screenPoint,
                                                                        anchorScreenPoint: item.anchorScreenPoint,
                                                                        displayScale: newScale,
                                                                        morph: item.morph,
                                                                        isFlowerPetal: item.isFlowerPetal,
                                                                        drawOrder: item.drawOrder)
                radii[candidateIndex] = unitBodyRadius * newScale
                scaleAdjusted = true
            }
        }
        if scaleAdjusted {
            for _ in 0..<8 {
                for pair in pairs {
                    resolvePair(pair.0, pair.1)
                }
            }
        }

        for index in markerItems.indices {
            let item = markerItems[index]
            let bodyScale = item.displayScale * item.marker.screenSizeScale
            let correctedPosition = centers[index]
                - SIMD2<Float>(0.0, geometry.bodyCenterOffsetPx * bodyScale)
            guard simd_length(correctedPosition - item.screenPoint.position) > 0.01 else { continue }
            var screenPoint = item.screenPoint
            screenPoint.position = correctedPosition
            markerItems[index] = AvatarCollisionMarkerItem(marker: item.marker,
                                                           squashScale: item.squashScale,
                                                           screenPoint: screenPoint,
                                                           anchorScreenPoint: item.anchorScreenPoint,
                                                           displayScale: item.displayScale,
                                                           morph: item.morph,
                                                           isFlowerPetal: item.isFlowerPetal,
                                                           drawOrder: item.drawOrder)
        }
    }

    // MARK: - Лепестки цветка

    /// Лепесток - обычный маркер, чья цель смещения задана слотом на кольце
    /// цветка: перелёт в слот и обратно идёт тем же сглаживанием, что и
    /// расталкивание.
    private func emitPetal(member: AvatarProjectedMarker,
                           slotCenter: SIMD2<Float>,
                           stateKey: UInt64,
                           wasGroupedLastFrame: Bool,
                           geometry: AvatarCollisionGeometry,
                           compressedScale: Float,
                           smoothingK: Float,
                           blendStep: Float,
                           unsettled: inout Bool,
                           seenMarkerIDs: inout Set<UInt64>,
                           markerItems: inout [AvatarCollisionMarkerItem]) {
        let id = member.marker.id
        seenMarkerIDs.insert(id)
        let screenSizeScale = member.marker.screenSizeScale
        // Целевое смещение кладёт центр тела лепестка ровно в слот.
        let targetOffset = slotCenter - member.screenPoint.position
            - SIMD2<Float>(0.0, geometry.bodyCenterOffsetPx * screenSizeScale * compressedScale)
        // Стационарно скрытый участник состояния не имеет (оно сброшено);
        // выход в лепестки начинается с blend 1 - проявление фейдом, как
        // раньше со «живым» скрытым состоянием.
        var state = markerStates[id] ?? MarkerMotionState(offset: targetOffset,
                                                          scale: compressedScale,
                                                          morph: 1.0,
                                                          clusterBlend: wasGroupedLastFrame ? 1.0 : 0.0,
                                                          lastClusterKey: stateKey)
        state.lastClusterKey = stateKey
        let offsetActive = smoothToward(&state.offset,
                                        target: targetOffset,
                                        factor: smoothingK,
                                        epsilon: AvatarCollisionMath.offsetSnapEpsilonPx)
        let scaleActive = smoothToward(&state.scale,
                                       target: compressedScale,
                                       factor: smoothingK,
                                       epsilon: AvatarCollisionMath.scaleSnapEpsilon)
        let morphActive = smoothToward(&state.morph,
                                       target: 1.0,
                                       factor: smoothingK,
                                       epsilon: AvatarCollisionMath.scaleSnapEpsilon)
        let blendActive = advanceBlend(&state.clusterBlend, target: 0.0, step: blendStep)
        unsettled = unsettled || offsetActive || scaleActive || morphActive || blendActive
        markerStates[id] = state

        var screenPoint = member.screenPoint
        screenPoint.position = member.screenPoint.position + state.offset
        screenPoint.visibilityAlpha *= 1.0 - state.clusterBlend
        markerItems.append(AvatarCollisionMarkerItem(marker: member.marker,
                                                     squashScale: member.squashScale,
                                                     screenPoint: screenPoint,
                                                     anchorScreenPoint: member.screenPoint,
                                                     displayScale: state.scale,
                                                     morph: state.morph,
                                                     isFlowerPetal: true,
                                                     drawOrder: member.drawOrder))
    }

    /// Не вместившийся в цветок участник: тает, слетаясь к центру цветка.
    private func emitHiddenMember(member: AvatarProjectedMarker,
                                  flowerCenter: SIMD2<Float>,
                                  stateKey: UInt64,
                                  geometry: AvatarCollisionGeometry,
                                  compressedScale: Float,
                                  smoothingK: Float,
                                  blendStep: Float,
                                  unsettled: inout Bool,
                                  seenMarkerIDs: inout Set<UInt64>,
                                  markerItems: inout [AvatarCollisionMarkerItem]) {
        let id = member.marker.id
        // Стационарно скрытый участник: состояния нет - создавать нечего,
        // анимировать нечего, не рисуется. Ранний выход делает спокойный
        // мировой зум с десятками тысяч скрытых участников почти бесплатным.
        guard var state = markerStates[id] else { return }
        seenMarkerIDs.insert(id)
        state.lastClusterKey = stateKey
        let blendActive = advanceBlend(&state.clusterBlend, target: 1.0, step: blendStep)
        let offsetActive = smoothToward(&state.offset,
                                        target: .zero,
                                        factor: smoothingK,
                                        epsilon: AvatarCollisionMath.offsetSnapEpsilonPx)
        let scaleActive = smoothToward(&state.scale,
                                       target: compressedScale,
                                       factor: smoothingK,
                                       epsilon: AvatarCollisionMath.scaleSnapEpsilon)
        let morphActive = smoothToward(&state.morph,
                                       target: 1.0,
                                       factor: smoothingK,
                                       epsilon: AvatarCollisionMath.scaleSnapEpsilon)
        unsettled = unsettled || blendActive || offsetActive || scaleActive || morphActive

        // Полностью растаявший участник устоялся: состояние сбрасывается, на
        // повторное появление лепестком/одиночкой укажет прошлокадровый
        // состав группы (groupedLastFrame).
        if state.clusterBlend >= 0.999,
           blendActive == false, offsetActive == false,
           scaleActive == false, morphActive == false {
            markerStates.removeValue(forKey: id)
            return
        }
        markerStates[id] = state

        guard state.clusterBlend < 0.999 else { return }
        let ease = AvatarCollisionMath.smoothstep(edge0: 0.0, edge1: 1.0, x: state.clusterBlend)
        let base = member.screenPoint.position + state.offset
        var screenPoint = member.screenPoint
        screenPoint.position = base + (flowerCenter - base) * ease
        screenPoint.visibilityAlpha *= 1.0 - state.clusterBlend
        markerItems.append(AvatarCollisionMarkerItem(marker: member.marker,
                                                     squashScale: member.squashScale,
                                                     screenPoint: screenPoint,
                                                     anchorScreenPoint: member.screenPoint,
                                                     displayScale: state.scale,
                                                     morph: state.morph,
                                                     isFlowerPetal: false,
                                                     drawOrder: member.drawOrder))
    }

    // MARK: - Группировка

    private func eventClusterSeeds(input: [AvatarProjectedMarker],
                                   markerSizePx: Float,
                                   config: ImmersiveMapSettings.AvatarSettings) -> [ClusterSeed] {
        let threshold = max(1.0, markerSizePx + config.collisionPaddingPx * 2.0)
        let thresholdSquared = threshold * threshold
        let candidateIndexes = input.indices.filter { input[$0].marker.clusterPolicy == .event }
        return connectedGroups(of: candidateIndexes,
                               in: input,
                               maxJoinDistance: threshold) { lhs, rhs in
            simd_length_squared(lhs.screenPoint.position - rhs.screenPoint.position) <= thresholdSquared
        }
        .filter { $0.count > 1 }
        .map { makeSeed(memberIndexes: $0, input: input) }
    }

    private func overflowClusterSeeds(input: [AvatarProjectedMarker],
                                      excluded: Set<UInt64>,
                                      markerSizePx: Float,
                                      compactnessLimit: Float,
                                      config: ImmersiveMapSettings.AvatarSettings) -> [ClusterSeed] {
        let enterRadius = markerSizePx * AvatarCollisionMath.groupingRadiusScale
        let exitRadius = enterRadius * AvatarCollisionMath.groupingHysteresisRatio
        let candidateIndexes = excluded.isEmpty
            ? Array(input.indices)
            : input.indices.filter { excluded.contains(input[$0].marker.id) == false }
        let previouslyGrouped = previouslyGroupedMarkerIDs
        let components = connectedGroups(of: candidateIndexes,
                                         in: input,
                                         maxJoinDistance: exitRadius) { lhs, rhs in
            // Расширенный (гистерезисный) радиус удерживает уже сложившуюся
            // группу, но не затягивает проходящих мимо соседей.
            let widened = previouslyGrouped.contains(lhs.marker.id) && previouslyGrouped.contains(rhs.marker.id)
            let radius = widened ? exitRadius : enterRadius
            return simd_length_squared(lhs.screenPoint.position - rhs.screenPoint.position) <= radius * radius
        }
        // Перколяция цепочек: на плотном поле компонента связности тянется
        // через весь экран, и кольцо получало бы участников за сотни px от
        // себя. Переростки режутся мировой сеткой на локальные кучи.
        return splitSprawlingComponents(components,
                                        input: input,
                                        compactnessLimit: compactnessLimit,
                                        groupingThreshold: config.groupingThreshold)
            // Цветок собирается, когда куча дорастает до порога (и минимум из пары).
            .filter { $0.count > 1 && $0.count >= config.groupingThreshold }
            .map { makeSeed(memberIndexes: $0, input: input) }
    }

    /// Режет компоненты с разбросом экранных якорей больше лимита по мировой
    /// сетке: границы ячеек привязаны к миру (стабильны при пане и повороте),
    /// шаг - степень двойки (меняется октавами зума, скачки состава сглаживает
    /// кроссфейд кластеров). Масштаб пиксель/мир берётся из самих точек.
    private func splitSprawlingComponents(_ components: [[Int]],
                                          input: [AvatarProjectedMarker],
                                          compactnessLimit: Float,
                                          groupingThreshold: Int) -> [[Int]] {
        var result: [[Int]] = []
        result.reserveCapacity(components.count)
        for component in components {
            guard component.count > 1 else {
                result.append(component)
                continue
            }
            var screenMin = input[component[0]].screenPoint.position
            var screenMax = screenMin
            for index in component.dropFirst() {
                let position = input[index].screenPoint.position
                screenMin = simd_min(screenMin, position)
                screenMax = simd_max(screenMax, position)
            }
            let screenDiagonal = simd_length(screenMax - screenMin)
            guard screenDiagonal > compactnessLimit else {
                result.append(component)
                continue
            }

            var worldMin = input[component[0]].worldPosition
            var worldMax = worldMin
            for index in component.dropFirst() {
                let world = input[index].worldPosition
                worldMin = simd_min(worldMin, world)
                worldMax = simd_max(worldMax, world)
            }
            let worldDiagonal = simd_length(worldMax - worldMin)
            guard worldDiagonal > 0 else {
                result.append(component)
                continue
            }

            let pixelsPerWorldUnit = Double(screenDiagonal) / worldDiagonal
            let rawStep = Double(compactnessLimit) / pixelsPerWorldUnit
            let step = pow(2.0, rawStep.isFinite ? floor(log2(rawStep)) : 0.0)
            var cellsBuckets: [SIMD2<Int64>: [Int]] = [:]
            for index in component {
                let world = input[index].worldPosition
                let cell = SIMD2<Int64>(Int64((world.x / step).rounded(.down)),
                                        Int64((world.y / step).rounded(.down)))
                cellsBuckets[cell, default: []].append(index)
            }
            // Порядок словаря недетерминирован: подгруппы сортируются по
            // наименьшему участнику.
            var subgroups = cellsBuckets.values.sorted { ($0.first ?? 0) < ($1.first ?? 0) }

            // Подгруппы-недоборы вливаются в ближайшую полноценную подгруппу
            // той же кучи: свободному кружку внутри сплошной мозаики колец
            // физически нет места - его тело замерзало бы в наложении.
            let seedThreshold = max(groupingThreshold, 2)
            var fullSubgroups: [(subgroupIndex: Int, centroid: SIMD2<Float>)] = []
            for (subgroupIndex, subgroup) in subgroups.enumerated() where subgroup.count >= seedThreshold {
                var centroid = SIMD2<Float>.zero
                for memberIndex in subgroup {
                    centroid += input[memberIndex].screenPoint.position
                }
                fullSubgroups.append((subgroupIndex, centroid / Float(subgroup.count)))
            }
            if fullSubgroups.isEmpty == false {
                for (subgroupIndex, subgroup) in subgroups.enumerated()
                where subgroup.count < seedThreshold {
                    var centroid = SIMD2<Float>.zero
                    for memberIndex in subgroup {
                        centroid += input[memberIndex].screenPoint.position
                    }
                    centroid /= Float(subgroup.count)
                    var nearestIndex = fullSubgroups[0].subgroupIndex
                    var nearestDistance = Float.greatestFiniteMagnitude
                    for candidate in fullSubgroups {
                        let distance = simd_length_squared(candidate.centroid - centroid)
                        if distance < nearestDistance {
                            nearestDistance = distance
                            nearestIndex = candidate.subgroupIndex
                        }
                    }
                    subgroups[nearestIndex].append(contentsOf: subgroup)
                    subgroups[subgroupIndex] = []
                }
                for subgroupIndex in subgroups.indices where subgroups[subgroupIndex].isEmpty == false {
                    subgroups[subgroupIndex].sort()
                }
                subgroups.removeAll(where: \.isEmpty)
            }
            result.append(contentsOf: subgroups)
        }
        return result
    }

    /// Плотная ячейка сетки: столько кандидатов в одной ячейке радиуса
    /// объединения - гарантированно толпа, попарные проверки внутри неё не
    /// нужны (участники и так связались бы цепочками через 3x3 окрестность).
    private static let denseGroupingCellPopulation = 16
    /// Против скольких участников плотной ячейки соседний разреженный маркер
    /// проверяется точно, прежде чем считать, что связи нет.
    private static let denseGroupingProbeLimit = 64

    /// Компоненты связности по парному предикату через пространственную
    /// сетку: cellSize = максимальная дистанция объединения, поэтому все
    /// потенциальные пары лежат в 3x3 окрестности. Плотные ячейки (толпы)
    /// объединяются целиком без попарного перебора - иначе куча в 30k
    /// маркеров на одном экране давала бы сотни миллионов проверок. Кандидаты
    /// приходят по возрастанию (id-порядок), состав групп детерминирован;
    /// возвращаются группы индексов входа.
    private func connectedGroups(of candidateIndexes: [Int],
                                 in input: [AvatarProjectedMarker],
                                 maxJoinDistance: Float,
                                 position: (AvatarProjectedMarker) -> SIMD2<Float> = { $0.screenPoint.position },
                                 joinable: (AvatarProjectedMarker, AvatarProjectedMarker) -> Bool) -> [[Int]] {
        guard candidateIndexes.count > 1 else {
            return []
        }

        let positions = candidateIndexes.map { position(input[$0]) }
        let grid = AvatarScreenHashGrid(positions: positions, cellSize: maxJoinDistance)
        var disjointSet = AvatarDisjointSet(count: candidateIndexes.count)
        var neighbors: [Int] = []

        // Плотные ячейки обрабатываются на уровне ячеек: толпа объединяется
        // целиком, соседние толпы сливаются (их кольца-цветки пересеклись бы
        // и слились составом в любом случае).
        let denseSlots = grid.cellSlots(withPopulationAtLeast: Self.denseGroupingCellPopulation)
        var isDenseSlot = [Bool](repeating: false, count: grid.cellCount)
        for slot in denseSlots {
            isDenseSlot[slot] = true
        }
        for slot in denseSlots {
            let cell = grid.entries(inCellSlot: slot)
            guard let first = cell.first else { continue }
            for other in cell.dropFirst() {
                disjointSet.union(first, other)
            }
            grid.forEachNeighborSlot(of: slot) { neighborSlot in
                guard neighborSlot > slot, isDenseSlot[neighborSlot] else { return }
                if let neighborFirst = grid.entries(inCellSlot: neighborSlot).first {
                    disjointSet.union(first, neighborFirst)
                }
            }
        }

        // Точечный проход - только для точек разреженных ячеек.
        for lhsIndex in candidateIndexes.indices
        where isDenseSlot[grid.cellSlot(ofPointAt: lhsIndex)] == false {
            grid.forEachNeighborCell(ofPointAt: lhsIndex) { cell, _ in
                if cell.count >= Self.denseGroupingCellPopulation {
                    // Разреженный маркер против толпы: точная проверка по
                    // ограниченной выборке (ids в ячейке распределены по
                    // экрану случайно, выборка покрывает её равномерно).
                    var probesLeft = Self.denseGroupingProbeLimit
                    for rhsIndex in cell {
                        if joinable(input[candidateIndexes[lhsIndex]], input[candidateIndexes[rhsIndex]]) {
                            disjointSet.union(lhsIndex, rhsIndex)
                            break
                        }
                        probesLeft -= 1
                        if probesLeft <= 0 { break }
                    }
                    return
                }
                // Разреженные ячейки: точный перебор пар (i, j > i).
                for rhsIndex in cell where rhsIndex > lhsIndex {
                    neighbors.append(rhsIndex)
                }
            }

            if neighbors.isEmpty == false {
                neighbors.sort()
                for rhsIndex in neighbors where joinable(input[candidateIndexes[lhsIndex]], input[candidateIndexes[rhsIndex]]) {
                    disjointSet.union(lhsIndex, rhsIndex)
                }
                neighbors.removeAll(keepingCapacity: true)
            }
        }

        // Компоненты извлекаются без хеширования: корень - минимальный
        // индекс, первая встреча корня задаёт порядок групп, поэтому они
        // сразу отсортированы по наименьшему id.
        var slotOfRoot = [Int](repeating: -1, count: candidateIndexes.count)
        var groupedIndexes: [[Int]] = []
        for index in candidateIndexes.indices {
            let root = disjointSet.find(index)
            var slot = slotOfRoot[root]
            if slot == -1 {
                slot = groupedIndexes.count
                slotOfRoot[root] = slot
                groupedIndexes.append([])
            }
            groupedIndexes[slot].append(index)
        }

        return groupedIndexes.map { indexes in indexes.map { candidateIndexes[$0] } }
    }

    /// Внешний радиус цветка: кольцо слотов плюс тело лепестка.
    private func flowerOuterRadius(memberCount: Int, petalBodyRadius: Float) -> Float {
        let petalCount = min(memberCount, AvatarCollisionMath.maxFlowerPetals)
        return AvatarCollisionMath.flowerRingRadius(petalBodyRadius: petalBodyRadius,
                                                    petalCount: petalCount) + petalBodyRadius
    }

    /// Цветки неподвижны и не могут уступать друг другу: пересекающиеся
    /// кольцами кучи сливаются в один цветок. Слияния идут раундами через
    /// union-find (слияние растит кольцо и может зацепить новых соседей,
    /// поэтому раунды повторяются до неподвижной точки). Слияние, разброс
    /// якорей которого превысил бы лимит компактности, запрещено: каскад
    /// слияний размазывал кластер на пол-экрана, и в него попадали маркеры
    /// вдалеке от кольца.
    private func mergeIntersectingFlowers(_ seeds: [ClusterSeed],
                                          input: [AvatarProjectedMarker],
                                          petalBodyRadius: Float,
                                          compactnessLimit: Float) -> [ClusterSeed] {
        guard seeds.count > 1 else { return seeds }

        let limitSquared = compactnessLimit * compactnessLimit
        var merged = seeds.sorted { $0.stateKey < $1.stateKey }
        while merged.count > 1 {
            var disjointSet = AvatarDisjointSet(count: merged.count)
            var didMerge = false
            for lhsIndex in merged.indices {
                let lhsRadius = flowerOuterRadius(memberCount: merged[lhsIndex].memberIDs.count,
                                                  petalBodyRadius: petalBodyRadius)
                for rhsIndex in (lhsIndex + 1)..<merged.count {
                    let minDistance = lhsRadius
                        + flowerOuterRadius(memberCount: merged[rhsIndex].memberIDs.count,
                                            petalBodyRadius: petalBodyRadius)
                    guard simd_length_squared(merged[lhsIndex].center - merged[rhsIndex].center)
                            < minDistance * minDistance else {
                        continue
                    }
                    let unionMin = simd_min(merged[lhsIndex].boundsMin, merged[rhsIndex].boundsMin)
                    let unionMax = simd_max(merged[lhsIndex].boundsMax, merged[rhsIndex].boundsMax)
                    guard simd_length_squared(unionMax - unionMin) <= limitSquared else {
                        continue
                    }
                    disjointSet.union(lhsIndex, rhsIndex)
                    didMerge = true
                }
            }
            guard didMerge else { break }

            var componentIndexes: [Int: [Int]] = [:]
            for index in merged.indices {
                componentIndexes[disjointSet.find(index), default: []].append(index)
            }
            merged = componentIndexes.keys.sorted().map { root in
                let indexes = componentIndexes[root] ?? []
                guard indexes.count > 1 else { return merged[indexes[0]] }
                var memberIndexes = merged[indexes[0]].memberIndexes
                for otherIndex in indexes.dropFirst() {
                    memberIndexes = Self.mergeSortedIndexes(memberIndexes,
                                                            merged[otherIndex].memberIndexes)
                }
                return makeSeed(memberIndexes: memberIndexes, input: input)
            }
            .sorted { $0.stateKey < $1.stateKey }
        }
        return merged
    }

    /// Пересекающиеся кольца цветков, которым слияние запрещено лимитом
    /// компактности, разводятся: смещается цветок с меньшим составом (при
    /// равенстве - с большим ключом). Гарантия непересечения сохраняется,
    /// одиночные маркеры цветки по-прежнему не двигают.
    private func separateFlowerRings(_ seeds: inout [ClusterSeed],
                                     petalBodyRadius: Float) {
        guard seeds.count > 1 else { return }

        for _ in 0..<8 {
            var moved = false
            for lhsIndex in seeds.indices {
                let lhsRadius = flowerOuterRadius(memberCount: seeds[lhsIndex].memberIDs.count,
                                                  petalBodyRadius: petalBodyRadius)
                for rhsIndex in (lhsIndex + 1)..<seeds.count {
                    let minDistance = lhsRadius
                        + flowerOuterRadius(memberCount: seeds[rhsIndex].memberIDs.count,
                                            petalBodyRadius: petalBodyRadius)
                    let delta = seeds[rhsIndex].center - seeds[lhsIndex].center
                    let distanceSquared = simd_length_squared(delta)
                    guard distanceSquared < minDistance * minDistance else { continue }
                    let distance = distanceSquared.squareRoot()
                    let direction = distance > 1e-4
                        ? delta / distance
                        : AvatarCollisionMath.stableUnitDirection(idA: seeds[lhsIndex].stateKey,
                                                                  idB: seeds[rhsIndex].stateKey)
                    let overlap = minDistance - distance
                    let lhsYields = seeds[lhsIndex].memberIDs.count < seeds[rhsIndex].memberIDs.count
                        || (seeds[lhsIndex].memberIDs.count == seeds[rhsIndex].memberIDs.count
                            && seeds[lhsIndex].stateKey > seeds[rhsIndex].stateKey)
                    if lhsYields {
                        seeds[lhsIndex].center -= direction * overlap
                    } else {
                        seeds[rhsIndex].center += direction * overlap
                    }
                    moved = true
                }
            }
            guard moved else { break }
        }
    }

    /// Слияние двух отсортированных списков индексов за линейное время.
    private static func mergeSortedIndexes(_ lhs: [Int], _ rhs: [Int]) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(lhs.count + rhs.count)
        var lhsIndex = 0
        var rhsIndex = 0
        while lhsIndex < lhs.count, rhsIndex < rhs.count {
            if lhs[lhsIndex] <= rhs[rhsIndex] {
                result.append(lhs[lhsIndex])
                lhsIndex += 1
            } else {
                result.append(rhs[rhsIndex])
                rhsIndex += 1
            }
        }
        result.append(contentsOf: lhs[lhsIndex...])
        result.append(contentsOf: rhs[rhsIndex...])
        return result
    }

    /// Бинарный поиск индекса маркера по id в отсортированном входе кадра.
    private static func inputIndex(ofID id: UInt64,
                                   in input: [AvatarProjectedMarker]) -> Int? {
        var low = 0
        var high = input.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let candidate = input[middle].marker.id
            if candidate == id {
                return middle
            } else if candidate < id {
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return nil
    }

    /// Бинарный поиск маркера по id в отсортированном входе кадра.
    private static func projectedMarker(withID id: UInt64,
                                        in input: [AvatarProjectedMarker]) -> AvatarProjectedMarker? {
        var low = 0
        var high = input.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let candidate = input[middle].marker.id
            if candidate == id {
                return input[middle]
            } else if candidate < id {
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return nil
    }

    /// Поглощение маркеров цветком: выбранный входит лепестком при касании
    /// телом (он неподвижен и не может уступить цветку), обычный маркер
    /// поглощается, когда его якорное тело оказывается внутри кольца - там
    /// пружина навсегда тянула бы его внутрь цветка.
    private func absorbMarkersIntoFlowers(seeds: inout [ClusterSeed],
                                          standaloneIndexes: inout [Int],
                                          input: [AvatarProjectedMarker],
                                          geometry: AvatarCollisionGeometry,
                                          petalBodyRadius: Float,
                                          config: ImmersiveMapSettings.AvatarSettings) {
        guard seeds.isEmpty == false, standaloneIndexes.isEmpty == false else { return }

        var absorbedIndexes = Set<Int>()
        for markerIndex in standaloneIndexes {
            let projected = input[markerIndex]
            let screenSizeScale = projected.marker.screenSizeScale
            let bodyCenter = projected.screenPoint.position
                + SIMD2<Float>(0.0, geometry.bodyCenterOffsetPx * screenSizeScale)
            // Минимально возможное тело: если даже предельно сжатый кружок
            // касается лепестков двух и более цветков, маркер зажат в кармане
            // мозаики - отступать некуда, наложение замерзало бы навсегда.
            let minimalBodyRadius = petalBodyRadius * screenSizeScale
            var touchedSeedCount = 0
            var nearestTouchedSeedIndex = -1
            var nearestTouchedDistance = Float.greatestFiniteMagnitude

            for seedIndex in seeds.indices {
                let seed = seeds[seedIndex]
                let ringRadius = flowerOuterRadius(memberCount: seed.memberIDs.count,
                                                   petalBodyRadius: petalBodyRadius) - petalBodyRadius
                let threshold: Float
                if projected.marker.isSelected {
                    threshold = ringRadius + petalBodyRadius
                        + geometry.bodyRadiusPx * screenSizeScale + config.collisionPaddingPx
                } else {
                    threshold = ringRadius
                }
                if simd_length_squared(bodyCenter - seed.center) < threshold * threshold {
                    seeds[seedIndex] = makeSeed(memberIndexes: Self.mergeSortedIndexes(seed.memberIndexes,
                                                                                       [markerIndex]),
                                                input: input)
                    absorbedIndexes.insert(markerIndex)
                    break
                }
                guard projected.marker.isSelected == false else { continue }
                let petalCount = min(seed.memberIDs.count, AvatarCollisionMath.maxFlowerPetals)
                let slotRing = AvatarCollisionMath.flowerRingRadius(petalBodyRadius: petalBodyRadius,
                                                                    petalCount: petalCount)
                let touchDistance = minimalBodyRadius + petalBodyRadius
                for petalIndex in 0..<petalCount {
                    let slotCenter = seed.center
                        + AvatarCollisionMath.flowerPetalOffset(index: petalIndex,
                                                                petalCount: petalCount,
                                                                ringRadius: slotRing)
                    let distance = simd_length(bodyCenter - slotCenter)
                    if distance < touchDistance {
                        touchedSeedCount += 1
                        if distance < nearestTouchedDistance {
                            nearestTouchedDistance = distance
                            nearestTouchedSeedIndex = seedIndex
                        }
                        break
                    }
                }
            }

            if absorbedIndexes.contains(markerIndex) == false,
               touchedSeedCount >= 2,
               nearestTouchedSeedIndex >= 0 {
                let seed = seeds[nearestTouchedSeedIndex]
                seeds[nearestTouchedSeedIndex] = makeSeed(memberIndexes: Self.mergeSortedIndexes(seed.memberIndexes,
                                                                                                 [markerIndex]),
                                                          input: input)
                absorbedIndexes.insert(markerIndex)
            }
        }
        standaloneIndexes.removeAll { absorbedIndexes.contains($0) }
    }

    private func makeSeed(memberIndexes: [Int], input: [AvatarProjectedMarker]) -> ClusterSeed {
        var memberIDs: [UInt64] = []
        memberIDs.reserveCapacity(memberIndexes.count)
        var anchor = SIMD2<Float>.zero
        var boundsMin = input[memberIndexes[0]].screenPoint.position
        var boundsMax = boundsMin
        for index in memberIndexes {
            let position = input[index].screenPoint.position
            memberIDs.append(input[index].marker.id)
            anchor += position
            boundsMin = simd_min(boundsMin, position)
            boundsMax = simd_max(boundsMax, position)
        }
        let centroid = anchor / Float(memberIndexes.count)
        return ClusterSeed(stateKey: memberIDs[0],
                           memberIndexes: memberIndexes,
                           memberIDs: memberIDs,
                           anchor: centroid,
                           boundsMin: boundsMin,
                           boundsMax: boundsMax,
                           center: centroid)
    }

    // MARK: - Релаксация

    /// Узлы солвера: одиночные маркеры + живые цветки. Узел маркера
    /// центрируется на центре тела (якорь + вертикальный сдвиг по текущему
    /// масштабу) с радиусом фактического размера: кружки прилегают плотно,
    /// пины - на полных дистанциях. Узел цветка накрывает всё кольцо
    /// лепестков. Релаксация стартует с несмещённых позиций: цель тогда -
    /// чистая функция входа, без памяти, иначе недоразрешённые скопления
    /// накапливают вращательный дрейф («карусель») кадр за кадром.
    /// Детерминированный джиттер старта ломает вырожденные конфигурации.
    private func makeNodes(standaloneMarkers: [AvatarProjectedMarker],
                           clusterSeeds: [ClusterSeed],
                           dominantIDs: Set<UInt64>,
                           geometry: AvatarCollisionGeometry,
                           config: ImmersiveMapSettings.AvatarSettings,
                           nodeShapeForMarker: (AvatarProjectedMarker, Int) -> (scale: Float, bodyRadius: Float)) -> [SolverNode] {
        let compressedScale = min(config.compressedScale, 1.0)
        let petalBodyRadius = geometry.circleBodyRadiusPx * compressedScale
        let jitterAmplitude = geometry.bodyRadiusPx * AvatarCollisionMath.startJitterScale
        func startJitter(for key: UInt64) -> SIMD2<Float> {
            AvatarCollisionMath.stableUnitDirection(idA: key,
                                                    idB: AvatarCollisionMath.startJitterSalt) * jitterAmplitude
        }

        var nodes: [SolverNode] = []
        nodes.reserveCapacity(standaloneMarkers.count + clusterSeeds.count)
        for (index, projected) in standaloneMarkers.enumerated() {
            let shape = nodeShapeForMarker(projected, index)
            let screenSizeScale = projected.marker.screenSizeScale
            let bodyCenter = projected.screenPoint.position
                + SIMD2<Float>(0.0, geometry.bodyCenterOffsetPx * shape.scale * screenSizeScale)
            let radius = shape.bodyRadius * shape.scale * screenSizeScale + config.collisionPaddingPx
            let isRigid = projected.marker.isSelected || dominantIDs.contains(projected.marker.id)
            nodes.append(SolverNode(anchor: bodyCenter,
                                    position: bodyCenter + startJitter(for: projected.marker.id),
                                    radius: max(1.0, radius),
                                    inverseMass: isRigid ? 0.0 : 1.0,
                                    directionKey: projected.marker.id))
        }
        // Цветок неподвижен и представлен фактическими лепестками: соседи
        // взаимодействуют с видимыми кружками, а не с невидимым описанным
        // кругом кольца (иначе пин «чувствовал» кластер с дистанции).
        for seed in clusterSeeds {
            let petalCount = min(seed.memberIDs.count, AvatarCollisionMath.maxFlowerPetals)
            let ringRadius = AvatarCollisionMath.flowerRingRadius(petalBodyRadius: petalBodyRadius,
                                                                  petalCount: petalCount)
            for petalIndex in 0..<petalCount {
                let slotCenter = seed.center
                    + AvatarCollisionMath.flowerPetalOffset(index: petalIndex,
                                                            petalCount: petalCount,
                                                            ringRadius: ringRadius)
                nodes.append(SolverNode(anchor: slotCenter,
                                        position: slotCenter,
                                        radius: petalBodyRadius + config.collisionPaddingPx,
                                        inverseMass: 0.0,
                                        directionKey: seed.stateKey &+ UInt64(petalIndex)))
            }
        }
        return nodes
    }

    /// Доминанты куч: в каждой связной компоненте касающихся полноразмерных
    /// тел лучший по рангу (выбранный, затем drawPriority, затем меньший id)
    /// маркер не сдвигается и сохраняет форму пина. Маркер, чьё якорное тело
    /// пересекает цветок, доминантом быть не может: цветок неподвижен, и два
    /// неподвижных тела заморозили бы перекрытие.
    private func dominantMarkerIDs(standaloneMarkers: [AvatarProjectedMarker],
                                   clusterSeeds: [ClusterSeed],
                                   geometry: AvatarCollisionGeometry,
                                   config: ImmersiveMapSettings.AvatarSettings) -> Set<UInt64> {
        guard standaloneMarkers.isEmpty == false else {
            return []
        }

        func bodyCenter(_ projected: AvatarProjectedMarker) -> SIMD2<Float> {
            projected.screenPoint.position
                + SIMD2<Float>(0.0, geometry.bodyCenterOffsetPx * projected.marker.screenSizeScale)
        }
        func bodyRadius(_ projected: AvatarProjectedMarker) -> Float {
            geometry.bodyRadiusPx * projected.marker.screenSizeScale + config.collisionPaddingPx
        }

        var dominants = Set<UInt64>(standaloneMarkers.map(\.marker.id))

        var maxBodyReach: Float = 1.0
        for projected in standaloneMarkers {
            maxBodyReach = max(maxBodyReach, bodyRadius(projected))
        }
        let groups = connectedGroups(of: Array(standaloneMarkers.indices),
                                     in: standaloneMarkers,
                                     maxJoinDistance: 2.0 * maxBodyReach,
                                     position: bodyCenter) { lhs, rhs in
            let minDistance = bodyRadius(lhs) + bodyRadius(rhs)
            return simd_length_squared(bodyCenter(lhs) - bodyCenter(rhs)) < minDistance * minDistance
        }
        for group in groups where group.count > 1 {
            guard group.count == 2 else {
                // Три и более маркеров вплотную показываются кружочками все:
                // доминант-пин с ромашкой вокруг оставлен только для пары.
                for memberIndex in group {
                    dominants.remove(standaloneMarkers[memberIndex].marker.id)
                }
                continue
            }
            let ranked = group.min { lhsIndex, rhsIndex in
                let lhs = standaloneMarkers[lhsIndex]
                let rhs = standaloneMarkers[rhsIndex]
                if lhs.marker.isSelected != rhs.marker.isSelected {
                    return lhs.marker.isSelected
                }
                if lhs.marker.drawPriority != rhs.marker.drawPriority {
                    return lhs.marker.drawPriority > rhs.marker.drawPriority
                }
                return lhs.marker.id < rhs.marker.id
            }
            for memberIndex in group where memberIndex != ranked {
                dominants.remove(standaloneMarkers[memberIndex].marker.id)
            }
        }

        guard clusterSeeds.isEmpty == false else {
            return dominants
        }
        let compressedScale = min(config.compressedScale, 1.0)
        let petalBodyRadius = geometry.circleBodyRadiusPx * compressedScale
        // Слоты лепестков всех цветков собираются в одну сетку: близость к
        // цветку проверяется точечным запросом, а не перебором всех куч.
        var petalSlotCenters: [SIMD2<Float>] = []
        for seed in clusterSeeds {
            let petalCount = min(seed.memberIDs.count, AvatarCollisionMath.maxFlowerPetals)
            let ringRadius = AvatarCollisionMath.flowerRingRadius(petalBodyRadius: petalBodyRadius,
                                                                  petalCount: petalCount)
            for petalIndex in 0..<petalCount {
                petalSlotCenters.append(seed.center
                    + AvatarCollisionMath.flowerPetalOffset(index: petalIndex,
                                                            petalCount: petalCount,
                                                            ringRadius: ringRadius))
            }
        }
        let petalGrid = AvatarScreenHashGrid(positions: petalSlotCenters,
                                             cellSize: maxBodyReach + petalBodyRadius + config.collisionPaddingPx)
        var petalCandidates: [Int] = []
        for projected in standaloneMarkers where projected.marker.isSelected == false {
            let minDistance = bodyRadius(projected) + petalBodyRadius + config.collisionPaddingPx
            let center = bodyCenter(projected)
            petalGrid.collectCandidates(around: center, into: &petalCandidates)
            for petalIndex in petalCandidates
            where simd_length_squared(center - petalSlotCenters[petalIndex]) < minDistance * minDistance {
                dominants.remove(projected.marker.id)
                break
            }
        }
        return dominants
    }

    /// Позиционная релаксация: пружина к якорю, затем разрешение перекрытий
    /// пар (немедленное применение - Gauss-Seidel). Ограничение выноса
    /// применяется один раз к финальной цели: clamp внутри итераций делает
    /// цель разрывной при несовместных ограничениях (толпа больше, чем
    /// допускает maxOffsetPx), и сглаживание никогда не сходится.
    private func relax(nodes: inout [SolverNode], config: ImmersiveMapSettings.AvatarSettings) {
        let maxOffset = max(0.0, config.maxOffsetPx)
        defer {
            for index in nodes.indices {
                let offset = nodes[index].position - nodes[index].anchor
                let length = simd_length(offset)
                if length > maxOffset {
                    nodes[index].position = nodes[index].anchor + offset * (maxOffset / max(length, 1e-6))
                } else if length < AvatarCollisionMath.restSnapRadiusPx {
                    nodes[index].position = nodes[index].anchor
                }
            }
        }

        guard nodes.count > 1 else {
            for index in nodes.indices {
                nodes[index].position = nodes[index].anchor
            }
            return
        }

        let springK = simd_clamp(config.springK, 0.0, 1.0)
        // Кандидатные пары собираются один раз по стартовым позициям (якоря
        // плюс джиттер): cellSize с полуторным запасом покрывает и пары,
        // сближающиеся в ходе итераций. Редкая упущенная пара разрешится
        // resolveDisplayedOverlaps и пересчётом целей в следующем кадре.
        var maxRadius: Float = 1.0
        for node in nodes {
            maxRadius = max(maxRadius, node.radius)
        }
        var positions = [SIMD2<Float>](repeating: .zero, count: nodes.count)
        for index in nodes.indices {
            positions[index] = nodes[index].position
        }
        let grid = AvatarScreenHashGrid(positions: positions, cellSize: 3.0 * maxRadius)
        var pairStarts = [Int](repeating: 0, count: nodes.count + 1)
        var pairNeighbors: [Int32] = []
        var neighbors: [Int] = []
        for index in nodes.indices {
            grid.collectNeighbors(ofPointAt: index, greaterThan: index, into: &neighbors)
            for neighbor in neighbors {
                // Пара остаётся кандидатом, если может коснуться при сближении
                // на бюджет maxRadius; остальное из 3x3 окрестности - шум.
                let reach = nodes[index].radius + nodes[neighbor].radius + maxRadius
                if simd_length_squared(positions[index] - positions[neighbor]) < reach * reach {
                    pairNeighbors.append(Int32(neighbor))
                }
            }
            pairStarts[index + 1] = pairNeighbors.count
        }

        for _ in 0..<max(1, config.collisionIterations) {
            for index in nodes.indices {
                if nodes[index].inverseMass > 0 {
                    nodes[index].position += (nodes[index].anchor - nodes[index].position) * springK
                } else {
                    nodes[index].position = nodes[index].anchor
                }
            }
            for lhsIndex in nodes.indices {
                for pairIndex in pairStarts[lhsIndex]..<pairStarts[lhsIndex + 1] {
                    let rhsIndex = Int(pairNeighbors[pairIndex])
                    let lhs = nodes[lhsIndex]
                    let rhs = nodes[rhsIndex]
                    let inverseMassSum = lhs.inverseMass + rhs.inverseMass
                    guard inverseMassSum > 0 else { continue }
                    let minDistance = lhs.radius + rhs.radius
                    let delta = rhs.position - lhs.position
                    let distanceSquared = simd_length_squared(delta)
                    guard distanceSquared < minDistance * minDistance else { continue }
                    let distance = distanceSquared.squareRoot()
                    let direction = distance > 1e-4
                        ? delta / distance
                        : AvatarCollisionMath.stableUnitDirection(idA: lhs.directionKey,
                                                                  idB: rhs.directionKey)
                    let overlap = minDistance - distance
                    nodes[lhsIndex].position -= direction * overlap * (lhs.inverseMass / inverseMassSum)
                    nodes[rhsIndex].position += direction * overlap * (rhs.inverseMass / inverseMassSum)
                }
            }
        }
    }

    // MARK: - Сглаживание

    /// Двигает значение к цели на долю пути; возвращает true, пока анимация
    /// не сошлась (после снапа к цели возвращает false).
    private func smoothToward(_ value: inout Float, target: Float, factor: Float, epsilon: Float) -> Bool {
        let delta = target - value
        if abs(delta) <= epsilon {
            value = target
            return false
        }
        value += delta * factor
        return true
    }

    private func smoothToward(_ value: inout SIMD2<Float>, target: SIMD2<Float>, factor: Float, epsilon: Float) -> Bool {
        let delta = target - value
        if simd_length(delta) <= epsilon {
            value = target
            return false
        }
        value += delta * factor
        return true
    }

    /// Линейный ход кроссфейда к цели; true, пока не дошёл.
    private func advanceBlend(_ value: inout Float, target: Float, step: Float) -> Bool {
        let delta = target - value
        if abs(delta) <= 0.001 {
            value = target
            return false
        }
        value += delta > 0 ? min(step, delta) : max(-step, delta)
        return true
    }
}

