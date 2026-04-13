//
//  WitMotionBLEManager.swift
//  OBDNav
//
//  Created by Codex on 13/04/2026.
//

import Combine
import CoreBluetooth
import CoreLocation
import Foundation
import SwiftUI
import simd

struct WitMotionDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    let isLikelySensor: Bool

    var displayName: String {
        if !name.isEmpty {
            return name
        }

        return "BLE Sensor \(id.uuidString.prefix(4))"
    }
}

enum WitMotionSensorConnectionState: Equatable {
    case idle
    case bluetoothOff
    case connecting(String)
    case connected(String)
    case failed(String)

    var displayText: String {
        switch self {
        case .idle:
            return "Not connected"
        case .bluetoothOff:
            return "Bluetooth off"
        case .connecting(let name):
            return "Connecting to \(name)"
        case .connected(let name):
            return "Connected to \(name)"
        case .failed(let message):
            return message
        }
    }

    var tint: Color {
        switch self {
        case .connected:
            return Color(red: 0.20, green: 0.63, blue: 0.42)
        case .connecting:
            return Color(red: 0.95, green: 0.57, blue: 0.16)
        case .failed, .bluetoothOff:
            return Color(red: 0.87, green: 0.29, blue: 0.29)
        case .idle:
            return Color.black.opacity(0.45)
        }
    }
}

struct WitMotionSample {
    let correctedAccelerationG: SIMD3<Double>
    let correctedRotationRateRadPerSec: SIMD3<Double>
    let yawDegrees: CLLocationDirection
}

@MainActor
final class WitMotionBLEManager: NSObject, ObservableObject {
    @Published private(set) var latestSample: WitMotionSample?
    @Published private(set) var connectionState: WitMotionSensorConnectionState = .idle
    @Published private(set) var discoveredDevices: [WitMotionDevice] = []
    @Published private(set) var isDiscoveringDevices = false
    @Published private(set) var connectingDeviceID: UUID?
    @Published private(set) var connectedDeviceID: UUID?

    private lazy var centralManager = CBCentralManager(delegate: self, queue: nil)
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var discoveredNames: [UUID: String] = [:]
    private var activePeripheral: CBPeripheral?
    private var pendingPeripheralToConnect: CBPeripheral?
    private var readCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var packetBuffer: [UInt8] = []
    private var hasStarted = false

    private let deviceNameTokens = ["WT", "WIT", "BWT", "HWT"]
    private let serviceUUIDTokens = ["FFE5", "49535343-FE7D-4AE5-8FA9-9FAFD205E455"]
    private lazy var knownServiceUUIDs: [CBUUID] = [
        CBUUID(string: "0000FFE5-0000-1000-8000-00805F9A34FB"),
        CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455")
    ]
    private let bleServiceUUID = "0000FFE5-0000-1000-8000-00805F9A34FB"
    private let bleReadUUID = "0000FFE4-0000-1000-8000-00805F9A34FB"
    private let bleWriteUUID = "0000FFE9-0000-1000-8000-00805F9A34FB"
    private let dualServiceUUID = "49535343-FE7D-4AE5-8FA9-9FAFD205E455"
    private let dualReadUUID = "49535343-1E4D-4BD9-BA61-23C647249616"
    private let dualWriteUUID = "49535343-8841-43F4-A8D4-ECBE34729BB3"

    func start() {
        hasStarted = true
        handleBluetoothState(centralManager.state)
    }

