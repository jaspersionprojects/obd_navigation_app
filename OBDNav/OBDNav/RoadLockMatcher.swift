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
    let snappedProjection: RoadLockProjection
    let currentDistanceMeters: CLLocationDistance
}

struct RoadLockProjection {
    let coordinate: CLLocationCoordinate2D
    let distanceMeters: CLLocationDistance
    let bearingDegrees: CLLocationDirection
    let segmentIndex: Int
    let segmentFraction: Double
}

struct RoadLockHeadingReference {
    let bearingDegrees: CLLocationDirection
    let maxDeviationDegrees: CLLocationDirection
    let sampleCount: Int
}

enum RoadLockMatcher {
    private static let localPathMaximumDistanceMeters = 100.0
    private static let minimumSampleCount = 4
    private static let maximumCurrentDistanceMeters = 22.0
    private static let candidateSearchRadiusMeters = 200.0
    private static let maximumRouteLengthMismatchFactor = 1.3
    private static let shapeBearingWeight = 0.55
    private static let shapeTurnWeight = 1.4
    private static let headingPenaltyWeight = 0.08
    private static let routeExtensionDistanceMeters = 90.0
    private static let minimumSuccessfulRouteExtensionDistanceMeters = 18.0
    private static let maximumExtensionInitialBearingDeltaDegrees = 28.0
    private static let shapeSampleCount = 12

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
                        currentCoordinate: currentCoordinate,
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

        let extendedRouteCoordinates = await extendRouteForward(
            routeCoordinates: bestCandidate.routeCoordinates,
            currentBearingDegrees: bestCandidate.lastProjection.bearingDegrees
        )

