struct IMAState {
    int16_t predictor;
    int8_t index;
};

// Step size table and index table are standard IMA ADPCM
// encodes audio into IMA ADPCM
// maps the bit of 0-88 to the PCM bits (0-32k)
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

// define IMA ADPCM function
// variable inputs in order: PCM input samples, number of samples, ADPCM output, predictor and index carried across
// KEY: PCM as 16-bit integer value becomes 8-bit integer value
void ima_encode_block(const int16_t* pcm, int numSamples, uint8_t* out, IMAState& state) {
    // start with previous value and check step size
    int predictor = state.predictor;
    int index = state.index;
    int step = stepTable[index];

    // each ADPCM code word becomes 4 bits (i.e. 2 codes = one byte) as bits 3,2,1,0
    uint8_t outByte = 0;
    bool highNibble = true;

    // iterate through each PCM sample
    for (int i = 0; i < numSamples; i++) {
        // compute the difference between the PCM and the current predictor state
        int diff = pcm[i] - predictor;
        int sign = (diff < 0) ? 8 : 0;
        if (diff < 0) diff = -diff;

        int delta = 0; // represents the sign bit
        int tempStep = step;

        // Ref: | is bitwise OR is operator where: if eithr input bits are 1, then the output is 1

        // compare the difference from above to the temporary step to determine the magnitude bits
        if (diff >= tempStep) { delta |= 4; diff -= tempStep; } // check if the difference is larger than full step --> true: set bit 2 to HIGH
        tempStep >>= 1; // ref: bitshift right causes bits left of the operand to be shifted x number of positions to the right  
        if (diff >= tempStep) { delta |= 2; diff -= tempStep; } // check if difference is larger than step/2 --> true: set bit 1 to HIGH
        tempStep >>= 1;
        if (diff >= tempStep) { delta |= 1; } // check if difference is larger than step/4 --> true: set bit 0 to HIGH

        delta |= sign; // adds sign bit 

        int diffq = step >> 3;
        if (delta & 4) diffq += step; // ref: & operator sets output to 0 unless both input bits are 1
        if (delta & 2) diffq += step >> 1;
        if (delta & 1) diffq += step >> 2;
        if (sign) predictor -= diffq;
        else predictor += diffq;

        // restrict range
        if (predictor > 32767) predictor = 32767; // sets maximum bound for predictor value
        else if (predictor < -32768) predictor = -32768; // sets minimum 

        index += indexTable[delta & 0x0F]; // hexadecimal values = 00001111 bit pattern
        // set index range
        if (index < 0) index = 0;
        if (index > 88) index = 88;
        step = stepTable[index];

        if (highNibble) {
            outByte = (delta & 0x0F) << 4; // ensure that the low 4 bits are used then assigned to the upper half of the byte (shift 4 times)
            highNibble = false;
        } else {
            // write the low nibble ( lower 4 bits) ** remember bits are labeled in descending order
            outByte |= (delta & 0x0F); 
            // Ref: *out is the value contained at the address pointed to by out
            *out++ = outByte; // increment out by 1 and assign to outByte
            highNibble = true;
        }
    }

    // if odd number of samples, flush the last nibble
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
