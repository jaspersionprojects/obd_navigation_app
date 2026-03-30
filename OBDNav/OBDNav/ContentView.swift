//
//  ContentView.swift
//  OBDNav
//
//  Created by Jasper Sion on 30/03/2026.
//

import MapKit
import SwiftUI

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
                statusCapsule
                DashboardPanel(
                    viewModel: viewModel,
                    collapsedHeight: 200,
                    expandedHeight: min(proxy.size.height * 0.58, 500)
                )
            }
            .background(Color.white)
            .ignoresSafeArea()
        }
        .sheet(isPresented: $viewModel.isShowingDevicePicker, onDismiss: viewModel.didDismissDevicePicker) {
            OBDDonglePickerSheet(viewModel: viewModel)
        }
        .task {
            viewModel.start()
        }
    }

    private var mapLayer: some View {
        Map(position: $viewModel.cameraPosition, interactionModes: .all) {
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

            if let gpsCoordinate = viewModel.gpsCoordinate {
                Annotation("GPS", coordinate: gpsCoordinate, anchor: .center) {
                    MarkerBadge(
                        title: "GPS",
                        systemImage: "location.fill",
                        tint: Color(red: 0.25, green: 0.62, blue: 0.97),
                        labelPosition: .bottom
                    )
                }
            }

            if let obdCoordinate = viewModel.obdCoordinate {
                Annotation("OBD", coordinate: obdCoordinate, anchor: .center) {
                    MarkerBadge(
                        title: "OBD",
                        systemImage: "scope",
                        tint: Color(red: 0.98, green: 0.48, blue: 0.20),
                        labelPosition: .top
                    )
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
    }

    private var statusCapsule: some View {
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
            .padding(.top, 18)

            Spacer()
        }
        .padding(.horizontal, 48)
        .allowsHitTesting(false)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(viewModel: .preview)
    }
}
