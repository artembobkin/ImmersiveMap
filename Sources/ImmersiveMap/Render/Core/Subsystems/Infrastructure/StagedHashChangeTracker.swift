// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  StagedHashChangeTracker.swift
//  ImmersiveMap
//

import Foundation

/// Tracks hash changes across frame stages.
/// `stage` records pending changes and `commitPending` confirms successful application.
struct StagedHashChangeTracker {
    private var committedHash: Int = Int.min
    private var pendingHash: Int?

    var hasPendingChange: Bool {
        return pendingHash != nil
    }

    /// Stages a new hash and returns `true` only when caller should re-run expensive work.
    /// Re-staging the same pending hash returns `false`.
    mutating func stage(_ hash: Int) -> Bool {
        if let pendingHash {
            guard pendingHash != hash else {
                return false
            }
            self.pendingHash = hash
            return true
        }

        guard committedHash != hash else {
            return false
        }

        pendingHash = hash
        return true
    }

    mutating func commitPending() {
        guard let pendingHash else {
            return
        }

        committedHash = pendingHash
        self.pendingHash = nil
    }

    mutating func invalidate() {
        committedHash = Int.min
        pendingHash = nil
    }
}
