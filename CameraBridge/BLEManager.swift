import SwiftUI
import UIKit
import Foundation
import CoreBluetooth
import Combine

// Must match ESP32 firmware UUIDs
private let kServiceUUID  = CBUUID(string: "19B10000-E8F2-537E-4F6C-D104768A1214")
private let kControlUUID  = CBUUID(string: "19B10001-E8F2-537E-4F6C-D104768A1214")
private let kStatusUUID   = CBUUID(string: "19B10002-E8F2-537E-4F6C-D104768A1214")
private let kImageUUID    = CBUUID(string: "19B10003-E8F2-537E-4F6C-D104768A1214")

private let kCmdSnap: UInt8 = 0x01
private let kFlagFirst: UInt8 = 0x01
private let kFlagLast:  UInt8 = 0x02

enum ConnectionState: String {
    case disconnected = "Disconnected"
    case scanning     = "Scanning..."
    case connecting   = "Connecting..."
    case ready        = "Ready"
    case capturing    = "Capturing..."
    case receiving    = "Receiving..."
    case error        = "Error"
}

final class BLEManager: NSObject, ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var snapshotImage: UIImage?
    @Published var progress: Double = 0
    @Published var lastTransferInfo: String = ""

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var controlChar: CBCharacteristic?

    // Reassembly buffer
    private var imageBuffer = Data()
    private var expectedSize: UInt32 = 0
    private var currentFrameId: UInt16 = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard central.state == .poweredOn else { return }
        connectionState = .scanning
        central.scanForPeripherals(withServices: [kServiceUUID])
    }

    func disconnect() {
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        connectionState = .disconnected
    }

    func requestSnapshot() {
        guard let p = peripheral else {
            lastTransferInfo = "Error: no peripheral"
            return
        }
        guard let ctrl = controlChar else {
            lastTransferInfo = "Error: CONTROL characteristic not found"
            return
        }
        connectionState = .capturing
        progress = 0
        lastTransferInfo = "Reading CONTROL to trigger snap..."
        p.readValue(for: ctrl)
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, connectionState == .disconnected {
            startScan()
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        connectionState = .connecting
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([kServiceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        self.peripheral = nil
        controlChar = nil
        connectionState = .disconnected
        // Auto-reconnect after 1 second
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.startScan()
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == kServiceUUID }) else { return }
        peripheral.discoverCharacteristics(
            [kControlUUID, kStatusUUID, kImageUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let chars = service.characteristics else {
            lastTransferInfo = "Error: no characteristics found"
            return
        }
        var found: [String] = []
        for c in chars {
            switch c.uuid {
            case kControlUUID:
                controlChar = c
                found.append("CONTROL")
            case kStatusUUID:
                peripheral.setNotifyValue(true, for: c)
                found.append("STATUS")
            case kImageUUID:
                peripheral.setNotifyValue(true, for: c)
                found.append("IMAGE")
            default:
                found.append("unknown:\(c.uuid)")
            }
        }
        lastTransferInfo = "Found: \(found.joined(separator: ", "))"
        connectionState = .ready
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value else { return }

        if characteristic.uuid == kStatusUUID {
            handleStatusUpdate(data)
        } else if characteristic.uuid == kImageUUID {
            handleImageChunk(data)
        }
    }

    private func handleStatusUpdate(_ data: Data) {
        guard let raw = data.first else { return }
        // Map ESP BleSnapState enum values
        switch raw {
        case 0: connectionState = .disconnected
        case 1: connectionState = .ready
        case 2: connectionState = .capturing
        case 3: connectionState = .receiving
        case 4: connectionState = .error
        default: break
        }
    }

    private func handleImageChunk(_ data: Data) {
        guard data.count >= 16 else { return }

        // Parse 16-byte ChunkHeader (little-endian, matching ESP32)
        let frameId:   UInt16 = data.withUnsafeBytes { $0.load(fromByteOffset: 0,  as: UInt16.self) }
        let offset:    UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 2,  as: UInt32.self) }
        let length:    UInt16 = data.withUnsafeBytes { $0.load(fromByteOffset: 6,  as: UInt16.self) }
        let totalSize: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 8,  as: UInt32.self) }
        let flags:     UInt8  = data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt8.self) }

        let payload = data.subdata(in: 16 ..< 16 + Int(length))

        // First chunk of a new frame — reset buffer
        if flags & kFlagFirst != 0 {
            imageBuffer = Data()
            expectedSize = totalSize
            currentFrameId = frameId
            connectionState = .receiving
        }

        // Append payload at correct offset
        if imageBuffer.count == Int(offset) {
            imageBuffer.append(payload)
        }

        // Update progress
        if expectedSize > 0 {
            progress = Double(imageBuffer.count) / Double(expectedSize)
        }

        // Last chunk — assemble image
        if flags & kFlagLast != 0 {
            if let img = UIImage(data: imageBuffer) {
                snapshotImage = img
                lastTransferInfo = String(format: "Frame %d: %.1f KB",
                                          currentFrameId,
                                          Double(imageBuffer.count) / 1024.0)
            }
            progress = 1.0
            connectionState = .ready
        }
    }
}
