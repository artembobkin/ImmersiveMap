// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  AvatarCollisionMath.swift
//  ImmersiveMap
//

import Foundation
import simd

/// Стейтлес-математика Zenly-подобного размещения аватаров: коэффициент
/// сглаживания, давление плотности анкеров, цели сжатия и запасные направления
/// разведения для совпадающих центров.
enum AvatarCollisionMath {
    /// Смещение считается сошедшимся, когда до цели меньше этого порога.
    static let offsetSnapEpsilonPx: Float = 0.5
    /// Масштаб/морф считаются сошедшимися при такой близости к цели.
    static let scaleSnapEpsilon: Float = 0.01
    /// Доля размера маркера: радиус слипания анкеров для overflow-группировки.
    static let groupingRadiusScale: Float = 0.35
    /// Расширение радиуса слипания для уже сгруппированных маркеров (гистерезис).
    static let groupingHysteresisRatio: Float = 1.3
    /// Длительность кроссфейда маркеры <-> кластер-иконка.
    static let clusterCrossfadeSeconds: Float = 0.25
    /// Ограничение кадрового шага времени: защита от прыжков после пауз.
    static let maxFrameDeltaSeconds: TimeInterval = 0.25
    /// Масштаб сжатия, ниже которого бейджи полностью скрыты.
    static let badgeFadeStartScale: Float = 0.8
    /// Масштаб сжатия, начиная с которого бейджи полностью видимы.
    static let badgeFadeEndScale: Float = 0.95
    /// Доля радиуса тела: детерминированный стартовый джиттер узлов. Ломает
    /// вырожденные конфигурации (коллинеарные якоря разводились бы строго
    /// вдоль одной линии и никогда не раскрывались бы веером).
    static let startJitterScale: Float = 0.05
    /// Решённое смещение меньше этого порога считается нулевым: гасит след
    /// стартового джиттера у одиночных маркеров.
    static let restSnapRadiusPx: Float = 1.5
    /// Соль для направления стартового джиттера.
    static let startJitterSalt: UInt64 = 0x517cc1b727220a95

    /// Доля пути к цели за кадр для экспоненциального сглаживания,
    /// нормированная к длительности кадра (не зависит от fps).
    static func smoothingFactor(smoothing: Float, deltaSeconds: TimeInterval) -> Float {
        let clamped = simd_clamp(smoothing, 0.0, 1.0)
        guard deltaSeconds > 0 else {
            return 0.0
        }
        return 1.0 - pow(1.0 - clamped, Float(deltaSeconds * 60.0))
    }

    /// Детерминированное направление разведения пары узлов, когда их центры
    /// совпадают и нормаль столкновения не определена.
    static func stableUnitDirection(idA: UInt64, idB: UInt64) -> SIMD2<Float> {
        var hash: UInt64 = 0xcbf29ce484222325
        for id in [min(idA, idB), max(idA, idB)] {
            var value = id
            for _ in 0..<8 {
                hash ^= UInt64(UInt8(truncatingIfNeeded: value))
                hash &*= 0x100000001b3
                value >>= 8
            }
        }
        let angle = Float(hash % 6283) * 0.001
        return SIMD2<Float>(cos(angle), sin(angle))
    }

    /// Базовый масштаб сдвинутого кружка: кружок всегда заметно меньше пина.
    /// При тесноте кружок сжимается дальше, но не ниже compressedScale.
    static let displacedCircleScale: Float = 0.7

    /// Глубина взаимного проникновения тел, при которой касание считается
    /// полным для статической проверки формы.
    static let staticTouchDepthPx: Float = 8.0

    /// Морф по фактическому касанию: полное тело маркера на якоре против
    /// фактических (уже уменьшенных) тел соседей. Пока видимого касания нет,
    /// маркер не реагирует - сосед-кружок не «давит» с дистанции.
    static func staticTouchMorph(overlapDepth: Float) -> Float {
        smoothstep(edge0: 0.0, edge1: staticTouchDepthPx, x: overlapDepth)
    }

    /// Верхняя граница масштаба по форме: пин - полный размер, сдвинутый
    /// кружок - не больше displacedCircleScale.
    static func scaleCap(morph: Float) -> Float {
        1.0 + (displacedCircleScale - 1.0) * simd_clamp(morph, 0.0, 1.0)
    }

    /// Масштаб, при котором пара тел перестаёт пересекаться на данной
    /// дистанции; сжатие вынужденное, распределяется на оба тела поровну.
    /// `otherIsRigid` - сосед не сжимается (выбранный или цветок): вся
    /// нехватка места ложится на текущий маркер.
    static func requiredScale(distance: Float,
                              bodyRadius: Float,
                              otherBodyRadius: Float,
                              padding: Float,
                              otherIsRigid: Bool) -> Float {
        let available = distance - 2.0 * padding
        guard bodyRadius > 0.0 else {
            return 1.0
        }
        let scale: Float
        if otherIsRigid {
            scale = (available - otherBodyRadius) / bodyRadius
        } else {
            scale = available / (bodyRadius + otherBodyRadius)
        }
        return simd_clamp(scale, 0.0, 1.0)
    }

    /// Максимум лепестков цветка-кластера; не вместившиеся участники скрыты.
    static let maxFlowerPetals = 7

    /// Кластер обязан быть локальным: разброс экранных якорей его участников
    /// не превышает этот множитель от размера маркера. Компоненты-переростки
    /// (перколяция цепочек группировки на плотном поле) режутся мировой
    /// сеткой, а слияния колец, нарушающие лимит, запрещаются.
    static let flowerCompactnessLimitScale: Float = 2.5

    /// Радиус кольца слотов цветка: соседние лепестки касаются друг друга.
    static func flowerRingRadius(petalBodyRadius: Float, petalCount: Int) -> Float {
        guard petalCount > 1 else {
            return 0.0
        }
        return petalBodyRadius / sin(.pi / Float(petalCount))
    }

    /// Позиция лепестка на кольце цветка; первый лепесток сверху.
    static func flowerPetalOffset(index: Int, petalCount: Int, ringRadius: Float) -> SIMD2<Float> {
        guard petalCount > 0 else {
            return .zero
        }
        let angle = Float.pi / 2.0 + 2.0 * .pi * Float(index) / Float(petalCount)
        return SIMD2<Float>(cos(angle), sin(angle)) * ringRadius
    }

    /// Смещение, с которого сдвинутый маркер начинает превращаться в кружок.
    static let displacedMorphStartPx: Float = 2.0
    /// Смещение, при котором маркер полностью превращается в кружок с лучом.
    static let displacedMorphEndPx: Float = 10.0

    /// Морф формы пин -> круг: форму пина маркер имеет только стоя ровно на
    /// своей геоточке; любой сдвинутый соседями маркер становится кружком.
    static func displacedMorph(offsetLength: Float) -> Float {
        smoothstep(edge0: displacedMorphStartPx, edge1: displacedMorphEndPx, x: offsetLength)
    }

    /// Альфа бейджей: при сжатии маркера бейджи плавно скрываются.
    static func badgeContentAlpha(displayScale: Float) -> Float {
        smoothstep(edge0: badgeFadeStartScale, edge1: badgeFadeEndScale, x: displayScale)
    }

    static func smoothstep(edge0: Float, edge1: Float, x: Float) -> Float {
        let t = simd_clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0)
        return t * t * (3.0 - 2.0 * t)
    }
}
