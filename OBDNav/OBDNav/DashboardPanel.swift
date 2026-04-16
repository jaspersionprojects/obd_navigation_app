//
//  DashboardPanel.swift
//  OBDNav
//
//  Created by Codex on 30/03/2026.
//

import SwiftUI

struct DashboardPanel: View {
    @ObservedObject var viewModel: NavigationViewModel

    let collapsedHeight: CGFloat
    let expandedHeight: CGFloat

    @State private var manualCalibrationOffsetText = ""

    var body: some View {
        let panelOffset = viewModel.isPanelExpanded ? 0 : expandedHeight - collapsedHeight

        VStack(spacing: 18) {
            panelHandle
            pageSelector
            panelContent
            pageDots
        }
        .padding(.top, 12)
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .frame(height: expandedHeight, alignment: .top)
        .background(panelSurface)
        .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 38, style: .continuous)
                .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .offset(y: panelOffset)
        .shadow(color: Color.black.opacity(0.18), radius: 24, x: 0, y: -8)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: viewModel.isPanelExpanded)
        .onAppear {
            syncManualCalibrationOffsetText()
        }
        .onChange(of: viewModel.compassCalibrationOffsetDegrees) { _, _ in
            syncManualCalibrationOffsetText()
        }
    }

    private var panelHandle: some View {
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                viewModel.isPanelExpanded.toggle()
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: viewModel.isPanelExpanded ? "chevron.compact.down" : "chevron.compact.up")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.44))

                Capsule()
                    .fill(Color.black.opacity(0.18))
                    .frame(width: 58, height: 6)
            }
            .frame(width: 96, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(viewModel.isPanelExpanded ? "Minimise control panel" : "Maximise control panel"))
    }

    private var pageSelector: some View {
        HStack(spacing: 12) {
            selectorButton(
                title: "Telemetry",
                systemImage: "waveform.path.ecg",
                index: 0
            )

            selectorButton(
                title: "Controls",
                systemImage: "slider.horizontal.3",
                index: 1
            )

            selectorButton(
                title: "Sensor",
                systemImage: "gyroscope",
                index: 2
            )

            selectorButton(
                title: "Test",
                systemImage: "checklist",
                index: 3
            )
        }
    }

    private var panelContent: some View {
        TabView(selection: $viewModel.selectedPanelPage) {
            telemetryPage
                .tag(0)

            futureControlsPage
                .tag(1)

            nudgeControlsPage
                .tag(2)

            testPage
                .tag(3)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var telemetryPage: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatCard(
                        title: "GPS Speed",
                        value: speedTextInMPH(viewModel.gpsSpeedKPH),
                        unit: "mph",
                        tint: Color(red: 0.66, green: 0.86, blue: 0.90)
                    )

                    StatCard(
                        title: "OBD Speed",
                        value: speedTextInMPH(viewModel.obdSpeedKPH),
                        unit: "mph",
                        tint: Color(red: 0.96, green: 0.90, blue: 0.72)
                    )

                    StatCard(
                        title: "Heading",
                        value: "\(Int(viewModel.headingDegrees.rounded()))",
                        unit: "deg",
                        tint: Color(red: 0.90, green: 0.93, blue: 0.93)
                    )

                    StatCard(
                        title: "GPS Gap",
                        value: "\(Int(viewModel.gapMeters.rounded()))",
                        unit: "m",
                        tint: Color(red: 0.82, green: 0.93, blue: 0.79)
                    )
                }

                HStack(alignment: .top, spacing: 12) {
                    connectButton
                    connectionStatusCard
                }

                HStack(alignment: .top, spacing: 12) {
                    sensorConnectButton
                    sensorConnectionStatusCard
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 4)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var futureControlsPage: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Controls")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)

                HStack(spacing: 12) {
                    Button(action: viewModel.toggleOBDMarkerVisibility) {
                        VStack(spacing: 8) {
                            Image(systemName: viewModel.isOBDMarkerVisible ? "eye.slash.fill" : "eye.fill")
                                .font(.system(size: 18, weight: .bold))

                            Text(viewModel.obdMarkerButtonTitle)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.78)
                        }
                        .frame(maxWidth: .infinity, minHeight: 82, alignment: .center)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(Color.white)
                        )
                        .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)

                    Button(action: viewModel.clearAllTrails) {
                        VStack(spacing: 8) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 18, weight: .bold))

                            Text("Clear All Trails")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.78)
                        }
                        .frame(maxWidth: .infinity, minHeight: 82, alignment: .center)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(Color.white)
                        )
                        .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: viewModel.toggleOBDSpawnPinPlacement) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: viewModel.isSelectingOBDSpawnPin ? "xmark.circle.fill" : "mappin.and.ellipse")
                                .font(.system(size: 19, weight: .bold))

                            Text(viewModel.obdSpawnButtonTitle)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .lineLimit(2)
                        }

                        Text(viewModel.obdSpawnButtonSubtitle)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.black.opacity(0.58))
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(viewModel.isSelectingOBDSpawnPin ? Color(red: 1.0, green: 0.90, blue: 0.78) : Color.white)
                    )
                    .foregroundStyle(.black)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
        }
    }

    private var nudgeControlsPage: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Sensor")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)

                Text("Connect the external BLE IMU sensor here, then enable it to replace the iPhone compass and motion sensors.")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.black.opacity(0.58))

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Sensor Status")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(.black)

                            Text(viewModel.sensorStatusText)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(.black.opacity(0.62))
                        }

                        Spacer(minLength: 12)

                        Circle()
                            .fill(viewModel.sensorStatusTint)
                            .frame(width: 14, height: 14)
                            .padding(.top, 4)
                    }

                    Text(viewModel.sensorConnectButtonSubtitle)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.black.opacity(0.72))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(Color.white.opacity(0.64))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                )

                Button(action: viewModel.toggleExternalSensorUsage) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: viewModel.isExternalSensorEnabled ? "sensor.tag.radiowaves.forward.fill" : "sensor.tag.radiowaves.forward")
                                .font(.system(size: 19, weight: .bold))

                            Text(viewModel.sensorEnableButtonTitle)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .lineLimit(2)
                        }

                        Text(viewModel.sensorEnableButtonSubtitle)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.black.opacity(0.58))
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(viewModel.isExternalSensorEnabled ? Color(red: 0.79, green: 0.93, blue: 0.85) : Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .foregroundStyle(.black)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Current Offset")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.42))

                    Text(compassOffsetText(viewModel.compassCalibrationOffsetDegrees))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.99, green: 0.70, blue: 0.43))

                    Text("Try larger moves first, then finish with ±1° nudges.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.black.opacity(0.68))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(Color(red: 0.96, green: 0.90, blue: 0.72).opacity(0.9))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                )

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    nudgeButton(title: "-10°", deltaDegrees: -10)
                    nudgeButton(title: "-5°", deltaDegrees: -5)
                    nudgeButton(title: "-1°", deltaDegrees: -1)
                    nudgeButton(title: "+1°", deltaDegrees: 1)
                    nudgeButton(title: "+5°", deltaDegrees: 5)
                    nudgeButton(title: "+10°", deltaDegrees: 10)
                }

                Text("Each tap updates the saved offset immediately and keeps the map calibration in sync.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.black.opacity(0.58))

                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Manual offset")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(.black)

                            Text("Type a positive or negative offset in degrees and apply it to the active sensor heading.")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(.black.opacity(0.62))
                        }

                        Spacer(minLength: 12)

                        Text(compassOffsetText(viewModel.compassCalibrationOffsetDegrees))
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(red: 0.99, green: 0.70, blue: 0.43))
                    }

                    HStack(spacing: 10) {
                        TextField("e.g. -12.5", text: $manualCalibrationOffsetText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .frame(height: 48)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.white.opacity(0.9))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                            )

                        Button {
                            viewModel.applyManualCompassCalibrationOffset(manualCalibrationOffsetText)
                            manualCalibrationOffsetText = String(
                                format: "%.1f",
                                viewModel.compassCalibrationOffsetDegrees
                            )
                        } label: {
                            Text("Apply")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .frame(minWidth: 78, minHeight: 48)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(Color(red: 0.99, green: 0.70, blue: 0.43))
                                )
                                .foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(Color(red: 0.90, green: 0.93, blue: 0.93).opacity(0.94))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                )

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
        }
    }

    private var testPage: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Test")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)

                Text("Start a timed validation run. Every 20 seconds the app logs GPS distance travelled, GPS vs raw OBD gap, GPS vs road-lock gap, and whether GPS and road lock appear to be on the same road.")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.black.opacity(0.58))

                Button(action: viewModel.toggleTestSession) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: viewModel.isTestRecording ? "stop.fill" : "play.fill")
                                .font(.system(size: 19, weight: .bold))

                            Text(viewModel.testButtonTitle)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .lineLimit(2)
                        }

                        Text(viewModel.testButtonSubtitle)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.black.opacity(0.58))
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(viewModel.isTestRecording ? Color(red: 1.0, green: 0.82, blue: 0.82) : Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .foregroundStyle(.black)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Status")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.42))

                    Text(viewModel.testStatusMessage)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)

                    Text("Samples logged: \(viewModel.testSampleCount)")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.black.opacity(0.62))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(Color.white.opacity(0.64))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                )

                Text("Stopping the run opens a CSV save sheet immediately.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.black.opacity(0.58))

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
        }
    }

    private var connectButton: some View {
        Button(action: viewModel.showOBDDevicePicker) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 16, weight: .semibold))

                    Text("Connect to OBD dongle")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .lineLimit(2)
                }

                Text(viewModel.connectButtonSubtitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.48))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.white.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Color(red: 0.95, green: 0.68, blue: 0.60), lineWidth: 1.5)
            )
            .foregroundStyle(.black)
        }
        .buttonStyle(.plain)
    }

    private var connectionStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.obdStatusTint)
                    .frame(width: 12, height: 12)

                Text("OBD Status")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.42))
            }

            Text(viewModel.obdStatusText)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.white.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var sensorConnectButton: some View {
        Button(action: viewModel.showSensorPicker) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "gyroscope")
                        .font(.system(size: 16, weight: .semibold))

                    Text("Connect to sensor")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .lineLimit(2)
                }

                Text(viewModel.sensorConnectButtonSubtitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.48))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.white.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Color(red: 0.53, green: 0.73, blue: 0.95), lineWidth: 1.5)
            )
            .foregroundStyle(.black)
        }
        .buttonStyle(.plain)
    }

    private var sensorConnectionStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.sensorStatusTint)
                    .frame(width: 12, height: 12)

                Text("Sensor Status")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.42))
            }

            Text(viewModel.sensorStatusText)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.white.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            pageDot(index: 0)
            pageDot(index: 1)
            pageDot(index: 2)
            pageDot(index: 3)
        }
    }

    private var panelSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 38, style: .continuous)
                .fill(Color.white.opacity(0.94))

            Circle()
                .fill(Color(red: 0.83, green: 0.95, blue: 0.78).opacity(0.55))
                .frame(width: 260, height: 260)
                .blur(radius: 60)
                .offset(x: -130, y: 90)

            Circle()
                .fill(Color(red: 1.00, green: 0.86, blue: 0.62).opacity(0.55))
                .frame(width: 240, height: 240)
                .blur(radius: 62)
                .offset(x: 120, y: 55)
        }
    }

    private func selectorButton(title: String, systemImage: String, index: Int) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                viewModel.selectedPanelPage = index
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(index == viewModel.selectedPanelPage ? Color(red: 0.20, green: 0.28, blue: 0.44) : Color.white.opacity(0.62))
            )
            .foregroundStyle(index == viewModel.selectedPanelPage ? .white : .black)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }

    private func clampOffset(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), expandedHeight - collapsedHeight)
    }

    private func pageDot(index: Int) -> some View {
        Circle()
            .fill(index == viewModel.selectedPanelPage ? Color.black.opacity(0.68) : Color.black.opacity(0.18))
            .frame(width: 11, height: 11)
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: viewModel.selectedPanelPage)
    }

    private func speedTextInMPH(_ value: Double?) -> String {
        guard let value else { return "--" }
        let milesPerHour = value * 0.621_371
        return milesPerHour.formatted(.number.precision(.fractionLength(1)))
    }

    private func compassOffsetText(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : "-"
        let magnitude = abs(value).formatted(.number.precision(.fractionLength(1)))
        return "\(sign)\(magnitude)°"
    }

    private func nudgeButton(title: String, deltaDegrees: Double) -> some View {
        Button {
            viewModel.nudgeCompassCalibrationOffset(by: deltaDegrees)
        } label: {
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(red: 0.98, green: 0.48, blue: 0.20).opacity(0.94))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color(red: 0.78, green: 0.30, blue: 0.10).opacity(0.45), lineWidth: 1)
                )
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func syncManualCalibrationOffsetText() {
        manualCalibrationOffsetText = String(format: "%.1f", viewModel.compassCalibrationOffsetDegrees)
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let unit: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.46))

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)

                Text(unit)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.52))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(tint.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
        )
    }
}

