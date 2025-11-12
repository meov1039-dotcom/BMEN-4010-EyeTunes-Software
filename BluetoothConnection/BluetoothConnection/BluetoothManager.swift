//
//  BluetoothManager.swift
//  BluetoothConnection
//
//  Created by Alena Tucker on 11/12/25.
//

import Foundation
import CoreBluetooth
import Combine

class BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    // Published properties so SwiftUI updates automatically
    @Published var peripherals: [CBPeripheral] = []
    @Published var status: String = "Initializing..."
    @Published var connectedPeripheral: CBPeripheral?

    private var centralManager: CBCentralManager!

    override init() {
        super.init()
        // Create central manager instance
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - CBCentralManagerDelegate methods
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DispatchQueue.main.async {
            switch central.state {
            case .poweredOn:
                self.status = "Scanning for Bluetooth devices..."
                self.peripherals.removeAll()
                self.centralManager.scanForPeripherals(withServices: nil, options: nil)
            case .poweredOff:
                self.status = "Bluetooth is powered off"
            case .unauthorized:
                self.status = "Bluetooth permission denied"
            case .unsupported:
                self.status = "Bluetooth not supported on this Mac"
            default:
                self.status = "Bluetooth unavailable (\(central.state.rawValue))"
            }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        DispatchQueue.main.async {
            // Get name from either the peripheral or the advertisement data
            let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""

            // Skip unnamed devices
            guard !name.isEmpty else { return }

            // Only include devices whose name contains "ESP" (case-insensitive)
            if name.uppercased().contains("ESP") {
                if !self.peripherals.contains(where: { $0.identifier == peripheral.identifier }) {
                    self.peripherals.append(peripheral)
                    print("Found ESP device: \(name)")
                }
            }
        }
    }


    // Connect to a specific peripheral
    func connect(to peripheral: CBPeripheral) {
        centralManager.stopScan()
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
        DispatchQueue.main.async {
            self.status = "Connecting to \(peripheral.name ?? "device")..."
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        DispatchQueue.main.async {
            self.connectedPeripheral = peripheral
            self.status = "Connected to \(peripheral.name ?? "device")"
        }
        peripheral.discoverServices(nil)
    }

    // MARK: - CBPeripheralDelegate methods
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        DispatchQueue.main.async {
            if let error = error {
                self.status = "Error discovering services: \(error.localizedDescription)"
                return
            }
            self.status = "Services discovered for \(peripheral.name ?? "device")"
        }

        for service in peripheral.services ?? [] {
            print("Service: \(service.uuid)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
}


