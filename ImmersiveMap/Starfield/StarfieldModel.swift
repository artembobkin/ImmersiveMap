// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

enum StarfieldModel {
    struct Star: Equatable {
        let position: SIMD3<Float>
        let size: Float
        let brightness: Float
        let temperature: Float
        let twinklePhase: Float
        let halo: Float
    }

    static func makeStars(config: ImmersiveMapSettings.StarfieldSettings,
                          seed: UInt64 = 0x5A17_F1E1_DA7A_CE01) -> [Star] {
        guard config.starCount > 0 else { return [] }

        var random = SplitMix64(state: seed ^ UInt64(config.starCount))
        let clusterAnchors = makeAnchors(count: 11, random: &random)
        let voidAnchors = makeAnchors(count: 3, random: &random)
        let sizeRange = max(config.sizeMax - config.sizeMin, 0.001)
        let brightnessRange = max(config.brightnessMax - config.brightnessMin, 0.001)

        let dustCount = max(1, Int(Float(config.starCount) * 0.68))
        let midCount = max(1, Int(Float(config.starCount) * 0.25))
        let accentCount = max(1, config.starCount - dustCount - midCount)

        let layers: [(count: Int, profile: LayerProfile)] = [
            (dustCount, LayerProfile(sizeLower: 0.00,
                                     sizeUpper: 0.28,
                                     brightnessLower: 0.00,
                                     brightnessUpper: 0.22,
                                     haloLower: 0.12,
                                     haloUpper: 0.28,
                                     clusterProbability: 0.78,
                                     clusterSpread: 0.10,
                                     valueBias: 1.9)),
            (midCount, LayerProfile(sizeLower: 0.18,
                                    sizeUpper: 0.62,
                                    brightnessLower: 0.20,
                                    brightnessUpper: 0.74,
                                    haloLower: 0.22,
                                    haloUpper: 0.48,
                                    clusterProbability: 0.66,
                                    clusterSpread: 0.16,
                                    valueBias: 1.35)),
            (accentCount, LayerProfile(sizeLower: 0.56,
                                       sizeUpper: 1.00,
                                       brightnessLower: 0.68,
                                       brightnessUpper: 1.00,
                                       haloLower: 0.45,
                                       haloUpper: 0.95,
                                       clusterProbability: 0.48,
                                       clusterSpread: 0.24,
                                       valueBias: 0.9))
        ]

        var stars: [Star] = []
        stars.reserveCapacity(config.starCount)

        for (layerIndex, layer) in layers.enumerated() {
            for _ in 0..<layer.count {
                let position = makePosition(profile: layer.profile,
                                            clusterAnchors: clusterAnchors,
                                            voidAnchors: voidAnchors,
                                            random: &random)
                let size = config.sizeMin + sampleRange(layer.profile.sizeLower...layer.profile.sizeUpper,
                                                        bias: layer.profile.valueBias,
                                                        random: &random) * sizeRange
                let brightness = config.brightnessMin
                    + sampleRange(layer.profile.brightnessLower...layer.profile.brightnessUpper,
                                  bias: max(0.7, layer.profile.valueBias - 0.2),
                                  random: &random) * brightnessRange
                let temperature = temperatureSample(layerIndex: layerIndex, random: &random)
                let twinklePhase = random.nextFloat(0.0...Float.pi * 2.0)
                let halo = sampleRange(layer.profile.haloLower...layer.profile.haloUpper,
                                       bias: 1.1,
                                       random: &random)

                stars.append(Star(position: position,
                                  size: size,
                                  brightness: brightness,
                                  temperature: temperature,
                                  twinklePhase: twinklePhase,
                                  halo: halo))
            }
        }

        return stars
    }

    private struct LayerProfile {
        let sizeLower: Float
        let sizeUpper: Float
        let brightnessLower: Float
        let brightnessUpper: Float
        let haloLower: Float
        let haloUpper: Float
        let clusterProbability: Float
        let clusterSpread: Float
        let valueBias: Float
    }

    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }

        mutating func nextFloat(_ range: ClosedRange<Float> = 0.0...1.0) -> Float {
            let unit = Float(next() >> 40) / Float(1 << 24)
            return range.lowerBound + (range.upperBound - range.lowerBound) * unit
        }
    }

    private static func makeAnchors(count: Int,
                                    random: inout SplitMix64) -> [SIMD3<Float>] {
        (0..<count).map { _ in
            uniformSphere(random: &random)
        }
    }

    private static func makePosition(profile: LayerProfile,
                                     clusterAnchors: [SIMD3<Float>],
                                     voidAnchors: [SIMD3<Float>],
                                     random: inout SplitMix64) -> SIMD3<Float> {
        for _ in 0..<8 {
            let candidate: SIMD3<Float>
            if random.nextFloat() < profile.clusterProbability {
                let anchorIndex = Int(random.next() % UInt64(clusterAnchors.count))
                candidate = clusteredDirection(anchor: clusterAnchors[anchorIndex],
                                               spread: profile.clusterSpread,
                                               random: &random)
            } else {
                candidate = uniformSphere(random: &random)
            }

            let isInsideVoid = voidAnchors.contains { simd_dot(candidate, $0) > 0.965 }
            if !isInsideVoid || random.nextFloat() > 0.82 {
                return candidate
            }
        }

        return uniformSphere(random: &random)
    }

    private static func clusteredDirection(anchor: SIMD3<Float>,
                                           spread: Float,
                                           random: inout SplitMix64) -> SIMD3<Float> {
        let referenceAxis = abs(anchor.y) < 0.92 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let tangentA = simd_normalize(simd_cross(anchor, referenceAxis))
        let tangentB = simd_normalize(simd_cross(anchor, tangentA))
        let angle = random.nextFloat(0.0...Float.pi * 2.0)
        let radius = spread * pow(random.nextFloat(), 1.75)
        let offset = tangentA * cos(angle) * radius + tangentB * sin(angle) * radius
        return simd_normalize(anchor + offset)
    }

    private static func uniformSphere(random: inout SplitMix64) -> SIMD3<Float> {
        let u = random.nextFloat()
        let v = random.nextFloat()
        let theta = 2.0 * Float.pi * u
        let z = 2.0 * v - 1.0
        let radial = sqrt(max(0.0, 1.0 - z * z))
        return SIMD3<Float>(radial * cos(theta), radial * sin(theta), z)
    }

    private static func sampleRange(_ range: ClosedRange<Float>,
                                    bias: Float,
                                    random: inout SplitMix64) -> Float {
        let lower = min(range.lowerBound, range.upperBound)
        let upper = max(range.lowerBound, range.upperBound)
        let normalized = pow(random.nextFloat(), bias)
        return lower + (upper - lower) * normalized
    }

    private static func temperatureSample(layerIndex: Int,
                                          random: inout SplitMix64) -> Float {
        let roll = random.nextFloat()
        switch layerIndex {
        case 0:
            if roll < 0.12 { return random.nextFloat(0.0...0.22) }
            if roll < 0.84 { return random.nextFloat(0.34...0.66) }
            return random.nextFloat(0.72...1.0)
        case 1:
            if roll < 0.18 { return random.nextFloat(0.0...0.26) }
            if roll < 0.76 { return random.nextFloat(0.30...0.70) }
            return random.nextFloat(0.72...1.0)
        default:
            if roll < 0.22 { return random.nextFloat(0.0...0.32) }
            if roll < 0.60 { return random.nextFloat(0.34...0.68) }
            return random.nextFloat(0.72...1.0)
        }
    }
}
