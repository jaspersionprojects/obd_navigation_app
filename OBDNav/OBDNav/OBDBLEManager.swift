//
//  OBDBLEManager.swift
//  OBDNav
//
//  Created by Codex on 30/03/2026.
//

import Combine
import CoreBluetooth
import Foundation
import SwiftUI

struct OBDDongle: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    let isLikelyOBD: Bool

    var displayName: String {
        if !name.isEmpty {
            return name
        }

        return "BLE Device \(id.uuidString.prefix(4))"
    }

    var signalIconName: String {
        switch rssi {
        case ..<(-85):
            return "wifi"
        case ..<(-70):
            return "wifi"
        case ..<(-55):
            return "wifi"
        default:
            return "wifi"
        }
    }
}

enum OBDConnectionState: Equatable {
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

@MainActor
final class OBDBLEManager: NSObject, ObservableObject {
    @Published private(set) var speedKPH: Double?
    @Published private(set) var connectionState: OBDConnectionState = .idle
    @Published private(set) var discoveredDevices: [OBDDongle] = []
    @Published private(set) var isDiscoveringDevices = false
    @Published private(set) var connectingDeviceID: UUID?
    @Published private(set) var connectedDeviceID: UUID?

    private lazy var centralManager = CBCentralManager(delegate: self, queue: nil)
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var discoveredNames: [UUID: String] = [:]
    private var activePeripheral: CBPeripheral?
    private var pendingPeripheralToConnect: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var responseCharacteristic: CBCharacteristic?
    private var pollTask: Task<Void, Never>?
    private var responseBuffer = ""
    private var hasStarted = false

    private let deviceNameTokens = [
        "OBD", "ELM", "VEEPEAK", "VGATE", "KIWI", "VLINK", "CARISTA", "CAN", "AUTO", "JV"
    ]
    private let serviceUUIDTokens = [
        "6E400001", "FFE0", "FFE1", "FFF0", "FFF1", "FFF2", "FFF3", "FFF4", "FFF5", "FFF6",
        "AE00", "AE01", "1101"
    ]
    private lazy var knownOBDServiceUUIDs: [CBUUID] = serviceUUIDTokens.map(CBUUID.init(string:))

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

    func connect(to dongle: OBDDongle) {
        guard let peripheral = discoveredPeripherals[dongle.id] else { return }
        connect(to: peripheral, knownName: dongle.displayName)
    }

    func setPreviewState(speedKPH: Double?, connectionState: OBDConnectionState) {
        self.speedKPH = speedKPH
        self.connectionState = connectionState
        connectedDeviceID = UUID()
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
        stopPolling()
        activePeripheral = nil
        pendingPeripheralToConnect = nil
        writeCharacteristic = nil
        responseCharacteristic = nil
        responseBuffer = ""
        speedKPH = nil
        connectingDeviceID = nil
        connectedDeviceID = nil
    }

    private func connect(to peripheral: CBPeripheral, knownName: String?) {
        stopDiscovery()
        stopPolling()
        responseBuffer = ""
        speedKPH = nil
        writeCharacteristic = nil
        responseCharacteristic = nil

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

    private func configureELM327() {
        guard writeCharacteristic != nil else { return }

        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }

            let setupCommands = ["ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0"]
            for command in setupCommands {
                send(command)
                try? await Task.sleep(for: .milliseconds(350))
            }

            while !Task.isCancelled {
                send("010D")
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func send(_ command: String) {
        guard let activePeripheral, let writeCharacteristic else { return }
        guard let data = "\(command)\r".data(using: .utf8) else { return }

        let writeType: CBCharacteristicWriteType = writeCharacteristic.properties.contains(.write)
            ? .withResponse
            : .withoutResponse

        activePeripheral.writeValue(data, for: writeCharacteristic, type: writeType)

        if let responseCharacteristic,
           responseCharacteristic.properties.contains(.read),
           !responseCharacteristic.properties.contains(.notify),
           !responseCharacteristic.properties.contains(.indicate) {
            activePeripheral.readValue(for: responseCharacteristic)
        }
    }

    private func handleIncomingData(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }

        responseBuffer.append(chunk.uppercased())

        if let speedKPH = Self.extractVehicleSpeed(from: responseBuffer) {
            self.speedKPH = speedKPH == 255 ? nil : speedKPH
        }

        if responseBuffer.count > 320 {
            responseBuffer = String(responseBuffer.suffix(320))
        }
    }

    private func shouldList(peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
        if isLikelyOBD(peripheral: peripheral, advertisementData: advertisementData) {
            return true
        }

        if let name = actualAdvertisedName(for: peripheral, advertisementData: advertisementData),
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        let serviceUUIDs = advertisedServiceUUIDStrings(from: advertisementData)
        return !serviceUUIDs.isEmpty
    }

    private func isLikelyOBD(peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
        if let name = actualAdvertisedName(for: peripheral, advertisementData: advertisementData)?.uppercased(),
           deviceNameTokens.contains(where: name.contains) {
            return true
        }

        let serviceUUIDs = advertisedServiceUUIDStrings(from: advertisementData)
        return serviceUUIDs.contains { uuid in
            serviceUUIDTokens.contains { uuid.contains($0) }
        }
    }

    private func updateDiscoveredDevice(_ peripheral: CBPeripheral, advertisementData: [String: Any], rssi: Int) {
        let name = actualAdvertisedName(for: peripheral, advertisementData: advertisementData)
            ?? peripheralDisplayName(for: peripheral, advertisementData: advertisementData)
        let isLikelyOBD = isLikelyOBD(peripheral: peripheral, advertisementData: advertisementData)
        discoveredPeripherals[peripheral.identifier] = peripheral
        discoveredNames[peripheral.identifier] = name

        let dongle = OBDDongle(id: peripheral.identifier, name: name, rssi: rssi, isLikelyOBD: isLikelyOBD)

        if let existingIndex = discoveredDevices.firstIndex(where: { $0.id == dongle.id }) {
            discoveredDevices[existingIndex] = dongle
        } else {
            discoveredDevices.append(dongle)
        }

        discoveredDevices.sort {
            if $0.isLikelyOBD != $1.isLikelyOBD {
                return $0.isLikelyOBD && !$1.isLikelyOBD
            }

            return $0.rssi > $1.rssi
        }
    }

    private func addConnectedCandidates() {
        guard !knownOBDServiceUUIDs.isEmpty else { return }

        let connectedPeripherals = centralManager.retrieveConnectedPeripherals(withServices: knownOBDServiceUUIDs)

        for peripheral in connectedPeripherals {
            updateDiscoveredDevice(peripheral, advertisementData: [:], rssi: 0)
        }
    }

    private func peripheralDisplayName(
        for peripheral: CBPeripheral,
        advertisementData: [String: Any]? = nil
    ) -> String {
        actualAdvertisedName(for: peripheral, advertisementData: advertisementData) ?? "Unnamed device"
    }

    private func actualAdvertisedName(
        for peripheral: CBPeripheral,
        advertisementData: [String: Any]? = nil
    ) -> String? {
        if let localName = advertisementData?[CBAdvertisementDataLocalNameKey] as? String,
           !localName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return localName
        }

        if let name = peripheral.name,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }

