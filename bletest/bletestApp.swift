import SwiftUI
import CoreBluetooth
import Combine

#if os(iOS)
import UIKit
#endif

#if os(macOS)

import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
#endif

#if os(visionOS)
#endif

struct DiscoveredDevice: Identifiable {
    let uuid: UUID
    var id: UUID { uuid }
    var peripheralName: String
    var advertisedLocalName: String
    var rssi: NSNumber
    
    var shortID: String {
        String(uuid.uuidString.prefix(8)).uppercased() + "..."
    }
    
    var rssiValue: Int {
        rssi.intValue
    }
}

class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate {
    let serviceUUID = CBUUID(string: "54EF7F90-A3EA-423A-8D6D-56FF28DE238A")
    
    var centralManager: CBCentralManager!
    var peripheralManager: CBPeripheralManager!
    
    @Published var receivedMessages: [String] = []
    @Published var currentMessage: String = "" {
        didSet {
            Task { await updateAdvertising() }
        }
    }
    
    //Update this when we update startAdvertising, just in case someone slips in
    //a new message while updating the old one
    var activeMessage: String = ""
    
    @Published var discoveredDevices: [DiscoveredDevice] = []  // This is now the source of truth for ordering + data

    private var deviceIndices: [UUID: Int] = [:]  // Fast O(1) lookup: UUID → array index
    
    private var deviceName: String {
#if os(iOS)
        return UIDevice.current.name
#elseif os(macOS)
        return Host.current().localizedName ?? "Mac Device"
#else
        return "Unknown Device"
#endif
    }
    
    override init() {
        super.init()
        
        receivedMessages.append("+init()")
        centralManager = CBCentralManager(delegate: self, queue: .main)
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
        receivedMessages.append("-init()")
    }
    
    // MARK: - CBPeripheralManagerDelegate (send)
    
    private func updateAdvertising() async {
        receivedMessages.append("updateAdvertising(), state: \(peripheralManager.state)")
        guard peripheralManager.state == .poweredOn else { return }
        
        peripheralManager.stopAdvertising()

//        do {
            //did this to try and see if the iPad would work, but it didn't help
            //try await Task.sleep(for: .seconds(0.1))
            if (activeMessage != currentMessage)
            {
                receivedMessages.append("for reals now updateAdvertising(), currentMessage: \(currentMessage)")
                activeMessage = currentMessage
                
                receivedMessages.append("startAdvertising(), adv: \(currentMessage)")
                peripheralManager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
                                                       CBAdvertisementDataLocalNameKey: currentMessage])
            }