        return RoadLockMatch(
            routeCoordinates: extendedRouteCoordinates,
            snappedCoordinate: bestCandidate.lastProjection.coordinate,
            snappedProjection: bestCandidate.lastProjection,
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

    static func isLikelyOnSameRoad(
        _ coordinate: CLLocationCoordinate2D,
        as routeCoordinates: [CLLocationCoordinate2D],
        maximumDistanceMeters: CLLocationDistance = 18
    ) -> Bool {
        guard let projection = closestProjection(on: routeCoordinates, to: coordinate) else {
            return false
        }

        return projection.distanceMeters <= maximumDistanceMeters
    }

    static func advance(
        _ projection: RoadLockProjection,
        on routeCoordinates: [CLLocationCoordinate2D],
        by distanceMeters: CLLocationDistance
    ) -> RoadLockProjection? {
        guard routeCoordinates.count > 1 else { return nil }
        guard distanceMeters > 0 else { return projection }

        var remainingDistance = distanceMeters
        var currentSegmentIndex = min(max(projection.segmentIndex, 0), routeCoordinates.count - 2)
        var currentFraction = min(max(projection.segmentFraction, 0), 1)

        while currentSegmentIndex < routeCoordinates.count - 1 {
            let segmentStart = routeCoordinates[currentSegmentIndex]
            let segmentEnd = routeCoordinates[currentSegmentIndex + 1]
            let segmentLength = distanceMetersBetween(segmentStart, segmentEnd)

            guard segmentLength > 0 else {
                currentSegmentIndex += 1
                currentFraction = 0
                continue
            }

            let remainingFraction = 1 - currentFraction
            let availableDistance = segmentLength * remainingFraction

            if remainingDistance <= availableDistance {
                let nextFraction = currentFraction + (remainingDistance / segmentLength)
                return projectionAt(
                    routeCoordinates: routeCoordinates,
                    segmentIndex: currentSegmentIndex,
                    fraction: nextFraction
                )
            }

            remainingDistance -= availableDistance
            currentSegmentIndex += 1
            currentFraction = 0
        }

        return projectionAt(
            routeCoordinates: routeCoordinates,
            segmentIndex: max(routeCoordinates.count - 2, 0),
            fraction: 1
        )
    }

    static func remainingDistance(
        from projection: RoadLockProjection,
        on routeCoordinates: [CLLocationCoordinate2D]
    ) -> CLLocationDistance {
        guard routeCoordinates.count > 1 else { return 0 }

        let clampedSegmentIndex = min(max(projection.segmentIndex, 0), routeCoordinates.count - 2)
        let currentSegmentDistance =
            segmentLength(on: routeCoordinates, at: clampedSegmentIndex) *
            max(0, 1 - min(max(projection.segmentFraction, 0), 1))

        guard clampedSegmentIndex < routeCoordinates.count - 2 else {
            return currentSegmentDistance
        }

        let remainingTailDistance = ((clampedSegmentIndex + 1)..<(routeCoordinates.count - 1)).reduce(0.0) { partialResult, index in
            partialResult + segmentLength(on: routeCoordinates, at: index)
        }

        return currentSegmentDistance + remainingTailDistance
    }

    static func extendForward(
        on routeCoordinates: [CLLocationCoordinate2D]
    ) async -> [CLLocationCoordinate2D]? {
        guard routeCoordinates.count > 1 else { return nil }

        let currentDistance = totalDistance(of: routeCoordinates)
        let currentBearingDegrees = bearingDegrees(
            from: routeCoordinates[routeCoordinates.count - 2],
            to: routeCoordinates[routeCoordinates.count - 1]
        )
        let extendedRouteCoordinates = await extendRouteForward(
            routeCoordinates: routeCoordinates,
            currentBearingDegrees: currentBearingDegrees
        )

        let extendedDistance = totalDistance(of: extendedRouteCoordinates)
        guard extendedDistance - currentDistance >= minimumSuccessfulRouteExtensionDistanceMeters else {
            return nil
        }

        return extendedRouteCoordinates
    }

    static func headingReference(
        on routeCoordinates: [CLLocationCoordinate2D],
        around projection: RoadLockProjection,
        windowDistanceMeters: CLLocationDistance
    ) -> RoadLockHeadingReference? {
        guard routeCoordinates.count > 1 else { return nil }

        let clampedSegmentIndex = min(max(projection.segmentIndex, 0), routeCoordinates.count - 2)
        var segmentIndexes = Set<Int>()
        segmentIndexes.insert(clampedSegmentIndex)

        var backwardDistanceRemaining = windowDistanceMeters
        var backwardSegmentIndex = clampedSegmentIndex
        backwardDistanceRemaining -= segmentLength(
            on: routeCoordinates,
            at: backwardSegmentIndex
        ) * projection.segmentFraction

        while backwardDistanceRemaining > 0, backwardSegmentIndex > 0 {
            backwardSegmentIndex -= 1
            segmentIndexes.insert(backwardSegmentIndex)
            backwardDistanceRemaining -= segmentLength(
                on: routeCoordinates,
                at: backwardSegmentIndex
            )
        }

        var forwardDistanceRemaining = windowDistanceMeters
        var forwardSegmentIndex = clampedSegmentIndex
        forwardDistanceRemaining -= segmentLength(
            on: routeCoordinates,
            at: forwardSegmentIndex
        ) * (1 - projection.segmentFraction)

        while forwardDistanceRemaining > 0, forwardSegmentIndex < routeCoordinates.count - 2 {
            forwardSegmentIndex += 1
            segmentIndexes.insert(forwardSegmentIndex)
            forwardDistanceRemaining -= segmentLength(
                on: routeCoordinates,
                at: forwardSegmentIndex
            )
        }

        let segmentBearings = segmentIndexes
            .sorted()
            .map { index in
                bearingDegrees(
                    from: routeCoordinates[index],
                    to: routeCoordinates[index + 1]
                )
            }

        guard let meanBearingDegrees = circularMeanDegrees(segmentBearings) else {
            return nil
        }

        let maxDeviationDegrees = segmentBearings.reduce(0.0) { partialResult, segmentBearing in
            max(partialResult, abs(signedDeltaDegrees(from: meanBearingDegrees, to: segmentBearing)))
        }

        return RoadLockHeadingReference(
            bearingDegrees: meanBearingDegrees,
            maxDeviationDegrees: maxDeviationDegrees,
            sampleCount: segmentBearings.count
        )
    }

    private static func evaluateCandidate(
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D,
        localTrail: [CLLocationCoordinate2D],
        currentCoordinate: CLLocationCoordinate2D,
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
                    currentCoordinate: currentCoordinate,
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
        currentCoordinate: CLLocationCoordinate2D,
        rawRouteDistance: CLLocationDistance,
        currentHeadingDegrees: CLLocationDirection?
    ) -> ScoredRoadLockCandidate? {
        let routeCoordinates = coordinates(for: route.polyline)
        guard
            let trimmedRouteCoordinates = trimmedRouteCoordinates(
                routeCoordinates,
                around: currentCoordinate,
                radiusMeters: candidateSearchRadiusMeters
            ),
            trimmedRouteCoordinates.count > 1
        else {
            return nil
        }

        let referenceHeadingDegrees = travelHeadingReference(
            from: localTrail,
            fallbackHeadingDegrees: currentHeadingDegrees
        )

        let localRouteCoordinates = orientRouteCoordinates(
            trimmedRouteCoordinates,
            preferredHeadingDegrees: referenceHeadingDegrees,
            anchorCoordinate: localTrail.last ?? currentCoordinate
        )

        guard let lastCoordinate = localTrail.last,
              let lastProjection = closestProjection(on: localRouteCoordinates, to: lastCoordinate) else {
            return nil
        }

        let localRouteDistance = totalDistance(of: localRouteCoordinates)
        let routeLengthFactor = max(localRouteDistance, rawRouteDistance) / max(min(localRouteDistance, rawRouteDistance), 1)
        guard routeLengthFactor <= maximumRouteLengthMismatchFactor else { return nil }

        let shapeScore = comparePathShape(
            localTrail,
            against: localRouteCoordinates
        )

        var headingPenalty = 0.0
        if let currentHeadingDegrees {
            headingPenalty = abs(signedDeltaDegrees(
                from: currentHeadingDegrees,
                to: lastProjection.bearingDegrees
            )) * headingPenaltyWeight
        }

        let score = shapeScore +
            (routeLengthFactor - 1) * 24 +
            headingPenalty

        return ScoredRoadLockCandidate(
            routeCoordinates: localRouteCoordinates,
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

    private static func travelHeadingReference(
        from localTrail: [CLLocationCoordinate2D],
        fallbackHeadingDegrees: CLLocationDirection?
    ) -> CLLocationDirection? {
        guard localTrail.count > 1 else { return fallbackHeadingDegrees }

        for index in stride(from: localTrail.count - 1, through: 1, by: -1) {
            let previousCoordinate = localTrail[index - 1]
            let currentCoordinate = localTrail[index]
            let segmentDistance = distanceMetersBetween(previousCoordinate, currentCoordinate)
            guard segmentDistance >= 1 else { continue }
            return bearingDegrees(from: previousCoordinate, to: currentCoordinate)
        }

        return fallbackHeadingDegrees
    }

    private static func orientRouteCoordinates(
        _ routeCoordinates: [CLLocationCoordinate2D],
        preferredHeadingDegrees: CLLocationDirection?,
        anchorCoordinate: CLLocationCoordinate2D
    ) -> [CLLocationCoordinate2D] {
        guard routeCoordinates.count > 1 else { return routeCoordinates }
        guard let preferredHeadingDegrees else { return routeCoordinates }
        guard let projection = closestProjection(on: routeCoordinates, to: anchorCoordinate) else {
            return routeCoordinates
        }

        let forwardBearingDeltaDegrees = abs(signedDeltaDegrees(
            from: preferredHeadingDegrees,
            to: projection.bearingDegrees
        ))

        if forwardBearingDeltaDegrees <= 90 {
            return routeCoordinates
        }

        return routeCoordinates.reversed()
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
                bearingDegrees: bearingDegrees(from: startCoordinate, to: endCoordinate),
                segmentIndex: index,
                segmentFraction: clampedProjectionScale
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

    private static func trimmedRouteCoordinates(
        _ routeCoordinates: [CLLocationCoordinate2D],
        around center: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance
    ) -> [CLLocationCoordinate2D]? {
        guard routeCoordinates.count > 1 else { return nil }

        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let inRadiusIndexes = routeCoordinates.indices.filter { index in
            centerLocation.distance(from: CLLocation(
                latitude: routeCoordinates[index].latitude,
                longitude: routeCoordinates[index].longitude
            )) <= radiusMeters
        }

        guard let firstIndex = inRadiusIndexes.first,
              let lastIndex = inRadiusIndexes.last,
              lastIndex > firstIndex else {
            return nil
        }

        return Array(routeCoordinates[firstIndex...lastIndex])
    }

    private static func extendRouteForward(
        routeCoordinates: [CLLocationCoordinate2D],
        currentBearingDegrees: CLLocationDirection
    ) async -> [CLLocationCoordinate2D] {
        guard routeCoordinates.count > 1, let routeEnd = routeCoordinates.last else {
            return routeCoordinates
        }

        let extensionDestination = DeadReckoning.advance(
            from: routeEnd,
            distanceMeters: routeExtensionDistanceMeters,
            bearingDegrees: currentBearingDegrees
        )

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: routeEnd))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: extensionDestination))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false

        let directions = MKDirections(request: request)

        do {
            let response = try await directions.calculate()
            guard
                let extensionRoute = response.routes.first,
                !extensionRoute.steps.isEmpty
            else {
                return routeCoordinates
            }

            let extensionCoordinates = coordinates(for: extensionRoute.polyline)
            guard extensionCoordinates.count > 1 else { return routeCoordinates }

            guard let firstExtensionCoordinate = extensionCoordinates.first,
                  distanceMetersBetween(routeEnd, firstExtensionCoordinate) <= 12
            else {
                return routeCoordinates
            }

            let extensionBearingDegrees = bearingDegrees(
                from: extensionCoordinates[0],
                to: extensionCoordinates[1]
            )
            let extensionBearingDeltaDegrees = abs(signedDeltaDegrees(
                from: currentBearingDegrees,
                to: extensionBearingDegrees
            ))
            guard extensionBearingDeltaDegrees <= maximumExtensionInitialBearingDeltaDegrees else {
                return routeCoordinates
            }

            return routeCoordinates + extensionCoordinates.dropFirst()
        } catch {
            return routeCoordinates
        }
    }

