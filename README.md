# iPhoneCameraBridge

ESP32-S3 camera with BLE snapshot transfer to an iOS app, with optional face recognition.

## Architecture

- **ESP32 firmware** (`src/`): WiFi video streaming + BLE snapshot service + motion detection
- **iOS app** (`ios/CameraBridge/`): BLE client that receives JPEG snapshots and runs face recognition

### How it works

1. ESP32 streams live video over WiFi (open `http://<device-ip>` in a browser)
2. ESP32 also runs a BLE GATT service called "CameraBridge"
3. iOS app connects via BLE, requests snapshots, and reassembles chunked JPEGs
4. Motion detection on the ESP32 can auto-trigger snapshots
5. (Optional) Face recognition matches snapshot faces against your iPhone contacts

## Hardware

- Seeed Studio XIAO ESP32S3 Sense (with OV2640 camera)
- **Important**: Connect the external WiFi antenna to the U.FL connector — the onboard antenna is too weak for most networks

## ESP32 Setup

### Prerequisites
- [PlatformIO](https://platformio.org/) (VSCode extension or CLI)

### Build & Upload
```bash
# Build
pio run -e xiao_esp32s3

# Upload (close serial monitor first)
pio run -e xiao_esp32s3 -t upload

# Monitor serial output
pio device monitor -e xiao_esp32s3 -b 115200
```

### WiFi Configuration
Edit `src/main.cpp` and set your 2.4GHz WiFi credentials:
```cpp
const char *ssid = "Your Network Name";
const char *password = "your_password";
```

## iOS App Setup

### Prerequisites
- Mac with Xcode
- Apple Developer account (free works for personal device testing)
- iPhone connected via USB

### Install the App

1. Clone the repo on your Mac
2. Create a new Xcode project: **File > New > Project > iOS > App** (SwiftUI, Swift)
   - Product Name: `CameraBridge`
   - Save inside `ios/CameraBridge/`
3. Delete the auto-generated `App.swift` and `ContentView.swift`
4. Drag these files from `ios/CameraBridge/CameraBridge/` into the Xcode project navigator:
   - `CameraBridgeApp.swift`
   - `ContentView.swift`
   - `BLEManager.swift`
   - `FaceRecognitionManager.swift`
   - Check "Copy items if needed" and select the CameraBridge target
5. In **Signing & Capabilities**, select your Apple Developer team
6. In the **Info** tab, add these privacy keys:
   - `Privacy - Bluetooth Always Usage Description`
   - `Privacy - Contacts Usage Description`
7. **Cmd+R** to build and run on your iPhone

The app will auto-scan for the "CameraBridge" BLE device and connect.

---

## Enabling Face Recognition

Face recognition is currently disabled. Follow these steps to enable it:

### Step 1: Convert the CoreML Model

On your Mac, in the `ios/CameraBridge/` directory:

```bash
# Create a clean Python environment (coremltools needs Python 3.11)
conda create -n coreml python=3.11 -y
conda activate coreml
pip install coremltools onnx onnx2torch torch numpy insightface onnxruntime

# Download the face embedding model
python download_mobilefacenet.py

# Convert ONNX to CoreML
python convert_model.py
```

This produces `MobileFaceNet.mlpackage`.

### Step 2: Add the Model to Xcode

1. Drag `MobileFaceNet.mlpackage` into the Xcode project navigator
2. Make sure the **CameraBridge** target is checked
3. Xcode will auto-generate a Swift class called `MobileFaceNet`

### Step 3: Uncomment the Model Loading Code

In `FaceRecognitionManager.swift`, find the `loadModel()` function and uncomment the model loading code:

```swift
private func loadModel() {
    // Uncomment this block:
    do {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let mlModel = try MobileFaceNet(configuration: config).model
        model = try VNCoreMLModel(for: mlModel)
        print("[FaceRec] CoreML model loaded")
    } catch {
        print("[FaceRec] ERROR loading CoreML model: \(error.localizedDescription)")
    }
}
```

### Step 4: Rebuild and Run

**Cmd+Shift+K** to clean, then **Cmd+R** to build and run.

### How Face Recognition Works

1. On app launch, it requests access to your **iPhone Contacts** (via CNContactStore)
2. It scans all contacts that have a **photo** (thumbnail image)
3. For each contact photo, it detects the face, crops it, and generates a 512-dimensional embedding using MobileFaceNet
4. When a BLE snapshot arrives, it detects faces in the image
5. Each detected face is compared against enrolled contact embeddings using **cosine similarity**
6. If similarity exceeds the threshold (0.55), the contact's name is displayed on the bounding box

### Important Notes on Contacts

- It reads from `CNContactStore`, which includes **all contacts on your iPhone** — this includes contacts synced from iCloud, Google, Exchange, or any other account configured in Settings > Contacts > Accounts
- Only contacts with a **photo** are enrolled for face recognition
- The photo used is the `thumbnailImageData` — the small version stored locally on the device
- For best results, make sure your contacts have clear, front-facing face photos
- No contact data leaves the device — all processing is done locally with CoreML and Vision framework
