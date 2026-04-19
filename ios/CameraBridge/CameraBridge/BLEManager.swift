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
private let kAudioUUID    = CBUUID(string: "19B10004-E8F2-537E-4F6C-D104768A1214")

private let kCmdSnap: UInt8 = 0x01
private let kCmdRecord: UInt8 = 0x02
private let kFlagFirst: UInt8 = 0x01
private let kFlagLast:  UInt8 = 0x02
private let kFlagAuto:  UInt8 = 0x04

// PCM format sent by ESP32: 16-bit mono, 16 kHz, little-endian
let kAudioSampleRate: Double = 16000

// PicoClaw gateway URL — update to your actual endpoint
private let kPicoClawURL = "https://your-picoclaw-gateway.example.com/upload"

enum ConnectionState: String {
    case disconnected = "Disconnected"
    case scanning     = "Scanning..."
    case connecting   = "Connecting..."
    case ready        = "Ready"
    case capturing    = "Capturing..."
    case receiving    = "Receiving..."
    case error        = "Error"
}

enum UploadState: String {
    case idle       = ""
    case uploading  = "Uploading..."
    case success    = "Uploaded"
    case failed     = "Upload failed"
}

final class BLEManager: NSObject, ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var snapshotImage: UIImage?
    @Published var progress: Double = 0
    @Published var lastTransferInfo: String = ""
    @Published var uploadState: UploadState = .idle
    @Published var autoSnapshotCount: Int = 0

    // Latest text produced from ESP32 audio. Shown under the chunk status.
    @Published var lastTranscript: String = ""
    @Published var lastSummary: String = ""
    @Published var lastContextName: String = ""

    // True while the ESP32 mic is hot OR audio is still transferring over BLE.
    // Drives the "🎤 Listening…" indicator in ContentView.
    @Published var isRecordingContext: Bool = false

    let faceRecognition = FaceRecognitionManager()

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var controlChar: CBCharacteristic?

    // Reassembly buffer — image
    private var imageBuffer = Data()
    private var expectedSize: UInt32 = 0
    private var currentFrameId: UInt16 = 0
    private var chunkCount = 0
    private var isAutoSnapshot = false

    // Reassembly buffer — audio
    private var audioBuffer = Data()
    private var audioChunkCount = 0

    // Name of the person whose face was matched on the preceding snapshot.
    // Set externally (FaceRecognitionManager calls captureContext(for:)),
    // read when an audio buffer finishes so we can write to the right contact.
    private var pendingContextName: String?

    private let transcriber = AudioTranscriber()
    private let summarizer  = ContextSummarizer()
    private let contactWriter = ContactNoteWriter()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        faceRecognition.onMatchedName = { [weak self] name in
            self?.captureContext(for: name)
        }
    }

    func startScan() {
        guard central.state == .poweredOn else { return }
        userDisconnected = false
        connectionState = .scanning
        central.scanForPeripherals(withServices: [kServiceUUID])
    }

    private var userDisconnected = false

    func disconnect() {
        userDisconnected = true
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

    /// Called by FaceRecognitionManager after a contact is matched.
    /// Tells the ESP32 to record audio and, on arrival, attribute it to `name`.
    func captureContext(for name: String) {
        guard let p = peripheral, let ctrl = controlChar else {
            lastTransferInfo = "captureContext: no peripheral/control"
            return
        }
        pendingContextName = name
        lastTransferInfo = "Recording audio for \(name)…"
        isRecordingContext = true
        p.writeValue(Data([kCmdRecord]), for: ctrl, type: .withResponse)
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
        // Auto-reconnect only if user didn't manually disconnect
        if !userDisconnected {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.startScan()
            }
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == kServiceUUID }) else { return }
        peripheral.discoverCharacteristics(
            [kControlUUID, kStatusUUID, kImageUUID, kAudioUUID], for: svc)
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
            case kAudioUUID:
                peripheral.setNotifyValue(true, for: c)
                found.append("AUDIO")
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
        } else if characteristic.uuid == kAudioUUID {
            handleAudioChunk(data)
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

        guard data.count > 16 else {
            lastTransferInfo = "Chunk #\(chunkCount) too small: \(data.count)b"
            return
        }

        let flags: UInt8 = data[12]

        // First chunk: reset buffer and detect auto flag
        if flags & kFlagFirst != 0 {
            // Skip auto-snapshots while face recognition is still processing
            if (flags & kFlagAuto) != 0 && faceRecognition.isProcessing {
                return
            }
            imageBuffer = Data()
            chunkCount = 1
            isAutoSnapshot = (flags & kFlagAuto) != 0
            connectionState = .receiving
            // Clear prior person's transcript/summary card as a new snapshot begins
            lastTranscript = ""
            lastSummary = ""
            lastContextName = ""
        }

        // Always append everything after the 16-byte header
        let payload = data.subdata(in: 16 ..< data.count)
        imageBuffer.append(payload)

        let totalSize = UInt32(data[8]) | (UInt32(data[9]) << 8) | (UInt32(data[10]) << 16) | (UInt32(data[11]) << 24)
        if totalSize > 0 {
            progress = Double(imageBuffer.count) / Double(totalSize)
        }

        let prefix = isAutoSnapshot ? "[AUTO] " : ""
        lastTransferInfo = "\(prefix)Chunk #\(chunkCount): \(imageBuffer.count)/\(totalSize) bytes"

        // Last chunk: assemble image
        if flags & kFlagLast != 0 {
            if let img = UIImage(data: imageBuffer) {
                snapshotImage = img
                faceRecognition.processSnapshot(img)
                lastTransferInfo = String(format: "%@%.1f KB (%d chunks)",
                                          prefix,
                                          Double(imageBuffer.count) / 1024.0,
                                          chunkCount)

                if isAutoSnapshot {
                    autoSnapshotCount += 1
                    // TODO: PicoClaw upload disabled for now
                    // uploadToPicoClaw(imageData: imageBuffer)
                }
            } else {
                lastTransferInfo = "\(prefix)JPEG failed! \(imageBuffer.count)/\(totalSize)b, chunks=\(chunkCount)"
            }
            progress = 1.0
            connectionState = .ready
        }
    }

    // MARK: - Audio chunk reassembly

    private func handleAudioChunk(_ data: Data) {
        guard data.count > 16 else { return }
        let flags: UInt8 = data[12]

        if flags & kFlagFirst != 0 {
            audioBuffer = Data()
            audioChunkCount = 0
        }
        audioChunkCount += 1

        let payload = data.subdata(in: 16 ..< data.count)
        audioBuffer.append(payload)

        let totalSize = UInt32(data[8]) | (UInt32(data[9]) << 8)
                      | (UInt32(data[10]) << 16) | (UInt32(data[11]) << 24)
        lastTransferInfo = "Audio chunk #\(audioChunkCount): \(audioBuffer.count)/\(totalSize)b"

        if flags & kFlagLast != 0 {
            let pcm = audioBuffer
            let name = pendingContextName ?? "Unknown"
            pendingContextName = nil
            lastTransferInfo = "Audio done: \(pcm.count) bytes, transcribing…"
            lastContextName = name
            lastTranscript = ""
            lastSummary = ""
            Task { await self.processContextAudio(pcm: pcm, name: name) }
        }
    }

    private func processContextAudio(pcm: Data, name: String) async {
        guard let transcript = await transcriber.transcribe(pcm: pcm,
                                                            sampleRate: kAudioSampleRate) else {
            await MainActor.run {
                self.lastTransferInfo = "Transcribe failed"
                self.isRecordingContext = false
            }
            return
        }
        await MainActor.run {
            self.lastTransferInfo = "Transcribed \(transcript.split(whereSeparator: { $0.isWhitespace }).count) words, summarizing…"
            self.lastTranscript = transcript
        }
        print("[BLE] transcript(\(name)): \(transcript)")

        let summary = await summarizer.summarize(transcript: transcript, subject: name)
        print("[BLE] summary(\(name)): \(summary)")
        await MainActor.run {
            self.lastSummary = summary
        }

        let ok = contactWriter.appendNote(forFullName: name, text: summary)
        await MainActor.run {
            self.lastTransferInfo = ok
                ? "Saved context to \(name)"
                : "Could not save to \(name)"
            self.isRecordingContext = false
        }
    }

    // MARK: - PicoClaw Upload

    private func uploadToPicoClaw(imageData: Data) {
        guard let url = URL(string: kPicoClawURL) else {
            uploadState = .failed
            return
        }

        uploadState = .uploading

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("\(imageData.count)", forHTTPHeaderField: "Content-Length")

        URLSession.shared.uploadTask(with: request, from: imageData) { [weak self] _, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.uploadState = .failed
                    self?.lastTransferInfo = "[AUTO] Upload error: \(error.localizedDescription)"
                    return
                }

                if let httpResponse = response as? HTTPURLResponse,
                   (200...299).contains(httpResponse.statusCode) {
                    self?.uploadState = .success
                    // Reset upload state after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if self?.uploadState == .success {
                            self?.uploadState = .idle
                        }
                    }
                } else {
                    self?.uploadState = .failed
                }
            }
        }.resume()
    }
}