private struct PlaceholderButton: View {
    let title: String

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [8, 8]))
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.03))
            )
            .frame(height: 84)
            .overlay {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
            }
    }
}

enum MarkerLabelPosition {
    case top
    case bottom
}

enum MarkerBadgeSize {
    case regular
    case compact

    var haloDiameter: CGFloat {
        switch self {
        case .regular:
            return 70
        case .compact:
            return 52
        }
    }

    var badgeDiameter: CGFloat {
        switch self {
        case .regular:
            return 50
        case .compact:
            return 38
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .regular:
            return 22
        case .compact:
            return 16
        }
    }

    var ringWidth: CGFloat {
        switch self {
        case .regular:
            return 4
        case .compact:
            return 3
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .regular:
            return 16
        case .compact:
            return 11
        }
    }

    var shadowYOffset: CGFloat {
        switch self {
        case .regular:
            return 8
        case .compact:
            return 5
        }
    }

    var labelFontSize: CGFloat {
        switch self {
        case .regular:
            return 12
        case .compact:
            return 10
        }
    }

    var labelHorizontalPadding: CGFloat {
        switch self {
        case .regular:
            return 8
        case .compact:
            return 7
        }
    }

    var labelVerticalPadding: CGFloat {
        switch self {
        case .regular:
            return 3
        case .compact:
            return 2.5
        }
    }

