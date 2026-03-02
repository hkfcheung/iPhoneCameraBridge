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
    private var chunkCount = 0

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
        lastTransferInfo = "STATUS: \(raw)"
        // Don't override connectionState during image transfer
        if raw == 1 && connectionState != .receiving {
            connectionState = .ready
        } else if raw == 2 {
            connectionState = .capturing
        } else if raw == 3 {
            connectionState = .receiving
        } else if raw == 4 {
            connectionState = .error
        }
    }

    private func handleImageChunk(_ data: Data) {
        chunkCount += 1
        lastTransferInfo = "Chunk #\(chunkCount), \(data.count) bytes"

        guard data.count >= 16 else {
            lastTransferInfo = "Chunk too small: \(data.count) bytes"
            return
        }

        // Read little-endian fields manually (packed struct has unaligned UInt32)
        let frameId:   UInt16 = UInt16(data[0]) | (UInt16(data[1]) << 8)
        let offset:    UInt32 = UInt32(data[2]) | (UInt32(data[3]) << 8) | (UInt32(data[4]) << 16) | (UInt32(data[5]) << 24)
        let length:    UInt16 = UInt16(data[6]) | (UInt16(data[7]) << 8)
        let totalSize: UInt32 = UInt32(data[8]) | (UInt32(data[9]) << 8) | (UInt32(data[10]) << 16) | (UInt32(data[11]) << 24)
        let flags:     UInt8  = data[12]

        lastTransferInfo = "Chunk #\(chunkCount) off=\(offset) len=\(length) total=\(totalSize) flags=\(flags)"

        let payloadEnd = 16 + Int(length)
        guard data.count >= payloadEnd else {
            lastTransferInfo = "Chunk data too short: have \(data.count), need \(payloadEnd)"
            return
        }
        let payload = data.subdata(in: 16 ..< payloadEnd)

        if flags & kFlagFirst != 0 {
            imageBuffer = Data()
            expectedSize = totalSize
            currentFrameId = frameId
            chunkCount = 1
            connectionState = .receiving
        }

        if imageBuffer.count == Int(offset) {
            imageBuffer.append(payload)
        } else {
            lastTransferInfo = "Gap! buf=\(imageBuffer.count) off=\(offset)"
        }

        if expectedSize > 0 {
            progress = Double(imageBuffer.count) / Double(expectedSize)
        }

        if flags & kFlagLast != 0 {
            lastTransferInfo = "Complete! \(imageBuffer.count)/\(totalSize) bytes"
            if let img = UIImage(data: imageBuffer) {
                snapshotImage = img
                lastTransferInfo = String(format: "Frame %d: %.1f KB (%d chunks)",
                                          currentFrameId,
                                          Double(imageBuffer.count) / 1024.0,
                                          chunkCount)
            } else {
                lastTransferInfo = "JPEG decode failed! \(imageBuffer.count) bytes"
            }
            progress = 1.0
            connectionState = .ready
        }
    }
}
