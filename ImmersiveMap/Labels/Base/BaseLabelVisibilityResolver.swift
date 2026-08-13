// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

enum BaseLabelCollisionVisibility: Equatable {
    case unknown
    case visible
    case hidden

    var collisionFlag: UInt32 {
        switch self {
        case .unknown, .hidden:
            return 1
        case .visible:
            return 0
        }
    }
}

enum BaseLabelVisibilityResolver {
    static let activeAlphaThreshold: Float = 0.0001

    static func targetVisibility(inputs: [BaseLabelPresentationInput],
                                 collisionFlags: [UInt32],
                                 horizonVisibility: [Bool],
                                 cameraZoom: Float,
                                 collisionVisibilityIsFresh: Bool = true) -> [Bool] {
        let collisionVisibility = collisionFlags.map { flag -> BaseLabelCollisionVisibility in
            if collisionVisibilityIsFresh == false {
                return .visible
            }
            return flag == 0 ? .visible : .hidden
        }
        return targetVisibility(inputs: inputs,
                                collisionVisibility: collisionVisibility,
                                horizonVisibility: horizonVisibility,
                                cameraZoom: cameraZoom)
    }

    static func targetVisibility(inputs: [BaseLabelPresentationInput],
                                 collisionVisibility: [BaseLabelCollisionVisibility],
                                 horizonVisibility: [Bool],
                                 cameraZoom: Float) -> [Bool] {
        inputs.indices.map { index in
            let input = inputs[index]
            let collisionHidden = index < collisionVisibility.count ? collisionVisibility[index] != .visible : true
            let horizonVisible = index < horizonVisibility.count ? horizonVisibility[index] : false
            return input.isValid &&
                input.duplicate == 0 &&
                input.isRetained == 0 &&
                collisionHidden == false &&
                horizonVisible &&
                input.minCameraZoom <= cameraZoom
        }
    }

    /// Turns the cache's per-label boxes into the frame's collision candidates.
    ///
    /// The cached boxes are in layout points, because that is what a prepared
    /// tile stores; the screen positions they are paired with are device pixels.
    /// This is where the two meet, so this is where the boxes convert.
    static func collisionCandidates(baseCandidates: [ScreenCollisionCandidate],
                                    screenPoints: [ScreenPointOutput],
                                    horizonVisibility: [Bool],
                                    currentAlphas: [Float],
                                    minCameraZooms: [Float],
                                    cameraZoom: Float,
                                    screenScale: ScreenScale) -> [ScreenCollisionCandidate] {
        var candidates = baseCandidates
        for index in candidates.indices {
            candidates[index].halfSize = screenScale.pixels(candidates[index].halfSize)
        }
        let count = min(candidates.count, screenPoints.count)

        for index in 0..<count {
            let point = screenPoints[index]
            candidates[index].position = point.position

            guard candidates[index].isEnabled,
                  point.visible != 0 else {
                candidates[index].isEnabled = false
                continue
            }

            let horizonVisible = index < horizonVisibility.count ? horizonVisibility[index] : false
            let currentAlpha = index < currentAlphas.count ? currentAlphas[index] : 0
            let active = horizonVisible || currentAlpha > activeAlphaThreshold
            // A label below its minCameraZoom does not reserve collision space
            // while it is fully invisible, otherwise a zoom-hidden POI would
            // displace visible ones. One already fading out (alpha > 0) keeps
            // holding its spot so neighbors don't jump during the fade-out
            // when crossing the threshold.
            let minCameraZoom = index < minCameraZooms.count ? minCameraZooms[index] : 0
            let suppressedByZoom = minCameraZoom > cameraZoom && currentAlpha <= activeAlphaThreshold
            candidates[index].isEnabled = active && suppressedByZoom == false
        }

        if count < candidates.count {
            for index in count..<candidates.count {
                candidates[index].isEnabled = false
            }
        }

        return candidates
    }

    static func horizonReservationSignature(horizonVisibility: [Bool],
                                            currentAlphas: [Float]) -> [Int] {
        let count = min(horizonVisibility.count, currentAlphas.count)
        guard count > 0 else {
            return []
        }

        var signature: [Int] = []
        for index in 0..<count where horizonVisibility[index] == false &&
            currentAlphas[index] > activeAlphaThreshold {
            signature.append(index)
        }
        return signature
    }
}
