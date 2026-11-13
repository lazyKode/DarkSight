// DarkSight Wi-Fi sensor for ESP32 (classic ESP32, e.g. "ESP32 Dev Module").
//
// What it does
//   1. Joins your home Wi-Fi.
//   2. Pings the router about 50 times a second. Every reply the router sends
//      back carries Wi-Fi channel state information (CSI): the amplitude and
//      phase of each of 64 OFDM subcarriers as received here. People moving
//      between or near the router and this board change how the signal
//      bounces around the room, and the CSI changes with them.
//   3. Streams each CSI measurement to the DarkSight app over UDP port 4211.
//
// Setup
//   - Arduino IDE: install "esp32 by Espressif Systems" (Boards Manager),
//     select board "ESP32 Dev Module", put your Wi-Fi name and password
//     below, upload. Open Serial Monitor at 115200 to see the board's IP.
//   - Put the board 3-6 m from the router, across the area you want to
//     watch (it can be in another room: the signal passes through walls).
//   - In the app (Android or iPhone, not the website) open the CSI tab and
//     enter the IP shown on the Serial Monitor.
//
// Packet sent to the app (little endian):
//   0  "DSCS"      4  u8 version (1)   5  i8 RSSI (dBm)
//   6  u8 n bytes  7  u8 reserved      8  u32 sequence   12 u32 millis()
//   16 int8[n]     CSI as (imaginary, real) pairs per subcarrier
//
// The app subscribes by sending "DSHELLO" to this board on port 4211 every
// couple of seconds. With no subscriber the board broadcasts instead (fine
// for Android; iPhones need the unicast subscription).

#include <WiFi.h>
#include <WiFiUdp.h>

#include "esp_wifi.h"
#include "lwip/inet.h"
#include "lwip/ip_addr.h"
#include "ping/ping_sock.h"

// ---- edit these ----
const char* WIFI_SSID = "YOUR_WIFI_NAME";
const char* WIFI_PASS = "YOUR_WIFI_PASSWORD";
// --------------------

static const uint16_t kPort = 4211;
static const uint32_t kPingIntervalMs = 20;  // ~50 Hz
static const int kMaxCsi = 128;              // 64 subcarriers x (imag, real)

struct CsiFrame {
  uint32_t ms;
  int8_t rssi;
  uint8_t len;
  int8_t buf[kMaxCsi];
};

static QueueHandle_t gQueue;
static uint8_t gRouterMac[6];
static WiFiUDP gUdp;
static IPAddress gSubscriber;
static uint16_t gSubscriberPort = 0;
static uint32_t gSubscriberSeen = 0;
static uint32_t gSeq = 0;
static uint32_t gSent = 0, gDropped = 0, gLastReport = 0;

// Runs in the Wi-Fi driver task: copy and hand off, nothing slow here.
static void onCsi(void* ctx, wifi_csi_info_t* info) {
  if (info == nullptr || info->buf == nullptr) return;
  if (memcmp(info->mac, gRouterMac, 6) != 0) return;  // only the router
  CsiFrame f;
  f.ms = millis();
  f.rssi = info->rx_ctrl.rssi;
  const int n = info->len < kMaxCsi ? info->len : kMaxCsi;
  f.len = (uint8_t)n;
  memcpy(f.buf, info->buf, n);
  if (xQueueSend(gQueue, &f, 0) != pdTRUE) gDropped++;
}

static void startCsi() {
  wifi_csi_config_t cfg = {};
  cfg.lltf_en = true;  // legacy long training field: 64 subcarriers
  cfg.htltf_en = false;
  cfg.stbc_htltf2_en = false;
  cfg.ltf_merge_en = true;
  cfg.channel_filter_en = false;
  cfg.manu_scale = false;
  cfg.shift = 0;
  ESP_ERROR_CHECK(esp_wifi_set_csi_config(&cfg));
  ESP_ERROR_CHECK(esp_wifi_set_csi_rx_cb(&onCsi, nullptr));
  ESP_ERROR_CHECK(esp_wifi_set_csi(true));
}

static void startPing() {
  const IPAddress gw = WiFi.gatewayIP();
  esp_ping_config_t cfg = ESP_PING_DEFAULT_CONFIG();
  IP_ADDR4(&cfg.target_addr, gw[0], gw[1], gw[2], gw[3]);
  cfg.count = ESP_PING_COUNT_INFINITE;
  cfg.interval_ms = kPingIntervalMs;
  cfg.timeout_ms = 1000;
  cfg.data_size = 1;
  esp_ping_callbacks_t cbs = {};
  esp_ping_handle_t ping;
  ESP_ERROR_CHECK(esp_ping_new_session(&cfg, &cbs, &ping));
  ESP_ERROR_CHECK(esp_ping_start(ping));
}

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println();
  Serial.println("DarkSight ESP32 Wi-Fi sensor");
  gQueue = xQueueCreate(64, sizeof(CsiFrame));

  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);  // power save would drop most CSI frames
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  Serial.print("Connecting to ");
  Serial.print(WIFI_SSID);
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println();
  memcpy(gRouterMac, WiFi.BSSID(), 6);
  Serial.print("Connected. Board IP: ");
  Serial.println(WiFi.localIP());
  Serial.print("Router: ");
  Serial.println(WiFi.gatewayIP());
  Serial.println("Enter the board IP in the DarkSight app (CSI tab).");

  gUdp.begin(kPort);
  startCsi();
  startPing();
}

void loop() {
  // Subscriptions from the app.
  int sz = gUdp.parsePacket();
  while (sz > 0) {
    char msg[16] = {0};
    gUdp.read(msg, sizeof(msg) - 1);
    if (strncmp(msg, "DSHELLO", 7) == 0) {
      gSubscriber = gUdp.remoteIP();
      gSubscriberPort = gUdp.remotePort();
      gSubscriberSeen = millis();
    }
    sz = gUdp.parsePacket();
  }
  const bool haveSub =
      gSubscriberPort != 0 && millis() - gSubscriberSeen < 10000;

  CsiFrame f;
  while (xQueueReceive(gQueue, &f, 0) == pdTRUE) {
    uint8_t pkt[16 + kMaxCsi];
    memcpy(pkt, "DSCS", 4);
    pkt[4] = 1;
    pkt[5] = (uint8_t)f.rssi;
    pkt[6] = f.len;
    pkt[7] = 0;
    const uint32_t seq = gSeq++;
    memcpy(pkt + 8, &seq, 4);  // ESP32 is little endian
    memcpy(pkt + 12, &f.ms, 4);
    memcpy(pkt + 16, f.buf, f.len);
    if (haveSub) {
      gUdp.beginPacket(gSubscriber, gSubscriberPort);
    } else {
      gUdp.beginPacket(IPAddress(255, 255, 255, 255), kPort);
    }
    gUdp.write(pkt, 16 + f.len);
    gUdp.endPacket();
    gSent++;
  }

  if (millis() - gLastReport > 5000) {
    gLastReport = millis();
    Serial.printf("CSI sent %lu (%.0f/s), dropped %lu, app %s\n",
                  (unsigned long)gSent, gSent / 5.0, (unsigned long)gDropped,
                  haveSub ? gSubscriber.toString().c_str() : "not connected");
    gSent = 0;
  }
  delay(1);
}
