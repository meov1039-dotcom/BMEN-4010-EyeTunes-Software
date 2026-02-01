#include <Arduino.h>
#include <Wire.h>
#include "ES8388.h"
#include <driver/i2s.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

struct IMAState {
    int16_t predictor;
    int8_t index;
};

// Step size table and index table are standard IMA ADPCM
// encodes audio into IMA ADPCM
static const int stepTable[89] = {
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
    19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
    130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
    337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
    876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
    2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
    5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
};

static const int indexTable[16] = {
    -1, -1, -1, -1, 2, 4, 6, 8,
    -1, -1, -1, -1, 2, 4, 6, 8
};

void ima_encode_block(const int16_t* pcm, int numSamples, uint8_t* out, IMAState& state) {
    int predictor = state.predictor;
    int index = state.index;
    int step = stepTable[index];

    uint8_t outByte = 0;
    bool highNibble = true;

    for (int i = 0; i < numSamples; i++) {
        int diff = pcm[i] - predictor;
        int sign = (diff < 0) ? 8 : 0;
        if (diff < 0) diff = -diff;

        int delta = 0;
        int tempStep = step;

        if (diff >= tempStep) { delta |= 4; diff -= tempStep; }
        tempStep >>= 1;
        if (diff >= tempStep) { delta |= 2; diff -= tempStep; }
        tempStep >>= 1;
        if (diff >= tempStep) { delta |= 1; }

        delta |= sign;

        int diffq = step >> 3;
        if (delta & 4) diffq += step;
        if (delta & 2) diffq += step >> 1;
        if (delta & 1) diffq += step >> 2;
        if (sign) predictor -= diffq;
        else predictor += diffq;

        if (predictor > 32767) predictor = 32767;
        else if (predictor < -32768) predictor = -32768;

        index += indexTable[delta & 0x0F];
        if (index < 0) index = 0;
        if (index > 88) index = 88;
        step = stepTable[index];

        if (highNibble) {
            outByte = (delta & 0x0F) << 4;
            highNibble = false;
        } else {
            outByte |= (delta & 0x0F);
            *out++ = outByte;
            highNibble = true;
        }
    }

    if (!highNibble) {
        *out++ = outByte;
    }

    state.predictor = predictor;
    state.index = index;
}

// I2C Pins
#define I2C_SDA 47 
#define I2C_SCL 21

// I2S Pins
#define I2S_BCK   38   
#define I2S_WS    37  
#define I2S_DIN   36  
#define I2S_DOUT  35  // <--- Added this
#define I2S_MCLK  0   

ES8388 es8388(I2C_SDA, I2C_SCL,400000); // Note: Most libraries handle the pins in the .begin() or .init()

IMAState imaState = {0, 0};

BLEServer* pServer = NULL;
BLECharacteristic* pCharacteristic = NULL;
bool deviceConnected = false;
bool oldDeviceConnected = false;
// const int inputPin = 18;
const int bitsPerSequence = 8;
// See the following for generating UUIDs:
// https://www.uuidgenerator.net/

#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"


class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
      deviceConnected = true;
    };

    void onDisconnect(BLEServer* pServer) {
      deviceConnected = false;
    }
};

void setup_i2s() {
  i2s_config_t i2s_config = {
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX | I2S_MODE_TX), 
    .sample_rate = 44100,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
    .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,
    .communication_format = I2S_COMM_FORMAT_I2S, // Adjusted for standard naming
    .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
    .dma_buf_count = 8,
    .dma_buf_len = 64,
    .use_apll = true 
  };

  i2s_pin_config_t pin_config = {
    .bck_io_num = I2S_BCK,
    .ws_io_num = I2S_WS,
    .data_out_num = I2S_DOUT,
    .data_in_num = I2S_DIN
  };
  
  // For ESP32-S3 or newer chips, mck_io_num is part of pin_config
  pin_config.mck_io_num = I2S_MCLK;

  i2s_driver_install(I2S_NUM_0, &i2s_config, 0, NULL);
  i2s_set_pin(I2S_NUM_0, &pin_config);
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  Serial.println("Initializing I2C...");
  Wire.begin(I2C_SDA, I2C_SCL); // Explicitly start Wire before ES8388

  Serial.println("Initializing ES8388...");
  if (!es8388.init()) { // Check your specific library's init method
    Serial.println("ES8388 Init Failed!");
    while (1);
  }

  es8388.inputSelect(IN1);     
  es8388.setInputGain(0); 
  
  setup_i2s();

  // Create the BLE Device
  BLEDevice::init("ESP32");

  // Create the BLE Server
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  // Create the BLE Service
  BLEService *pService = pServer->createService(SERVICE_UUID);

  // Create a BLE Characteristic
  pCharacteristic = pService->createCharacteristic(
                      CHARACTERISTIC_UUID,
                      BLECharacteristic::PROPERTY_WRITE |
                      BLECharacteristic::PROPERTY_NOTIFY
                    );

  // https://www.bluetooth.com/specifications/gatt/viewer?attributeXmlFile=org.bluetooth.descriptor.gatt.client_characteristic_configuration.xml
  // Create a BLE Descriptor
  pCharacteristic->addDescriptor(new BLE2902());

  // Start the service
  pService->start();

  // Start advertising
  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(false);
  pAdvertising->setMinPreferred(0x0);  // set value to 0x00 to not advertise this parameter
  BLEDevice::startAdvertising();
  Serial.println("Waiting a client connection to notify...");
}

void loop() {
  // read 128 samples (64*2 samples)
  int16_t stereoBuf[256];   // 256 samples = 128 frames
  int16_t monoBuf[128];     // 128 mono samples 
  uint8_t adpcmBuffer[64];    // 4:1 compression
  size_t bytes_read = 0;

  esp_err_t result = i2s_read(I2S_NUM_0, stereoBuf, sizeof(stereoBuf), &bytes_read, portMAX_DELAY);

  if (result == ESP_OK && bytes_read > 0) {
    int frames = bytes_read / (2 * sizeof(int16_t)); // 2 samples per frame

  for (int i = 0; i < frames; i++) {
    int16_t rightChannel = stereoBuf[2*i + 1];

    if (i==0) Serial.println(rightChannel);

    monoBuf[i] = rightChannel;
  }

  if (deviceConnected) {
  ima_encode_block(monoBuf, frames, adpcmBuffer, imaState);
  static uint8_t seq = 0;

  uint8_t packet[68]; // 4-byte header + 64 bytes ADPCM
  packet[0] = seq++;
  packet[1] = 0; // flags
  packet[2] = frames & 0xFF;
  packet[3] = (frames >> 8) & 0xFF;

  memcpy(&packet[4], adpcmBuffer, sizeof(adpcmBuffer));

  pCharacteristic->setValue(packet, sizeof(packet));
  pCharacteristic->notify();
  }
  
  if (!deviceConnected && oldDeviceConnected) {
    delay(500);
    pServer->startAdvertising(); // restart advertising
    Serial.println("Start Advertising");
    oldDeviceConnected = deviceConnected;
  }

  // connecting
  if (deviceConnected && !oldDeviceConnected) {
        // do stuff here on connecting
        oldDeviceConnected = deviceConnected;
  }

  }
}