//
//  ContentView.swift
//  OBDNav
//
//  Created by Jasper Sion on 30/03/2026.
//

import MapKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    @StateObject private var viewModel: NavigationViewModel

    init(viewModel: NavigationViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    init() {
        _viewModel = StateObject(wrappedValue: NavigationViewModel())
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                mapLayer
                calibrationBanner(topInset: proxy.safeAreaInsets.top)
                statusCapsule(topInset: proxy.safeAreaInsets.top)
                mapActionHotbar(bottomInset: proxy.safeAreaInsets.bottom)
                DashboardPanel(
                    viewModel: viewModel,
                    collapsedHeight: 76,
                    expandedHeight: min(proxy.size.height * 0.66, 560)
                )
            }
            .background(Color.white)
            .ignoresSafeArea()
        }
        .sheet(isPresented: $viewModel.isShowingDevicePicker, onDismiss: viewModel.didDismissDevicePicker) {
            OBDDonglePickerSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingSensorPicker, onDismiss: viewModel.didDismissSensorPicker) {
            WitMotionSensorPickerSheet(viewModel: viewModel)
        }
        .fileExporter(
            isPresented: Binding(
                get: { viewModel.isShowingTestExport },
                set: { isPresented in
                    if !isPresented {
                        viewModel.dismissTestExport()
                    }
                }
            ),
            document: CSVExportDocument(csvText: viewModel.pendingTestCSV),
            contentType: .commaSeparatedText,
            defaultFilename: viewModel.pendingTestExportFilename
        ) { result in
            viewModel.handleTestExportCompletion(result)
        }
        .task {
            viewModel.start()
        }
    }

    private var mapLayer: some View {
        MapReader { proxy in
            Map(position: $viewModel.cameraPosition, interactionModes: .all) {
                if viewModel.gpsTrailCoordinates.count > 1 {
                    MapPolyline(coordinates: viewModel.gpsTrailCoordinates)
                        .stroke(
                            Color(red: 0.25, green: 0.62, blue: 0.97).opacity(0.9),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                        )
                }

                if viewModel.obdTrailCoordinates.count > 1 {
                    MapPolyline(coordinates: viewModel.obdTrailCoordinates)
                        .stroke(
                            Color(red: 0.98, green: 0.48, blue: 0.20).opacity(0.88),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                        )
                }

                if viewModel.shouldShowRoadLockOverlay {
                    ForEach(Array(viewModel.roadLockTrailSegments.enumerated()), id: \.offset) { _, segment in
                        if segment.coordinates.count > 1 {
                            MapPolyline(coordinates: segment.coordinates)
                                .stroke(
                                    roadLockTrailColor(for: segment.style).opacity(0.92),
                                    style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                                )
                        }
                    }
                }

                if viewModel.calibrationGuideCoordinates.count == 2 {
                    MapPolyline(coordinates: viewModel.calibrationGuideCoordinates)
                        .stroke(
                            Color.white.opacity(0.92),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)
                        )
                }

                if let gpsCoordinate = viewModel.gpsCoordinate,
                   let obdCoordinate = viewModel.obdCoordinate {
                    MapPolyline(coordinates: [gpsCoordinate, obdCoordinate])
                        .stroke(
                            .linearGradient(
                                colors: [
                                    Color(red: 0.25, green: 0.62, blue: 0.97).opacity(0.9),
                                    Color(red: 0.98, green: 0.48, blue: 0.20).opacity(0.9)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [7, 6])
                        )
                }

                if let calibrationTapCoordinate = viewModel.compassCalibrationTapCoordinate,
                   viewModel.isCompassCalibrationActive || viewModel.isResolvingCompassCalibrationRoad {
                    Annotation("Calibration Tap", coordinate: calibrationTapCoordinate, anchor: .center) {
                        CalibrationAnchorView(isResolving: viewModel.isResolvingCompassCalibrationRoad)
                    }
                }

                if let obdSpawnPinCoordinate = viewModel.obdSpawnPinCoordinate {
                    Annotation("OBD Spawn Pin", coordinate: obdSpawnPinCoordinate, anchor: .bottom) {
                        SpawnPinBadge(isSelecting: viewModel.isSelectingOBDSpawnPin)
                    }
                }

                if let candidate = viewModel.compassCalibrationCandidate,
                   let forwardCoordinate = viewModel.compassCalibrationForwardArrowCoordinate,
                   let reverseCoordinate = viewModel.compassCalibrationReverseArrowCoordinate {
                    Annotation("Forward Direction", coordinate: forwardCoordinate, anchor: .center) {
                        Button(action: viewModel.chooseForwardCompassCalibrationDirection) {
                            CalibrationDirectionArrow(
                                tint: Color(red: 0.98, green: 0.48, blue: 0.20),
                                bearingDegrees: candidate.forwardBearingDegrees
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Annotation("Reverse Direction", coordinate: reverseCoordinate, anchor: .center) {
                        Button(action: viewModel.chooseReverseCompassCalibrationDirection) {
                            CalibrationDirectionArrow(
                                tint: Color(red: 0.20, green: 0.28, blue: 0.44),
                                bearingDegrees: candidate.forwardBearingDegrees + 180
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let gpsCoordinate = viewModel.gpsCoordinate {
                    Annotation("GPS", coordinate: gpsCoordinate, anchor: .center) {
                        MarkerBadge(
                            title: "GPS",
                            systemImage: "location.fill",
                            tint: Color(red: 0.25, green: 0.62, blue: 0.97),
                            labelPosition: .bottom,
                            size: .compact
                        )
                    }
                }

                if viewModel.isOBDMarkerVisible,
                   let obdCoordinate = viewModel.obdCoordinate {
                    Annotation("OBD", coordinate: obdCoordinate, anchor: .center) {
                        MarkerBadge(
                            title: "OBD",
                            systemImage: "scope",
                            tint: Color(red: 0.98, green: 0.48, blue: 0.20),
                            labelPosition: .top,
                            size: .compact
                        )
                    }
                }

                if viewModel.shouldShowRoadLockOverlay,
                   let roadLockCoordinate = viewModel.roadLockCoordinate {
                    Annotation("Road Lock", coordinate: roadLockCoordinate, anchor: .center) {
                        MarkerBadge(
                            title: "LOCK",
                            systemImage: "lock.fill",
                            tint: Color(red: 0.96, green: 0.26, blue: 0.66),
                            labelPosition: .top,
                            size: .compact
                        )
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted))
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .local)
                    .onEnded { value in
                        guard let coordinate = proxy.convert(value.location, from: .local) else { return }

                        if viewModel.isSelectingOBDSpawnPin {
                            viewModel.handleOBDSpawnPinTap(at: coordinate)
                            return
                        }

                        guard viewModel.isCompassCalibrationActive else { return }
                        guard viewModel.compassCalibrationCandidate == nil else { return }
                        viewModel.handleCompassCalibrationTap(at: coordinate)
                    }
            )
        }
    }

    private func calibrationBanner(topInset: CGFloat) -> some View {
        VStack {
            if let calibrationOverlayText = viewModel.calibrationOverlayText {
                Text(calibrationOverlayText)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.82))
                    )
                    .padding(.top, topInset + 92)
            }

            Spacer()
        }
        .padding(.horizontal, 30)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: viewModel.calibrationOverlayText)
        .allowsHitTesting(false)
    }

    private func statusCapsule(topInset: CGFloat) -> some View {
        VStack {
            HStack(spacing: 18) {
                CompactStatusView(
                    title: "GPS",
                    value: viewModel.gpsStatusText,
                    tint: Color(red: 0.25, green: 0.62, blue: 0.97)
                )

                Divider()
                    .frame(height: 28)
                    .overlay(Color.white.opacity(0.15))

                CompactStatusView(
                    title: "OBD",
                    value: viewModel.obdStatusText,
                    tint: viewModel.obdStatusTint
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.88))
            )
            .padding(.top, topInset + 8)

            Spacer()
        }
        .padding(.horizontal, 36)
        .allowsHitTesting(false)
    }

    private func mapActionHotbar(bottomInset: CGFloat) -> some View {
        VStack {
            Spacer()

            if !viewModel.isPanelExpanded {
                HStack(spacing: 8) {
                    mapActionButton(
                        title: "Snap",
                        systemImage: "location.fill",
                        background: LinearGradient(
                            colors: [
                                Color(red: 0.99, green: 0.56, blue: 0.18),
                                Color(red: 0.91, green: 0.33, blue: 0.04)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    ) {
                        viewModel.snapOBDToGPS()
                    }

                    mapActionButton(
                        title: "Road",
                        systemImage: viewModel.isRoadLockEnabled ? "lock.fill" : "lock.open.fill",
                        background: LinearGradient(
                            colors: viewModel.isRoadLockEnabled
                                ? [
                                    Color(red: 0.98, green: 0.56, blue: 0.80),
                                    Color(red: 0.87, green: 0.25, blue: 0.60)
                                ]
                                : [
                                    Color.black.opacity(0.90),
                                    Color.black.opacity(0.80)
                                ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        foreground: viewModel.isRoadLockEnabled ? .black : .white
                    ) {
                        viewModel.toggleRoadLock()
                    }

                    mapActionButton(
                        title: viewModel.isCompassCalibrationActive ? "Cancel" : "Cal",
                        systemImage: viewModel.isCompassCalibrationActive ? "xmark.circle.fill" : "scope",
                        background: LinearGradient(
                            colors: viewModel.isCompassCalibrationActive
                                ? [
                                    Color(red: 1.0, green: 0.84, blue: 0.66),
                                    Color(red: 0.96, green: 0.66, blue: 0.30)
                                ]
                                : [
                                    Color.black.opacity(0.90),
                                    Color.black.opacity(0.80)
                                ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        foreground: viewModel.isCompassCalibrationActive ? .black : .white
                    ) {
                        viewModel.toggleCompassCalibration()
                    }

                    mapActionButton(
                        title: viewModel.isCompassOffsetLocked ? "Locked" : "Offset",
                        systemImage: viewModel.compassOffsetLockButtonSystemImage,
                        background: LinearGradient(
                            colors: viewModel.isCompassOffsetLocked
                                ? [
                                    Color(red: 0.25, green: 0.70, blue: 0.39),
                                    Color(red: 0.13, green: 0.49, blue: 0.27)
                                ]
                                : [
                                    Color.black.opacity(0.90),
                                    Color.black.opacity(0.80)
                                ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        foreground: viewModel.isCompassOffsetLocked ? .black : .white
                    ) {
                        viewModel.toggleCompassOffsetLock()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.black.opacity(0.88))
                )
                .padding(.horizontal, 18)
                .padding(.bottom, max(bottomInset, 12) + 64)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.30, dampingFraction: 0.84), value: viewModel.isPanelExpanded)
        .allowsHitTesting(!viewModel.isPanelExpanded)
    }

    private func mapActionButton(
        title: String,
        systemImage: String,
        background: LinearGradient,
        foreground: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .bold))

                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(background)
            )
        }
        .buttonStyle(.plain)
    }

    private func roadLockTrailColor(for style: RoadLockTrailStyle) -> Color {
        switch style {
        case .locked:
            return Color(red: 0.96, green: 0.26, blue: 0.66)
        case .traveling:
            return Color(red: 0.23, green: 0.72, blue: 0.38)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(viewModel: .preview)
    }
}

private struct CalibrationDirectionArrow: View {
    let tint: Color
    let bearingDegrees: CLLocationDirection

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.92))
                .frame(width: 56, height: 56)
                .shadow(color: tint.opacity(0.28), radius: 10, x: 0, y: 5)

            Circle()
                .stroke(tint.opacity(0.42), lineWidth: 4)
                .frame(width: 66, height: 66)

            Image(systemName: "arrow.up")
                .font(.system(size: 28, weight: .black))
                .foregroundStyle(tint)
                .rotationEffect(.degrees(bearingDegrees))
        }
    }
}

private struct SpawnPinBadge: View {
    let isSelecting: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(isSelecting ? Color(red: 1.0, green: 0.76, blue: 0.34) : Color(red: 0.99, green: 0.56, blue: 0.18))
                    .frame(width: 38, height: 38)

                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
            }

            Text("Spawn")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule(style: .continuous).fill(Color.white.opacity(0.96)))
                .offset(y: -2)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 4)
    }
}

private struct CSVExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    let csvText: String

    init(csvText: String) {
        self.csvText = csvText
    }

    init(configuration: ReadConfiguration) throws {
        if let regularFileContents = configuration.file.regularFileContents,
           let csvText = String(data: regularFileContents, encoding: .utf8) {
            self.csvText = csvText
        } else {
            self.csvText = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(csvText.utf8))
    }
}

private struct CalibrationAnchorView: View {
    let isResolving: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.92))
                .frame(width: 20, height: 20)

            Circle()
                .stroke(Color.black.opacity(0.12), lineWidth: 6)
                .frame(width: isResolving ? 44 : 30, height: isResolving ? 44 : 30)

            Circle()
                .fill(Color(red: 0.98, green: 0.48, blue: 0.20))
                .frame(width: 10, height: 10)
        }
        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: isResolving)
    }
}
