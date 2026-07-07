// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

// Бизнес-назначение:
// Централизованно управляет окнами повторных попыток загрузки тайлов,
// чтобы карта не создавала request-storm при постоянных ошибках.
// Контроллер хранит per-tile backoff и глобальный cooldown (например для auth/rate-limit),
// а также дает единое решение: можно ли прямо сейчас снова запрашивать конкретный тайл.
// Глобальный cooldown нужен как аварийный предохранитель при системных сбоях:
// при 401/403 (проблема авторизации) и 429 (перегрузка/rate-limit) он временно
// притормаживает весь поток tile-запросов, чтобы не бомбить API каждым тайлом отдельно.
enum TileRetryFailureReason {
    case download(TileDownloader.DownloadFailure)
    case parseFailed
}

final class TileRetryController {
    struct Policy {
        var baseBackoff: TimeInterval
        var maxBackoff: TimeInterval
        var parseFailureCooldown: TimeInterval
        var notFoundCooldown: TimeInterval
        var missingAuthorizationTokenCooldown: TimeInterval
        var authCooldown: TimeInterval
        var genericClientCooldown: TimeInterval
        var rateLimitCooldown: TimeInterval
        var globalAuthCooldown: TimeInterval
        var globalRateLimitCooldown: TimeInterval
        var maxExponent: Int

        static let `default` = Policy(baseBackoff: 0.5,
                                      maxBackoff: 30.0,
                                      parseFailureCooldown: 120.0,
                                      notFoundCooldown: 600.0,
                                      missingAuthorizationTokenCooldown: 30.0,
                                      authCooldown: 30.0,
                                      genericClientCooldown: 60.0,
                                      rateLimitCooldown: 5.0,
                                      globalAuthCooldown: 15.0,
                                      globalRateLimitCooldown: 2.0,
                                      maxExponent: 6)
    }

    private struct RetryState {
        let failureCount: Int
        let nextRetryAt: Date
    }

    private var retryStateByTile: [Tile: RetryState] = [:]
    private var globalRetryBlockedUntil: Date?
    private let policy: Policy
    private let nowProvider: () -> Date

    // Создает контроллер retry-политики с источником текущего времени
    // (в проде - реальное время, в тестах - управляемые часы).
    init(policy: Policy, now: @escaping () -> Date = Date.init) {
        self.policy = policy
        self.nowProvider = now
    }

    // Возвращает, нужно ли сейчас блокировать запрос конкретного тайла
    // с учетом глобального cooldown и индивидуального backoff этого тайла.
    func shouldBlock(tile: Tile) -> Bool {
        let now = nowProvider()
        clearExpiredGlobalBlockIfNeeded(now: now)

        if let blockedUntil = globalRetryBlockedUntil, now < blockedUntil {
            return true
        }
        if let retryState = retryStateByTile[tile], now < retryState.nextRetryAt {
            return true
        }
        return false
    }

    // Фиксирует успешную загрузку/парс тайла и сбрасывает его retry-state.
    func registerSuccess(for tile: Tile) {
        retryStateByTile.removeValue(forKey: tile)
        clearExpiredGlobalBlockIfNeeded(now: nowProvider())
    }

    // Регистрирует неуспешную попытку тайла, рассчитывает следующий retry window
    // и при необходимости расширяет глобальный cooldown.
    func registerFailure(for tile: Tile, reason: TileRetryFailureReason) {
        let now = nowProvider()
        let failureCount = retryStateByTile[tile]?.failureCount ?? 0
        let retryDelay = retryDelay(for: reason, failureCount: failureCount)
        let nextRetryAt = now.addingTimeInterval(retryDelay)
        retryStateByTile[tile] = RetryState(failureCount: failureCount + 1, nextRetryAt: nextRetryAt)

        if let globalDelay = globalRetryDelay(for: reason) {
            let nextGlobalRetryAt = now.addingTimeInterval(globalDelay)
            if let currentGlobalBlockedUntil = globalRetryBlockedUntil {
                globalRetryBlockedUntil = max(currentGlobalBlockedUntil, nextGlobalRetryAt)
            } else {
                globalRetryBlockedUntil = nextGlobalRetryAt
            }
        }
    }

