# firmware/config.py
# Single source of truth for all hardware pins, WiFi credentials, calibration defaults,
# and protocol constants. Every other firmware file imports from here — nothing hardcoded elsewhere.

import sys

# ─── Platform ────────────────────────────────────────────────────────────────
ON_PICO = sys.platform == "rp2"

# ─── SPI / TFT (ILI9341, 3.2in, 320×240) ────────────────────────────────────
TFT_SPI_ID   = 0        # SPI bus 0
TFT_SCK_PIN  = 18       # GP18 — SPI0 SCK
TFT_MOSI_PIN = 19       # GP19 — SPI0 MOSI (SDI on display)
TFT_MISO_PIN = 16       # GP16 — SPI0 MISO (SDO on display, optional)
TFT_CS_PIN   = 17       # GP17 — Chip Select (active LOW)
TFT_DC_PIN   = 15       # GP15 — Data/Command (confirmed from professor's wiring)
TFT_RST_PIN  = 14       # GP14 — Reset (active LOW, confirmed from professor's wiring)
# TFT LED backlight: hardwired to 3V3 + VCC — always on, no GPIO needed

TFT_WIDTH  = 320
TFT_HEIGHT = 240

# ─── ADC Sensors ─────────────────────────────────────────────────────────────
CL_ADC_PIN  = 26        # GP26 = ADC0 — Colorimetric (CL) sensor
FL_ADC_PIN  = 27        # GP27 = ADC1 — Fluorescence (FL) sensor
ADC_SAMPLES = 5         # Median-filter window size (odd preferred)
ADC_MAX     = 65535     # RP2040 read_u16() full-scale value (2¹⁶ − 1)

# ─── WiFi (Soft-AP) ──────────────────────────────────────────────────────────
WIFI_SSID     = "PestiSafe_AP"
WIFI_PASSWORD = "pestisafe2024"
WIFI_HOST     = "0.0.0.0"
WIFI_PORT     = 8080

# ─── Protocol message types ───────────────────────────────────────────────────
MSG_SENSOR     = "sensor"      # {"type":"sensor","cl":x,"fl":y}
MSG_STATUS     = "status"      # {"type":"status","state":"waiting"|"measuring"|"calibrating"}
MSG_HEARTBEAT  = "heartbeat"   # {"type":"heartbeat"}
MSG_ERROR      = "error"       # {"type":"error","msg":"..."}
MSG_CAL_START  = "cal_start"   # app→firmware: begin calibration level {"level":"0.10"}
MSG_CAL_SAMPLE = "cal_sample"  # app→firmware: collect one sample {"level":"0.10","sample":2}
MSG_CAL_ACK    = "cal_ack"     # firmware→app: sample result {"level":"0.10","sample":2,"cl":x,"fl":y}
MSG_CAL_END    = "cal_end"     # app→firmware: all levels collected, reset mode to waiting
PROTOCOL_VERSION = 1         # Increment when wire format changes

HEARTBEAT_INTERVAL_S = 5

# ─── BLE GATT (Nordic UART Service UUIDs) ────────────────────────────────────
# Must match pestisafe/lib/services/ble_connection.dart exactly.
BLE_SERVICE_UUID = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E'  # service
BLE_TX_UUID      = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E'  # firmware→app (notify)
BLE_RX_UUID      = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E'  # app→firmware (write)
BLE_DEVICE_NAME  = 'PestiSafe_AP'

# ─── Calibration defaults ────────────────────────────────────────────────────
CALIB_CONCENTRATIONS = [0.00, 0.10, 0.50, 1.00]   # mg/L: Blank, Low, Mid, High
CALIB_SAMPLES        = 5                            # readings averaged per level
