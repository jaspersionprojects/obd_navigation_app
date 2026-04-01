//
//  NavigationViewModel.swift
//  OBDNav
//
//  Created by Codex on 30/03/2026.
//

import Combine
import CoreLocation
import MapKit
import SwiftUI

@MainActor
final class NavigationViewModel: ObservableObject {
    @Published var gpsCoordinate: CLLocationCoordinate2D?
    @Published var obdCoordinate: CLLocationCoordinate2D?
    @Published var gpsTrailCoordinates: [CLLocationCoordinate2D] = []
    @Published var obdTrailCoordinates: [CLLocationCoordinate2D] = []
    @Published var gpsSpeedKPH: Double = 0
    @Published var obdSpeedKPH: Double?
    @Published var headingDegrees: CLLocationDirection = 0
    @Published var gapMeters: CLLocationDistance = 0
    @Published var selectedPanelPage = 0
    @Published var isPanelExpanded = false
    @Published var isShowingDevicePicker = false
    @Published var cameraPosition: MapCameraPosition = .region(NavigationViewModel.defaultRegion)

    @Published private(set) var obdConnectionState: OBDConnectionState = .idle
    @Published private(set) var isDiscoveringDongles = false
    @Published private(set) var discoveredDongles: [OBDDongle] = []
    @Published private(set) var connectingDongleID: UUID?
    @Published private(set) var connectedDongleID: UUID?

    let locationService: LocationService
    let obdManager: OBDBLEManager

    private var cancellables = Set<AnyCancellable>()
    private var deadReckoningTask: Task<Void, Never>?
    private var lastTick = Date()
    private let previewMode: Bool
    private var hasStarted = false
    private var hasInitializedCamera = false
    private let trailMinimumStepMeters: CLLocationDistance = 1.5
    private let maxTrailPoints = 1_200

