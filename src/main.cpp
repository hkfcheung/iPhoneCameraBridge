#include <Arduino.h>
#include "esp_camera.h"
#include <WiFi.h>
#include <WebServer.h>
#include "ble_snapshot.h"
#include "face_detect.h"

// ===================
// WiFi Credentials
// ===================
const char *ssid = "The Command Center";
const char *password = "Raynor4027";

// const char *ssid = "Amigo 2.4";
// const char *password = "8186677982";

// ===================
// Camera Pin Map
// ===================
#ifdef BOARD_XIAO_ESP32S3
  // Seeed XIAO ESP32S3 Sense (OV2640)
  #define PWDN_GPIO_NUM    -1
  #define RESET_GPIO_NUM   -1
  #define XCLK_GPIO_NUM    10
  #define SIOD_GPIO_NUM    40
  #define SIOC_GPIO_NUM    39
  #define Y9_GPIO_NUM      48
  #define Y8_GPIO_NUM      11
  #define Y7_GPIO_NUM      12
  #define Y6_GPIO_NUM      14
  #define Y5_GPIO_NUM      16
  #define Y4_GPIO_NUM      18
  #define Y3_GPIO_NUM      17
  #define Y2_GPIO_NUM      15
  #define VSYNC_GPIO_NUM   38
  #define HREF_GPIO_NUM    47
  #define PCLK_GPIO_NUM    13
  #define BUTTON_PIN       -1  // no dedicated button
  #define LED_PIN          21  // onboard LED
#else
  // ESP-WROVER-KIT
  #define PWDN_GPIO_NUM    -1
  #define RESET_GPIO_NUM   -1
  #define XCLK_GPIO_NUM    21
  #define SIOD_GPIO_NUM    26
  #define SIOC_GPIO_NUM    27
  #define Y9_GPIO_NUM      35
  #define Y8_GPIO_NUM      34
  #define Y7_GPIO_NUM      39
  #define Y6_GPIO_NUM      36
  #define Y5_GPIO_NUM      19
  #define Y4_GPIO_NUM      18
  #define Y3_GPIO_NUM       5
  #define Y2_GPIO_NUM       4
  #define VSYNC_GPIO_NUM   25
  #define HREF_GPIO_NUM    23
  #define PCLK_GPIO_NUM    22
  #define BUTTON_PIN       33
  #define LED_PIN          2   // onboard green LED
#endif

volatile bool cameraOn = true;
bool buttonReleased = true;

void checkButton() {
#if BUTTON_PIN >= 0
  bool pressed = digitalRead(BUTTON_PIN) == LOW;

  if (pressed && buttonReleased) {
    buttonReleased = false;
    cameraOn = !cameraOn;
    digitalWrite(LED_PIN, cameraOn ? HIGH : LOW);
    Serial.printf("Camera %s\n", cameraOn ? "ON" : "OFF");
    // Wait for release
    while (digitalRead(BUTTON_PIN) == LOW) {
      delay(10);
    }
    delay(50);  // debounce after release
    buttonReleased = true;
  }
#endif
}

WebServer server(80);

void handleJpgStream() {
  if (!cameraOn) {
    server.send(503, "text/plain", "Camera is off");
    return;
  }

  WiFiClient client = server.client();
  String response = "HTTP/1.1 200 OK\r\n"
                    "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n\r\n";
  client.print(response);

  while (client.connected() && cameraOn) {
    checkButton();

    camera_fb_t *fb = esp_camera_fb_get();
    if (!fb) {
      Serial.println("Camera capture failed");
      break;
    }

    String header = "--frame\r\n"
                    "Content-Type: image/jpeg\r\n"
                    "Content-Length: " + String(fb->len) + "\r\n\r\n";
    client.print(header);
    client.write(fb->buf, fb->len);
    client.print("\r\n");

    esp_camera_fb_return(fb);
  }
}

void handleStatus() {
  server.send(200, "text/plain", cameraOn ? "on" : "off");
}

void handleJpgCapture() {
  camera_fb_t *fb = esp_camera_fb_get();
  if (!fb) {
    server.send(500, "text/plain", "Camera capture failed");
    return;
  }
  server.sendHeader("Content-Disposition", "inline; filename=capture.jpg");
  server.send_P(200, "image/jpeg", (const char *)fb->buf, fb->len);
  esp_camera_fb_return(fb);
}

