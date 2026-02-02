#include "ES8388.h"
#include "driver/i2s.h"

#include <Arduino.h>
#include <WiFi.h>

const char* ssid = "SSID"; // unique for each network
const char* password = "PASS";  // same as above
const char* udpAddress = "192.168.1.100"; // Receiver IP
const int udpPort = 12345;
const int localPort = 12345;

WiFiUDP udp; // set up as UDP (User Datagram Protocol)

// set up packet sequence number for packet drop 

struct AudioPacket {
  uint16_t seq;
  int16_t samples[160];
};

// SDA --> GPIO47
// SCL --> GPIO21
ES8388 es8388(47, 21, 400000);

uint32_t timeLapsed, ledTick;
uint8_t volume = 12;

i2s_config_t i2s_config = {
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX ), // | I2S_MODE_TX), // set modes as needed
    .sample_rate = 8000, // lower sample rate needed for udp
    .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
    .channel_format = I2S_CHANNEL_FMT_ONLY_RIGHT,
    .communication_format = I2S_COMM_FORMAT_I2S, // check syntax, may need to update to for new library
    .intr_alloc_flags = 0,
    .dma_buf_count = 8, // direct memory access buffer
    .dma_buf_len = 160,
    .use_apll = false, // improves audio quality at cost of power consumption, but will not help improve BT transmitted audio data
    .tx_desc_auto_clear = true,
    .fixed_mclk = 0};

// sck = bit clock [BCLK] (GPIO38)
// ws = word select = LRCLK = LRC (GPIO37)
// data_out = ESP32 TX pin (NOT USED, but still must be assigned to value)
// data_in = ESP32 RX pin (USED TO RECEIVE ES8388 AUDIO) ES8388 DOUT --> GPIO35

i2s_pin_config_t pin_config = {
  .mck_io_num = 0, .bck_io_num = 38, .ws_io_num = 37, .data_out_num = -1, .data_in_num = 35}; // may need to change .data_out if it does not work as -1

// set up handlers for WiFi
void ConnectedToAP_Handler(WiFiEvent_t wifi_event, WiFiEventInfo_t wifi_info) {
  Serial.println("Connected To The WiFi Network");
}

// provides local IP 
void GotIP_Handler(WiFiEvent_t wifi_event, WiFiEventInfo_t wifi_info) {
  Serial.print("Local ESP32 IP: ");
  Serial.println(WiFi.localIP());
}

void WiFi_Disconnected_Handler(WiFiEvent_t wifi_event, WiFiEventInfo_t wifi_info) {
  Serial.println("Disconnected From WiFi Network");
  // Attempt Re-Connection
  WiFi.begin(ssid, password);
}


void setup() {
  Serial.begin(115200);
  Serial.println("Read Reg ES8388 : ");
  if (!es8388.init()) Serial.println("Init Fail"); // may need to swap SDA or SCL pins if fails
  es8388.inputSelect(IN2); // swap to IN1 for AUX
  es8388.setInputGain(8);
  es8388.mixerSourceSelect(MIXADC, MIXADC);
  uint8_t *reg;
  // dump regs once
  for (uint8_t i = 0; i < 53; i++) {
    reg = es8388.readAllReg();
    Serial.printf("Reg-%02d = 0x%02x\r\n", i, reg[i]);
  }

  // i2s setup for esp32
  // MLCK --> GPIO2
  // PIN_FUNC_SELECT(PERIPHS_IO_MUX_GPIO2_U, FUNC_GPIO2_CLK_OUT2); // may need to change if "FUNC_GPIO3_CLK_OUT1" does not work with ESP32 model
  // may need to change to "FUNC_GPIO3_CLK_OUT2" if code fails to compile 
  WRITE_PERI_REG(PIN_CTRL, 0xFFF0);

  // installs i2s driver on esp32 
  i2s_driver_install(I2S_NUM_0, &i2s_config, 0, NULL);
  i2s_set_pin(I2S_NUM_0, &pin_config);

  // set up WiFi
  WiFi.mode(WIFI_STA); // sets as WiFi station (can act as WiFi access point)
  // Wifi.onEvent() asks for handler function and ID or name of event that will be triggered
  WiFi.onEvent(ConnectedToAP_Handler, ARDUINO_EVENT_WIFI_STA_CONNECTED);
  WiFi.onEvent(GotIP_Handler, ARDUINO_EVENT_WIFI_STA_GOT_IP);
  WiFi.onEvent(WiFi_Disconnected_Handler, ARDUINO_EVENT_WIFI_STA_DISCONNECTED);
  WiFi.begin(ssid, password);
  Serial.println("\nConnecting to WiFi Network");
  udp.begin(12345);
  }

void loop() {

  // ideal audio frame of 20ms at 8kHz sampling = 160 samples
  static uint16_t seq = 0;
  AudioPacket pkt;

  size_t bytesRead = 0;

  esp_err_t res = i2s_read(I2S_NUM_0, pkt.samples, sizeof(pkt.samples), &bytesRead, 20 / portTICK_PERIOD_MS);
  

if (res == ESP_OK && bytesRead == sizeof(pkt.samples)) {
    pkt.seq = seq++;          // little-endian is fine for iOS

    for (int i = 0; i < 160; i++) {
      Serial.println(pkt.samples[i]);
    }
    
    if (WiFi.status() == WL_CONNECTED) {
      udp.beginPacket(udpAddress, udpPort);
      udp.write((uint8_t*)&pkt, sizeof(pkt));
      udp.endPacket();
    }
  }
  // skips cycle to maintain timing
  
  }