    var spacing: CGFloat {
        switch self {
        case .regular:
            return 4
        case .compact:
            return 3
        }
    }
}

struct MarkerBadge: View {
    let title: String
    let systemImage: String
    let tint: Color
    let labelPosition: MarkerLabelPosition
    let size: MarkerBadgeSize

    var body: some View {
        VStack(spacing: size.spacing) {
            if labelPosition == .top {
                markerLabel
            }

            ZStack {
                Circle()
                    .fill(tint.opacity(0.22))
                    .frame(width: size.haloDiameter, height: size.haloDiameter)

                Circle()
                    .fill(tint)
                    .frame(width: size.badgeDiameter, height: size.badgeDiameter)
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: size.ringWidth)
                    )

                Image(systemName: systemImage)
                    .font(.system(size: size.iconSize, weight: .bold))
                    .foregroundStyle(.white)
            }
            .shadow(color: tint.opacity(0.4), radius: size.shadowRadius, x: 0, y: size.shadowYOffset)

            if labelPosition == .bottom {
                markerLabel
            }
        }
    }

    private var markerLabel: some View {
        Text(title)
            .font(.system(size: size.labelFontSize, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .padding(.horizontal, size.labelHorizontalPadding)
            .padding(.vertical, size.labelVerticalPadding)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.9))
            )
    }
}

struct CompactStatusView: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))

                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }
    }
}
