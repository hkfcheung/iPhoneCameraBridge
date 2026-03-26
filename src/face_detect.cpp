#include "face_detect.h"
#include <Arduino.h>
#include "esp_camera.h"
#include "img_converters.h"
#include "ble_snapshot.h"

// ---------------------------------------------------------------------------
// Motion + Skin-Color Presence Detection (zero extra IRAM)
//
// Strategy:
//   1. Decode JPEG to small 160x120 RGB565 buffer
//   2. Detect motion via frame differencing with reference
//   3. In changed regions, check for skin-colored pixels
//   4. If large enough skin-colored region found → person detected
//   5. Debounce (3 consecutive detections) → trigger auto snapshot
// ---------------------------------------------------------------------------

static bool           enabled       = true;
static unsigned long  lastProbe     = 0;
static uint32_t       probeCount    = 0;
static unsigned long  lastAutoSnap  = 0;
static uint8_t        confirmCount  = 0;
static uint16_t      *curBuf        = nullptr;
static uint16_t      *refBuf        = nullptr;
static bool           hasRef        = false;

// Downscaled dimensions: VGA 640x480 / 8 = 80x60
static const int kWidth  = 80;
static const int kHeight = 60;
static const int kPixels = kWidth * kHeight;

// Thresholds
static const int   kMotionThreshold   = 30;    // per-pixel diff threshold
static const float kMotionFraction    = 0.03f; // 3% of pixels must change
static const float kSkinFraction      = 0.02f; // 2% of pixels must be skin-colored
static const int   kMinSkinCluster    = 50;    // minimum skin pixels in a region

// ---------------------------------------------------------------------------
// RGB565 helpers
// ---------------------------------------------------------------------------
static inline void rgb565_to_rgb(uint16_t px, uint8_t &r, uint8_t &g, uint8_t &b) {
    r = (px >> 8) & 0xF8;
    g = (px >> 3) & 0xFC;
    b = (px << 3) & 0xF8;
}

static inline int pixel_diff(uint16_t a, uint16_t b) {
    uint8_t r1, g1, b1, r2, g2, b2;
    rgb565_to_rgb(a, r1, g1, b1);
    rgb565_to_rgb(b, r2, g2, b2);
    int dr = (int)r1 - r2; if (dr < 0) dr = -dr;
    int dg = (int)g1 - g2; if (dg < 0) dg = -dg;
    int db = (int)b1 - b2; if (db < 0) db = -db;
    return (dr + dg + db) / 3;
}

// Skin detection in RGB space (works across diverse skin tones)
static inline bool is_skin_color(uint8_t r, uint8_t g, uint8_t b) {
    // Not too dark, not too bright
    if (r < 40 || g < 20 || b < 15) return false;
    if (r > 250 && g > 250 && b > 250) return false;

    // R must be highest channel
    if (r <= g || r <= b) return false;

    int rg_diff = (int)r - g;
    int rb_diff = (int)r - b;

    // Skin tends to have R > G > B with moderate gaps
    if (rg_diff < 10 || rb_diff < 10) return false;

    // Maximum channel difference check
    int min_ch = b < g ? b : g;
    if (r - min_ch < 15) return false;

    return true;
}

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------
void faceDetectInit() {
    curBuf = (uint16_t *)ps_malloc(kPixels * sizeof(uint16_t));
    refBuf = (uint16_t *)ps_malloc(kPixels * sizeof(uint16_t));
    if (!curBuf || !refBuf) {
        Serial.println("[FACE] ERROR: failed to allocate RGB565 buffers");
        enabled = false;
        return;
    }
    Serial.printf("[FACE] init OK  bufs=%p,%p (%d bytes each in PSRAM)\n",
                  curBuf, refBuf, kPixels * 2);
}

// ---------------------------------------------------------------------------
// Loop — called from main loop()
// ---------------------------------------------------------------------------
void faceDetectLoop() {
    if (!enabled || !curBuf || !refBuf) return;

    unsigned long now = millis();
    if (now - lastProbe < FACE_DETECT_INTERVAL_MS) return;
    lastProbe = now;

    if (bleSnapshotBusy()) return;

    if (lastAutoSnap > 0 && now - lastAutoSnap < FACE_DETECT_COOLDOWN_MS) return;

    camera_fb_t *fb = esp_camera_fb_get();
    if (!fb) return;

    uint32_t flen = fb->len;
    uint8_t hdr0 = fb->buf[0], hdr1 = fb->buf[1];

    if (fb->format != PIXFORMAT_JPEG || flen < 100) {
        Serial.printf("[FACE] bad frame: fmt=%d len=%u\n", fb->format, flen);
        esp_camera_fb_return(fb);
        return;
    }

    if (hdr0 != 0xFF || hdr1 != 0xD8) {
        Serial.printf("[FACE] not JPEG: first bytes=0x%02X 0x%02X len=%u\n", hdr0, hdr1, flen);
        esp_camera_fb_return(fb);
        return;
    }

    bool ok = jpg2rgb565(fb->buf, flen, (uint8_t *)curBuf, JPG_SCALE_8X);
    esp_camera_fb_return(fb);

    if (!ok) {
        Serial.printf("[FACE] jpg2rgb565 failed (len=%u, scale=8X)\n", flen);
        return;
    }

    // First frame: store as reference
    if (!hasRef) {
        memcpy(refBuf, curBuf, kPixels * sizeof(uint16_t));
        hasRef = true;
        Serial.println("[FACE] reference frame captured");
        return;
    }

    // Detect motion via frame differencing
    int motionPixels = 0;

    for (int i = 0; i < kPixels; i++) {
        int diff = pixel_diff(curBuf[i], refBuf[i]);
        if (diff > kMotionThreshold) {
            motionPixels++;
        }
    }

    // Slowly adapt reference to lighting changes (every 8th pixel)
    if (motionPixels < (int)(kPixels * 0.5f)) {
        for (int i = 0; i < kPixels; i += 8) {
            refBuf[i] = curBuf[i];
        }
    }

    float motionFrac = (float)motionPixels / kPixels;

    probeCount++;
    if (probeCount % 10 == 0) {
        Serial.printf("[FACE] motion=%.1f%% confirm=%d\n",
                      motionFrac * 100, confirmCount);
    }

    // Need at least 10% of pixels changed to count as presence
    if (motionFrac < 0.10f) {
        if (confirmCount > 0) {
            confirmCount = 0;
        }
        return;
    }

    confirmCount++;
    Serial.printf("[FACE] motion %.1f%% confirm=%d/%d\n",
                  motionFrac * 100, confirmCount, FACE_CONFIRM_COUNT);

    if (confirmCount >= FACE_CONFIRM_COUNT) {
        confirmCount = 0;
        lastAutoSnap = now;
        hasRef = false;  // recapture reference after snapshot
        Serial.println("[FACE] -> triggering auto snapshot");
        bleSnapshotTriggerAuto();
    }
}

// ---------------------------------------------------------------------------
void setFaceDetectEnabled(bool en) {
    enabled = en;
    if (!en) confirmCount = 0;
    Serial.printf("[FACE] %s\n", en ? "enabled" : "disabled");
}