        return nil
    }

    private func advertisedServiceUUIDStrings(from advertisementData: [String: Any]) -> [String] {
        let uuidKeys = [
            CBAdvertisementDataServiceUUIDsKey,
            CBAdvertisementDataOverflowServiceUUIDsKey,
            CBAdvertisementDataSolicitedServiceUUIDsKey
        ]

        return uuidKeys
            .compactMap { advertisementData[$0] as? [CBUUID] }
            .flatMap { $0 }
            .map { $0.uuidString.uppercased() }
    }

    private static func extractVehicleSpeed(from response: String) -> Double? {
        let bytes = hexByteStrings(from: response)

        guard bytes.count >= 3 else { return nil }

        for index in 0..<(bytes.count - 2) where bytes[index] == "41" && bytes[index + 1] == "0D" {
            guard let speed = Int(bytes[index + 2], radix: 16) else { continue }
            return Double(speed)
        }

        return nil
    }

    private static func hexByteStrings(from response: String) -> [String] {
        var bytes: [String] = []
        var pendingNibble: Character?

        for character in response.uppercased() where character.isHexDigit {
            if let nibble = pendingNibble {
                bytes.append(String([nibble, character]))
                pendingNibble = nil
            } else {
                pendingNibble = character
            }
        }

        return bytes
    }
}

extension OBDBLEManager: CBCentralManagerDelegate {
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
        activePeripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectingDeviceID = nil
        connectedDeviceID = nil
        activePeripheral = nil
        connectionState = .failed("Unable to connect")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        stopPolling()
        writeCharacteristic = nil
        responseCharacteristic = nil
        speedKPH = nil
        connectedDeviceID = nil
        activePeripheral = nil

        if let pendingPeripheralToConnect {
            let nextPeripheral = pendingPeripheralToConnect
            self.pendingPeripheralToConnect = nil
            connect(to: nextPeripheral, knownName: discoveredNames[nextPeripheral.identifier])
            return
        }

        if connectingDeviceID != nil {
            connectionState = .failed("Connection lost")
        } else {
            connectionState = .idle
        }

        connectingDeviceID = nil
    }
}

extension OBDBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            connectingDeviceID = nil
            connectedDeviceID = nil
            connectionState = .failed("Service discovery failed")
            return
        }

        peripheral.services?.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil else {
            connectingDeviceID = nil
            connectedDeviceID = nil
            connectionState = .failed("Characteristic discovery failed")
            return
        }

        service.characteristics?.forEach { characteristic in
            if writeCharacteristic == nil,
               characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
                writeCharacteristic = characteristic
            }

            if responseCharacteristic == nil,
               characteristic.properties.contains(.notify) ||
               characteristic.properties.contains(.indicate) ||
               characteristic.properties.contains(.read) {
                responseCharacteristic = characteristic

                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }

        if writeCharacteristic != nil, responseCharacteristic != nil {
            connectedDeviceID = peripheral.identifier
            connectingDeviceID = nil
            connectionState = .connected(peripheralDisplayName(for: peripheral))
            configureELM327()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }
        handleIncomingData(data)
    }
}
