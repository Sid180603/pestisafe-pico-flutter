# firmware/main.py
# Entry point — initialises HAL, starts WiFi Soft-AP, and runs all async tasks concurrently.
#
# Run on PC (no hardware):  python firmware/main.py
#   → WebSocket server at  ws://127.0.0.1:8080/ws
#   → Flutter dev mode:    connect to 127.0.0.1
#
# Deploy to Pico WH:  copy all firmware/*.py + microdot/ to the Pico root
#   → Pico creates Soft-AP "PestiSafe_AP" at 192.168.4.1
#   → Flutter production:  connect to 192.168.4.1

import asyncio

from ble_server import ble_task
from config import (
    WIFI_SSID, WIFI_PASSWORD, WIFI_PORT,
    TFT_SPI_ID, TFT_SCK_PIN, TFT_MOSI_PIN, TFT_MISO_PIN,
    TFT_CS_PIN, TFT_DC_PIN, TFT_RST_PIN,
    HEARTBEAT_INTERVAL_S,
)
from hal import WiFiAP, Display, LED
from server import run_server, _state

# ─── Initialise hardware (HAL picks real or simulated automatically) ──────────

led     = LED()
display = Display(
    TFT_SPI_ID, TFT_SCK_PIN, TFT_MOSI_PIN, TFT_MISO_PIN,
    TFT_CS_PIN, TFT_DC_PIN, TFT_RST_PIN,
    # LED backlight is hardwired to 3V3 — no pin argument needed
)
wifi = WiFiAP(WIFI_SSID, WIFI_PASSWORD)

# ─── Async tasks ─────────────────────────────────────────────────────────────

async def heartbeat_task():
    """Blink the on-board LED every HEARTBEAT_INTERVAL_S seconds."""
    while True:
        led.toggle()
        await asyncio.sleep(HEARTBEAT_INTERVAL_S)


async def display_task():
    """Refresh the TFT with live status every 2 seconds."""
    while True:
        mode = _state.get("mode", "waiting").upper()
        cl   = _state.get("last_cl", 0.0)
        fl   = _state.get("last_fl", 0.0)
        display.print(0, "PestiSafe 2.0")
        display.print(1, f"IP: {wifi.ip}")
        display.print(2, f"Mode: {mode}")
        display.print(3, f"CL:{cl:.4f} FL:{fl:.4f}")
        await asyncio.sleep(2)


async def main():
    display.clear()
    display.print(0, "PestiSafe 2.0")
    display.print(1, "Booting...")

    wifi.start()

    display.print(1, f"IP: {wifi.ip}")
    display.print(2, f"Port: {WIFI_PORT}")
    display.print(3, "WS ready — /ws")
    led.on()

    print(f"[MAIN] WebSocket server starting on ws://{wifi.ip}:{WIFI_PORT}/ws")

    await asyncio.gather(
        run_server(),
        ble_task(),
        heartbeat_task(),
        display_task(),
    )


asyncio.run(main())
