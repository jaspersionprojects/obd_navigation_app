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
    @Published private(set) var isStationaryByIMU = false
    @Published private(set) var isCompassCalibrationActive = false
    @Published private(set) var isResolvingCompassCalibrationRoad = false
    @Published private(set) var compassCalibrationCandidate: CompassCalibrationCandidate?
    @Published private(set) var compassCalibrationTapCoordinate: CLLocationCoordinate2D?
    @Published private(set) var compassCalibrationOffsetDegrees: CLLocationDirection = 0
    @Published private(set) var compassCalibrationMessage = "Tap a road to calibrate the compass."

    let locationService: LocationService
    let obdManager: OBDBLEManager
    let motionService: MotionService

    private var cancellables = Set<AnyCancellable>()
    private var deadReckoningTask: Task<Void, Never>?
    private var compassCalibrationTask: Task<Void, Never>?
    private var lastTick = Date()
    private let previewMode: Bool
    private var hasStarted = false
    private var hasInitializedCamera = false
    private let trailMinimumStepMeters: CLLocationDistance = 1.5
    private let maxTrailPoints = 4_000
    private var stationaryDetector = StationaryDetector()
    private var stationaryVelocityHoldActive = false
    private var reportedOBDSpeedKPH: Double?
    private var rawCompassHeadingDegrees: CLLocationDirection?

    private static let compassCalibrationOffsetDefaultsKey = "CompassCalibrationOffsetDegrees"

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

    var calibrationButtonTitle: String {
        isCompassCalibrationActive ? "Cancel Calibration" : "Calibrate Compass"
    }

    var calibrationButtonSubtitle: String {
        if isResolvingCompassCalibrationRoad {
            return "Reading the road under your tap"
        }

        if compassCalibrationCandidate != nil {
            return "Choose the arrow that matches your direction"
        }

        if isCompassCalibrationActive {
            return "Tap the road you are driving on"
        }

        if abs(compassCalibrationOffsetDegrees) >= 0.1 {
            return "Saved offset \(formattedCalibrationOffset)"
        }

        return "No saved offset yet"
    }

    var calibrationStatusTitle: String {
        if isResolvingCompassCalibrationRoad {
            return "Finding Road Direction"
        }

        if compassCalibrationCandidate != nil {
            return "Choose Your Direction"
        }

        if isCompassCalibrationActive {
            return "Tap The Road On The Map"
        }

        return "Compass Offset"
    }

    var calibrationOverlayText: String? {
        guard isCompassCalibrationActive || compassCalibrationCandidate != nil || isResolvingCompassCalibrationRoad else {
            return nil
        }

        return compassCalibrationMessage
    }

    var calibrationGuideCoordinates: [CLLocationCoordinate2D] {
        guard
            let forwardCoordinate = compassCalibrationForwardArrowCoordinate,
            let reverseCoordinate = compassCalibrationReverseArrowCoordinate
        else {
            return []
        }

        return [reverseCoordinate, forwardCoordinate]
    }

    var compassCalibrationForwardArrowCoordinate: CLLocationCoordinate2D? {
        guard let compassCalibrationCandidate else { return nil }

        return DeadReckoning.advance(
            from: compassCalibrationCandidate.anchorCoordinate,
            distanceMeters: 16,
            bearingDegrees: compassCalibrationCandidate.forwardBearingDegrees
        )
    }

    var compassCalibrationReverseArrowCoordinate: CLLocationCoordinate2D? {
        guard let compassCalibrationCandidate else { return nil }

        return DeadReckoning.advance(
            from: compassCalibrationCandidate.anchorCoordinate,
            distanceMeters: 16,
            bearingDegrees: normalizeDegrees(compassCalibrationCandidate.forwardBearingDegrees + 180)
        )
    }

    convenience init(previewMode: Bool = false) {
        self.init(
            locationService: LocationService(),
            obdManager: OBDBLEManager(),
            motionService: MotionService(),
            previewMode: previewMode
        )
    }

    init(
        locationService: LocationService,
        obdManager: OBDBLEManager,
        motionService: MotionService,
        previewMode: Bool = false
    ) {
        self.locationService = locationService
        self.obdManager = obdManager
        self.motionService = motionService
        self.previewMode = previewMode
        self.compassCalibrationOffsetDegrees = UserDefaults.standard.double(
            forKey: Self.compassCalibrationOffsetDefaultsKey
        )

        if previewMode {
            seedPreviewState()
        } else {
            bind()
        }
    }

    deinit {
        deadReckoningTask?.cancel()
        compassCalibrationTask?.cancel()
    }

    func start() {
        guard !previewMode, !hasStarted else { return }
        hasStarted = true
        locationService.start()
        obdManager.start()
        motionService.start()
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

    func toggleCompassCalibration() {
        if isCompassCalibrationActive || compassCalibrationCandidate != nil || isResolvingCompassCalibrationRoad {
            cancelCompassCalibration()
        } else {
            beginCompassCalibration()
        }
    }

    func handleCompassCalibrationTap(at coordinate: CLLocationCoordinate2D) {
        guard isCompassCalibrationActive else { return }
        guard !isResolvingCompassCalibrationRoad else { return }
        guard compassCalibrationCandidate == nil else { return }

        compassCalibrationTapCoordinate = coordinate
        compassCalibrationMessage = "Finding road direction..."
        isResolvingCompassCalibrationRoad = true

        compassCalibrationTask?.cancel()
        compassCalibrationTask = Task { [weak self] in
            guard let self else { return }

            do {
                let candidate = try await RoadAlignmentResolver.resolveRoadAlignment(near: coordinate)
                guard !Task.isCancelled else { return }

                self.compassCalibrationCandidate = candidate
                self.compassCalibrationTapCoordinate = candidate.anchorCoordinate
                self.isResolvingCompassCalibrationRoad = false
                self.compassCalibrationMessage = "Choose the arrow that matches your direction of travel."
            } catch {
                guard !Task.isCancelled else { return }

                self.compassCalibrationCandidate = nil
                self.isResolvingCompassCalibrationRoad = false
                self.compassCalibrationMessage = error.localizedDescription.isEmpty
                    ? "Couldn’t read that road. Tap the road again."
                    : error.localizedDescription
            }
        }
    }

    func chooseForwardCompassCalibrationDirection() {
        guard let compassCalibrationCandidate else { return }
        applyCompassCalibration(
            targetBearingDegrees: compassCalibrationCandidate.forwardBearingDegrees
        )
    }

    func chooseReverseCompassCalibrationDirection() {
        guard let compassCalibrationCandidate else { return }
        applyCompassCalibration(
            targetBearingDegrees: normalizeDegrees(compassCalibrationCandidate.forwardBearingDegrees + 180)
        )
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
                self?.handleRawCompassHeading(heading)
            }
            .store(in: &cancellables)

        motionService.$latestSample
            .receive(on: RunLoop.main)
            .sink { [weak self] sample in
                self?.handleMotionSample(sample)
            }
            .store(in: &cancellables)

        obdManager.$speedKPH
            .receive(on: RunLoop.main)
            .sink { [weak self] speedKPH in
                self?.handleReportedOBDSpeed(speedKPH)
            }
            .store(in: &cancellables)

        obdManager.$connectionState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.obdConnectionState = state
                if case .connected = state {
                    self?.isShowingDevicePicker = false
                } else if case .connecting = state {
                    self?.resetStationaryHold()
                } else {
                    self?.resetStationaryState()
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

    private func handleMotionSample(_ sample: MotionSample?) {
        guard let sample else { return }

        isStationaryByIMU = stationaryDetector.update(
            correctedAccelerationG: sample.correctedAccelerationG,
            correctedRotationRateRadPerSec: sample.correctedRotationRateRadPerSec,
            currentHeadingDegrees: calibratedCompassHeadingDegrees
        )

        applyEffectiveOBDSpeed()
    }

    private func handleReportedOBDSpeed(_ speedKPH: Double?) {
        reportedOBDSpeedKPH = speedKPH
        applyEffectiveOBDSpeed()
    }

    private func applyEffectiveOBDSpeed() {
        let rawSpeedKPH = reportedOBDSpeedKPH

        if stationaryVelocityHoldActive {
            if let rawSpeedKPH, rawSpeedKPH <= 0 {
                stationaryVelocityHoldActive = false
            } else if rawSpeedKPH == nil {
                stationaryVelocityHoldActive = false
            } else {
                obdSpeedKPH = 0
                updateGap()
                return
            }
        }

        if isStationaryByIMU, rawSpeedKPH != nil {
            stationaryVelocityHoldActive = true
            obdSpeedKPH = 0
        } else {
            obdSpeedKPH = rawSpeedKPH
        }

        updateGap()
    }

    private func resetStationaryHold() {
        stationaryVelocityHoldActive = false
        obdSpeedKPH = reportedOBDSpeedKPH
        updateGap()
    }

    private func resetStationaryState() {
        stationaryDetector.reset()
        isStationaryByIMU = false
        stationaryVelocityHoldActive = false
        reportedOBDSpeedKPH = nil
        obdSpeedKPH = nil
        updateGap()
    }

    private func startDeadReckoningLoop() {
        deadReckoningTask?.cancel()
        lastTick = Date()

        deadReckoningTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(83))
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
        guard let heading = calibratedCompassHeadingDegrees else { return }
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
            compactTrail(&trail)
        }
    }

    private func compactTrail(_ trail: inout [CLLocationCoordinate2D]) {
        guard trail.count > maxTrailPoints else { return }

        var compacted: [CLLocationCoordinate2D] = []
        compacted.reserveCapacity((trail.count / 2) + 1)

        for (index, coordinate) in trail.enumerated() where index.isMultiple(of: 2) {
            compacted.append(coordinate)
        }

        if let lastCoordinate = trail.last,
           let compactedLast = compacted.last,
           compactedLast.latitude != lastCoordinate.latitude ||
           compactedLast.longitude != lastCoordinate.longitude {
            compacted.append(lastCoordinate)
        } else if let lastCoordinate = trail.last, compacted.isEmpty {
            compacted.append(lastCoordinate)
        }

        trail = compacted
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

    private func beginCompassCalibration() {
        isCompassCalibrationActive = true
        isResolvingCompassCalibrationRoad = false
        compassCalibrationCandidate = nil
        compassCalibrationTapCoordinate = nil
        compassCalibrationMessage = "Tap the road you are driving on."
    }

    private func cancelCompassCalibration() {
        compassCalibrationTask?.cancel()
        compassCalibrationTask = nil
        isCompassCalibrationActive = false
        isResolvingCompassCalibrationRoad = false
        compassCalibrationCandidate = nil
        compassCalibrationTapCoordinate = nil
        compassCalibrationMessage = abs(compassCalibrationOffsetDegrees) >= 0.1
            ? "Saved offset \(formattedCalibrationOffset)"
            : "Tap a road to calibrate the compass."
    }

    private func applyCompassCalibration(targetBearingDegrees: CLLocationDirection) {
        guard let rawCompassHeadingDegrees else {
            compassCalibrationMessage = "Heading unavailable. Keep the phone steady and try again."
            return
        }

        compassCalibrationOffsetDegrees = signedDeltaDegrees(
            from: rawCompassHeadingDegrees,
            to: targetBearingDegrees
        )
        UserDefaults.standard.set(
            compassCalibrationOffsetDegrees,
            forKey: Self.compassCalibrationOffsetDefaultsKey
        )

        headingDegrees = normalizeDegrees(rawCompassHeadingDegrees + compassCalibrationOffsetDegrees)
        isCompassCalibrationActive = false
        isResolvingCompassCalibrationRoad = false
        compassCalibrationCandidate = nil
        compassCalibrationTapCoordinate = nil
        compassCalibrationMessage = "Compass calibrated with \(formattedCalibrationOffset) applied."
    }

    private func handleRawCompassHeading(_ heading: CLLocationDirection?) {
        rawCompassHeadingDegrees = heading

        guard let calibratedCompassHeadingDegrees else { return }
        headingDegrees = calibratedCompassHeadingDegrees
    }

    private var calibratedCompassHeadingDegrees: CLLocationDirection? {
        guard let rawCompassHeadingDegrees else { return nil }
        return normalizeDegrees(rawCompassHeadingDegrees + compassCalibrationOffsetDegrees)
    }

    private var formattedCalibrationOffset: String {
        let sign = compassCalibrationOffsetDegrees >= 0 ? "+" : "-"
        return "\(sign)\(abs(compassCalibrationOffsetDegrees).formatted(.number.precision(.fractionLength(1))))°"
    }

    private func normalizeDegrees(_ value: CLLocationDirection) -> CLLocationDirection {
        let normalized = value.truncatingRemainder(dividingBy: 360)
        return normalized >= 0 ? normalized : normalized + 360
    }

    private func signedDeltaDegrees(
        from source: CLLocationDirection,
        to target: CLLocationDirection
    ) -> CLLocationDirection {
        let delta = normalizeDegrees(target - source)
        return delta > 180 ? delta - 360 : delta
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
        reportedOBDSpeedKPH = 3.8
        compassCalibrationOffsetDegrees = 4.5
        headingDegrees = 100.5
        gapMeters = 31
        selectedPanelPage = 0
        isPanelExpanded = true
        isStationaryByIMU = false
        compassCalibrationMessage = "Saved offset +4.5°"
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
