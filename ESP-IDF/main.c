#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"

#include "esp_system.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include "esp_timer.h"

#include "esp_netif.h"

#include "lwip/err.h"
#include "lwip/sockets.h"
#include "lwip/inet.h"
#include "driver/i2c.h"
#include "driver/i2s.h"
#include "driver/gpio.h"

#include "codec_es8388.h"

// ===================== USER CONFIG =====================
#define WIFI_SSID   "       " // Insert Wi-Fi Name
#define WIFI_PASS   "       " // Insert Wi-Fi Password
#define HOST_IP     "       " // Insert IP Address
#define HOST_PORT   12345

// Audio format we will SEND to phone app:
#define SAMPLE_RATE_SEND     16000               // best for STT
#define BYTES_PER_SAMPLE     2                   // PCM16
#define MONO                1

// Choose payload size (mono PCM16): 1024 bytes = 512 samples = 32 ms @16k
#define AUDIO_PAYLOAD_BYTES  320

static const char *TAG = "AudioBridge";

// ===================== ES8388 / PINS =====================
#define I2C_PORT        I2C_NUM_0
#define I2C_SDA         47
#define I2C_SCL         21
#define I2C_FREQ_HZ     400000

#define I2S_PORT        I2S_NUM_0
#define I2S_BCK         38
#define I2S_WS          37
#define I2S_DOUT        35   // ESP32 -> codec DIN
#define I2S_DIN         36   // codec DOUT -> ESP32
#define I2S_MCLK        0    // PCB Artist: GPIO0
// =========================================================

// ===================== WIFI EVENT GROUP =====================
static EventGroupHandle_t wifi_event_group;
#define WIFI_CONNECTED_BIT BIT0

// ===================== UDP GLOBALS =====================
static int g_sock = -1;
static struct sockaddr_in g_dest_addr;

// 8-byte header + fixed payload
typedef struct __attribute__((packed)) {
    uint64_t timestamp_us;
    uint8_t  audio_data[AUDIO_PAYLOAD_BYTES];
} audio_packet_t;

// ===================== WIFI HANDLER =====================
static void wifi_event_handler(void* arg, esp_event_base_t event_base,
                               int32_t event_id, void* event_data)
{
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
        ESP_LOGI(TAG, "WiFi started, attempting connection...");
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        wifi_event_sta_disconnected_t *disconn = (wifi_event_sta_disconnected_t*) event_data;
        ESP_LOGW(TAG, "Disconnected from AP. Reason: %d", disconn->reason);
        esp_wifi_connect();
        ESP_LOGI(TAG, "Retrying to connect to the AP");
        xEventGroupClearBits(wifi_event_group, WIFI_CONNECTED_BIT);
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t* event = (ip_event_got_ip_t*) event_data;
        ESP_LOGI(TAG, "Got IP:" IPSTR, IP2STR(&event->ip_info.ip));
        xEventGroupSetBits(wifi_event_group, WIFI_CONNECTED_BIT);
    }
}

static void wifi_init_sta(void)
{
    wifi_event_group = xEventGroupCreate();

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));

    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        WIFI_EVENT, ESP_EVENT_ANY_ID, &wifi_event_handler, NULL, NULL));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        IP_EVENT, IP_EVENT_STA_GOT_IP, &wifi_event_handler, NULL, NULL));

    wifi_config_t wifi_config = { 0 };
    strncpy((char*)wifi_config.sta.ssid, WIFI_SSID, sizeof(wifi_config.sta.ssid));
    strncpy((char*)wifi_config.sta.password, WIFI_PASS, sizeof(wifi_config.sta.password));

    // Keep your choices:
    wifi_config.sta.threshold.authmode = WIFI_AUTH_OPEN;
    wifi_config.sta.scan_method = WIFI_ALL_CHANNEL_SCAN;
    wifi_config.sta.sort_method = WIFI_CONNECT_AP_BY_SIGNAL;

    ESP_LOGI(TAG, "Attempting to connect to SSID: '%s'", wifi_config.sta.ssid);
    ESP_LOGI(TAG, "Password length: %d", (int)strlen((char*)wifi_config.sta.password));

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wifi_config));
    ESP_ERROR_CHECK(esp_wifi_start());

    // Strongly recommended for UDP streaming stability:
    ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));

    ESP_LOGI(TAG, "wifi_init_sta finished.");
}