    private static func projectionAt(
        routeCoordinates: [CLLocationCoordinate2D],
        segmentIndex: Int,
        fraction: Double
    ) -> RoadLockProjection? {
        guard routeCoordinates.count > 1 else { return nil }

        let clampedSegmentIndex = min(max(segmentIndex, 0), routeCoordinates.count - 2)
        let clampedFraction = min(max(fraction, 0), 1)
        let startCoordinate = routeCoordinates[clampedSegmentIndex]
        let endCoordinate = routeCoordinates[clampedSegmentIndex + 1]
        let startPoint = MKMapPoint(startCoordinate)
        let endPoint = MKMapPoint(endCoordinate)
        let projectedPoint = MKMapPoint(
            x: startPoint.x + (endPoint.x - startPoint.x) * clampedFraction,
            y: startPoint.y + (endPoint.y - startPoint.y) * clampedFraction
        )

        return RoadLockProjection(
            coordinate: projectedPoint.coordinate,
            distanceMeters: 0,
            bearingDegrees: bearingDegrees(from: startCoordinate, to: endCoordinate),
            segmentIndex: clampedSegmentIndex,
            segmentFraction: clampedFraction
        )
    }

    private static func comparePathShape(
        _ lhs: [CLLocationCoordinate2D],
        against rhs: [CLLocationCoordinate2D]
    ) -> Double {
        let sampledLHS = resamplePath(lhs, sampleCount: shapeSampleCount)
        let sampledRHS = resamplePath(rhs, sampleCount: shapeSampleCount)

        guard sampledLHS.count >= 3, sampledRHS.count >= 3 else {
            return .greatestFiniteMagnitude
        }

        let lhsBearings = segmentBearings(for: sampledLHS)
        let rhsBearings = segmentBearings(for: sampledRHS)
        let lhsTurns = turnProfile(for: lhsBearings)
        let rhsTurns = turnProfile(for: rhsBearings)

        let bearingScore = zip(lhsBearings, rhsBearings).reduce(0.0) { partialResult, pair in
            partialResult + abs(signedDeltaDegrees(from: pair.0, to: pair.1))
        } / Double(max(lhsBearings.count, 1))

        let turnScore = zip(lhsTurns, rhsTurns).reduce(0.0) { partialResult, pair in
            partialResult + abs(signedDeltaDegrees(from: pair.0, to: pair.1))
        } / Double(max(lhsTurns.count, 1))

        return bearingScore * shapeBearingWeight + turnScore * shapeTurnWeight
    }

