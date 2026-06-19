# firmware/hal.py
# Hardware Abstraction Layer — provides identical interfaces for Pico WH and PC.
# All hardware access goes through this module; no other file imports from machine/network.

import sys
import time

ON_PICO = sys.platform == "rp2"

# ──────────────────────────────────────────────────────────────────────────────
# ADC Channel
# ──────────────────────────────────────────────────────────────────────────────

if ON_PICO:
    from machine import ADC, Pin  # type: ignore

    class ADCChannel:
        """Real ADC on Pico — reads GP26/GP27."""
        def __init__(self, pin: int):
            self._adc = ADC(Pin(pin))

        def read_u16(self) -> int:
            """Returns raw 16-bit ADC value (0–65535)."""
            return self._adc.read_u16()

else:
    import random

    class ADCChannel:
        """Simulated ADC on PC — Gaussian noise around mid-scale."""
        def __init__(self, pin: int):
            self._pin = pin
            # Slightly different base per channel so CL and FL aren't identical
            self._base = 30000 if pin == 26 else 34000

        def read_u16(self) -> int:
            noise = int(random.gauss(0, 600))
            return max(0, min(65535, self._base + noise))


# ──────────────────────────────────────────────────────────────────────────────
# TFT Display (ILI9341)
# ──────────────────────────────────────────────────────────────────────────────

if ON_PICO:
    from machine import SPI, Pin as _Pin  # type: ignore

    try:
        # nano-gui ILI9341 driver — install via mip or copy manually to Pico
        from drivers.ili9341.ili9341 import ILI9341 as _ILI9341
        _HAS_DRIVER = True
    except ImportError:
        _HAS_DRIVER = False

    class Display:
        # LED backlight is hardwired to 3V3 + VCC — always on, no GPIO pin needed.
        def __init__(self, spi_id, sck, mosi, miso, cs, dc, rst):
            if _HAS_DRIVER:
                spi = SPI(
                    spi_id,
                    baudrate=40_000_000,
                    sck=_Pin(sck),
                    mosi=_Pin(mosi),
                    miso=_Pin(miso),
                )
                self._tft = _ILI9341(spi, cs=_Pin(cs, _Pin.OUT), dc=_Pin(dc, _Pin.OUT), rst=_Pin(rst, _Pin.OUT))
            else:
                self._tft = None

        def print(self, row: int, text: str):
            if self._tft:
                self._tft.fill_rect(0, row * 20, 320, 20, 0x0000)
                self._tft.text(text[:26], 4, row * 20 + 4, 0xFFFF)
            else:
                print(f"[DISPLAY r{row}] {text}")

        def clear(self):
            if self._tft:
                self._tft.fill(0x0000)
            else:
                print("[DISPLAY] --- CLEAR ---")

else:
    class Display:
        """Terminal-based display stub for PC development.
        Accepts (and ignores) all SPI/pin constructor args so main.py can
        call Display(spi_id, sck, mosi, miso, cs, dc, rst) identically on
        both Pico and PC without branching."""
        def __init__(self, *args, **kwargs):
            pass  # no hardware on PC

        def print(self, row: int, text: str):
            print(f"[DISPLAY r{row:02d}] {text}")

        def clear(self):
            print("[DISPLAY] --- CLEAR ---")


# ──────────────────────────────────────────────────────────────────────────────
# WiFi Soft-AP
# ──────────────────────────────────────────────────────────────────────────────

if ON_PICO:
    import network  # type: ignore
    from config import WIFI_COUNTRY

    class WiFiAP:
        def __init__(self, ssid: str, password: str):
            # Set the regulatory domain BEFORE activating the interface, otherwise
            # the CYW43 radio reports active() == True but never beacons, making the
            # AP invisible to phones and laptops.
            try:
                network.country(WIFI_COUNTRY)
            except Exception as e:
                print(f"[WiFi] country() not set: {e}")
            self._ap = network.WLAN(network.AP_IF)
            self._ssid = ssid
            self._password = password

        def start(self):
            # Cold-boot ordering matters. On a freshly powered CYW43 chip, calling
            # active(True) first brings the AP up under its DEFAULT name ("PICO<MAC>")
            # and a later config(ssid=...) does not reliably rename the live beacon.
            # So we set the SSID/password BEFORE activating, then re-apply and verify
            # in a retry loop after activation to make the name stick on cold boot.
            #
            # Also: use ssid= (NOT essid=) on MicroPython v1.23+. essid= is stored
            # and echoed back by config('essid') but is NOT applied to the broadcast.
            self._ap.active(False)
            time.sleep(0.5)

            # 1) Configure name/password BEFORE bringing the interface up.
            try:
                self._ap.config(ssid=self._ssid, password=self._password)
            except Exception as e:
                print(f"[WiFi] pre-activate config failed: {e}")

            # 2) Activate the radio.
            self._ap.active(True)
            while not self._ap.active():
                time.sleep(0.1)

            # 3) Re-apply and verify the SSID actually took effect. On cold boot the
            #    first apply can be ignored, so retry until the broadcast name matches.
            for _ in range(10):
                try:
                    self._ap.config(ssid=self._ssid, password=self._password)
                except Exception as e:
                    print(f"[WiFi] post-activate config failed: {e}")
                try:
                    current = self._ap.config("ssid")
                except Exception:
                    current = None
                if current == self._ssid:
                    break
                time.sleep(0.5)

            time.sleep(1)  # give the beacon time to start
            print(f"[WiFi] AP '{self._ssid}' active — {self._ap.ifconfig()[0]}")

        @property
        def ip(self) -> str:
            return self._ap.ifconfig()[0]

else:
    class WiFiAP:
        """Simulated Soft-AP on PC — no network interface needed."""
        def __init__(self, ssid: str, password: str):
            self._ssid = ssid

        def start(self):
            print(f"[WiFi-SIM] Soft-AP '{self._ssid}' started — connect Flutter to ws://127.0.0.1:8080/ws")

        @property
        def ip(self) -> str:
            return "127.0.0.1"


# ──────────────────────────────────────────────────────────────────────────────
# On-board LED
# ──────────────────────────────────────────────────────────────────────────────

if ON_PICO:
    from machine import Pin as _PinLED  # type: ignore

    class LED:
        def __init__(self):
            self._led = _PinLED("LED", _PinLED.OUT)

        def on(self):     self._led.on()
        def off(self):    self._led.off()
        def toggle(self): self._led.toggle()

else:
    class LED:
        def on(self):     print("[LED] ON")
        def off(self):    print("[LED] OFF")
        def toggle(self): print("[LED] TOGGLE")
