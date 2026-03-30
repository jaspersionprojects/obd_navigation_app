//
//  DeadReckoning.swift
//  OBDNav
//
//  Created by Codex on 30/03/2026.
//

import CoreLocation
import Foundation

enum DeadReckoning {
    private static let earthRadiusMeters = 6_371_000.0

    static func advance(
        from coordinate: CLLocationCoordinate2D,
        distanceMeters: CLLocationDistance,
        bearingDegrees: CLLocationDirection
    ) -> CLLocationCoordinate2D {
        let angularDistance = distanceMeters / earthRadiusMeters
        let bearingRadians = bearingDegrees * .pi / 180
        let latitudeRadians = coordinate.latitude * .pi / 180
        let longitudeRadians = coordinate.longitude * .pi / 180

        let nextLatitude = asin(
            sin(latitudeRadians) * cos(angularDistance) +
            cos(latitudeRadians) * sin(angularDistance) * cos(bearingRadians)
        )

        let nextLongitude = longitudeRadians + atan2(
            sin(bearingRadians) * sin(angularDistance) * cos(latitudeRadians),
            cos(angularDistance) - sin(latitudeRadians) * sin(nextLatitude)
        )

        return CLLocationCoordinate2D(
            latitude: nextLatitude * 180 / .pi,
            longitude: nextLongitude * 180 / .pi
        )
    }
}
