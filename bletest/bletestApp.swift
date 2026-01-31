import SwiftUI
import CoreBluetooth
import Combine   // ← Add this import

#if os(iOS)
import UIKit
#endif

class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate {
    let serviceUUID = CBUUID(string: "54EF7F90-A3EA-423A-8D6D-56FF28DE238A")
    
    var centralManager: CBCentralManager!
    var peripheralManager: CBPeripheralManager!
    
    @Published var receivedMessages: [String] = []
    @Published var currentMessage: String = "" {
        didSet {
            updateAdvertising()
        }
    }
    
    private var lastReceived: [UUID: String] = [:]
    
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
    
    private func updateAdvertising() {
        // Only advertise if Bluetooth is powered on
        
        receivedMessages.append("updateAdvertising(), state: \(peripheralManager.state)")
        guard peripheralManager.state == .poweredOn else { return }
        
        peripheralManager.stopAdvertising()
        
        guard let data = currentMessage.data(using: .utf8), !data.isEmpty else { return }
        
        let advertisementData: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataLocalNameKey: currentMessage
        ]
        
        receivedMessages.append("startAdvertising(), adv: \(currentMessage)")
        peripheralManager.startAdvertising(advertisementData)
    }
    
    // MARK: - CBPeripheralManagerDelegate
    
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        receivedMessages.append("peripheralManagerDidUpdateState(), peripheral.state: \(peripheral.state)")
        if peripheral.state == .poweredOn {
            updateAdvertising() // Ensure we advertise the current message once powered on
        }
    }
    
    // MARK: - CBCentralManagerDelegate
    
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
        print("=== DISCOVERED PERIPHERAL ===")
        print("Name: \(senderName)")
        print("ID (short): \(shortID)...")
        print("Full ID: \(peripheral.identifier.uuidString)")
        print("RSSI: \(RSSI) dBm")
        print("Full advertisementData: \(advertisementData)")
        print("==============================")
        
        // Optional: still show basic activity in UI even if no message
        let advertisedLocalName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "(none)"
        receivedMessages.append("Discovered \(senderName) (\(shortID)...) – RSSI \(RSSI) dBm, advData: \(advertisedLocalName)")
        
        guard let serviceDataDict = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
              let data = serviceDataDict[serviceUUID],
              let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            print("No valid message data found in this advertisement.")
            return
        }
        
        // We have a valid message → log it EVERY time (no deduping, so you see all repeats)
        let time = Date().formatted(date: .omitted, time: .shortened)
        let entry = "\(time) | \(message) | from \(senderName) (\(shortID)...) | RSSI \(RSSI) dBm"
        
        receivedMessages.append(entry)
        print("RECEIVED MESSAGE: \(entry)")
    }
}

@main
struct BLEBroadcastApp: App {
    @StateObject private var bleManager = BLEManager()
    
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
    
    // Computed property: validates in real-time as the user types
    private var isValidMessage: Bool {
        let trimmed = inputText.trimmingCharacters(in: .whitespaces)
        let count = trimmed.count
        return count >= 6 && count <= 12
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("BLE Broadcast Messenger")
                .font(.title)
                .padding(.top)
            
            HStack {
                TextField("6-12 char message", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                
                
                Button("Broadcast") {
                    // Runs only on tap
                    let trimmed = inputText.trimmingCharacters(in: .whitespaces)
                    let count = trimmed.count
                    
                    if count >= 6 && count <= 12 {
                        bleManager.currentMessage = trimmed
                    }
                    // Optional: clear field after sending
                    // inputText = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValidMessage)  // Disabled if length is wrong
            }
            .padding(.horizontal)
            
            if !bleManager.currentMessage.isEmpty {
                Text("Will broadcast: \"\(bleManager.currentMessage)\"")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Received messages log (newest at bottom)
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
                .onChange(of: bleManager.receivedMessages.count) { newCount in
                    if newCount > 0 {
                        withAnimation {
                            proxy.scrollTo(newCount - 1, anchor: .bottom)
                        }
                    }
                }
            }
            
            Spacer()
        }
        .onAppear {
            // Default to a relatively unique 12-character string (new UUID prefix each launch)
            if inputText.isEmpty {
                let uniquePrefix = String(UUID().uuidString.prefix(12)).uppercased()
                inputText = uniquePrefix
                bleManager.currentMessage = uniquePrefix
            }
        }
    }
}
