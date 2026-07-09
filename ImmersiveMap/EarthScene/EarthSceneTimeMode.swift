// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

public enum EarthSceneTimeMode: Equatable {
    case realtime
    case fixed(Date)

    func resolvedDate(now: Date = Date()) -> Date {
        switch self {
        case .realtime:
            now
        case let .fixed(date):
            date
        }
    }
}
