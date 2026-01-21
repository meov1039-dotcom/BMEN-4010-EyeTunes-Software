#include "ES8388.h"
#include "driver/i2s.h"

#include "BluetoothA2DPSource.h"

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
    .dma_buf_count = 8,
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

// create a2dp source object
BluetoothA2DPSource a2dp_source;

int16_t i2s_sample[128]; // creates 64 stereo frames (64*2 for L & R sides)
int16_t* get_audio_data() { // * implies address of one or more samples
  size_t bytes_read;
  i2s_read(I2S_NUM_0, i2s_sample, sizeof(i2s_sample), &bytes_read, portMAX_DELAY);
  return i2s_sample;
  
}

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

  // set up A2DP protocol (advanced audio distribution profile) for esp32 as source (sender)
  // latency below 100 ms is not likely possible for a2dp
  a2dp_source.set_sbc_bitpool(32);   // lower bitpool = lower latency
  a2dp_source.set_sbc_frame_blocks(4);  // fewer frames per packet

  a2dp_source.start("ESP32_BT", get_audio_data);


}

void loop() {
  // read 128 samples (64 stereo samples)
  }