// ===================== I2C / I2S INIT =====================
static void i2c_init_codec(void)
{
    i2c_config_t conf = {
        .mode = I2C_MODE_MASTER,
        .sda_io_num = I2C_SDA,
        .scl_io_num = I2C_SCL,
        .sda_pullup_en = GPIO_PULLUP_ENABLE,
        .scl_pullup_en = GPIO_PULLUP_ENABLE,
        .master.clk_speed = I2C_FREQ_HZ,
    };
    ESP_ERROR_CHECK(i2c_param_config(I2C_PORT, &conf));
    ESP_ERROR_CHECK(i2c_driver_install(I2C_PORT, conf.mode, 0, 0, 0));
}

static void i2s_init_legacy(void)
{
    i2s_config_t i2s_config = {
        .mode = I2S_MODE_MASTER | I2S_MODE_RX | I2S_MODE_TX,
        .sample_rate = SAMPLE_RATE_SEND,   // 16k for STT
        .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
        .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,  // still capture stereo
        .communication_format = I2S_COMM_FORMAT_I2S,
        .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count = 8,
        .dma_buf_len = 64,
        .use_apll = true,              // critical
        .tx_desc_auto_clear = true,
        .fixed_mclk = 0,
    };

    i2s_pin_config_t pins = {
        .bck_io_num = I2S_BCK,
        .ws_io_num = I2S_WS,
        .data_out_num = I2S_DOUT,
        .data_in_num = I2S_DIN,
        .mck_io_num = I2S_MCLK,
    };

    ESP_ERROR_CHECK(i2s_driver_install(I2S_PORT, &i2s_config, 0, NULL));
    ESP_ERROR_CHECK(i2s_set_pin(I2S_PORT, &pins));
    ESP_ERROR_CHECK(i2s_set_clk(I2S_PORT, SAMPLE_RATE_SEND, I2S_BITS_PER_SAMPLE_16BIT, I2S_CHANNEL_STEREO));
}

// ===================== AUDIO UDP TASK =====================
// We'll read stereo PCM16 from I2S into a temp buffer, then convert to mono payload.
static void audio_udp_task(void *arg)
{
    (void)arg;

    ESP_LOGI(TAG, "Audio UDP task started.");

    audio_packet_t *packet = (audio_packet_t*) malloc(sizeof(audio_packet_t));
    if (!packet) {
        ESP_LOGE(TAG, "Failed to alloc packet");
        vTaskDelete(NULL);
        return;
    }

    // temp stereo buffer: need 2x mono bytes because stereo has L+R
    static int16_t stereo_tmp[(AUDIO_PAYLOAD_BYTES / 2) * 2]; // int16 count

    int pkt = 0;

    while (1) {
        size_t bytes_read = 0;

        // Read stereo bytes = 2 channels * mono payload
        // We want AUDIO_PAYLOAD_BYTES mono output, so read 2*AUDIO_PAYLOAD_BYTES input (stereo).
        esp_err_t err = i2s_read(I2S_PORT,
                                 stereo_tmp,
                                 2 * AUDIO_PAYLOAD_BYTES,
                                 &bytes_read,
                                 portMAX_DELAY);

        if (err != ESP_OK) {
            ESP_LOGE(TAG, "i2s_read failed: %s", esp_err_to_name(err));
            vTaskDelay(pdMS_TO_TICKS(30));
            continue;
        }
        if (bytes_read == 0) continue;

        // Convert stereo interleaved -> mono (take LEFT channel)
        // bytes_read is stereo bytes. frames = bytes_read / 4.
        int frames = bytes_read / 4;
        int16_t *mono = (int16_t*)packet->audio_data;

        for (int i = 0; i < frames; i++) {
            mono[i] = (int16_t)(((int32_t)stereo_tmp[2 * i] + (int32_t)stereo_tmp[2*i +1])/2); // mono stero
        }

        int mono_bytes = frames * 2;

        // Force fixed-size payload (pad zeros)
        if (mono_bytes < AUDIO_PAYLOAD_BYTES) {
            memset(packet->audio_data + mono_bytes, 0, AUDIO_PAYLOAD_BYTES - mono_bytes);
        } else if (mono_bytes > AUDIO_PAYLOAD_BYTES) {
            // If we somehow got more, clamp
            mono_bytes = AUDIO_PAYLOAD_BYTES;
        }

        // Debug: max amplitude (every ~50 packets)
        if ((pkt % 50) == 0) {
            int max = 0;
            int sample_count = AUDIO_PAYLOAD_BYTES / 2;
            int16_t *s = (int16_t*)packet->audio_data;
            for (int i = 0; i < sample_count; i++) {
                int v = s[i];
                if (v < 0) v = -v;
                if (v > max) max = v;
            }
            ESP_LOGI(TAG, "pkt=%d max_amp=%d", pkt, max);
        }

        packet->timestamp_us = esp_timer_get_time();

        int total_size = 8 + AUDIO_PAYLOAD_BYTES;
        int sent = sendto(g_sock,
                          packet,
                          total_size,
                          0,
                          (struct sockaddr *)&g_dest_addr,
                          sizeof(g_dest_addr));


        if (sent < 0) {
            ESP_LOGE(TAG, "UDP send error: sent=%d errno=%d", sent, errno);
            vTaskDelay(pdMS_TO_TICKS(20));
        } else {
            if ((pkt % 200) == 0) {
                ESP_LOGI(TAG, "sent pkt=%d bytes=%d", pkt, sent);
            }
            pkt++;
        }
    }
}

