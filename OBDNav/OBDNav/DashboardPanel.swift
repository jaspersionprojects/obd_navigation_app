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

    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        let baseOffset = viewModel.isPanelExpanded ? 0 : expandedHeight - collapsedHeight
        let interactiveOffset = clampOffset(baseOffset + dragOffset)

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
        .offset(y: interactiveOffset)
        .shadow(color: Color.black.opacity(0.18), radius: 24, x: 0, y: -8)
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: viewModel.isPanelExpanded)
    }

    private var panelHandle: some View {
        Capsule()
            .fill(Color.black.opacity(0.18))
            .frame(width: 58, height: 7)
            .padding(.top, 4)
            .contentShape(Rectangle())
            .gesture(verticalDragGesture)
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
        }
        .contentShape(Rectangle())
        .gesture(verticalDragGesture)
    }

    private var panelContent: some View {
        TabView(selection: $viewModel.selectedPanelPage) {
            telemetryPage
                .tag(0)

            futureControlsPage
                .tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private var telemetryPage: some View {
        VStack(spacing: 14) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                StatCard(
                    title: "GPS Speed",
                    value: speedText(viewModel.gpsSpeedKPH),
                    unit: "km/h",
                    tint: Color(red: 0.66, green: 0.86, blue: 0.90)
                )

                StatCard(
                    title: "OBD Speed",
                    value: speedText(viewModel.obdSpeedKPH),
                    unit: "km/h",
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

            HStack(spacing: 12) {
                connectButton
                connectionStatusCard
            }

            snapButton
        }
        .padding(.top, 4)
    }

    private var futureControlsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Future Controls")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("This second slide is ready for the next buttons you want to add later.")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.74))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                PlaceholderButton(title: "Slot 1")
                PlaceholderButton(title: "Slot 2")
                PlaceholderButton(title: "Slot 3")
                PlaceholderButton(title: "Slot 4")
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.black.opacity(0.96))
        )
    }

    private var connectButton: some View {
        Button(action: viewModel.showOBDDevicePicker) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 18, weight: .semibold))

                    Text("Connect to OBD dongle")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .lineLimit(2)
                }

                Text(viewModel.connectButtonSubtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.48))
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .padding(.horizontal, 18)
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
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .lineLimit(3)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.white.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var snapButton: some View {
        Button(action: viewModel.snapOBDToGPS) {
            HStack(spacing: 12) {
                Image(systemName: "location.fill")
                    .font(.system(size: 20, weight: .bold))

                Text("Snap To GPS")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.99, green: 0.56, blue: 0.18),
                                Color(red: 0.91, green: 0.33, blue: 0.04)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            pageDot(index: 0)
            pageDot(index: 1)
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

    private var verticalDragGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .updating($dragOffset) { value, state, _ in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                state = value.translation.height
            }
            .onEnded { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }

                if value.translation.height < -60 {
                    viewModel.isPanelExpanded = true
                } else if value.translation.height > 60 {
                    viewModel.isPanelExpanded = false
                }
            }
    }

    private func selectorButton(title: String, systemImage: String, index: Int) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                viewModel.selectedPanelPage = index
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))

                Text(title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(index == viewModel.selectedPanelPage ? Color(red: 0.20, green: 0.28, blue: 0.44) : Color.white.opacity(0.62))
            )
            .foregroundStyle(index == viewModel.selectedPanelPage ? .white : .black)
        }
        .buttonStyle(.plain)
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

    private func speedText(_ value: Double?) -> String {
        guard let value else { return "--" }
        return value.formatted(.number.precision(.fractionLength(1)))
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
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.46))

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)

                Text(unit)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.52))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 122, alignment: .leading)
        .padding(20)
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

struct MarkerBadge: View {
    let title: String
    let systemImage: String
    let tint: Color
    let labelPosition: MarkerLabelPosition

    var body: some View {
        VStack(spacing: 4) {
            if labelPosition == .top {
                markerLabel
            }

            ZStack {
                Circle()
                    .fill(tint.opacity(0.22))
                    .frame(width: 70, height: 70)

                Circle()
                    .fill(tint)
                    .frame(width: 50, height: 50)
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 4)
                    )

                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            .shadow(color: tint.opacity(0.4), radius: 16, x: 0, y: 8)

            if labelPosition == .bottom {
                markerLabel
            }
        }
    }

    private var markerLabel: some View {
        Text(title)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
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