    func beginDiscovery() {
        guard hasStarted else { return }
        guard centralManager.state == .poweredOn else {
            handleBluetoothState(centralManager.state)
            return
        }

        discoveredDevices = []
        discoveredPeripherals = [:]
        discoveredNames = [:]
        isDiscoveringDevices = true

        centralManager.stopScan()
        addConnectedCandidates()
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopDiscovery() {
        isDiscoveringDevices = false
        centralManager.stopScan()
    }

    func connect(to device: WitMotionDevice) {
        guard let peripheral = discoveredPeripherals[device.id] else { return }
        connect(to: peripheral, knownName: device.displayName)
    }

    private func handleBluetoothState(_ state: CBManagerState) {
        guard hasStarted else { return }

        switch state {
        case .poweredOn:
            if activePeripheral == nil, connectedDeviceID == nil, connectingDeviceID == nil {
                connectionState = .idle
            }
        case .poweredOff:
            resetConnectionState()
            connectionState = .bluetoothOff
        case .unauthorized:
            resetConnectionState()
            connectionState = .failed("Bluetooth permission denied")
        case .unsupported:
            resetConnectionState()
            connectionState = .failed("Bluetooth unsupported")
        case .resetting, .unknown:
            break
        @unknown default:
            resetConnectionState()
            connectionState = .failed("Bluetooth unavailable")
        }
    }

    private func resetConnectionState() {
        stopDiscovery()
        activePeripheral = nil
        pendingPeripheralToConnect = nil
        readCharacteristic = nil
        writeCharacteristic = nil
        packetBuffer = []
        latestSample = nil
        connectingDeviceID = nil
        connectedDeviceID = nil
    }

    private func connect(to peripheral: CBPeripheral, knownName: String?) {
        stopDiscovery()
        latestSample = nil
        packetBuffer = []
        readCharacteristic = nil
        writeCharacteristic = nil

        let displayName = knownName ?? discoveredNames[peripheral.identifier] ?? peripheralDisplayName(for: peripheral)
        connectingDeviceID = peripheral.identifier
        connectionState = .connecting(displayName)

        if let activePeripheral, activePeripheral.identifier != peripheral.identifier,
           activePeripheral.state != .disconnected {
            pendingPeripheralToConnect = peripheral
            connectedDeviceID = nil
            centralManager.cancelPeripheralConnection(activePeripheral)
            return
        }

        pendingPeripheralToConnect = nil
        activePeripheral = peripheral
        peripheral.delegate = self

        if peripheral.state == .connected {
            peripheral.discoverServices(nil)
        } else {
            centralManager.connect(peripheral, options: nil)
        }
    }

    private func finalizeConnectionIfReady() {
        guard let activePeripheral, readCharacteristic != nil else { return }

        let displayName = discoveredNames[activePeripheral.identifier] ?? peripheralDisplayName(for: activePeripheral)
        connectedDeviceID = activePeripheral.identifier
        connectingDeviceID = nil
        connectionState = .connected(displayName)
    }

    private func updateDiscoveredDevice(_ peripheral: CBPeripheral, advertisementData: [String: Any], rssi: Int) {
        let name = actualAdvertisedName(for: peripheral, advertisementData: advertisementData)
            ?? peripheralDisplayName(for: peripheral, advertisementData: advertisementData)
        let isLikelySensor = isLikelyWitMotionSensor(peripheral: peripheral, advertisementData: advertisementData)
        discoveredPeripherals[peripheral.identifier] = peripheral
        discoveredNames[peripheral.identifier] = name

        let device = WitMotionDevice(id: peripheral.identifier, name: name, rssi: rssi, isLikelySensor: isLikelySensor)

        if let existingIndex = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[existingIndex] = device
        } else {
            discoveredDevices.append(device)
        }

        discoveredDevices.sort {
            if $0.isLikelySensor != $1.isLikelySensor {
                return $0.isLikelySensor && !$1.isLikelySensor
            }

            return $0.rssi > $1.rssi
        }
    }

    private func addConnectedCandidates() {
        let connectedPeripherals = centralManager.retrieveConnectedPeripherals(withServices: knownServiceUUIDs)

        for peripheral in connectedPeripherals {
            updateDiscoveredDevice(peripheral, advertisementData: [:], rssi: 0)
        }
    }

    private func shouldList(peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
        if isLikelyWitMotionSensor(peripheral: peripheral, advertisementData: advertisementData) {
            return true
        }

        if let name = actualAdvertisedName(for: peripheral, advertisementData: advertisementData),
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           deviceNameTokens.contains(where: name.uppercased().contains) {
            return true
        }

        let serviceUUIDs = advertisedServiceUUIDStrings(from: advertisementData)
        return serviceUUIDs.contains { uuid in
            serviceUUIDTokens.contains { uuid.contains($0) }
        }
    }

    private func isLikelyWitMotionSensor(peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
        if let name = actualAdvertisedName(for: peripheral, advertisementData: advertisementData)?.uppercased(),
           deviceNameTokens.contains(where: name.contains) {
            return true
        }

        let serviceUUIDs = advertisedServiceUUIDStrings(from: advertisementData)
        return serviceUUIDs.contains { uuid in
            serviceUUIDTokens.contains { uuid.contains($0) }
        }
    }

    private func handleIncomingData(_ data: Data) {
        packetBuffer.append(contentsOf: data)

        while packetBuffer.count >= 20 {
            guard let headerIndex = packetBuffer.firstIndex(of: 0x55) else {
                packetBuffer.removeAll(keepingCapacity: true)
                return
            }

            if headerIndex > 0 {
                packetBuffer.removeFirst(headerIndex)
            }

            guard packetBuffer.count >= 20 else { return }

            let flag = packetBuffer[1]
            guard flag == 0x61 else {
                packetBuffer.removeFirst()
                continue
            }

            let packet = Array(packetBuffer.prefix(20))
            packetBuffer.removeFirst(20)

            if let sample = Self.decodeRealtimePacket(packet) {
                latestSample = sample
            }
        }

        if packetBuffer.count > 200 {
            packetBuffer = Array(packetBuffer.suffix(200))
        }
    }

