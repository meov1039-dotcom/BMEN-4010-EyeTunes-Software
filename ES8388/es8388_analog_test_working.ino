#include <Arduino.h>
#include <Wire.h>
#include "ES8388.h"
#include <driver/i2s.h>

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
}

void loop() {
  int16_t samples[128];
  size_t bytes_read;

  // Read the data from the I2S bus
  esp_err_t result = i2s_read(I2S_NUM_0, &samples, sizeof(samples), &bytes_read, portMAX_DELAY);

  if (result == ESP_OK && bytes_read > 0) {
    int sample_count = bytes_read / sizeof(int16_t);
    
    // We step by 2 to process pairs, but we only print the Right channel (i + 1)
    for (int i = 0; i < sample_count - 1; i += 2) { 
        // samples[i]   is Left (empty)
        // samples[i+1] is Right (your Sine Wave from RIN1)
        Serial.println(samples[i+1]); 
    }
  }
}