    private static func resamplePath(
        _ coordinates: [CLLocationCoordinate2D],
        sampleCount: Int
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 1, sampleCount > 1 else { return coordinates }

        let totalPathDistance = totalDistance(of: coordinates)
        guard totalPathDistance > 0 else { return coordinates }

        let stepDistance = totalPathDistance / Double(sampleCount - 1)
        var sampledCoordinates: [CLLocationCoordinate2D] = [coordinates[0]]
        sampledCoordinates.reserveCapacity(sampleCount)

        var accumulatedDistance = 0.0
        var targetDistance = stepDistance

        for index in 0..<(coordinates.count - 1) {
            let startCoordinate = coordinates[index]
            let endCoordinate = coordinates[index + 1]
            let segmentDistance = distanceMetersBetween(startCoordinate, endCoordinate)

            guard segmentDistance > 0 else { continue }

            while targetDistance <= accumulatedDistance + segmentDistance,
                  sampledCoordinates.count < sampleCount - 1 {
                let fraction = (targetDistance - accumulatedDistance) / segmentDistance
                let startPoint = MKMapPoint(startCoordinate)
                let endPoint = MKMapPoint(endCoordinate)
                let interpolatedPoint = MKMapPoint(
                    x: startPoint.x + (endPoint.x - startPoint.x) * fraction,
                    y: startPoint.y + (endPoint.y - startPoint.y) * fraction
                )
                sampledCoordinates.append(interpolatedPoint.coordinate)
                targetDistance += stepDistance
            }

            accumulatedDistance += segmentDistance
        }

        sampledCoordinates.append(coordinates[coordinates.count - 1])
        return sampledCoordinates
    }

