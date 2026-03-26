#include "ble_snapshot.h"
#include <Arduino.h>
#include "esp_camera.h"
#include <NimBLEDevice.h>

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
static BleSnapState     state       = BleSnapState::IDLE;
static uint16_t         frameId     = 0;
static volatile bool    snapRequest     = false;
static volatile bool    autoSnapRequest = false;
static unsigned long    errTime     = 0;
static uint16_t         peerMtu     = 0;

static NimBLEServer         *pServer  = nullptr;
static NimBLECharacteristic *pControl = nullptr;
static NimBLECharacteristic *pStatus  = nullptr;
static NimBLECharacteristic *pImage   = nullptr;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static void setState(BleSnapState s) {
    state = s;
    uint8_t v = static_cast<uint8_t>(s);
    pStatus->setValue(&v, 1);
    pStatus->notify();
    Serial.printf("[BLE] state -> %d\n", v);
}

static void startAdvertising() {
    NimBLEAdvertising *pAdv = NimBLEDevice::getAdvertising();
    pAdv->addServiceUUID(SERVICE_UUID);
    pAdv->setName("CameraBridge");
    pAdv->start();
    Serial.println("BLE CameraBridge advertising started");
}

// ---------------------------------------------------------------------------
// Send JPEG in chunks over IMAGE characteristic
// ---------------------------------------------------------------------------
static void sendSnapshot(bool isAuto = false) {
    camera_fb_t *fb = esp_camera_fb_get();
    if (!fb) {
        Serial.println("[BLE] capture failed");
        state = BleSnapState::ERR;
        errTime = millis();
        return;
    }

    state = BleSnapState::SENDING;
    frameId++;

    // Use conservative 180-byte payload (fits in any MTU)
    const uint16_t chunkPayload = 180;

    uint32_t offset = 0;
    uint32_t total  = fb->len;
    uint8_t buf[200];  // 16 header + 180 payload

    while (offset < total) {
        if (pServer->getConnectedCount() == 0) {
            Serial.println("[BLE] client gone, aborting send");
            break;
        }

        uint16_t len = (total - offset > chunkPayload)
                       ? chunkPayload
                       : (uint16_t)(total - offset);

        ChunkHeader hdr = {};
        hdr.frame_id   = frameId;
        hdr.offset     = offset;
        hdr.length     = len;
        hdr.total_size = total;
        hdr.flags      = isAuto ? FLAG_AUTO : 0;
        if (offset == 0)          hdr.flags |= FLAG_FIRST;
        if (offset + len >= total) hdr.flags |= FLAG_LAST;

        memcpy(buf, &hdr, sizeof(ChunkHeader));
        memcpy(buf + sizeof(ChunkHeader), fb->buf + offset, len);

        pImage->setValue(buf, sizeof(ChunkHeader) + len);
        pImage->notify();

        offset += len;
        delay(50);  // 50ms between chunks — reliable delivery
    }

    esp_camera_fb_return(fb);
    Serial.printf("[BLE] sent frame %u  (%u bytes, chunk=%u)\n",
                  frameId, total, chunkPayload);
    state = BleSnapState::READY;
}

// ---------------------------------------------------------------------------
// NimBLE Callbacks — NimBLE-Arduino 2.x API
// ---------------------------------------------------------------------------
class ServerCB : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer *srv, NimBLEConnInfo &connInfo) override {
        peerMtu = 0;
        Serial.println("[BLE] client connected");
        state = BleSnapState::READY;
    }

    void onDisconnect(NimBLEServer *srv, NimBLEConnInfo &connInfo, int reason) override {
        Serial.printf("[BLE] client disconnected (reason=%d)\n", reason);
        state = BleSnapState::IDLE;
        snapRequest = false;
        startAdvertising();
    }

    void onMTUChange(uint16_t mtu, NimBLEConnInfo &connInfo) override {
        peerMtu = mtu;
        Serial.printf("[BLE] MTU negotiated: %u\n", mtu);
    }
};

// Use onRead as snap trigger — iOS reads CONTROL to request a snapshot
class ControlCB : public NimBLECharacteristicCallbacks {
    void onRead(NimBLECharacteristic *pChr, NimBLEConnInfo &connInfo) override {
        Serial.println("[BLE] CONTROL read -> SNAP triggered");
        snapRequest = true;
    }
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
void bleSnapshotInit() {
    Serial.println("[BLE] init starting...");
    NimBLEDevice::init("CameraBridge");
    Serial.println("[BLE] NimBLE initialized");
    NimBLEDevice::setMTU(517);

    pServer = NimBLEDevice::createServer();
    pServer->setCallbacks(new ServerCB());
    Serial.println("[BLE] server created");

    NimBLEService *pSvc = pServer->createService(SERVICE_UUID);

    pControl = pSvc->createCharacteristic(
        CONTROL_UUID,
        NIMBLE_PROPERTY::READ
    );
    pControl->setCallbacks(new ControlCB());

    pStatus = pSvc->createCharacteristic(
        STATUS_UUID,
        NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
    );
    uint8_t initState = static_cast<uint8_t>(BleSnapState::IDLE);
    pStatus->setValue(&initState, 1);

    pImage = pSvc->createCharacteristic(
        IMAGE_UUID,
        NIMBLE_PROPERTY::NOTIFY
    );
    Serial.println("[BLE] characteristics created");

    pSvc->start();
    Serial.println("[BLE] service started");
    startAdvertising();
}

void bleSnapshotLoop() {
    // Manual snapshot has priority
    if (state == BleSnapState::READY && snapRequest) {
        snapRequest = false;
        autoSnapRequest = false;  // discard pending auto if manual requested
        Serial.println("[BLE] processing manual SNAP");
        sendSnapshot(false);
    }
    // Auto snapshot
    else if (state == BleSnapState::READY && autoSnapRequest) {
        autoSnapRequest = false;
        Serial.println("[BLE] processing auto SNAP");
        sendSnapshot(true);
    }

    if (state == BleSnapState::ERR && millis() - errTime > 1000) {
        setState(BleSnapState::READY);
    }
}

void bleSnapshotTriggerAuto() {
    autoSnapRequest = true;
}

bool bleSnapshotBusy() {
    return state == BleSnapState::CAPTURING || state == BleSnapState::SENDING;
}