void handleRoot() {
  String html = "<html><head><title>ESP-WROVER Camera</title>"
                "<style>body{font-family:sans-serif;text-align:center;background:#222;color:#fff;}"
                "img{max-width:100%;border:2px solid #444;border-radius:8px;margin-top:20px;}"
                "#status{font-size:1.5em;margin:20px;}</style></head>"
#ifdef BOARD_XIAO_ESP32S3
                "<body><h1>XIAO ESP32S3 Camera</h1>"
#else
                "<body><h1>ESP-WROVER-KIT Camera</h1>"
#endif
                "<div id=\"status\"></div>"
                "<img id=\"stream\" src=\"\">"
                "<script>"
                "function poll(){"
                "fetch('/status').then(r=>r.text()).then(s=>{"
                "var img=document.getElementById('stream');"
                "var st=document.getElementById('status');"
                "if(s==='on'){"
                "if(!img.src.includes('/stream'))img.src='/stream?'+Date.now();"
                "st.textContent='Camera ON';"
                "st.style.color='#4caf50';"
                "}else{"
                "img.src='';"
                "st.textContent='Camera OFF';"
                "st.style.color='#f44336';"
                "}"
                "});"
                "setTimeout(poll,1000);}"
                "poll();"
                "</script>"
                "</body></html>";
  server.send(200, "text/html", html);
}

void setup() {
  Serial.begin(115200);
#ifdef BOARD_XIAO_ESP32S3
  Serial.println("\n\nXIAO ESP32S3 Sense Camera Init");
#else
  Serial.println("\n\nESP-WROVER-KIT Camera Init");
#endif

  // Button & LED setup
#if BUTTON_PIN >= 0
  pinMode(BUTTON_PIN, INPUT_PULLUP);
#endif
  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, HIGH);  // LED on at startup (camera starts on)

  // Camera config
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer   = LEDC_TIMER_0;
  config.pin_d0       = Y2_GPIO_NUM;
  config.pin_d1       = Y3_GPIO_NUM;
  config.pin_d2       = Y4_GPIO_NUM;
  config.pin_d3       = Y5_GPIO_NUM;
  config.pin_d4       = Y6_GPIO_NUM;
  config.pin_d5       = Y7_GPIO_NUM;
  config.pin_d6       = Y8_GPIO_NUM;
  config.pin_d7       = Y9_GPIO_NUM;
  config.pin_xclk     = XCLK_GPIO_NUM;
  config.pin_pclk     = PCLK_GPIO_NUM;
  config.pin_vsync    = VSYNC_GPIO_NUM;
  config.pin_href     = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn     = PWDN_GPIO_NUM;
  config.pin_reset    = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;
  config.frame_size   = FRAMESIZE_VGA;   // 640x480
  config.jpeg_quality = 12;              // 0-63 (lower = better quality)
  config.fb_count     = 2;
  config.grab_mode    = CAMERA_GRAB_LATEST;

  // Init camera
  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("Camera init FAILED: 0x%x\n", err);
    Serial.println("Check camera ribbon cable connection!");
    return;
  }
  Serial.println("Camera init OK");

  // Connect to WiFi
  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid, password);
  Serial.printf("Connecting to WiFi '%s'", ssid);
  int attempts = 0;
  while (WiFi.status() != WL_CONNECTED && attempts < 40) {
    delay(500);
    Serial.printf(".");
    attempts++;
    if (attempts % 10 == 0) {
      Serial.printf(" (status=%d)\n", WiFi.status());
      // Retry connection
      WiFi.disconnect();
      delay(1000);
      WiFi.begin(ssid, password);
      Serial.print("Retrying");
    }
  }
  if (WiFi.status() != WL_CONNECTED) {
    Serial.printf("\nWiFi FAILED after %d attempts. Status: %d\n", attempts, WiFi.status());
    Serial.println("Continuing without WiFi (BLE still active)...");
  } else {
    Serial.println();
    Serial.print("Connected! Open browser to: http://");
    Serial.println(WiFi.localIP());
    Serial.printf("WiFi RSSI: %d dBm\n", WiFi.RSSI());
  }

  // Start web server
  server.on("/", handleRoot);
  server.on("/stream", handleJpgStream);
  server.on("/capture", handleJpgCapture);
  server.on("/status", handleStatus);
  server.begin();
  Serial.println("Web server started");

  // BLE snapshot service
  bleSnapshotInit();

  // Face detection (auto-snapshot)
  faceDetectInit();
}

static unsigned long lastRssiLog = 0;

void loop() {
  checkButton();
  server.handleClient();
  bleSnapshotLoop();
  faceDetectLoop();

  // Log WiFi signal strength every 30 seconds
  if (WiFi.status() == WL_CONNECTED && millis() - lastRssiLog > 30000) {
    lastRssiLog = millis();
    int rssi = WiFi.RSSI();
    const char *quality = rssi > -50 ? "Excellent" :
                          rssi > -60 ? "Good" :
                          rssi > -70 ? "Fair" :
                          rssi > -80 ? "Weak" : "Very Weak";
    Serial.printf("[WiFi] RSSI: %d dBm (%s)\n", rssi, quality);
  }
}