// ===================== MAIN =====================
void app_main(void)
{
    // NVS required for WiFi
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ESP_ERROR_CHECK(nvs_flash_init());
    }

    ESP_LOGI(TAG, "Starting WiFi...");
    wifi_init_sta();

    ESP_LOGI(TAG, "Waiting for WiFi connection...");
    EventBits_t bits = xEventGroupWaitBits(wifi_event_group,
                                          WIFI_CONNECTED_BIT,
                                          pdFALSE,
                                          pdFALSE,
                                          portMAX_DELAY);
    if (!(bits & WIFI_CONNECTED_BIT)) {
        ESP_LOGE(TAG, "Failed to connect to WiFi");
        return;
    }
    ESP_LOGI(TAG, "Connected to WiFi!");

    // Build destination address using the HOTSPOT GATEWAY (iPhone)
    esp_netif_ip_info_t ip;
    esp_netif_t *netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    ESP_ERROR_CHECK(esp_netif_get_ip_info(netif, &ip));

    ESP_LOGI(TAG, "STA IP: " IPSTR, IP2STR(&ip.ip));
    ESP_LOGI(TAG, "GW  IP: " IPSTR, IP2STR(&ip.gw));

  // Create UDP socket
    g_sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
    if (g_sock < 0) {
    ESP_LOGE(TAG, "Unable to create socket: errno %d", errno);
    return;
}

    memset(&g_dest_addr, 0, sizeof(g_dest_addr));
    g_dest_addr.sin_family = AF_INET;
    g_dest_addr.sin_port = htons(HOST_PORT);
    g_dest_addr.sin_addr.s_addr = ip.gw.addr;  // iPhone hotspot gateway

    ESP_LOGI(TAG, "UDP destination = gateway:%d", HOST_PORT);

    // Init codec + I2S
    ESP_LOGI(TAG, "Initializing ES8388 + I2S @ %d Hz...", SAMPLE_RATE_SEND);

    i2c_init_codec();
    vTaskDelay(pdMS_TO_TICKS(100));

    // AUX in on LIN2/RIN2
    es_dac_output_t out = DAC_OUTPUT_LOUT1 | DAC_OUTPUT_ROUT1;
    es_adc_input_t  in  = ADC_INPUT_LINPUT2_RINPUT2;

    ESP_ERROR_CHECK(es8388_init(out, in));
    ESP_ERROR_CHECK(es8388_config_i2s(BIT_LENGTH_16BITS, ES_MODULE_ADC_DAC, I2S_NORMAL));
    ESP_ERROR_CHECK(es8388_start(ES_MODULE_ADC));

    i2s_init_legacy();

    // Start streaming task
    xTaskCreatePinnedToCore(audio_udp_task, "audio_udp_task", 8192, NULL, 5, NULL,1);

    ESP_LOGI(TAG, "Setup complete. Streaming 16kHz mono PCM16 over UDP.");
}
