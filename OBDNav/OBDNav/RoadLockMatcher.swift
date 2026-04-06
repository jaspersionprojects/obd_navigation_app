//
//  RoadLockMatcher.swift
//  OBDNav
//
//  Created by Codex on 06/04/2026.
//

import CoreLocation
import MapKit

struct RoadLockMatch {
    let routeCoordinates: [CLLocationCoordinate2D]
    let snappedCoordinate: CLLocationCoordinate2D
    let currentDistanceMeters: CLLocationDistance
}

struct RoadLockProjection {
    let coordinate: CLLocationCoordinate2D
    let distanceMeters: CLLocationDistance
    let bearingDegrees: CLLocationDirection
}

enum RoadLockMatcher {
    private static let localPathMaximumDistanceMeters = 180.0
    private static let minimumSampleCount = 4
    private static let maximumAverageDistanceMeters = 16.0
    private static let maximumCurrentDistanceMeters = 22.0
    private static let maximumRouteLengthMismatchFactor = 1.3
    private static let headingPenaltyWeight = 0.22

    static func match(
        rawTrail: [CLLocationCoordinate2D],
        currentCoordinate: CLLocationCoordinate2D,
        currentHeadingDegrees: CLLocationDirection?
    ) async -> RoadLockMatch? {
        let localTrail = recentLocalTrail(
            from: rawTrail,
            currentCoordinate: currentCoordinate
        )

        guard localTrail.count >= minimumSampleCount else { return nil }

        let candidatePairs = candidateRequests(for: localTrail)
        guard !candidatePairs.isEmpty else { return nil }

        let rawRouteDistance = totalDistance(of: localTrail)

        let bestCandidate = await withTaskGroup(of: ScoredRoadLockCandidate?.self) { group in
            for pair in candidatePairs {
                group.addTask {
                    await evaluateCandidate(
                        start: pair.start,
                        end: pair.end,
                        localTrail: localTrail,
                        rawRouteDistance: rawRouteDistance,
                        currentHeadingDegrees: currentHeadingDegrees
                    )
                }
            }

            var bestCandidate: ScoredRoadLockCandidate?

            for await candidate in group {
                guard let candidate else { continue }

                if let existingBestCandidate = bestCandidate {
                    if candidate.score < existingBestCandidate.score {
                        bestCandidate = candidate
                    }
                } else {
                    bestCandidate = candidate
                }
            }

            return bestCandidate
        }

        guard let bestCandidate else { return nil }

        return RoadLockMatch(
            routeCoordinates: bestCandidate.routeCoordinates,
            snappedCoordinate: bestCandidate.lastProjection.coordinate,
            currentDistanceMeters: bestCandidate.lastProjection.distanceMeters
        )
    }

    static func snap(
        _ coordinate: CLLocationCoordinate2D,
        to routeCoordinates: [CLLocationCoordinate2D],
        currentHeadingDegrees: CLLocationDirection?
    ) -> RoadLockProjection? {
        guard let projection = closestProjection(
            on: routeCoordinates,
            to: coordinate
        ) else {
            return nil
        }

        guard projection.distanceMeters <= maximumCurrentDistanceMeters else {
            return nil
        }

        if let currentHeadingDegrees {
            let headingDelta = abs(signedDeltaDegrees(
                from: currentHeadingDegrees,
                to: projection.bearingDegrees
            ))

            guard headingDelta <= 95 else {
                return nil
            }
        }

        return projection
    }

    private static func evaluateCandidate(
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D,
        localTrail: [CLLocationCoordinate2D],
        rawRouteDistance: CLLocationDistance,
        currentHeadingDegrees: CLLocationDirection?
    ) async -> ScoredRoadLockCandidate? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = .automobile
        request.requestsAlternateRoutes = true

        let directions = MKDirections(request: request)

