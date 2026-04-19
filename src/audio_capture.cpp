#include "audio_capture.h"
#include <Arduino.h>

#ifdef BOARD_XIAO_ESP32S3

#include <driver/i2s.h>

#define PDM_CLK_GPIO   42
#define PDM_DATA_GPIO  41
#define I2S_PORT       I2S_NUM_0

static bool initialized = false;

bool audioCaptureInit() {
    if (initialized) return true;

    i2s_config_t cfg = {};
    cfg.mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX | I2S_MODE_PDM);
    cfg.sample_rate = AUDIO_SAMPLE_RATE;
    cfg.bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT;
    cfg.channel_format = I2S_CHANNEL_FMT_ONLY_LEFT;
    cfg.communication_format = I2S_COMM_FORMAT_STAND_I2S;
    cfg.intr_alloc_flags = ESP_INTR_FLAG_LEVEL1;
    cfg.dma_buf_count = 8;
    cfg.dma_buf_len = 1024;
    cfg.use_apll = false;
    cfg.tx_desc_auto_clear = false;
    cfg.fixed_mclk = 0;

    esp_err_t err = i2s_driver_install(I2S_PORT, &cfg, 0, nullptr);
    if (err != ESP_OK) {
        Serial.printf("[AUDIO] i2s_driver_install failed: 0x%x\n", err);
        return false;
    }

    i2s_pin_config_t pins = {};
    pins.bck_io_num   = I2S_PIN_NO_CHANGE;
    pins.ws_io_num    = PDM_CLK_GPIO;
    pins.data_out_num = I2S_PIN_NO_CHANGE;
    pins.data_in_num  = PDM_DATA_GPIO;

    err = i2s_set_pin(I2S_PORT, &pins);
    if (err != ESP_OK) {
        Serial.printf("[AUDIO] i2s_set_pin failed: 0x%x\n", err);
        i2s_driver_uninstall(I2S_PORT);
        return false;
    }

    i2s_set_clk(I2S_PORT, AUDIO_SAMPLE_RATE,
                I2S_BITS_PER_SAMPLE_16BIT, I2S_CHANNEL_MONO);

    // Explicitly set PDM decimation. Without this, the legacy driver on
    // ESP32-S3 leaves the PDM RX decimator at a default that produces
    // a sample rate 2-3x lower than AUDIO_SAMPLE_RATE → playback sounds
    // sped up when interpreted at 16 kHz. I2S_PDM_DSR_16S = 64× oversample,
    // standard for 1 MHz-class PDM MEMS mics (MSM261D3526H1CPM).
    i2s_set_pdm_rx_down_sample(I2S_PORT, I2S_PDM_DSR_16S);

    initialized = true;
    Serial.printf("[AUDIO] PDM mic init OK  (%d Hz, mono, 16-bit, dsr=16s)\n",
                  AUDIO_SAMPLE_RATE);
    return true;
}

size_t audioCaptureRecord(uint8_t *outBuf, size_t bufSize) {
    if (!initialized || !outBuf) return 0;
    if (bufSize < AUDIO_BYTES) {
        Serial.printf("[AUDIO] buf too small: %u < %u\n",
                      (unsigned)bufSize, (unsigned)AUDIO_BYTES);
        return 0;
    }

    // Prime: PDM decimation filter produces garbage for the first ~100 ms.
    uint8_t prime[2048];
    size_t primeRemaining = AUDIO_SAMPLE_RATE / 10 * 2;  // 100 ms
    while (primeRemaining > 0) {
        size_t got = 0;
        size_t toRead = primeRemaining > sizeof(prime) ? sizeof(prime) : primeRemaining;
        i2s_read(I2S_PORT, prime, toRead, &got, pdMS_TO_TICKS(100));
        if (got == 0) break;
        primeRemaining -= got;
    }

    size_t total = 0;
    unsigned long t0 = millis();
    while (total < AUDIO_BYTES) {
        size_t got = 0;
        size_t toRead = AUDIO_BYTES - total;
        esp_err_t err = i2s_read(I2S_PORT, outBuf + total, toRead, &got, pdMS_TO_TICKS(1000));
        if (err != ESP_OK) {
            Serial.printf("[AUDIO] read err 0x%x at %u bytes\n", err, (unsigned)total);
            break;
        }
        total += got;
    }
    unsigned long ms = millis() - t0;

    // DC-block + gain: PDM output has heavy DC offset and is very low-level.
    int16_t *samples = reinterpret_cast<int16_t *>(outBuf);
    size_t sampleCount = total / 2;
    int32_t dcSum = 0;
    for (size_t i = 0; i < sampleCount; i++) dcSum += samples[i];
    int16_t dc = sampleCount ? (int16_t)(dcSum / (int32_t)sampleCount) : 0;

    const int gain = 8;  // +18 dB
    for (size_t i = 0; i < sampleCount; i++) {
        int32_t v = (int32_t)(samples[i] - dc) * gain;
        if (v >  32767) v =  32767;
        if (v < -32768) v = -32768;
        samples[i] = (int16_t)v;
    }

    Serial.printf("[AUDIO] captured %u bytes in %lu ms  (dc=%d)\n",
                  (unsigned)total, ms, dc);
    return total;
}

#else  // non-XIAO boards have no PDM mic on this project

bool audioCaptureInit() {
    Serial.println("[AUDIO] no mic on this board — stub");
    return false;
}

size_t audioCaptureRecord(uint8_t *, size_t) { return 0; }

#endif
