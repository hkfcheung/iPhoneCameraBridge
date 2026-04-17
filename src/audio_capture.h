#pragma once
#include <cstdint>
#include <cstddef>

// Audio capture for XIAO ESP32-S3 Sense onboard PDM mic (MSM261D3526H1CPM)
// PDM CLK = GPIO 42, PDM DATA = GPIO 41

#define AUDIO_SAMPLE_RATE    16000          // Hz, matches SFSpeechRecognizer
#define AUDIO_SECONDS        4               // clip length
#define AUDIO_SAMPLES        (AUDIO_SAMPLE_RATE * AUDIO_SECONDS)
#define AUDIO_BYTES          (AUDIO_SAMPLES * 2)  // 16-bit mono

// Init PDM I2S. Returns true on success. Idempotent.
bool audioCaptureInit();

// Record AUDIO_SECONDS of 16-bit mono PCM at 16 kHz into `outBuf`.
// `outBuf` must be at least AUDIO_BYTES in size (128 KB).
// Returns bytes actually written, 0 on failure.
size_t audioCaptureRecord(uint8_t *outBuf, size_t bufSize);
