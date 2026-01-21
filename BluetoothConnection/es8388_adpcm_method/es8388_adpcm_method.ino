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


#include "ES8388.h"
#include "driver/i2s.h"

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

BLEServer* pServer;
BLECharacteristic* pAudioChar;

#define SERVICE_UUID        "12345678-0000-1000-8000-00805F9B34FB"
#define AUDIO_CHAR_UUID     "12345678-0001-1000-8000-00805F9B34FB"

IMAState imaState = {0, 0};

void setup_ble() {
    BLEDevice::init("ESP32");
    pServer = BLEDevice::createServer();
    BLEService* pService = pServer->createService(SERVICE_UUID);

    pAudioChar = pService->createCharacteristic(
        AUDIO_CHAR_UUID,
        BLECharacteristic::PROPERTY_NOTIFY
    );

    pAudioChar->addDescriptor(new BLE2902());
    pService->start();

    BLEAdvertising* pAdvertising = BLEDevice::getAdvertising();
    pAdvertising->addServiceUUID(SERVICE_UUID);
    pAdvertising->start();
}


// SDA --> GPIO21
// SCL --> GPIO22
ES8388 es8388(21, 22, 400000);

uint32_t timeLapsed, ledTick;
uint8_t volume = 12;

i2s_config_t i2s_config = {
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX ) // | I2S_MODE_TX), // set modes as needed
    .sample_rate = 44100,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
    .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,
    .communication_format = I2S_COMM_FORMAT_I2S, // check syntax, may need to update to for new library
    .intr_alloc_flags = 0,
    .dma_buf_count = 8, // direct memory access buffer
    .dma_buf_len = 256,
    .use_apll = false, // improves audio quality at cost of power consumption, but will not help improve BT transmitted audio data
    .tx_desc_auto_clear = true,
    .fixed_mclk = 0};

// sck = bit clock (GPIO17)
// ws = word select = LRCLK = LRC (GPIO4)
// data_out = ESP32 TX pin (NOT USED, but still must be assigned to value)
// data_in = ESP32 RX pin (USED TO RECEIVE ES8388 AUDIO) ES8388 DOUT --> GPIO2

i2s_pin_config_t pin_config = {
  .bck_io_num = 17, .ws_io_num = 4, .data_out_num = -1, .data_in_num = 2};

size_t readsize = 0;

void setup() {
  Serial.begin(115200);
  Serial.println("Read Reg ES8388 : ");
  if (!es8388.init()) Serial.println("Init Fail");
  es8388.inputSelect(IN2);
  es8388.setInputGain(8);
  es8388.mixerSourceSelect(MIXADC, MIXADC);
  uint8_t *reg;
  for (uint8_t i = 0; i < 53; i++) {
    reg = es8388.readAllReg();
    Serial.printf("Reg-%02d = 0x%02x\r\n", i, reg[i]);
  }

  // i2s setup for esp32
  // MLCK --> GPIO3
  PIN_FUNC_SELECT(PERIPHS_IO_MUX_GPIO3_U, FUNC_GPIO3_CLK_OUT1); // may need to change if "FUNC_GPIO3_CLK_OUT1" does not work with ESP32 model
  // may need to change to "FUNC_GPIO3_CLK_OUT2" if code fails to compile 
  WRITE_PERI_REG(PIN_CTRL, 0xFFF0);

  // installs i2s driver on esp32 
  i2s_driver_install(I2S_NUM_0, &i2s_config, 0, NULL);
  i2s_set_pin(I2S_NUM_0, &pin_config);

  setup_ble();


}

void loop() {
  // read 128 samples (64*2 samples)
  int16_t stereoBuf[256];   // 256 samples = 128 frames
  int16_t monoBuf[128];     // 128 mono samples 
  uint8_t adpcmBuffer[64];    // 4:1 compression


  size_t bytes_read = 0;
  i2s_read(I2S_NUM_0, stereoBuf, sizeof(stereoBuf), &bytes_read, portMAX_DELAY);

  int frames = bytes_read / (2 * sizeof(int16_t)); // 2 samples per frame

  for (int i = 0; i < frames; i++) {
    int16_t L = stereoBuf[2*i];
    int16_t R = stereoBuf[2*i + 1];
    monoBuf[i] = (L + R) / 2;
  }
  ima_encode_block(monoBuf, frames, adpcmBuffer, imaState);
  static uint8_t seq = 0;

uint8_t packet[68]; // 4-byte header + 64 bytes ADPCM
packet[0] = seq++;
packet[1] = 0; // flags
packet[2] = frames & 0xFF;
packet[3] = (frames >> 8) & 0xFF;

memcpy(&packet[4], adpcmBuffer, sizeof(adpcmBuffer));

pAudioChar->setValue(packet, sizeof(packet));
pAudioChar->notify();
  
  }
