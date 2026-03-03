#pragma once

// Detection probe interval (ms)
#define FACE_DETECT_INTERVAL_MS   500

// Consecutive detections required before triggering auto snapshot
#define FACE_CONFIRM_COUNT        3

// Cooldown between auto snapshots (ms)
#define FACE_DETECT_COOLDOWN_MS   15000

void faceDetectInit();
void faceDetectLoop();
void setFaceDetectEnabled(bool enabled);
