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
    @Published var isShowingSensorPicker = false
    @Published var cameraPosition: MapCameraPosition = .region(NavigationViewModel.defaultRegion)

    @Published private(set) var obdConnectionState: OBDConnectionState = .idle
    @Published private(set) var isDiscoveringDongles = false
    @Published private(set) var discoveredDongles: [OBDDongle] = []
    @Published private(set) var connectingDongleID: UUID?
    @Published private(set) var connectedDongleID: UUID?
    @Published private(set) var sensorConnectionState: WitMotionSensorConnectionState = .idle
    @Published private(set) var isDiscoveringSensors = false
    @Published private(set) var discoveredSensors: [WitMotionDevice] = []
    @Published private(set) var connectingSensorID: UUID?
    @Published private(set) var connectedSensorID: UUID?
    @Published private(set) var isExternalSensorEnabled = false
    @Published private(set) var isStationaryByIMU = false
    @Published private(set) var isCompassCalibrationActive = false
    @Published private(set) var isResolvingCompassCalibrationRoad = false
    @Published private(set) var compassCalibrationCandidate: CompassCalibrationCandidate?
    @Published private(set) var compassCalibrationTapCoordinate: CLLocationCoordinate2D?
    @Published private(set) var compassCalibrationOffsetDegrees: CLLocationDirection = 0
    @Published private(set) var compassCalibrationMessage = "Tap a road to calibrate the compass."
    @Published private(set) var transientBannerText: String?
    @Published private(set) var isCompassOffsetLocked = false
    @Published private(set) var isOBDMarkerVisible = true
    @Published private(set) var isRoadLockEnabled = false
    @Published private(set) var isResolvingRoadLock = false
    @Published private(set) var roadLockCoordinate: CLLocationCoordinate2D?
    @Published private(set) var roadLockTrailSegments: [[CLLocationCoordinate2D]] = []
    @Published private(set) var roadLockStatusMessage = "Road lock is off."
    @Published private(set) var isTestRecording = false
    @Published private(set) var testStatusMessage = "Ready to log a CSV sample every 20 seconds."
    @Published private(set) var testSampleCount = 0
    @Published private(set) var pendingTestCSV = ""
    @Published private(set) var pendingTestExportFilename = "obdnav-test.csv"
    @Published private(set) var isShowingTestExport = false

    let locationService: LocationService
    let obdManager: OBDBLEManager
    let motionService: MotionService
    let sensorManager: WitMotionBLEManager

    private var cancellables = Set<AnyCancellable>()
    private var deadReckoningTask: Task<Void, Never>?
    private var compassCalibrationTask: Task<Void, Never>?
    private var roadLockTask: Task<Void, Never>?
    private var roadLockRouteExtensionTask: Task<Void, Never>?
    private var testLoggingTask: Task<Void, Never>?
    private var transientBannerTask: Task<Void, Never>?
    private var lastTick = Date()
    private let previewMode: Bool
    private var hasStarted = false
    private var hasInitializedCamera = false
    private let trailMinimumStepMeters: CLLocationDistance = 1.5
    private let maxTrailPoints = 4_000
    private var stationaryDetector = StationaryDetector()
    private var stationaryVelocityHoldActive = false
    private var reportedOBDSpeedKPH: Double?
    private var phoneCompassCalibrationOffsetDegrees: CLLocationDirection = 0
    private var externalSensorCalibrationOffsetDegrees: CLLocationDirection = 0
    private var rawCompassHeadingDegrees: CLLocationDirection?
    private var fusedSensorHeadingDegrees: CLLocationDirection?
    private var externalSensorHeadingDegrees: CLLocationDirection?
    private var externalFusedSensorHeadingDegrees: CLLocationDirection?
    private var lastMotionYawRadians: Double?
    private var lastExternalSensorSampleDate: Date?
    private var activeRoadLockRouteCoordinates: [CLLocationCoordinate2D] = []
    private var activeRoadLockProjection: RoadLockProjection?
    private var isRoadLockSegmentOpen = false
    private var lastRoadLockRefreshDate = Date.distantPast
    private var lastRoadLockRefreshCoordinate: CLLocationCoordinate2D?
    private var lastRoadLockSuccessfulMatchDate = Date.distantPast
    private var roadLockConfidenceStreak = 0
    private var activeRoadLockRouteVersion = 0
    private var lastRoadLockRouteExtensionAttemptDate = Date.distantPast
    private var lastRoadHeadingNotificationDate = Date.distantPast
    private var lastRoadHeadingNotificationDegrees: CLLocationDirection?
    private var testEntries: [TestLogEntry] = []
    private var testGPSDistanceTravelledMeters: CLLocationDistance = 0
    private var lastTestGPSCoordinate: CLLocationCoordinate2D?
    private var lastTestSnapshotDate: Date?

    private static let phoneCompassCalibrationOffsetDefaultsKey = "PhoneCompassCalibrationOffsetDegrees"
    private static let externalSensorCalibrationOffsetDefaultsKey = "ExternalSensorCalibrationOffsetDegrees"
    private static let roadLockRefreshInterval: TimeInterval = 0.9
    private static let roadLockRefreshDistanceMeters: CLLocationDistance = 10
    private static let roadLockRouteExtensionTriggerDistanceMeters: CLLocationDistance = 45
    private static let roadLockRouteExtensionCooldown: TimeInterval = 1.25
    private static let headingFreezeSpeedKPH = 0.8
    private static let minimumCompassCorrectionSpeedKPH = 3.0
    private static let fullCompassCorrectionSpeedKPH = 26.0
    private static let stableRotationRateThresholdRadPerSec = 0.16
    private static let movingCompassCorrectionGain = 0.02
    private static let stableCompassCorrectionGain = 0.08
    private static let movingCompassCorrectionClampDegrees = 0.35
    private static let stableCompassCorrectionClampDegrees = 1.4
    private static let maximumCompassCorrectionDeltaDegrees = 110.0
    private static let maximumAbsoluteHeadingCorrectionWithoutGyroDegrees = 18.0
    private static let absoluteHeadingCorrectionGyroAllowanceMultiplier = 3.2
    private static let absoluteHeadingCorrectionRotationAllowanceDegrees = 6.0
    private static let minimumRoadHeadingCorrectionSpeedKPH = 8.0
    private static let fullRoadHeadingCorrectionSpeedKPH = 32.0
    private static let roadHeadingCorrectionWindowMeters = 28.0
    private static let maximumRoadHeadingStraightnessDegrees = 12.0
    private static let minimumRoadHeadingConfidenceStreak = 2
    private static let roadHeadingCorrectionFreshnessInterval: TimeInterval = 3.0
    private static let maximumRoadHeadingCorrectionDeltaDegrees = 75.0
    private static let movingRoadHeadingCorrectionGain = 0.05
    private static let stableRoadHeadingCorrectionGain = 0.12
    private static let movingRoadHeadingCorrectionClampDegrees = 0.45
    private static let stableRoadHeadingCorrectionClampDegrees = 1.1
    private static let roadHeadingNotificationMinimumDeltaDegrees = 2.0
    private static let roadHeadingNotificationChangeThresholdDegrees = 3.0
    private static let roadHeadingNotificationCooldown: TimeInterval = 3.0
    private static let transientBannerDuration: TimeInterval = 2.4
    private static let testLoggingInterval: TimeInterval = 20.0
    private static let testExportDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

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

    var sensorStatusText: String {
        if isDiscoveringSensors, case .idle = sensorConnectionState {
            return "Scanning for nearby sensors"
        }

        return sensorConnectionState.displayText
    }

    var sensorStatusTint: Color {
        sensorConnectionState.tint
    }

    var sensorConnectButtonSubtitle: String {
        switch sensorConnectionState {
        case .connected(let name):
            return "Currently connected to \(name)"
        case .connecting(let name):
            return "Connecting to \(name)"
        case .bluetoothOff:
            return "Turn Bluetooth on to discover sensors"
        case .failed(let message):
            return message
        case .idle:
            return isDiscoveringSensors ? "Looking for nearby WITMotion BLE sensors" : "Choose your nearby BLE IMU sensor"
        }
    }

    var sensorEnableButtonTitle: String {
        isExternalSensorEnabled ? "Sensor Enabled" : "Enable Sensor"
    }

    var sensorEnableButtonSubtitle: String {
        if isExternalSensorEnabled {
            return "Heading and IMU data now come from the BLE sensor only."
        }

        if case .connected(let name) = sensorConnectionState {
            return "Use \(name) instead of the iPhone compass and gyro."
        }

        return "Connect the BLE sensor first, then enable it here."
    }

    var compassOffsetLockButtonTitle: String {
        isCompassOffsetLocked ? "Offset Locked" : "Offset Unlocked"
    }

    var compassOffsetLockButtonSystemImage: String {
        isCompassOffsetLocked ? "lock.fill" : "lock.open.fill"
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

    var roadLockButtonTitle: String {
        isRoadLockEnabled ? "Road Lock On" : "Road Lock"
    }

    var obdMarkerButtonTitle: String {
        isOBDMarkerVisible ? "Hide OBD Marker" : "Show OBD Marker"
    }

    var obdMarkerButtonSubtitle: String {
        isOBDMarkerVisible ? "Hide the orange raw OBD marker from the map." : "Show the orange raw OBD marker on the map."
    }

    var roadLockButtonSubtitle: String {
        if isResolvingRoadLock {
            return "Matching the recent route to nearby roads"
        }

        if isRoadLockEnabled, roadLockCoordinate != nil {
            return "Pink marker is following the matched road path"
        }

        if isRoadLockEnabled {
            return "Waiting for a confident road fit nearby"
        }

        return "Map the raw OBD route onto nearby roads"
    }

    var roadLockStatusTitle: String {
        if isResolvingRoadLock {
            return "Matching Nearby Roads"
        }

        if isRoadLockEnabled, roadLockCoordinate != nil {
            return "Road Lock Active"
        }

        if isRoadLockEnabled {
            return "Awaiting Road Fit"
        }

        return "Road Lock Off"
    }

    var testButtonTitle: String {
        isTestRecording ? "Stop Test" : "Start Test"
    }

    var testButtonSubtitle: String {
        if isTestRecording {
            return "Logging a CSV row every 20 seconds. Press stop to save the file."
        }

        return "Record timestamped GPS, raw OBD, and road-lock gap data to a CSV export."
    }

    var shouldShowRoadLockOverlay: Bool {
        isRoadLockEnabled
    }

    var calibrationOverlayText: String? {
        if let transientBannerText {
            return transientBannerText
        }

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
            sensorManager: WitMotionBLEManager(),
            previewMode: previewMode
        )
    }

    init(
        locationService: LocationService,
        obdManager: OBDBLEManager,
        motionService: MotionService,
        sensorManager: WitMotionBLEManager,
        previewMode: Bool = false
    ) {
        self.locationService = locationService
        self.obdManager = obdManager
        self.motionService = motionService
        self.sensorManager = sensorManager
        self.previewMode = previewMode
        self.phoneCompassCalibrationOffsetDegrees = UserDefaults.standard.double(
            forKey: Self.phoneCompassCalibrationOffsetDefaultsKey
        )
        self.externalSensorCalibrationOffsetDegrees = UserDefaults.standard.double(
            forKey: Self.externalSensorCalibrationOffsetDefaultsKey
        )
        self.compassCalibrationOffsetDegrees = phoneCompassCalibrationOffsetDegrees

        if previewMode {
            seedPreviewState()
        } else {
            bind()
        }
    }

    deinit {
        deadReckoningTask?.cancel()
        compassCalibrationTask?.cancel()
        roadLockTask?.cancel()
        roadLockRouteExtensionTask?.cancel()
        testLoggingTask?.cancel()
    }

    func start() {
        guard !previewMode, !hasStarted else { return }
        hasStarted = true
        locationService.start()
        obdManager.start()
        motionService.start()
        sensorManager.start()
        startDeadReckoningLoop()
    }

    func snapOBDToGPS() {
        guard let gpsCoordinate else { return }
        obdCoordinate = gpsCoordinate
        appendCoordinate(gpsCoordinate, to: &obdTrailCoordinates)
        if isRoadLockEnabled {
            resetActiveRoadLockRoute()
            refreshRoadLockIfNeeded(force: true)
        }
        updateGap()
    }

    func showOBDDevicePicker() {
        isShowingDevicePicker = true
        obdManager.beginDiscovery()
    }

    func showSensorPicker() {
        isShowingSensorPicker = true
        sensorManager.beginDiscovery()
    }

    func beginDongleDiscovery() {
        obdManager.beginDiscovery()
    }

    func beginSensorDiscovery() {
        sensorManager.beginDiscovery()
    }

    func didDismissDevicePicker() {
        isShowingDevicePicker = false
        obdManager.stopDiscovery()
    }

    func didDismissSensorPicker() {
        isShowingSensorPicker = false
        sensorManager.stopDiscovery()
    }

    func selectOBDDongle(_ dongle: OBDDongle) {
        obdManager.connect(to: dongle)
    }

    func selectSensor(_ sensor: WitMotionDevice) {
        sensorManager.connect(to: sensor)
    }

    func toggleExternalSensorUsage() {
        if isExternalSensorEnabled {
            disableExternalSensorUsage()
        } else {
            enableExternalSensorUsage()
        }
    }

    func toggleRoadLock() {
        if isRoadLockEnabled {
            disableRoadLock()
        } else {
            enableRoadLock()
        }
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

    func toggleOBDMarkerVisibility() {
        isOBDMarkerVisible.toggle()
    }

    func clearAllTrails() {
        gpsTrailCoordinates = gpsCoordinate.map { [$0] } ?? []
        obdTrailCoordinates = obdCoordinate.map { [$0] } ?? []

        if let roadLockCoordinate {
            roadLockTrailSegments = [[roadLockCoordinate]]
            isRoadLockSegmentOpen = true
        } else {
            roadLockTrailSegments = []
            breakRoadLockSegment()
        }
    }

    private func startTestSession() {
        isTestRecording = true
        testEntries = []
        testGPSDistanceTravelledMeters = 0
        lastTestGPSCoordinate = gpsCoordinate
        lastTestSnapshotDate = nil
        testSampleCount = 0
        pendingTestCSV = ""
        isShowingTestExport = false
        pendingTestExportFilename = makeTestExportFilename(for: Date())
        testStatusMessage = "Test running. Logging a CSV row every 20 seconds."

        testLoggingTask?.cancel()
        testLoggingTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.testLoggingInterval))
                guard !Task.isCancelled else { return }
                self.recordTestSnapshot()
            }
        }
    }

    private func stopTestSession() {
        isTestRecording = false
        testLoggingTask?.cancel()
        testLoggingTask = nil

        recordTestSnapshot(force: true)
        pendingTestCSV = buildTestCSV()
        pendingTestExportFilename = makeTestExportFilename(for: Date())
        isShowingTestExport = true
        testStatusMessage = "CSV ready to save."
    }

    func applyManualCompassCalibrationOffset(_ input: String) {
        let normalizedInput = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")

        guard !normalizedInput.isEmpty else {
            compassCalibrationMessage = "Enter a compass offset in degrees first."
            return
        }

        guard let parsedOffset = Double(normalizedInput), parsedOffset.isFinite else {
            compassCalibrationMessage = "Enter a valid positive or negative degree offset."
            return
        }

        applyCompassCalibrationOffset(parsedOffset, messagePrefix: "Manual offset")
    }

    func nudgeCompassCalibrationOffset(by deltaDegrees: CLLocationDirection) {
        applyCompassCalibrationOffset(
            compassCalibrationOffsetDegrees + deltaDegrees,
            messagePrefix: "Compass offset"
        )
    }

    func toggleCompassOffsetLock() {
        isCompassOffsetLocked.toggle()
        transientBannerText = nil
        compassCalibrationMessage = isCompassOffsetLocked
            ? "Compass offset locked. Road lock and manual calibration cannot change it."
            : "Compass offset unlocked."
    }

    func toggleTestSession() {
        if isTestRecording {
            stopTestSession()
        } else {
            startTestSession()
        }
    }

    func dismissTestExport() {
        isShowingTestExport = false
        pendingTestCSV = ""
    }

    func handleTestExportCompletion(_ result: Result<URL, Error>) {
        defer { dismissTestExport() }

        switch result {
        case .success:
            testStatusMessage = "CSV export completed."
        case .failure(let error):
            testStatusMessage = error.localizedDescription.isEmpty
                ? "CSV export was cancelled."
                : "CSV export failed: \(error.localizedDescription)"
        }
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

        sensorManager.$latestSample
            .receive(on: RunLoop.main)
            .sink { [weak self] sample in
                self?.handleExternalSensorSample(sample)
            }
            .store(in: &cancellables)

        sensorManager.$connectionState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }

                let previousSensorConnectionState = self.sensorConnectionState
                self.sensorConnectionState = state

                if case .connected(let name) = previousSensorConnectionState {
                    switch state {
                    case .connected:
                        break
                    case .failed(let message):
                        self.showTransientBanner(
                            message.isEmpty
                                ? "Lost connection to sensor \(name)"
                                : "Lost connection to sensor \(name): \(message)"
                        )
                    case .bluetoothOff:
                        self.showTransientBanner("Lost connection to sensor \(name): Bluetooth is off")
                    case .idle, .connecting:
                        self.showTransientBanner("Lost connection to sensor \(name)")
                    }
                }

                if case .connected = state {
                    self.isShowingSensorPicker = false
                    if !self.isExternalSensorEnabled {
                        self.enableExternalSensorUsage()
                    }
                } else if self.isExternalSensorEnabled {
                    self.disableExternalSensorUsage()
                }
            }
            .store(in: &cancellables)

        sensorManager.$isDiscoveringDevices
            .receive(on: RunLoop.main)
            .assign(to: &$isDiscoveringSensors)

        sensorManager.$discoveredDevices
            .receive(on: RunLoop.main)
            .assign(to: &$discoveredSensors)

        sensorManager.$connectingDeviceID
            .receive(on: RunLoop.main)
            .assign(to: &$connectingSensorID)

        sensorManager.$connectedDeviceID
            .receive(on: RunLoop.main)
            .assign(to: &$connectedSensorID)
    }

    private func updateTestDistance(with coordinate: CLLocationCoordinate2D) {
        guard isTestRecording else {
            lastTestGPSCoordinate = coordinate
            return
        }

        if let lastTestGPSCoordinate {
            let distance = CLLocation(latitude: lastTestGPSCoordinate.latitude, longitude: lastTestGPSCoordinate.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            testGPSDistanceTravelledMeters += distance
        }

        lastTestGPSCoordinate = coordinate
    }

    private func recordTestSnapshot(force: Bool = false) {
        guard isTestRecording || force else { return }

        let now = Date()
        if force,
           let lastTestSnapshotDate,
           now.timeIntervalSince(lastTestSnapshotDate) < 1.0 {
            return
        }

        let gpsToOBDDistanceMeters = markerDistance(from: gpsCoordinate, to: obdCoordinate)
        let gpsToRoadLockDistanceMeters = markerDistance(from: gpsCoordinate, to: roadLockCoordinate)
        let isOnSameRoad = isGPSMarkerOnCurrentRoadLockRoad()

        testEntries.append(
            TestLogEntry(
                timestamp: now,
                gpsDistanceTravelledMeters: testGPSDistanceTravelledMeters,
                gpsToRawOBDDistanceMeters: gpsToOBDDistanceMeters,
                gpsToRoadLockDistanceMeters: gpsToRoadLockDistanceMeters,
                gpsAndRoadLockOnSameRoad: isOnSameRoad
            )
        )

        lastTestSnapshotDate = now
        testSampleCount = testEntries.count

        if isTestRecording {
            testStatusMessage = "Recorded \(testEntries.count) sample\(testEntries.count == 1 ? "" : "s")."
        }
    }

    private func buildTestCSV() -> String {
        var lines = ["timestamp,gps_distance_travelled_m,gps_to_raw_obd_m,gps_to_road_lock_m,gps_and_road_lock_same_road"]

        for entry in testEntries {
            lines.append([
                Self.testExportDateFormatter.string(from: entry.timestamp),
                csvNumber(entry.gpsDistanceTravelledMeters),
                csvNumber(entry.gpsToRawOBDDistanceMeters),
                csvNumber(entry.gpsToRoadLockDistanceMeters),
                entry.gpsAndRoadLockOnSameRoad ? "yes" : "no"
            ].joined(separator: ","))
        }

        return lines.joined(separator: "\n")
    }

    private func makeTestExportFilename(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_GB_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "obdnav-test-\(formatter.string(from: date)).csv"
    }

    private func csvNumber(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    private func markerDistance(
        from source: CLLocationCoordinate2D?,
        to target: CLLocationCoordinate2D?
    ) -> CLLocationDistance? {
        guard let source, let target else { return nil }

        return CLLocation(latitude: source.latitude, longitude: source.longitude)
            .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
    }

    private func isGPSMarkerOnCurrentRoadLockRoad() -> Bool {
        guard let gpsCoordinate else { return false }
        guard roadLockCoordinate != nil else { return false }
        guard !activeRoadLockRouteCoordinates.isEmpty else { return false }

        return RoadLockMatcher.isLikelyOnSameRoad(
            gpsCoordinate,
            as: activeRoadLockRouteCoordinates
        )
    }

    private func handleGPSLocation(_ location: CLLocation?) {
        guard let location else { return }

        updateTestDistance(with: location.coordinate)

        gpsCoordinate = location.coordinate
        gpsSpeedKPH = max(location.speed, 0) * 3.6
        appendCoordinate(location.coordinate, to: &gpsTrailCoordinates)

        if obdCoordinate == nil {
            obdCoordinate = location.coordinate
            appendCoordinate(location.coordinate, to: &obdTrailCoordinates)

            if isRoadLockEnabled {
                refreshRoadLockIfNeeded(force: true)
            }
        }

        if !hasInitializedCamera {
            centerCameraInitially(on: location.coordinate)
        }

        updateGap()
    }

    private func handleMotionSample(_ sample: MotionSample?) {
        guard !isExternalSensorEnabled else { return }
        guard let sample else { return }

        updateFusedHeading(using: sample)

        isStationaryByIMU = stationaryDetector.update(
            correctedAccelerationG: sample.correctedAccelerationG,
            correctedRotationRateRadPerSec: sample.correctedRotationRateRadPerSec,
            currentHeadingDegrees: calibratedCompassHeadingDegrees
        )

        applyEffectiveOBDSpeed()
    }

    private func handleExternalSensorSample(_ sample: WitMotionSample?) {
        guard isExternalSensorEnabled else { return }
        guard let sample else { return }

        externalSensorHeadingDegrees = sample.yawDegrees

        updateExternalFusedHeading(using: sample)

        if let calibratedCompassHeadingDegrees {
            headingDegrees = calibratedCompassHeadingDegrees
        }

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

    private func resetStationaryTrackingState() {
        stationaryDetector.reset()
        isStationaryByIMU = false
        stationaryVelocityHoldActive = false
        applyEffectiveOBDSpeed()
    }

    private func resetStationaryState() {
        stationaryDetector.reset()
        isStationaryByIMU = false
        stationaryVelocityHoldActive = false
        reportedOBDSpeedKPH = nil
        obdSpeedKPH = nil
        if isRoadLockEnabled {
            roadLockCoordinate = nil
            roadLockStatusMessage = "Road lock is waiting for fresh OBD movement."
            resetActiveRoadLockRoute()
        }
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

        if isRoadLockEnabled {
            refreshRoadLockIfNeeded()
        }

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
        if isRoadLockEnabled {
            advanceRoadLockMarker(by: distanceMeters)
            refreshRoadLockIfNeeded()
        }
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

    private func appendRoadLockCoordinate(_ coordinate: CLLocationCoordinate2D) {
        if !isRoadLockSegmentOpen || roadLockTrailSegments.isEmpty {
            roadLockTrailSegments.append([coordinate])
            isRoadLockSegmentOpen = true
            return
        }

        var currentSegment = roadLockTrailSegments.removeLast()
        appendCoordinate(coordinate, to: &currentSegment)
        roadLockTrailSegments.append(currentSegment)
    }

    private func breakRoadLockSegment() {
        isRoadLockSegmentOpen = false
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
        guard let sensorHeadingDegrees = stabilizedSensorHeadingDegrees else {
            compassCalibrationMessage = "Heading unavailable. Keep the phone steady and try again."
            return
        }

        let offsetDegrees = signedDeltaDegrees(
            from: sensorHeadingDegrees,
            to: targetBearingDegrees
        )
        applyCompassCalibrationOffset(offsetDegrees, messagePrefix: "Compass calibrated")
    }

    private func handleRawCompassHeading(_ heading: CLLocationDirection?) {
        guard !isExternalSensorEnabled else { return }
        rawCompassHeadingDegrees = heading

        if fusedSensorHeadingDegrees == nil {
            fusedSensorHeadingDegrees = heading
        }

        guard let calibratedCompassHeadingDegrees else { return }
        headingDegrees = calibratedCompassHeadingDegrees
    }

    private func applyCompassCalibrationOffset(
        _ offsetDegrees: CLLocationDirection,
        messagePrefix: String
    ) {
        guard !isCompassOffsetLocked else {
            compassCalibrationMessage = "Compass offset is locked."
            return
        }

        saveActiveCompassCalibrationOffset(normalizedSignedDegrees(offsetDegrees))

        if let stabilizedSensorHeadingDegrees {
            headingDegrees = normalizeDegrees(stabilizedSensorHeadingDegrees + compassCalibrationOffsetDegrees)
        }

        isCompassCalibrationActive = false
        isResolvingCompassCalibrationRoad = false
        compassCalibrationCandidate = nil
        compassCalibrationTapCoordinate = nil
        compassCalibrationMessage = "\(messagePrefix) \(formattedCalibrationOffset) applied."
    }

    private func enableExternalSensorUsage() {
        guard case .connected = sensorConnectionState else {
            compassCalibrationMessage = "Connect the BLE sensor first."
            return
        }

        isExternalSensorEnabled = true
        syncActiveCompassCalibrationOffset()
        rawCompassHeadingDegrees = nil
        fusedSensorHeadingDegrees = nil
        lastMotionYawRadians = nil
        externalFusedSensorHeadingDegrees = nil
        lastExternalSensorSampleDate = nil
        locationService.setHeadingUpdatesEnabled(false)
        motionService.stop()
        resetStationaryTrackingState()

        if let latestSample = sensorManager.latestSample {
            handleExternalSensorSample(latestSample)
        } else {
            headingDegrees = calibratedCompassHeadingDegrees ?? headingDegrees
        }
    }

    private func disableExternalSensorUsage() {
        isExternalSensorEnabled = false
        syncActiveCompassCalibrationOffset()
        externalSensorHeadingDegrees = nil
        externalFusedSensorHeadingDegrees = nil
        lastExternalSensorSampleDate = nil
        rawCompassHeadingDegrees = nil
        fusedSensorHeadingDegrees = nil
        lastMotionYawRadians = nil
        resetStationaryTrackingState()
        locationService.setHeadingUpdatesEnabled(true)
        motionService.start()
    }

    private func enableRoadLock() {
        isRoadLockEnabled = true
        isResolvingRoadLock = false
        roadLockStatusMessage = "Matching the recent route to nearby roads."
        roadLockCoordinate = nil
        roadLockTrailSegments = []
        resetActiveRoadLockRoute()
        refreshRoadLockIfNeeded(force: true)
    }

    private func disableRoadLock() {
        roadLockTask?.cancel()
        roadLockTask = nil
        roadLockRouteExtensionTask?.cancel()
        roadLockRouteExtensionTask = nil
        isRoadLockEnabled = false
        isResolvingRoadLock = false
        roadLockCoordinate = nil
        roadLockStatusMessage = "Road lock is off."
        resetActiveRoadLockRoute()
    }

    private func updateFusedHeading(using sample: MotionSample) {
        defer {
            if let calibratedCompassHeadingDegrees {
                headingDegrees = calibratedCompassHeadingDegrees
            }
        }

        let currentYawRadians = sample.yawRadians
        let headingReferenceSpeedKPH = currentHeadingReferenceSpeedKPH
        var recentGyroDeltaDegrees = 0.0

        if headingReferenceSpeedKPH <= Self.headingFreezeSpeedKPH {
            if fusedSensorHeadingDegrees == nil, let rawCompassHeadingDegrees {
                fusedSensorHeadingDegrees = rawCompassHeadingDegrees
            }
            lastMotionYawRadians = currentYawRadians
            return
        }

        if let previousYawRadians = lastMotionYawRadians {
            let yawDeltaRadians = normalizedSignedRadians(currentYawRadians - previousYawRadians)
            let yawDeltaDegrees = -(yawDeltaRadians * 180 / .pi)
            recentGyroDeltaDegrees = yawDeltaDegrees

            if let fusedSensorHeadingDegrees {
                self.fusedSensorHeadingDegrees = normalizeDegrees(fusedSensorHeadingDegrees + yawDeltaDegrees)
            } else if let rawCompassHeadingDegrees {
                self.fusedSensorHeadingDegrees = normalizeDegrees(rawCompassHeadingDegrees + yawDeltaDegrees)
            }
        } else if fusedSensorHeadingDegrees == nil, let rawCompassHeadingDegrees {
            fusedSensorHeadingDegrees = rawCompassHeadingDegrees
        }

        lastMotionYawRadians = currentYawRadians

        guard let rawCompassHeadingDegrees,
              let fusedSensorHeadingDegrees else {
            return
        }

        let compassDeltaDegrees = signedDeltaDegrees(
            from: fusedSensorHeadingDegrees,
            to: rawCompassHeadingDegrees
        )
        let absoluteCompassDeltaDegrees = abs(compassDeltaDegrees)

        guard absoluteCompassDeltaDegrees <= Self.maximumCompassCorrectionDeltaDegrees else {
            return
        }

        let rotationMagnitude = sqrt(
            sample.correctedRotationRateRadPerSec.x * sample.correctedRotationRateRadPerSec.x +
            sample.correctedRotationRateRadPerSec.y * sample.correctedRotationRateRadPerSec.y +
            sample.correctedRotationRateRadPerSec.z * sample.correctedRotationRateRadPerSec.z
        )

        guard isAbsoluteHeadingCorrectionPlausible(
            absoluteHeadingDeltaDegrees: absoluteCompassDeltaDegrees,
            recentGyroDeltaDegrees: recentGyroDeltaDegrees,
            rotationMagnitude: rotationMagnitude
        ) else {
            return
        }

        let speedWeight = correctionWeight(
            for: headingReferenceSpeedKPH,
            minimumSpeedKPH: Self.minimumCompassCorrectionSpeedKPH,
            fullSpeedKPH: Self.fullCompassCorrectionSpeedKPH
        )

        guard speedWeight > 0 else { return }

        let isRotationStable = rotationMagnitude <= Self.stableRotationRateThresholdRadPerSec
        let baseCorrectionGain = isRotationStable ? Self.stableCompassCorrectionGain : Self.movingCompassCorrectionGain
        let baseCorrectionClampDegrees = isRotationStable
            ? Self.stableCompassCorrectionClampDegrees
            : Self.movingCompassCorrectionClampDegrees
        let correctionGain = baseCorrectionGain * speedWeight
        let correctionClampDegrees = baseCorrectionClampDegrees * max(speedWeight, 0.2)

        let boundedCorrectionDegrees = min(
            max(compassDeltaDegrees * correctionGain, -correctionClampDegrees),
            correctionClampDegrees
        )

        self.fusedSensorHeadingDegrees = normalizeDegrees(fusedSensorHeadingDegrees + boundedCorrectionDegrees)
        applyRoadHeadingCorrection(
            rotationMagnitude: rotationMagnitude,
            currentCalibratedHeadingDegrees: calibratedCompassHeadingDegrees
        )
    }

    private func updateExternalFusedHeading(using sample: WitMotionSample) {
        defer {
            if let calibratedCompassHeadingDegrees {
                headingDegrees = calibratedCompassHeadingDegrees
            }
        }

        let rawHeadingDegrees = sample.yawDegrees
        let headingReferenceSpeedKPH = currentHeadingReferenceSpeedKPH
        var recentGyroDeltaDegrees = 0.0

        if headingReferenceSpeedKPH <= Self.headingFreezeSpeedKPH {
            if externalFusedSensorHeadingDegrees == nil {
                externalFusedSensorHeadingDegrees = rawHeadingDegrees
            }
            lastExternalSensorSampleDate = sample.timestamp
            return
        }

        if let lastExternalSensorSampleDate {
            let deltaTime = sample.timestamp.timeIntervalSince(lastExternalSensorSampleDate)
            if deltaTime > 0 {
                let yawDeltaDegrees = -(sample.correctedRotationRateRadPerSec.z * deltaTime * 180 / .pi)
                recentGyroDeltaDegrees = yawDeltaDegrees

                if let externalFusedSensorHeadingDegrees {
                    self.externalFusedSensorHeadingDegrees = normalizeDegrees(externalFusedSensorHeadingDegrees + yawDeltaDegrees)
                } else {
                    self.externalFusedSensorHeadingDegrees = normalizeDegrees(rawHeadingDegrees + yawDeltaDegrees)
                }
            }
        } else if externalFusedSensorHeadingDegrees == nil {
            externalFusedSensorHeadingDegrees = rawHeadingDegrees
        }

        lastExternalSensorSampleDate = sample.timestamp

        guard let externalFusedSensorHeadingDegrees else { return }

        let headingDeltaDegrees = signedDeltaDegrees(
            from: externalFusedSensorHeadingDegrees,
            to: rawHeadingDegrees
        )
        let absoluteHeadingDeltaDegrees = abs(headingDeltaDegrees)

        guard absoluteHeadingDeltaDegrees <= Self.maximumCompassCorrectionDeltaDegrees else {
            return
        }

        let rotationMagnitude = sqrt(
            sample.correctedRotationRateRadPerSec.x * sample.correctedRotationRateRadPerSec.x +
            sample.correctedRotationRateRadPerSec.y * sample.correctedRotationRateRadPerSec.y +
            sample.correctedRotationRateRadPerSec.z * sample.correctedRotationRateRadPerSec.z
        )

        guard isAbsoluteHeadingCorrectionPlausible(
            absoluteHeadingDeltaDegrees: absoluteHeadingDeltaDegrees,
            recentGyroDeltaDegrees: recentGyroDeltaDegrees,
            rotationMagnitude: rotationMagnitude
        ) else {
            return
        }

        let speedWeight = correctionWeight(
            for: headingReferenceSpeedKPH,
            minimumSpeedKPH: Self.minimumCompassCorrectionSpeedKPH,
            fullSpeedKPH: Self.fullCompassCorrectionSpeedKPH
        )

        guard speedWeight > 0 else { return }

        let isRotationStable = rotationMagnitude <= Self.stableRotationRateThresholdRadPerSec
        let baseCorrectionGain = isRotationStable ? Self.stableCompassCorrectionGain : Self.movingCompassCorrectionGain
        let baseCorrectionClampDegrees = isRotationStable
            ? Self.stableCompassCorrectionClampDegrees
            : Self.movingCompassCorrectionClampDegrees
        let correctionGain = baseCorrectionGain * speedWeight
        let correctionClampDegrees = baseCorrectionClampDegrees * max(speedWeight, 0.2)

        let boundedCorrectionDegrees = min(
            max(headingDeltaDegrees * correctionGain, -correctionClampDegrees),
            correctionClampDegrees
        )

        self.externalFusedSensorHeadingDegrees = normalizeDegrees(externalFusedSensorHeadingDegrees + boundedCorrectionDegrees)
        applyRoadHeadingCorrection(
            rotationMagnitude: rotationMagnitude,
            currentCalibratedHeadingDegrees: calibratedCompassHeadingDegrees
        )
    }

    private func resetActiveRoadLockRoute() {
        roadLockRouteExtensionTask?.cancel()
        roadLockRouteExtensionTask = nil
        activeRoadLockRouteCoordinates = []
        activeRoadLockProjection = nil
        activeRoadLockRouteVersion += 1
        lastRoadLockRouteExtensionAttemptDate = .distantPast
        lastRoadLockSuccessfulMatchDate = .distantPast
        roadLockConfidenceStreak = 0
        breakRoadLockSegment()
        lastRoadLockRefreshCoordinate = nil
        lastRoadLockRefreshDate = .distantPast
    }

    private func refreshRoadLockIfNeeded(force: Bool = false) {
        guard isRoadLockEnabled else { return }
        guard roadLockTask == nil else { return }
        guard let currentCoordinate = obdCoordinate else { return }
        guard obdTrailCoordinates.count >= 4 else {
            roadLockStatusMessage = "Drive a little farther before road lock can fit the route."
            return
        }

        if !force {
            let timeSinceRefresh = Date().timeIntervalSince(lastRoadLockRefreshDate)
            let distanceSinceRefresh = lastRoadLockRefreshCoordinate.map {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                    .distance(from: CLLocation(latitude: currentCoordinate.latitude, longitude: currentCoordinate.longitude))
            } ?? .greatestFiniteMagnitude

            guard
                timeSinceRefresh >= Self.roadLockRefreshInterval ||
                distanceSinceRefresh >= Self.roadLockRefreshDistanceMeters ||
                activeRoadLockRouteCoordinates.isEmpty
            else {
                return
            }
        }

        let rawTrail = obdTrailCoordinates
        let heading = calibratedCompassHeadingDegrees
        isResolvingRoadLock = true

        roadLockTask = Task { [weak self] in
            guard let self else { return }

            let match = await RoadLockMatcher.match(
                rawTrail: rawTrail,
                currentCoordinate: currentCoordinate,
                currentHeadingDegrees: heading
            )

            guard !Task.isCancelled else { return }

            self.roadLockTask = nil
            self.isResolvingRoadLock = false
            self.lastRoadLockRefreshDate = Date()
            self.lastRoadLockRefreshCoordinate = currentCoordinate

            guard self.isRoadLockEnabled else { return }

            if let match {
                self.roadLockRouteExtensionTask?.cancel()
                self.roadLockRouteExtensionTask = nil
                self.activeRoadLockRouteCoordinates = match.routeCoordinates
                self.activeRoadLockRouteVersion += 1
                self.lastRoadLockRouteExtensionAttemptDate = .distantPast
                self.lastRoadLockSuccessfulMatchDate = Date()
                self.roadLockConfidenceStreak = min(
                    self.roadLockConfidenceStreak + 1,
                    Self.minimumRoadHeadingConfidenceStreak + 3
                )
                self.applyRoadLockMatch(match)
            } else {
                if self.roadLockCoordinate != nil,
                   !self.activeRoadLockRouteCoordinates.isEmpty,
                   self.activeRoadLockProjection != nil {
                    self.roadLockConfidenceStreak = max(self.roadLockConfidenceStreak - 1, 0)
                    self.roadLockStatusMessage = "Holding the last matched road until the next road lock."
                } else {
                    self.roadLockRouteExtensionTask?.cancel()
                    self.roadLockRouteExtensionTask = nil
                    self.activeRoadLockRouteCoordinates = []
                    self.activeRoadLockProjection = nil
                    self.activeRoadLockRouteVersion += 1
                    self.lastRoadLockRouteExtensionAttemptDate = .distantPast
                    self.lastRoadLockSuccessfulMatchDate = .distantPast
                    self.roadLockConfidenceStreak = 0
                    self.roadLockCoordinate = nil
                    self.breakRoadLockSegment()
                    self.roadLockStatusMessage = "No strong road fit nearby right now."
                }
            }
        }
    }

    private func applyRoadLockMatch(_ match: RoadLockMatch) {
        activeRoadLockProjection = match.snappedProjection
        roadLockCoordinate = match.snappedCoordinate
        appendRoadLockCoordinate(match.snappedCoordinate)
        roadLockStatusMessage = "Road lock is following the matched road path."
        scheduleRoadLockRouteExtensionIfNeeded()
    }

    private func advanceRoadLockMarker(by distanceMeters: CLLocationDistance) {
        guard isRoadLockEnabled else { return }
        guard distanceMeters > 0 else { return }
        guard !activeRoadLockRouteCoordinates.isEmpty else { return }
        guard let activeRoadLockProjection else { return }

        scheduleRoadLockRouteExtensionIfNeeded()

        guard let nextProjection = RoadLockMatcher.advance(
            activeRoadLockProjection,
            on: activeRoadLockRouteCoordinates,
            by: distanceMeters
        ) else {
            if !isResolvingRoadLock {
                roadLockStatusMessage = "Road lock is waiting for the next nearby road fit."
            }
            return
        }

        self.activeRoadLockProjection = nextProjection
        roadLockCoordinate = nextProjection.coordinate
        appendRoadLockCoordinate(nextProjection.coordinate)
        scheduleRoadLockRouteExtensionIfNeeded()

        let isAtRouteEnd =
            nextProjection.segmentIndex >= max(activeRoadLockRouteCoordinates.count - 2, 0) &&
            nextProjection.segmentFraction >= 0.999

        if !isResolvingRoadLock {
            roadLockStatusMessage = isAtRouteEnd
                ? "Road lock reached the end of the current road and is waiting."
                : "Road lock is following the matched road path."
        }
    }

    private func scheduleRoadLockRouteExtensionIfNeeded() {
        guard isRoadLockEnabled else { return }
        guard roadLockRouteExtensionTask == nil else { return }
        guard !isResolvingRoadLock else { return }
        guard !activeRoadLockRouteCoordinates.isEmpty else { return }
        guard let activeRoadLockProjection else { return }

        let remainingDistance = RoadLockMatcher.remainingDistance(
            from: activeRoadLockProjection,
            on: activeRoadLockRouteCoordinates
        )
        guard remainingDistance <= Self.roadLockRouteExtensionTriggerDistanceMeters else { return }
        guard Date().timeIntervalSince(lastRoadLockRouteExtensionAttemptDate) >= Self.roadLockRouteExtensionCooldown else {
            return
        }

        let routeCoordinates = activeRoadLockRouteCoordinates
        let routeVersion = activeRoadLockRouteVersion
        lastRoadLockRouteExtensionAttemptDate = Date()

        roadLockRouteExtensionTask = Task { [weak self] in
            guard let self else { return }

            let extendedRouteCoordinates = await RoadLockMatcher.extendForward(on: routeCoordinates)

            guard !Task.isCancelled else { return }
            self.roadLockRouteExtensionTask = nil

            guard self.isRoadLockEnabled else { return }
            guard routeVersion == self.activeRoadLockRouteVersion else { return }
            guard let extendedRouteCoordinates else { return }

            self.activeRoadLockRouteCoordinates = extendedRouteCoordinates
            self.activeRoadLockRouteVersion += 1

            if !self.isResolvingRoadLock {
                self.roadLockStatusMessage = "Road lock is following the matched road path."
            }
        }
    }

    private func applyRoadHeadingCorrection(
        rotationMagnitude: Double,
        currentCalibratedHeadingDegrees: CLLocationDirection?
    ) {
        guard isRoadLockEnabled else { return }
        guard roadLockConfidenceStreak >= Self.minimumRoadHeadingConfidenceStreak else { return }
        guard Date().timeIntervalSince(lastRoadLockSuccessfulMatchDate) <= Self.roadHeadingCorrectionFreshnessInterval else { return }
        let speedKPH = currentHeadingReferenceSpeedKPH
        guard speedKPH >= Self.minimumRoadHeadingCorrectionSpeedKPH else { return }
        guard let activeRoadLockProjection else { return }
        guard !activeRoadLockRouteCoordinates.isEmpty else { return }
        guard let currentCalibratedHeadingDegrees else { return }

        guard let headingReference = RoadLockMatcher.headingReference(
            on: activeRoadLockRouteCoordinates,
            around: activeRoadLockProjection,
            windowDistanceMeters: Self.roadHeadingCorrectionWindowMeters
        ) else {
            return
        }

        guard headingReference.sampleCount >= 2 else { return }
        guard headingReference.maxDeviationDegrees <= Self.maximumRoadHeadingStraightnessDegrees else { return }

        let roadHeadingDeltaDegrees = signedDeltaDegrees(
            from: currentCalibratedHeadingDegrees,
            to: headingReference.bearingDegrees
        )

        guard abs(roadHeadingDeltaDegrees) <= Self.maximumRoadHeadingCorrectionDeltaDegrees else {
            return
        }

        let speedWeight = correctionWeight(
            for: speedKPH,
            minimumSpeedKPH: Self.minimumRoadHeadingCorrectionSpeedKPH,
            fullSpeedKPH: Self.fullRoadHeadingCorrectionSpeedKPH
        )

        guard speedWeight > 0 else { return }

        let isRotationStable = rotationMagnitude <= Self.stableRotationRateThresholdRadPerSec
        let baseCorrectionGain = isRotationStable ? Self.stableRoadHeadingCorrectionGain : Self.movingRoadHeadingCorrectionGain
        let baseCorrectionClampDegrees = isRotationStable
            ? Self.stableRoadHeadingCorrectionClampDegrees
            : Self.movingRoadHeadingCorrectionClampDegrees
        let correctionGain = baseCorrectionGain * speedWeight
        let correctionClampDegrees = baseCorrectionClampDegrees * max(speedWeight, 0.25)

        let boundedCorrectionDegrees = min(
            max(roadHeadingDeltaDegrees * correctionGain, -correctionClampDegrees),
            correctionClampDegrees
        )

        let updatedOffsetDegrees = normalizedSignedDegrees(
            compassCalibrationOffsetDegrees + boundedCorrectionDegrees
        )

        guard abs(updatedOffsetDegrees - compassCalibrationOffsetDegrees) >= 0.05 else { return }
        guard !isCompassOffsetLocked else { return }

        saveActiveCompassCalibrationOffset(updatedOffsetDegrees)

        if let stabilizedSensorHeadingDegrees {
            headingDegrees = normalizeDegrees(stabilizedSensorHeadingDegrees + compassCalibrationOffsetDegrees)
        }

        maybeShowRoadLockRecalibrationBanner(forSavedOffset: updatedOffsetDegrees)
    }

    private var stabilizedSensorHeadingDegrees: CLLocationDirection? {
        if isExternalSensorEnabled {
            return externalFusedSensorHeadingDegrees ?? externalSensorHeadingDegrees
        }

        return fusedSensorHeadingDegrees ?? rawCompassHeadingDegrees
    }

    private var currentHeadingReferenceSpeedKPH: Double {
        max(obdSpeedKPH ?? 0, 0)
    }

    private func saveActiveCompassCalibrationOffset(_ offsetDegrees: CLLocationDirection) {
        compassCalibrationOffsetDegrees = normalizedSignedDegrees(offsetDegrees)

        if isExternalSensorEnabled {
            externalSensorCalibrationOffsetDegrees = compassCalibrationOffsetDegrees
            UserDefaults.standard.set(
                externalSensorCalibrationOffsetDegrees,
                forKey: Self.externalSensorCalibrationOffsetDefaultsKey
            )
        } else {
            phoneCompassCalibrationOffsetDegrees = compassCalibrationOffsetDegrees
            UserDefaults.standard.set(
                phoneCompassCalibrationOffsetDegrees,
                forKey: Self.phoneCompassCalibrationOffsetDefaultsKey
            )
        }
    }

    private func syncActiveCompassCalibrationOffset() {
        compassCalibrationOffsetDegrees = isExternalSensorEnabled
            ? externalSensorCalibrationOffsetDegrees
            : phoneCompassCalibrationOffsetDegrees
    }

    private var calibratedCompassHeadingDegrees: CLLocationDirection? {
        guard let stabilizedSensorHeadingDegrees else { return nil }
        return normalizeDegrees(stabilizedSensorHeadingDegrees + compassCalibrationOffsetDegrees)
    }

    private var formattedCalibrationOffset: String {
        formattedSignedDegrees(compassCalibrationOffsetDegrees)
    }

    private func formattedSignedDegrees(_ degrees: CLLocationDirection) -> String {
        let sign = degrees >= 0 ? "+" : "-"
        return "\(sign)\(abs(degrees).formatted(.number.precision(.fractionLength(1))))°"
    }

    private func maybeShowRoadLockRecalibrationBanner(forSavedOffset savedOffsetDegrees: CLLocationDirection) {
        let normalizedOffset = normalizedSignedDegrees(savedOffsetDegrees)
        guard abs(normalizedOffset) >= Self.roadHeadingNotificationMinimumDeltaDegrees else { return }

        let now = Date()
        let deltaChangedEnough: Bool
        if let lastRoadHeadingNotificationDegrees {
            deltaChangedEnough =
                abs(signedDeltaDegrees(from: lastRoadHeadingNotificationDegrees, to: normalizedOffset))
                >= Self.roadHeadingNotificationChangeThresholdDegrees
        } else {
            deltaChangedEnough = true
        }

        guard
            deltaChangedEnough || now.timeIntervalSince(lastRoadHeadingNotificationDate) >= Self.roadHeadingNotificationCooldown
        else {
            return
        }

        lastRoadHeadingNotificationDate = now
        lastRoadHeadingNotificationDegrees = normalizedOffset
        showTransientBanner("Road lock just recalibrated compass to \(formattedSignedDegrees(normalizedOffset))")
    }

    private func showTransientBanner(_ text: String) {
        transientBannerTask?.cancel()
        transientBannerText = text
        transientBannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.transientBannerDuration))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.transientBannerText = nil
            }
        }
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

    private func normalizedSignedRadians(_ value: Double) -> Double {
        var normalizedValue = value.truncatingRemainder(dividingBy: 2 * .pi)

        if normalizedValue > .pi {
            normalizedValue -= 2 * .pi
        } else if normalizedValue < -.pi {
            normalizedValue += 2 * .pi
        }

        return normalizedValue
    }

    private func correctionWeight(
        for speedKPH: Double,
        minimumSpeedKPH: Double,
        fullSpeedKPH: Double
    ) -> Double {
        guard fullSpeedKPH > minimumSpeedKPH else {
            return speedKPH >= fullSpeedKPH ? 1 : 0
        }

        let normalizedValue = (speedKPH - minimumSpeedKPH) / (fullSpeedKPH - minimumSpeedKPH)
        let clampedValue = min(max(normalizedValue, 0), 1)
        return clampedValue * clampedValue * (3 - 2 * clampedValue)
    }

    private func isAbsoluteHeadingCorrectionPlausible(
        absoluteHeadingDeltaDegrees: CLLocationDirection,
        recentGyroDeltaDegrees: CLLocationDirection,
        rotationMagnitude: Double
    ) -> Bool {
        let gyroTurnAllowanceDegrees =
            abs(recentGyroDeltaDegrees) * Self.absoluteHeadingCorrectionGyroAllowanceMultiplier
        let rotationAllowanceDegrees =
            rotationMagnitude * 180 / .pi * Self.absoluteHeadingCorrectionRotationAllowanceDegrees
        let allowedHeadingCorrectionDegrees =
            Self.maximumAbsoluteHeadingCorrectionWithoutGyroDegrees +
            gyroTurnAllowanceDegrees +
            rotationAllowanceDegrees

        return absoluteHeadingDeltaDegrees <= allowedHeadingCorrectionDegrees
    }

    private func normalizedSignedDegrees(_ value: CLLocationDirection) -> CLLocationDirection {
        let normalized = normalizeDegrees(value)
        return normalized > 180 ? normalized - 360 : normalized
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
        rawCompassHeadingDegrees = 96
        fusedSensorHeadingDegrees = 96
        compassCalibrationOffsetDegrees = 4.5
        headingDegrees = 100.5
        gapMeters = 31
        selectedPanelPage = 0
        isPanelExpanded = true
        isStationaryByIMU = false
        compassCalibrationMessage = "Saved offset +4.5°"
        isRoadLockEnabled = true
        roadLockCoordinate = CLLocationCoordinate2D(latitude: 51.50768, longitude: -0.12702)
        roadLockTrailSegments = [[
            CLLocationCoordinate2D(latitude: 51.50802, longitude: -0.12772),
            CLLocationCoordinate2D(latitude: 51.50788, longitude: -0.12746),
            CLLocationCoordinate2D(latitude: 51.50778, longitude: -0.12724),
            CLLocationCoordinate2D(latitude: 51.50768, longitude: -0.12702)
        ]]
        roadLockStatusMessage = "Road lock is following the nearest matching road path."
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

private struct TestLogEntry {
    let timestamp: Date
    let gpsDistanceTravelledMeters: CLLocationDistance
    let gpsToRawOBDDistanceMeters: CLLocationDistance?
    let gpsToRoadLockDistanceMeters: CLLocationDistance?
    let gpsAndRoadLockOnSameRoad: Bool
}

extension NavigationViewModel {
    static var preview: NavigationViewModel {
        NavigationViewModel(previewMode: true)
    }
}
