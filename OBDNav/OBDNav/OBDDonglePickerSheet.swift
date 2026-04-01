//
//  OBDDonglePickerSheet.swift
//  OBDNav
//
//  Created by Codex on 30/03/2026.
//

import SwiftUI

struct OBDDonglePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: NavigationViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard

                    if viewModel.discoveredDongles.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(viewModel.discoveredDongles) { dongle in
                                dongleRow(for: dongle)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(red: 0.97, green: 0.97, blue: 0.95))
            .navigationTitle("Nearby OBD dongles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Rescan") {
                        viewModel.beginDongleDiscovery()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            viewModel.beginDongleDiscovery()
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(viewModel.obdStatusTint)
                    .frame(width: 12, height: 12)

                Text("OBD connection")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.46))
            }

            Text(viewModel.obdStatusText)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.black)

            Text("Tap a nearby BLE device below to connect. Likely OBD dongles are shown first.")
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

    private func dongleRow(for dongle: OBDDongle) -> some View {
        Button {
            viewModel.selectOBDDongle(dongle)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.08))
                        .frame(width: 46, height: 46)

                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.black)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(dongle.displayName)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("RSSI \(dongle.rssi) dBm")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.46))

                    if dongle.isLikelyOBD {
                        Text("Likely OBD dongle")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(red: 0.95, green: 0.57, blue: 0.16))
                    }
                }

                rowAccessory(for: dongle)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(borderColor(for: dongle), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func rowAccessory(for dongle: OBDDongle) -> some View {
        if viewModel.connectedDongleID == dongle.id {
            Text("Connected")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(red: 0.84, green: 0.95, blue: 0.80))
                )
                .foregroundStyle(Color(red: 0.17, green: 0.46, blue: 0.24))
        } else if viewModel.connectingDongleID == dongle.id {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.black)
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.26))
        }
    }

    private func borderColor(for dongle: OBDDongle) -> Color {
        if viewModel.connectedDongleID == dongle.id {
            return Color(red: 0.55, green: 0.83, blue: 0.57)
        }

        if viewModel.connectingDongleID == dongle.id {
            return Color(red: 0.97, green: 0.56, blue: 0.18)
        }

        return Color.black.opacity(0.06)
    }

    private var emptyStateTitle: String {
        switch viewModel.obdConnectionState {
        case .bluetoothOff:
            return "Bluetooth is off"
        case .failed:
            return "No dongles yet"
        case .idle, .connecting, .connected:
            return "Searching nearby"
        }
    }

    private var emptyStateMessage: String {
        switch viewModel.obdConnectionState {
        case .bluetoothOff:
            return "Turn Bluetooth on and make sure your OBD dongle is powered."
        case .failed(let message):
            return message
        case .idle, .connecting, .connected:
            return "Make sure the dongle is powered on and advertising over BLE."
        }
    }
}