    private static func segmentBearings(
        for coordinates: [CLLocationCoordinate2D]
    ) -> [CLLocationDirection] {
        guard coordinates.count > 1 else { return [] }

        return zip(coordinates, coordinates.dropFirst()).map { pair in
            bearingDegrees(from: pair.0, to: pair.1)
        }
    }

    private static func turnProfile(
        for bearings: [CLLocationDirection]
    ) -> [CLLocationDirection] {
        guard bearings.count > 1 else { return [] }

        return zip(bearings, bearings.dropFirst()).map { pair in
            signedDeltaDegrees(from: pair.0, to: pair.1)
        }
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

    private static func distanceMetersBetween(
        _ start: CLLocationCoordinate2D,
        _ end: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        distanceMeters(from: start, to: end)
    }

    private static func segmentLength(
        on routeCoordinates: [CLLocationCoordinate2D],
        at index: Int
    ) -> CLLocationDistance {
        guard index >= 0, index < routeCoordinates.count - 1 else { return 0 }
        return distanceMetersBetween(routeCoordinates[index], routeCoordinates[index + 1])
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

    private static func circularMeanDegrees(
        _ bearings: [CLLocationDirection]
    ) -> CLLocationDirection? {
        guard !bearings.isEmpty else { return nil }

        let sum = bearings.reduce(CGPoint.zero) { partialResult, bearing in
            let radians = bearing * .pi / 180
            return CGPoint(
                x: partialResult.x + cos(radians),
                y: partialResult.y + sin(radians)
            )
        }

        guard sum.x != 0 || sum.y != 0 else {
            guard let firstBearing = bearings.first else { return nil }
            let normalizedBearing = firstBearing.truncatingRemainder(dividingBy: 360)
            return normalizedBearing >= 0 ? normalizedBearing : normalizedBearing + 360
        }

        return normalizeDegrees(atan2(sum.y, sum.x) * 180 / .pi)
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
