//
//  StationaryDetector.swift
//  OBDNav
//
//  Created by Codex on 02/04/2026.
//

import simd

struct StationaryDetector {
    private let gravityMetersPerSecondSquared = 9.80665
    private let accelerationDeadband = 0.05
    private let fixedMountForwardAxisSign = 1.0

    private let stationaryAccelerationThreshold = 0.12
    private let stationaryRotationRateThreshold = 0.08
    private let stationaryHeadingDeltaThreshold = 8.0
    private let stationarySampleThreshold = 5

    private(set) var stationarySampleCount = 0
    private(set) var stationaryHeadingReference: Double?

    mutating func reset() {
        stationarySampleCount = 0
        stationaryHeadingReference = nil
    }

    mutating func update(
        correctedAccelerationG: SIMD3<Double>,
        correctedRotationRateRadPerSec: SIMD3<Double>,
        currentHeadingDegrees: Double?
    ) -> Bool {
        let planarAcceleration = planarAccelerationMetersPerSecondSquared(from: correctedAccelerationG)
        let accelerationMagnitude = simd_length(planarAcceleration)

        let rotationMagnitude = sqrt(
            correctedRotationRateRadPerSec.x * correctedRotationRateRadPerSec.x +
            correctedRotationRateRadPerSec.y * correctedRotationRateRadPerSec.y +
            correctedRotationRateRadPerSec.z * correctedRotationRateRadPerSec.z
        )

        let headingIsStable: Bool
        if let currentHeadingDegrees {
            if let stationaryHeadingReference {
                headingIsStable =
                    abs(normalizedDeltaDegrees(currentHeadingDegrees, stationaryHeadingReference))
                    <= stationaryHeadingDeltaThreshold
            } else {
                headingIsStable = true
            }
        } else {
            headingIsStable = true
        }

        let isCandidateStationary =
            accelerationMagnitude <= stationaryAccelerationThreshold &&
            rotationMagnitude <= stationaryRotationRateThreshold &&
            headingIsStable

        if isCandidateStationary {
            stationarySampleCount += 1

            if let currentHeadingDegrees {
                if let stationaryHeadingReference {
                    let delta = normalizedDeltaDegrees(currentHeadingDegrees, stationaryHeadingReference)
                    self.stationaryHeadingReference = normalize(
                        angle: stationaryHeadingReference + delta * 0.25
                    )
                } else {
                    stationaryHeadingReference = currentHeadingDegrees
                }
            }
        } else {
            stationarySampleCount = 0
            stationaryHeadingReference = currentHeadingDegrees
        }

        return stationarySampleCount >= stationarySampleThreshold
    }

    private func planarAccelerationMetersPerSecondSquared(
        from correctedAccelerationG: SIMD3<Double>
    ) -> SIMD2<Double> {
        var lateralAcceleration = correctedAccelerationG.x * gravityMetersPerSecondSquared
        var forwardAcceleration = correctedAccelerationG.y * gravityMetersPerSecondSquared * fixedMountForwardAxisSign

        if abs(lateralAcceleration) < accelerationDeadband {
            lateralAcceleration = 0
        }
        if abs(forwardAcceleration) < accelerationDeadband {
            forwardAcceleration = 0
        }

        return SIMD2<Double>(lateralAcceleration, forwardAcceleration)
    }

    private func normalize(angle: Double) -> Double {
        let normalized = angle.truncatingRemainder(dividingBy: 360)
        return normalized >= 0 ? normalized : normalized + 360
    }

    private func normalizedDeltaDegrees(_ lhs: Double, _ rhs: Double) -> Double {
        let delta = normalize(angle: lhs - rhs)
        return delta > 180 ? delta - 360 : delta
    }
}