    // Ближайший БУДУЩИЙ момент, когда хотя бы один заблокированный тайл снова
    // станет доступен для запроса. Нужен планировщику, чтобы разбудить on-demand
    // рендер-цикл к истечению backoff-окна: сам контроллер пассивен и таймеров
    // не держит. Уже истёкшие окна не учитываются: их тайлы разблокированы и
    // будут ретраены ближайшим кадром, а истёкшая запись (она живёт до
    // registerSuccess/retainOnly) не должна маскировать будущие окна других
    // тайлов. При активном глобальном cooldown возвращает его границу -
    // раньше неё не разблокируется ни один тайл.
    func earliestNextRetryDate() -> Date? {
        let now = nowProvider()
        clearExpiredGlobalBlockIfNeeded(now: now)

        if let globalRetryBlockedUntil {
            return globalRetryBlockedUntil
        }
        return retryStateByTile.values.map(\.nextRetryAt).filter { $0 > now }.min()
    }

    // Оставляет retry-state только для актуального набора тайлов, чтобы
    // не держать устаревшее состояние для тайлов вне текущего интереса.
    func retainOnly(tiles: Set<Tile>) {
        retryStateByTile = retryStateByTile.filter { tiles.contains($0.key) }
        clearExpiredGlobalBlockIfNeeded(now: nowProvider())
    }

    // Полностью очищает retry-state (тайловый и глобальный cooldown).
    func reset() {
        retryStateByTile.removeAll()
        globalRetryBlockedUntil = nil
    }

    // Снимает глобальную блокировку, если ее срок уже истек.
    private func clearExpiredGlobalBlockIfNeeded(now: Date) {
        if let blockedUntil = globalRetryBlockedUntil, blockedUntil <= now {
            globalRetryBlockedUntil = nil
        }
    }

    // Выбирает задержку retry для конкретной причины ошибки.
    private func retryDelay(for reason: TileRetryFailureReason, failureCount: Int) -> TimeInterval {
        switch reason {
        case .parseFailed:
            return policy.parseFailureCooldown
        case let .download(downloadFailure):
            switch downloadFailure {
            case .missingAuthorizationToken:
                return policy.missingAuthorizationTokenCooldown
            case .unauthorized, .forbidden:
                return policy.authCooldown
            case .notFound, .gone:
                return policy.notFoundCooldown
            case let .rateLimited(retryAfter):
                return max(retryAfter ?? 0, policy.rateLimitCooldown)
            case .client(_):
                return policy.genericClientCooldown
            case .server(_), .network, .nonHTTPResponse, .emptyBody:
                return exponentialBackoff(failureCount: failureCount)
            }
        }
    }

    // Возвращает задержку глобального cooldown для "глобальных" ошибок
    // (например auth/rate-limit), либо nil если нужен только per-tile backoff.
    private func globalRetryDelay(for reason: TileRetryFailureReason) -> TimeInterval? {
        switch reason {
        case .parseFailed:
            return nil
        case let .download(downloadFailure):
            switch downloadFailure {
            case .missingAuthorizationToken, .unauthorized, .forbidden:
                return policy.globalAuthCooldown
            case let .rateLimited(retryAfter):
                return max(retryAfter ?? 0, policy.globalRateLimitCooldown)
            case .notFound, .gone, .server(_), .client(_), .nonHTTPResponse, .emptyBody, .network:
                return nil
            }
        }
    }

    // Экспоненциальный backoff для временных/сетевых ошибок.
    private func exponentialBackoff(failureCount: Int) -> TimeInterval {
        let exponent = min(failureCount, policy.maxExponent)
        let delay = policy.baseBackoff * pow(2.0, Double(exponent))
        return min(delay, policy.maxBackoff)
    }
}