        do {
            let response = try await directions.calculate()
            var bestCandidate: ScoredRoadLockCandidate?

            for route in response.routes {
                guard let candidate = score(
                    route: route,
                    localTrail: localTrail,
                    rawRouteDistance: rawRouteDistance,
                    currentHeadingDegrees: currentHeadingDegrees
                ) else {
                    continue
                }

                if let existingBestCandidate = bestCandidate {
                    if candidate.score < existingBestCandidate.score {
                        bestCandidate = candidate
                    }
                } else {
                    bestCandidate = candidate
                }
            }

            return bestCandidate
        } catch {
            return nil
        }
    }

    private static func score(
        route: MKRoute,
        localTrail: [CLLocationCoordinate2D],
        rawRouteDistance: CLLocationDistance,
        currentHeadingDegrees: CLLocationDirection?
    ) -> ScoredRoadLockCandidate? {
        let routeCoordinates = coordinates(for: route.polyline)
        guard routeCoordinates.count > 1 else { return nil }

        var projectionDistances: [CLLocationDistance] = []
        projectionDistances.reserveCapacity(localTrail.count)

        for coordinate in localTrail {
            guard let projection = closestProjection(on: routeCoordinates, to: coordinate) else {
                return nil
            }
            projectionDistances.append(projection.distanceMeters)
        }

        guard let lastCoordinate = localTrail.last,
              let lastProjection = closestProjection(on: routeCoordinates, to: lastCoordinate) else {
            return nil
        }

        let averageDistanceMeters = projectionDistances.reduce(0, +) / Double(projectionDistances.count)
        guard averageDistanceMeters <= maximumAverageDistanceMeters else { return nil }
        guard lastProjection.distanceMeters <= maximumCurrentDistanceMeters else { return nil }

        let routeLengthFactor = max(route.distance, rawRouteDistance) / max(min(route.distance, rawRouteDistance), 1)
        guard routeLengthFactor <= maximumRouteLengthMismatchFactor else { return nil }

        var headingPenalty = 0.0
        if let currentHeadingDegrees {
            headingPenalty = abs(signedDeltaDegrees(
                from: currentHeadingDegrees,
                to: lastProjection.bearingDegrees
            )) * headingPenaltyWeight
        }

        let score = averageDistanceMeters * 1.6 +
            lastProjection.distanceMeters * 2.3 +
            (routeLengthFactor - 1) * 24 +
            headingPenalty

        return ScoredRoadLockCandidate(
            routeCoordinates: routeCoordinates,
            lastProjection: lastProjection,
            score: score
        )
    }

    private static func recentLocalTrail(
        from rawTrail: [CLLocationCoordinate2D],
        currentCoordinate: CLLocationCoordinate2D
    ) -> [CLLocationCoordinate2D] {
        guard !rawTrail.isEmpty else { return [] }

        var reversedLocalTrail: [CLLocationCoordinate2D] = []
        reversedLocalTrail.reserveCapacity(18)

        var pathDistance = 0.0
        var previousCoordinate: CLLocationCoordinate2D?

        for coordinate in rawTrail.reversed() {
            let distanceFromCurrent = distanceMeters(from: coordinate, to: currentCoordinate)

            if distanceFromCurrent > localPathMaximumDistanceMeters,
               reversedLocalTrail.count >= minimumSampleCount {
                break
            }

            if let previousCoordinate {
                pathDistance += distanceMeters(from: coordinate, to: previousCoordinate)
            }

            reversedLocalTrail.append(coordinate)
            previousCoordinate = coordinate

            if pathDistance >= localPathMaximumDistanceMeters {
                break
            }

            if reversedLocalTrail.count >= 22 {
                break
            }
        }

        return reversedLocalTrail.reversed()
    }

    private static func candidateRequests(
        for localTrail: [CLLocationCoordinate2D]
    ) -> [(start: CLLocationCoordinate2D, end: CLLocationCoordinate2D)] {
        guard localTrail.count >= minimumSampleCount,
              let firstCoordinate = localTrail.first,
              let lastCoordinate = localTrail.last else {
            return []
        }

        var candidates: [(start: CLLocationCoordinate2D, end: CLLocationCoordinate2D)] = [
            (firstCoordinate, lastCoordinate)
        ]

        if localTrail.count > 5 {
            candidates.append((localTrail[1], lastCoordinate))
            candidates.append((firstCoordinate, localTrail[localTrail.count - 2]))
        }

        if localTrail.count > 7 {
            candidates.append((localTrail[1], localTrail[localTrail.count - 2]))
        }

        return candidates
    }

    private static func closestProjection(
        on coordinates: [CLLocationCoordinate2D],
        to target: CLLocationCoordinate2D
    ) -> RoadLockProjection? {
        guard coordinates.count > 1 else { return nil }

        let targetPoint = MKMapPoint(target)
        var bestProjection: RoadLockProjection?

        for index in 0..<(coordinates.count - 1) {
            let startCoordinate = coordinates[index]
            let endCoordinate = coordinates[index + 1]
            let startPoint = MKMapPoint(startCoordinate)
            let endPoint = MKMapPoint(endCoordinate)

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

            let projection = RoadLockProjection(
                coordinate: projectedPoint.coordinate,
                distanceMeters: projectedPoint.distance(to: targetPoint),
                bearingDegrees: bearingDegrees(from: startCoordinate, to: endCoordinate)
            )

            if let existingProjection = bestProjection {
                if projection.distanceMeters < existingProjection.distanceMeters {
                    bestProjection = projection
                }
            } else {
                bestProjection = projection
            }
        }

        return bestProjection
    }

    private static func coordinates(for polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        let buffer = UnsafeBufferPointer(start: polyline.points(), count: polyline.pointCount)
        return buffer.map(\.coordinate)
    }

    private static func totalDistance(of coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
        guard coordinates.count > 1 else { return 0 }

        return zip(coordinates, coordinates.dropFirst()).reduce(0) { partialResult, pair in
            partialResult + distanceMeters(from: pair.0, to: pair.1)
        }
    }

    private static func distanceMeters(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
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

    private static func signedDeltaDegrees(
        from source: CLLocationDirection,
        to target: CLLocationDirection
    ) -> CLLocationDirection {
        let delta = normalizeDegrees(target - source)
        return delta > 180 ? delta - 360 : delta
    }
}

private struct ScoredRoadLockCandidate {
    let routeCoordinates: [CLLocationCoordinate2D]
    let lastProjection: RoadLockProjection
    let score: Double
}
