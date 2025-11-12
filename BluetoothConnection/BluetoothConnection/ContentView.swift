//
//  ContentView.swift
//  BluetoothConnection
//
//  Created by Alena Tucker on 11/5/25.
//

import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @StateObject private var bluetooth = BluetoothManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bluetooth Scanner")
                .font(.largeTitle)
                .padding(.bottom, 10)

            Text(bluetooth.status)
                .font(.headline)
                .padding(.bottom, 5)

            List(bluetooth.peripherals, id: \.identifier) { peripheral in
                HStack {
                    VStack(alignment: .leading) {
                        Text(peripheral.name ?? "Unknown Device")
                            .fontWeight(.medium)
                        Text(peripheral.identifier.uuidString)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    if bluetooth.connectedPeripheral?.identifier == peripheral.identifier {
                        Text("Connected")
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    bluetooth.connect(to: peripheral)
                }
            }
            .frame(minHeight: 300)

            Spacer()
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
    }
}