//        } catch {
//            //Task throws CancellationError if it exits early
//            return
//        }
    }
    
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        receivedMessages.append("peripheralManagerDidUpdateState(), peripheral.state: \(peripheral.state)")
        if peripheral.state == .poweredOn {
            Task { await updateAdvertising() }
        }
    }
    
    // MARK: - CBCentralManagerDelegate (receive)
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        receivedMessages.append("centralManagerDidUpdateState(), central.state: \(central.state)")
        if central.state == .poweredOn {
            receivedMessages.append("starting scanForPeripherals()")
            central.scanForPeripherals(
                withServices: [serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // Print raw discovery info and ALL advertisement values to console (for full debugging)
        let senderName = peripheral.name ?? "Unknown Device"
        let shortID = String(peripheral.identifier.uuidString.prefix(8))
        
        let uuid = peripheral.identifier
        let advertisedLocalName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "(none)"
        
        var gotMessage = false
        
        if let index = deviceIndices[uuid] {
            if (senderName != discoveredDevices[index].peripheralName
            || advertisedLocalName != discoveredDevices[index].advertisedLocalName)
            {
                gotMessage = true;
            }
            
            discoveredDevices[index].peripheralName = senderName
            discoveredDevices[index].advertisedLocalName = advertisedLocalName
            discoveredDevices[index].rssi = RSSI
            
        } else {
            // Brand-new device → append to bottom
            let newDevice = DiscoveredDevice(
                uuid: uuid,
                peripheralName: senderName,
                advertisedLocalName: advertisedLocalName,
                rssi: RSSI
            )
            discoveredDevices.append(newDevice)
            deviceIndices[uuid] = discoveredDevices.count - 1
            gotMessage = true
        }
        
        if (gotMessage)
        {
            print("=== DISCOVERED PERIPHERAL ===")
            print("Name: \(senderName)")
            print("ID (short): \(shortID)...")
            print("Full ID: \(peripheral.identifier.uuidString)")
            print("RSSI: \(RSSI) dBm")
            print("Full advertisementData: \(advertisementData)")
            print("==============================")
            
            var message: String?
            if advertisedLocalName != "(none)" {
                message = advertisedLocalName.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            if let message = message, !message.isEmpty {
                let time = Date().formatted(date: .omitted, time: .shortened)
                let entry = "\(time) | \(message) | from \(senderName) (\(shortID)...) | RSSI \(RSSI) dBm"
                receivedMessages.append(entry)
                print("RECEIVED MESSAGE: \(entry)")
            }
        }
    }
}

@main
struct BLEBroadcastApp: App {
    @StateObject private var bleManager = BLEManager()
    
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bleManager)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var bleManager: BLEManager
    
    @State private var inputText: String = ""
    
    private var trimmedInput: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValidMessage: Bool {
        !trimmedInput.isEmpty && trimmedInput.utf8.count <= 8
    }

    private var needsUpdate: Bool {
        trimmedInput != bleManager.currentMessage
    }
    
    private var buttonTitle: String {
        if !isValidMessage {
            return "Invalid Message"
        }
        if bleManager.currentMessage.isEmpty {
            return "Broadcast"
        }
        if needsUpdate {
            return "Update Message"
        }
        return "Broadcasting..."
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("MeetOOMF BLE Broadcast Messenger")
                .font(.title)
                .padding(.top)
            
            Text("Broadcast a message of up to 8 characters to all nearby devices:")
                .font(.caption)
                .foregroundColor(.secondary)
        
            HStack {
                TextField("Message to broadcast", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                
                Button(buttonTitle) {
                    // Updates the message we're sending out, bleManager will automatically pick the new message up
                    // and call startAdvertising with it
                    bleManager.currentMessage = trimmedInput
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValidMessage || !needsUpdate)
            }
            .padding(.horizontal)
            
            if !bleManager.currentMessage.isEmpty {
                Text("Broadcast Message: \"\(bleManager.currentMessage)\"")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            HStack(spacing: 0) {
                // Left panel: Received messages
                VStack(alignment: .leading) {
                    Text("Received Messages")
                        .font(.headline)
                        .padding()
                    
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(bleManager.receivedMessages.enumerated()), id: \.offset) { offset, message in
                                    Text(message)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color.secondary.opacity(0.15))
                                        .cornerRadius(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(offset)
                                }
                            }
                            .padding()
                        }
                        .onChange(of: bleManager.receivedMessages.count, initial: true, {oldCount, newCount in
                            if newCount > 0 {
                                withAnimation {
                                    proxy.scrollTo(newCount - 1, anchor: .bottom)
                                }
                            }
                        })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                Divider()
                
                // Right panel: Discovered devices
                VStack(alignment: .leading) {
                    Text("Discovered Devices")
                        .font(.headline)
                        .padding()
                    
                    List {
                        if bleManager.discoveredDevices.isEmpty {
                            Text("No devices discovered yet")
                                .foregroundColor(.secondary)
                                .italic()
                        } else {
                            ForEach(bleManager.discoveredDevices) { device in
                                DisclosureGroup {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Device Name: \(device.peripheralName)")
                                        Text("UUID: \(device.uuid.uuidString)")
                                        Text("RSSI: \(device.rssiValue) dBm")
                                        Text("Advertised Local Name: \(device.advertisedLocalName)")
                                    }
                                    .padding(.leading, 8)
                                } label: {
                                    HStack {
                                        if device.advertisedLocalName == "(none)" || device.advertisedLocalName.isEmpty {
                                            Text("Unknown Device (\(device.shortID))")
                                        } else {
                                            Text(device.advertisedLocalName)
                                        }
                                        Spacer()
                                        Text("\(device.rssiValue) dBm")
                                            .monospacedDigit()
                                            .foregroundColor(device.rssiValue > -70 ? .green : (device.rssiValue > -90 ? .orange : .red))
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .padding()
        .onAppear {
            if inputText.isEmpty {
                let uniquePrefix = String(UUID().uuidString.prefix(4)).uppercased()
                inputText = uniquePrefix
                bleManager.currentMessage = uniquePrefix
            }
        }
    }
}