    private static func decodeRealtimePacket(_ packet: [UInt8]) -> WitMotionSample? {
        guard packet.count >= 20, packet[0] == 0x55, packet[1] == 0x61 else {
            return nil
        }

        let ax = decodeSigned(packet[2], packet[3]) / 32768.0 * 16.0
        let ay = decodeSigned(packet[4], packet[5]) / 32768.0 * 16.0
        let az = decodeSigned(packet[6], packet[7]) / 32768.0 * 16.0

        let gxDegreesPerSecond = decodeSigned(packet[8], packet[9]) / 32768.0 * 2000.0
        let gyDegreesPerSecond = decodeSigned(packet[10], packet[11]) / 32768.0 * 2000.0
        let gzDegreesPerSecond = decodeSigned(packet[12], packet[13]) / 32768.0 * 2000.0

        let yawDegrees = normalizeDegrees(decodeSigned(packet[18], packet[19]) / 32768.0 * 180.0)

        return WitMotionSample(
            correctedAccelerationG: SIMD3<Double>(ax, ay, az),
            correctedRotationRateRadPerSec: SIMD3<Double>(
                gxDegreesPerSecond * .pi / 180,
                gyDegreesPerSecond * .pi / 180,
                gzDegreesPerSecond * .pi / 180
            ),
            yawDegrees: yawDegrees
        )
    }

    private static func decodeSigned(_ lowByte: UInt8, _ highByte: UInt8) -> Double {
        let value = Int16(bitPattern: UInt16(lowByte) | (UInt16(highByte) << 8))
        return Double(value)
    }

    private static func normalizeDegrees(_ value: CLLocationDirection) -> CLLocationDirection {
        let normalized = value.truncatingRemainder(dividingBy: 360)
        return normalized >= 0 ? normalized : normalized + 360
    }

    private func peripheralDisplayName(
        for peripheral: CBPeripheral,
        advertisementData: [String: Any]? = nil
    ) -> String {
        actualAdvertisedName(for: peripheral, advertisementData: advertisementData) ?? "Unnamed sensor"
    }

    private func actualAdvertisedName(
        for peripheral: CBPeripheral,
        advertisementData: [String: Any]?
    ) -> String? {
        if let advertisedName = advertisementData?[CBAdvertisementDataLocalNameKey] as? String,
           !advertisedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return advertisedName
        }

        if let peripheralName = peripheral.name,
           !peripheralName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return peripheralName
        }

        return nil
    }

    private func advertisedServiceUUIDStrings(from advertisementData: [String: Any]) -> [String] {
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        return serviceUUIDs.map { $0.uuidString.uppercased() }
    }
}

extension WitMotionBLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        handleBluetoothState(central.state)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard shouldList(peripheral: peripheral, advertisementData: advertisementData) else { return }
        updateDiscoveredDevice(peripheral, advertisementData: advertisementData, rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectingDeviceID = nil
        connectedDeviceID = nil
        connectionState = .failed(error?.localizedDescription ?? "Failed to connect to sensor")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let disconnectedID = peripheral.identifier

        if activePeripheral?.identifier == disconnectedID {
            activePeripheral = nil
            readCharacteristic = nil
            writeCharacteristic = nil
            packetBuffer = []
            latestSample = nil
            connectedDeviceID = nil
            connectingDeviceID = nil
            connectionState = .failed(error?.localizedDescription ?? "Sensor disconnected")
        }

        if let pendingPeripheralToConnect {
            self.pendingPeripheralToConnect = nil
            connect(to: pendingPeripheralToConnect, knownName: discoveredNames[pendingPeripheralToConnect.identifier])
        }
    }
}

extension WitMotionBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            connectionState = .failed(error?.localizedDescription ?? "Unable to discover sensor services")
            return
        }

        for service in peripheral.services ?? [] {
            let serviceUUID = service.uuid.uuidString.uppercased()

            if serviceUUID == bleServiceUUID || serviceUUID == dualServiceUUID {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            connectionState = .failed(error?.localizedDescription ?? "Unable to discover sensor characteristics")
            return
        }

        let serviceUUID = service.uuid.uuidString.uppercased()
        let expectedReadUUID = serviceUUID == dualServiceUUID ? dualReadUUID : bleReadUUID
        let expectedWriteUUID = serviceUUID == dualServiceUUID ? dualWriteUUID : bleWriteUUID

        for characteristic in service.characteristics ?? [] {
            let uuid = characteristic.uuid.uuidString.uppercased()

            if uuid == expectedReadUUID {
                readCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            } else if uuid == expectedWriteUUID {
                writeCharacteristic = characteristic
            }
        }

        finalizeConnectionIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            connectionState = .failed(error?.localizedDescription ?? "Unable to subscribe to sensor data")
            return
        }

        finalizeConnectionIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else { return }
        guard let data = characteristic.value else { return }
        handleIncomingData(data)
    }
}
