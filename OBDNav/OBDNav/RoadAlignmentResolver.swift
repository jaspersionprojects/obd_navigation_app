//
//  RoadAlignmentResolver.swift
//  OBDNav
//
//  Created by Codex on 06/04/2026.
//

import CoreLocation
import MapKit

struct CompassCalibrationCandidate {
    let anchorCoordinate: CLLocationCoordinate2D
    let forwardBearingDegrees: CLLocationDirection
}

enum RoadAlignmentResolver {
    private static let sampleRadiusMeters = 42.0
    private static let maximumMatchDistanceMeters = 24.0
    private static let probeBearings: [CLLocationDirection] = [0, 30, 60, 90, 120, 150]

    static func resolveRoadAlignment(
        near coordinate: CLLocationCoordinate2D
    ) async throws -> CompassCalibrationCandidate {
        let bestMatch = await withTaskGroup(of: RoadSegmentMatch?.self) { group in
            for probeBearing in probeBearings {
                group.addTask {
                    await safeMatch(around: coordinate, probeBearingDegrees: probeBearing)
                }
            }

            var currentBestMatch: RoadSegmentMatch?

            for await match in group {
                guard let match else { continue }

                if let existingBestMatch = currentBestMatch {
                    if match.score < existingBestMatch.score {
                        currentBestMatch = match
                    }
                } else {
                    currentBestMatch = match
                }
            }

            return currentBestMatch
        }

        guard let bestMatch, bestMatch.distanceToTapMeters <= maximumMatchDistanceMeters else {
            throw RoadAlignmentError.roadNotFound
        }

        return CompassCalibrationCandidate(
            anchorCoordinate: bestMatch.anchorCoordinate,
            forwardBearingDegrees: bestMatch.forwardBearingDegrees
        )
    }

    private static func safeMatch(
        around coordinate: CLLocationCoordinate2D,
        probeBearingDegrees: CLLocationDirection
    ) async -> RoadSegmentMatch? {
        do {
            return try await match(around: coordinate, probeBearingDegrees: probeBearingDegrees)
        } catch {
            return nil
        }
    }

    private static func match(
        around coordinate: CLLocationCoordinate2D,
        probeBearingDegrees: CLLocationDirection
    ) async throws -> RoadSegmentMatch? {
        let start = DeadReckoning.advance(
            from: coordinate,
            distanceMeters: sampleRadiusMeters,
            bearingDegrees: normalizeDegrees(probeBearingDegrees + 180)
        )
        let end = DeadReckoning.advance(
            from: coordinate,
            distanceMeters: sampleRadiusMeters,
            bearingDegrees: probeBearingDegrees
        )

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false

        let directions = MKDirections(request: request)
        let response = try await directions.calculate()

        var currentBestMatch: RoadSegmentMatch?

        for route in response.routes {
            guard let segmentMatch = closestSegment(
                in: route.polyline,
                near: coordinate,
                routeDistanceMeters: route.distance
            ) else {
                continue
            }

            if let existingBestMatch = currentBestMatch {
                if segmentMatch.score < existingBestMatch.score {
                    currentBestMatch = segmentMatch
                }
            } else {
                currentBestMatch = segmentMatch
            }
        }

        return currentBestMatch
    }

    private static func closestSegment(
        in polyline: MKPolyline,
        near coordinate: CLLocationCoordinate2D,
        routeDistanceMeters: CLLocationDistance
    ) -> RoadSegmentMatch? {
        guard polyline.pointCount > 1 else { return nil }

        let targetPoint = MKMapPoint(coordinate)
        let points = polyline.points()
        let buffer = UnsafeBufferPointer(start: points, count: polyline.pointCount)

        var currentBestMatch: RoadSegmentMatch?

        for index in 0..<(buffer.count - 1) {
            let startPoint = buffer[index]
            let endPoint = buffer[index + 1]

            let dx = endPoint.x - startPoint.x
            let dy = endPoint.y - startPoint.y
            let lengthSquared = (dx * dx) + (dy * dy)

            guard lengthSquared > 0 else { continue }

            let projectionScale = ((targetPoint.x - startPoint.x) * dx + (targetPoint.y - startPoint.y) * dy) / lengthSquared
            let clampedProjectionScale = min(max(projectionScale, 0), 1)

            let projectedPoint = MKMapPoint(
                x: startPoint.x + dx * clampedProjectionScale,
                y: startPoint.y + dy * clampedProjectionScale
            )

            let distanceToTapMeters = projectedPoint.distance(to: targetPoint)
            let score = distanceToTapMeters + (routeDistanceMeters * 0.02)

            let candidate = RoadSegmentMatch(
                anchorCoordinate: projectedPoint.coordinate,
                forwardBearingDegrees: bearingDegrees(from: startPoint.coordinate, to: endPoint.coordinate),
                distanceToTapMeters: distanceToTapMeters,
                score: score
            )

            if let existingBestMatch = currentBestMatch {
                if candidate.score < existingBestMatch.score {
                    currentBestMatch = candidate
                }
            } else {
                currentBestMatch = candidate
            }
        }

        return currentBestMatch
    }

    private static func bearingDegrees(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> CLLocationDirection {
        let startLatitude = start.latitude * .pi / 180
        let startLongitude = start.longitude * .pi / 180
        let endLatitude = end.latitude * .pi / 180
        let endLongitude = end.longitude * .pi / 180

        let deltaLongitude = endLongitude - startLongitude
        let y = sin(deltaLongitude) * cos(endLatitude)
        let x = cos(startLatitude) * sin(endLatitude) -
            sin(startLatitude) * cos(endLatitude) * cos(deltaLongitude)

        return normalizeDegrees(atan2(y, x) * 180 / .pi)
    }

    private static func normalizeDegrees(_ value: CLLocationDirection) -> CLLocationDirection {
        let normalized = value.truncatingRemainder(dividingBy: 360)
        return normalized >= 0 ? normalized : normalized + 360
    }
}

private struct RoadSegmentMatch {
    let anchorCoordinate: CLLocationCoordinate2D
    let forwardBearingDegrees: CLLocationDirection
    let distanceToTapMeters: CLLocationDistance
    let score: Double
}

enum RoadAlignmentError: LocalizedError {
    case roadNotFound

    var errorDescription: String? {
        switch self {
        case .roadNotFound:
            return "Couldn’t read that road. Tap the road surface again."
        }
    }
}
