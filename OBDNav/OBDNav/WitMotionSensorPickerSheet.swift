//
//  WitMotionSensorPickerSheet.swift
//  OBDNav
//
//  Created by Codex on 13/04/2026.
//

import SwiftUI

struct WitMotionSensorPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: NavigationViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard

                    if viewModel.discoveredSensors.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(viewModel.discoveredSensors) { sensor in
                                sensorRow(for: sensor)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(red: 0.97, green: 0.97, blue: 0.95))
            .navigationTitle("Nearby BLE sensors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Rescan") {
                        viewModel.beginSensorDiscovery()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            viewModel.beginSensorDiscovery()
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(viewModel.sensorStatusTint)
                    .frame(width: 12, height: 12)

                Text("Sensor connection")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.46))
            }

            Text(viewModel.sensorStatusText)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.black)

            Text("Tap your nearby WITMotion BLE sensor below to connect. Likely sensors are shown first.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.55))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.black)

            Text(emptyStateTitle)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.black)

            Text(emptyStateMessage)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    private func sensorRow(for sensor: WitMotionDevice) -> some View {
        Button {
            viewModel.selectSensor(sensor)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.08))
                        .frame(width: 46, height: 46)

                    Image(systemName: "gyroscope")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.black)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(sensor.displayName)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("RSSI \(sensor.rssi) dBm")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.46))

                    if sensor.isLikelySensor {
                        Text("Likely WITMotion sensor")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(red: 0.20, green: 0.52, blue: 0.93))
                    }
                }

                rowAccessory(for: sensor)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(borderColor(for: sensor), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func rowAccessory(for sensor: WitMotionDevice) -> some View {
        if viewModel.connectedSensorID == sensor.id {
            Text("Connected")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(red: 0.84, green: 0.95, blue: 0.80))
                )
                .foregroundStyle(Color(red: 0.17, green: 0.46, blue: 0.24))
        } else if viewModel.connectingSensorID == sensor.id {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.black)
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.26))
        }
    }

    private func borderColor(for sensor: WitMotionDevice) -> Color {
        if viewModel.connectedSensorID == sensor.id {
            return Color(red: 0.55, green: 0.83, blue: 0.57)
        }

        if viewModel.connectingSensorID == sensor.id {
            return Color(red: 0.97, green: 0.56, blue: 0.18)
        }

        return Color.black.opacity(0.06)
    }

    private var emptyStateTitle: String {
        switch viewModel.sensorConnectionState {
        case .bluetoothOff:
            return "Bluetooth is off"
        case .failed:
            return "No sensors yet"
        case .idle, .connecting, .connected:
            return "Searching nearby"
        }
    }

    private var emptyStateMessage: String {
        switch viewModel.sensorConnectionState {
        case .bluetoothOff:
            return "Turn Bluetooth on and make sure your WITMotion sensor is powered."
        case .failed(let message):
            return message
        case .idle, .connecting, .connected:
            return "Make sure the sensor is powered on and advertising over BLE."
        }
    }
}
