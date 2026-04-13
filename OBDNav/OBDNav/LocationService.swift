//
//  LocationService.swift
//  OBDNav
//
//  Created by Codex on 30/03/2026.
//

import Combine
import CoreLocation
import Foundation

@MainActor
final class LocationService: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var location: CLLocation?
    @Published private(set) var compassHeadingDegrees: CLLocationDirection?

    private let manager = CLLocationManager()
    private var isHeadingUpdatesEnabled = true

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        authorizationStatus = manager.authorizationStatus

        if authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }

        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            return
        }

        manager.startUpdatingLocation()
        updateHeadingSubscription()
    }

    func setHeadingUpdatesEnabled(_ enabled: Bool) {
        isHeadingUpdatesEnabled = enabled
        updateHeadingSubscription()
    }

    private func updateHeadingSubscription() {
        guard CLLocationManager.headingAvailable() else { return }

        if isHeadingUpdatesEnabled {
            manager.startUpdatingHeading()
        } else {
            manager.stopUpdatingHeading()
            compassHeadingDegrees = nil
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus

        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
            updateHeadingSubscription()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latestLocation = locations.last else { return }
        location = latestLocation
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let normalizedHeading = newHeading.magneticHeading.truncatingRemainder(dividingBy: 360)
        compassHeadingDegrees = normalizedHeading >= 0 ? normalizedHeading : normalizedHeading + 360
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }
}
