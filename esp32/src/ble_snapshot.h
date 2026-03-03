#pragma once
#include <cstdint>

// GATT UUIDs — must match iOS app
#define SERVICE_UUID    "19B10000-E8F2-537E-4F6C-D104768A1214"
#define CONTROL_UUID    "19B10001-E8F2-537E-4F6C-D104768A1214"
#define STATUS_UUID     "19B10002-E8F2-537E-4F6C-D104768A1214"
#define IMAGE_UUID      "19B10003-E8F2-537E-4F6C-D104768A1214"

// Control commands (written to CONTROL characteristic)
#define CMD_SNAP  0x01

// Chunk header flags
#define FLAG_FIRST  0x01
#define FLAG_LAST   0x02
#define FLAG_AUTO   0x04

enum class BleSnapState : uint8_t {
    IDLE,       // not connected, advertising
    READY,      // connected, waiting for command
    CAPTURING,  // camera capture in progress
    SENDING,    // chunked transfer in progress
    ERR         // error, auto-recovers to READY after 1s
};

// 16-byte chunk header prepended to every IMAGE notification
struct __attribute__((packed)) ChunkHeader {
    uint16_t frame_id;   // increments per snapshot
    uint32_t offset;     // byte offset into the JPEG
    uint16_t length;     // payload bytes following this header
    uint32_t total_size; // total JPEG size (repeated every chunk)
    uint8_t  flags;      // FLAG_FIRST, FLAG_LAST, or both
    uint8_t  reserved[3];
};
static_assert(sizeof(ChunkHeader) == 16, "ChunkHeader must be 16 bytes");

void bleSnapshotInit();
void bleSnapshotLoop();
void bleSnapshotTriggerAuto();
bool bleSnapshotBusy();
