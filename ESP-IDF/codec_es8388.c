#include <stdio.h>
#include <stdint.h>
#include "esp_err.h"
#include "esp_log.h"
#include "driver/i2c.h"

#include "codec_es8388.h"

static const char *TAG = "codec_es8388";

// ES8388: 7-bit I2C address is typically 0x10
#define ES8388_ADDR 0x10
#define ES_I2C_PORT I2C_NUM_0

// ---------- Low-level I2C ----------
static esp_err_t es_write_reg(uint8_t reg, uint8_t val)
{
    i2c_cmd_handle_t cmd = i2c_cmd_link_create();
    i2c_master_start(cmd);
    i2c_master_write_byte(cmd, (ES8388_ADDR << 1) | I2C_MASTER_WRITE, true);
    i2c_master_write_byte(cmd, reg, true);
    i2c_master_write_byte(cmd, val, true);
    i2c_master_stop(cmd);
    esp_err_t ret = i2c_master_cmd_begin(ES_I2C_PORT, cmd, pdMS_TO_TICKS(200));
    i2c_cmd_link_delete(cmd);
    return ret;
}

static esp_err_t es_read_reg(uint8_t reg, uint8_t *val)
{
    i2c_cmd_handle_t cmd = i2c_cmd_link_create();

    i2c_master_start(cmd);
    i2c_master_write_byte(cmd, (ES8388_ADDR << 1) | I2C_MASTER_WRITE, true);
    i2c_master_write_byte(cmd, reg, true);

    i2c_master_start(cmd);
    i2c_master_write_byte(cmd, (ES8388_ADDR << 1) | I2C_MASTER_READ, true);
    i2c_master_read_byte(cmd, val, I2C_MASTER_NACK);
    i2c_master_stop(cmd);

    esp_err_t ret = i2c_master_cmd_begin(ES_I2C_PORT, cmd, pdMS_TO_TICKS(200));
    i2c_cmd_link_delete(cmd);
    return ret;
}

static int es8388_set_adc_dac_volume(int mode, int volume_db, int dot)
{
    // volume_db is 0..-96 (0 = loudest)
    if (volume_db < -96) volume_db = -96;
    if (volume_db > 0) volume_db = 0;
    dot = (dot >= 5 ? 1 : 0);
    int regv = (-volume_db << 1) + dot;

    int res = 0;
    if (mode == ES_MODULE_ADC || mode == ES_MODULE_ADC_DAC) {
        res |= (es_write_reg(ES8388_ADCCONTROL8, regv) == ESP_OK) ? 0 : 1;
        res |= (es_write_reg(ES8388_ADCCONTROL9, regv) == ESP_OK) ? 0 : 1;
    }
    if (mode == ES_MODULE_DAC || mode == ES_MODULE_ADC_DAC) {
        res |= (es_write_reg(ES8388_DACCONTROL5, regv) == ESP_OK) ? 0 : 1;
        res |= (es_write_reg(ES8388_DACCONTROL4, regv) == ESP_OK) ? 0 : 1;
    }
    return res;
}

// ---------- Public API ----------
esp_err_t es8388_init(es_dac_output_t output, es_adc_input_t input)
{
    // This init sequence is adapted from PCB Artist’s ES8388 code
    if (es_write_reg(ES8388_DACCONTROL3, 0x04) != ESP_OK) return ESP_FAIL;

    (void)es_write_reg(ES8388_CONTROL2, 0x50);
    (void)es_write_reg(ES8388_CHIPPOWER, 0x00);
    (void)es_write_reg(ES8388_MASTERMODE, ES_MODE_SLAVE);

    // DAC config (OK even if you only record)
    (void)es_write_reg(ES8388_DACPOWER, 0xC0);
    (void)es_write_reg(ES8388_CONTROL1, 0x12);
    (void)es_write_reg(ES8388_DACCONTROL1, 0x18); // 16-bit I2S
    (void)es_write_reg(ES8388_DACCONTROL2, 0x02); // 256fs
    (void)es_write_reg(ES8388_DACCONTROL16, 0x00);
    (void)es_write_reg(ES8388_DACCONTROL17, 0x90);
    (void)es_write_reg(ES8388_DACCONTROL20, 0x90);
    (void)es_write_reg(ES8388_DACCONTROL21, 0x80);
    (void)es_write_reg(ES8388_DACCONTROL23, 0x00);
    (void)es8388_set_adc_dac_volume(ES_MODULE_DAC, 0, 0);

    // Enable chosen DAC outputs
    (void)es_write_reg(ES8388_DACPOWER, output);

    // ADC config
    (void)es_write_reg(ES8388_ADCPOWER, 0xFF);
    (void)es_write_reg(ES8388_ADCCONTROL1, 0x88);  // PGA gain baseline
    (void)es_write_reg(ES8388_ADCCONTROL2, input); // IN2 is 0x50
    (void)es_write_reg(ES8388_ADCCONTROL3, 0x02);
    (void)es_write_reg(ES8388_ADCCONTROL4, 0x0D);  // I2S + 16-bit + L/R
    (void)es_write_reg(ES8388_ADCCONTROL5, 0x02);  // 256fs
    (void)es8388_set_adc_dac_volume(ES_MODULE_ADC, -24, 0);

    // Power on ADC + enable LIN/RIN (important)
    (void)es_write_reg(ES8388_ADCPOWER, 0x09);

    ESP_LOGI(TAG, "init ok (out=0x%02X in=0x%02X)", output, input);
    return ESP_OK;
}

