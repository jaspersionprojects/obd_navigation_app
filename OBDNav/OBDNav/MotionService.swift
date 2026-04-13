//
//  MotionService.swift
//  OBDNav
//
//  Created by Codex on 02/04/2026.
//

import CoreMotion
import Combine
import Foundation
import simd

struct MotionSample {
    let correctedAccelerationG: SIMD3<Double>
    let correctedRotationRateRadPerSec: SIMD3<Double>
    let yawRadians: Double
}

@MainActor
final class MotionService: ObservableObject {
    @Published private(set) var latestSample: MotionSample?

    private let motionManager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "OBDNav.MotionService"
        queue.qualityOfService = .userInteractive
        return queue
    }()

    func start() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }

        motionManager.deviceMotionUpdateInterval = 1.0 / 25.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }

            let sample = MotionSample(
                correctedAccelerationG: SIMD3<Double>(
                    motion.userAcceleration.x,
                    motion.userAcceleration.y,
                    motion.userAcceleration.z
                ),
                correctedRotationRateRadPerSec: SIMD3<Double>(
                    motion.rotationRate.x,
                    motion.rotationRate.y,
                    motion.rotationRate.z
                ),
                yawRadians: motion.attitude.yaw
            )

            Task { @MainActor in
                self.latestSample = sample
            }
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        latestSample = nil
    }
}
