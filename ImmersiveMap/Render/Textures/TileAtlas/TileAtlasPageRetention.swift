// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Гистерезис выгрузки страниц глобусного атласа. Страницы (86 МиБ каждая при
/// 4096 px с мипами) нужны только spherical-режиму, но освобождать их сразу на
/// границе глобус/плоскость нельзя: осцилляция зума вокруг порога перехода
/// пересоздавала бы сотни МиБ текстур каждые несколько кадров. Страницы
/// отпускаются после устойчивого пребывания в flat; возврат на глобус стоит
/// одной перерисовки страниц по актуальному плану атласа.
struct TileAtlasPageRetention {
    /// Секунды flat-рендера, после которых страницы атласа выгружаются.
    static let releaseDelay: TimeInterval = 5

    private var lastSphericalTime: TimeInterval?

    /// Вызывается раз в кадр. Возвращает true ровно один раз, когда страницы
    /// пора выгрузить: карта дольше `releaseDelay` в flat, а страницы ещё живы.
    mutating func shouldReleasePages(isSpherical: Bool,
                                     hasPages: Bool,
                                     time: TimeInterval) -> Bool {
        if isSpherical {
            lastSphericalTime = time
            return false
        }
        guard hasPages else {
            lastSphericalTime = nil
            return false
        }
        guard let lastSphericalTime else {
            // Страницы есть, а глобусного кадра ещё не видели: отсчёт с текущего
            // кадра, чтобы не выгружать по «бесконечно давнему» глобусу.
            self.lastSphericalTime = time
            return false
        }
        if time - lastSphericalTime >= Self.releaseDelay {
            self.lastSphericalTime = nil
            return true
        }
        return false
    }
}