    static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278),
        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
    )

    var gpsStatusText: String {
        if locationService.authorizationStatus == .denied || locationService.authorizationStatus == .restricted {
            return "Permission needed"
        }

        return gpsCoordinate == nil ? "Waiting for fix" : "Live GPS"
    }

    var obdStatusText: String {
        if isDiscoveringDongles, case .idle = obdConnectionState {
            return "Scanning for nearby dongles"
        }

        return obdConnectionState.displayText
    }

    var obdStatusTint: Color {
        obdConnectionState.tint
    }

    var connectButtonSubtitle: String {
        switch obdConnectionState {
        case .connected(let name):
            return "Currently connected to \(name)"
        case .connecting(let name):
            return "Connecting to \(name)"
        case .bluetoothOff:
            return "Turn Bluetooth on to discover devices"
        case .failed(let message):
            return message
        case .idle:
            return isDiscoveringDongles ? "Looking for nearby BLE OBD dongles" : "Choose a nearby BLE OBD dongle"
        }
    }

    convenience init(previewMode: Bool = false) {
        self.init(
            locationService: LocationService(),
            obdManager: OBDBLEManager(),
            previewMode: previewMode
        )
    }

    init(
        locationService: LocationService,
        obdManager: OBDBLEManager,
        previewMode: Bool = false
    ) {
        self.locationService = locationService
        self.obdManager = obdManager
        self.previewMode = previewMode

        if previewMode {
            seedPreviewState()
        } else {
            bind()
        }
    }

    deinit {
        deadReckoningTask?.cancel()
    }

    func start() {
        guard !previewMode, !hasStarted else { return }
        hasStarted = true
        locationService.start()
        obdManager.start()
        startDeadReckoningLoop()
    }

    func snapOBDToGPS() {
        guard let gpsCoordinate else { return }
        obdCoordinate = gpsCoordinate
        appendCoordinate(gpsCoordinate, to: &obdTrailCoordinates)
        updateGap()
    }

    func showOBDDevicePicker() {
        isShowingDevicePicker = true
        obdManager.beginDiscovery()
    }

    func beginDongleDiscovery() {
        obdManager.beginDiscovery()
    }

    func didDismissDevicePicker() {
        isShowingDevicePicker = false
        obdManager.stopDiscovery()
    }

    func selectOBDDongle(_ dongle: OBDDongle) {
        obdManager.connect(to: dongle)
    }

    private func bind() {
        locationService.$location
            .receive(on: RunLoop.main)
            .sink { [weak self] location in
                self?.handleGPSLocation(location)
            }
            .store(in: &cancellables)

        locationService.$compassHeadingDegrees
            .receive(on: RunLoop.main)
            .sink { [weak self] heading in
                guard let heading else { return }
                self?.headingDegrees = heading
            }
            .store(in: &cancellables)

        obdManager.$speedKPH
            .receive(on: RunLoop.main)
            .sink { [weak self] speedKPH in
                self?.obdSpeedKPH = speedKPH
                self?.updateGap()
            }
            .store(in: &cancellables)

        obdManager.$connectionState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.obdConnectionState = state
                if case .connected = state {
                    self?.isShowingDevicePicker = false
                }
            }
            .store(in: &cancellables)

        obdManager.$isDiscoveringDevices
            .receive(on: RunLoop.main)
            .assign(to: &$isDiscoveringDongles)

        obdManager.$discoveredDevices
            .receive(on: RunLoop.main)
            .assign(to: &$discoveredDongles)

        obdManager.$connectingDeviceID
            .receive(on: RunLoop.main)
            .assign(to: &$connectingDongleID)

        obdManager.$connectedDeviceID
            .receive(on: RunLoop.main)
            .assign(to: &$connectedDongleID)
    }

    private func handleGPSLocation(_ location: CLLocation?) {
        guard let location else { return }

        gpsCoordinate = location.coordinate
        gpsSpeedKPH = max(location.speed, 0) * 3.6
        appendCoordinate(location.coordinate, to: &gpsTrailCoordinates)

        if obdCoordinate == nil {
            obdCoordinate = location.coordinate
            appendCoordinate(location.coordinate, to: &obdTrailCoordinates)
        }

        if !hasInitializedCamera {
            centerCameraInitially(on: location.coordinate)
        }

        updateGap()
    }

    private func startDeadReckoningLoop() {
        deadReckoningTask?.cancel()
        lastTick = Date()

        deadReckoningTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self.advanceOBDMarker()
            }
        }
    }

    private func advanceOBDMarker() {
        let now = Date()
        let delta = now.timeIntervalSince(lastTick)
        lastTick = now

        guard delta > 0 else { return }
        guard let speedKPH = obdSpeedKPH, speedKPH > 0.5 else { return }
        guard let heading = locationService.compassHeadingDegrees else { return }
        guard let currentCoordinate = obdCoordinate else { return }

        let distanceMeters = (speedKPH / 3.6) * delta
        let nextCoordinate = DeadReckoning.advance(
            from: currentCoordinate,
            distanceMeters: distanceMeters,
            bearingDegrees: heading
        )
        obdCoordinate = nextCoordinate
        appendCoordinate(nextCoordinate, to: &obdTrailCoordinates)
        updateGap()
    }

    private func appendCoordinate(
        _ coordinate: CLLocationCoordinate2D,
        to trail: inout [CLLocationCoordinate2D]
    ) {
        if let previous = trail.last {
            let previousLocation = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
            let nextLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

            guard previousLocation.distance(from: nextLocation) >= trailMinimumStepMeters else {
                return
            }
        }

        trail.append(coordinate)

        if trail.count > maxTrailPoints {
            trail.removeFirst(trail.count - maxTrailPoints)
        }
    }

    private func updateGap() {
        guard let gpsCoordinate, let obdCoordinate else {
            gapMeters = 0
            return
        }

        let gpsLocation = CLLocation(latitude: gpsCoordinate.latitude, longitude: gpsCoordinate.longitude)
        let obdLocation = CLLocation(latitude: obdCoordinate.latitude, longitude: obdCoordinate.longitude)
        gapMeters = gpsLocation.distance(from: obdLocation)
    }

    private func centerCameraInitially(on coordinate: CLLocationCoordinate2D) {
        hasInitializedCamera = true
        cameraPosition = .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
            )
        )
    }

    private func seedPreviewState() {
        gpsCoordinate = CLLocationCoordinate2D(latitude: 51.50786, longitude: -0.12765)
        obdCoordinate = CLLocationCoordinate2D(latitude: 51.50762, longitude: -0.12688)
        gpsTrailCoordinates = [
            CLLocationCoordinate2D(latitude: 51.50820, longitude: -0.12835),
            CLLocationCoordinate2D(latitude: 51.50805, longitude: -0.12805),
            CLLocationCoordinate2D(latitude: 51.50795, longitude: -0.12785),
            CLLocationCoordinate2D(latitude: 51.50786, longitude: -0.12765)
        ]
        obdTrailCoordinates = [
            CLLocationCoordinate2D(latitude: 51.50808, longitude: -0.12795),
            CLLocationCoordinate2D(latitude: 51.50792, longitude: -0.12755),
            CLLocationCoordinate2D(latitude: 51.50774, longitude: -0.12718),
            CLLocationCoordinate2D(latitude: 51.50762, longitude: -0.12688)
        ]
        gpsSpeedKPH = 5.2
        obdSpeedKPH = 3.8
        headingDegrees = 96
        gapMeters = 31
        selectedPanelPage = 0
        isPanelExpanded = true
        cameraPosition = .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 51.50755, longitude: -0.1271),
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        )
        hasInitializedCamera = true

        obdConnectionState = .connected("Demo OBD")
        connectedDongleID = UUID()
        obdManager.setPreviewState(speedKPH: 3.8, connectionState: .connected("Demo OBD"))
    }
}

extension NavigationViewModel {
    static var preview: NavigationViewModel {
        NavigationViewModel(previewMode: true)
    }
}