esp_err_t es8388_config_i2s(es_bits_length_t bits_length, es_module_t mode, es_format_t fmt)
{
    uint8_t reg = 0;

    // Set format
    if (mode == ES_MODULE_ADC || mode == ES_MODULE_ADC_DAC) {
        ESP_ERROR_CHECK(es_read_reg(ES8388_ADCCONTROL4, &reg));
        reg = (reg & 0xFC) | (uint8_t)fmt;
        ESP_ERROR_CHECK(es_write_reg(ES8388_ADCCONTROL4, reg));
    }
    if (mode == ES_MODULE_DAC || mode == ES_MODULE_ADC_DAC) {
        ESP_ERROR_CHECK(es_read_reg(ES8388_DACCONTROL1, &reg));
        reg = (reg & 0xF9) | ((uint8_t)fmt << 1);
        ESP_ERROR_CHECK(es_write_reg(ES8388_DACCONTROL1, reg));
    }

    // Set bits
    int bits = (int)bits_length;
    if (mode == ES_MODULE_ADC || mode == ES_MODULE_ADC_DAC) {
        ESP_ERROR_CHECK(es_read_reg(ES8388_ADCCONTROL4, &reg));
        reg = (reg & 0xE3) | (uint8_t)(bits << 2);
        ESP_ERROR_CHECK(es_write_reg(ES8388_ADCCONTROL4, reg));
    }
    if (mode == ES_MODULE_DAC || mode == ES_MODULE_ADC_DAC) {
        ESP_ERROR_CHECK(es_read_reg(ES8388_DACCONTROL1, &reg));
        reg = (reg & 0xC7) | (uint8_t)(bits << 3);
        ESP_ERROR_CHECK(es_write_reg(ES8388_DACCONTROL1, reg));
    }

    return ESP_OK;
}

esp_err_t es8388_start(es_module_t mode)
{
    // Reset state machine if necessary and power up blocks
    uint8_t prev = 0, now = 0;
    (void)es_read_reg(ES8388_DACCONTROL21, &prev);

    if (mode == ES_MODULE_LINE) {
        (void)es_write_reg(ES8388_DACCONTROL16, 0x09);
        (void)es_write_reg(ES8388_DACCONTROL17, 0x50);
        (void)es_write_reg(ES8388_DACCONTROL20, 0x50);
        (void)es_write_reg(ES8388_DACCONTROL21, 0xC0);
    } else {
        (void)es_write_reg(ES8388_DACCONTROL21, 0x80);
    }

    (void)es_read_reg(ES8388_DACCONTROL21, &now);
    if (prev != now) {
        (void)es_write_reg(ES8388_CHIPPOWER, 0xF0);
        (void)es_write_reg(ES8388_CHIPPOWER, 0x00);
    }

    if (mode == ES_MODULE_ADC || mode == ES_MODULE_ADC_DAC || mode == ES_MODULE_LINE) {
        (void)es_write_reg(ES8388_ADCPOWER, 0x00);
    }
    if (mode == ES_MODULE_DAC || mode == ES_MODULE_ADC_DAC || mode == ES_MODULE_LINE) {
        (void)es_write_reg(ES8388_DACPOWER, 0x3C);
        // unmute
        uint8_t r = 0;
        (void)es_read_reg(ES8388_DACCONTROL3, &r);
        r = (r & 0xFB);
        (void)es_write_reg(ES8388_DACCONTROL3, r);
    }

    return ESP_OK;
}

esp_err_t es8388_set_voice_volume(int volume_0_to_100)
{
    if (volume_0_to_100 < 0) volume_0_to_100 = 0;
    if (volume_0_to_100 > 100) volume_0_to_100 = 100;

    int v = volume_0_to_100 / 3;

    ESP_ERROR_CHECK(es_write_reg(ES8388_DACCONTROL24, v));
    ESP_ERROR_CHECK(es_write_reg(ES8388_DACCONTROL25, v));
    ESP_ERROR_CHECK(es_write_reg(ES8388_DACCONTROL26, v));
    ESP_ERROR_CHECK(es_write_reg(ES8388_DACCONTROL27, v));
    return ESP_OK;
}
