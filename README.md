# PestiSafe 2.0

Portable dual-mode optical pesticide detection system — thesis deliverable at MMNE Lab (MEMS, Microfluidics & Nanoelectronics), SERB-funded (CRG/2022/008002), Government of India.

---

## What It Does

The system measures pesticide residue on food commodities using two simultaneous optical methods (Fluorescence and Colorimetric), classifies results against CODEX ALIMENTARIUS Maximum Residue Limits (MRLs), and stores a timestamped history with CSV export.

---

## Repository Layout

```
pestisafe/          Flutter app (Android + Web)
firmware/           MicroPython firmware for Raspberry Pi Pico WH
firmware/tests/     pytest test suite (54 tests)
wokwi/              Wokwi hardware simulation project
```

---

## Quick Start — No Hardware Required

Both the firmware and the app run on a PC. Two terminals are all you need.

### 1. Start the firmware simulator

```powershell
# From the repo root
.venv\Scripts\Activate.ps1          # activate Python 3.11 venv
python firmware/main.py             # WebSocket server at ws://127.0.0.1:8080/ws
```

Terminal output confirms startup:
```
[HAL]  PC mode — WiFi and BLE stubs active
[MAIN] WebSocket server starting on ws://127.0.0.1:8080/ws
```

### 2. Run the Flutter app

```powershell
cd pestisafe
flutter pub get
flutter run -d chrome `
  --web-header "Cross-Origin-Opener-Policy=same-origin" `
  --web-header "Cross-Origin-Embedder-Policy=require-corp"
```

On the **Connect** screen, enable the **Dev Mode** toggle (switches target to `127.0.0.1`), then tap **Connect**.

**Full workflow:** Connect → Calibrate → Measure → View History → Export CSV

---

## Running on Android

1. Start `python firmware/main.py` on your PC.
2. Note your PC's local IP address (e.g. `192.168.1.50`).
3. Connect your Android phone to the same WiFi network.
4. `flutter run -d <device-id>` — enable **Dev Mode** in the app and enter your PC's IP.

---

## Connect via BLE (Android only, real Pico WH required)

1. Install aioble on the Pico: `mpremote mip install aioble`
2. Deploy all firmware files (see **Deploying to Pico WH** below).
3. In the app, select the **BLE** segment on the Connect screen, tap **Scan**, choose `PestiSafe_AP`.

BLE is automatically hidden when running on Web (Chrome does not support flutter_blue_plus).

---

## Wokwi Hardware Demo

Open `wokwi/` in VS Code with the [Wokwi extension](https://marketplace.visualstudio.com/items?itemName=Wokwi.wokwi-vscode), or upload `wokwi/diagram.json` at [wokwi.com](https://wokwi.com).

The simulation shows:
- TFT display boot sequence ("PestiSafe 2.0 / Booting…")
- Live CL/FL ADC readings driven by the two potentiometers
- Heartbeat LED blink every 5 s

WiFi and BLE are not simulated in Wokwi. For end-to-end testing use `python firmware/main.py`.

---

## Deploying to a Real Pico WH

```bash
# Install dependencies
mpremote mip install microdot
mpremote mip install aioble

# Copy firmware files
mpremote cp firmware/config.py     :config.py
mpremote cp firmware/hal.py        :hal.py
mpremote cp firmware/sensor.py     :sensor.py
mpremote cp firmware/protocol.py   :protocol.py
mpremote cp firmware/server.py     :server.py
mpremote cp firmware/ble_server.py :ble_server.py
mpremote cp firmware/main.py       :main.py
```

The ILI9341 TFT driver must also be placed on the Pico at `drivers/ili9341/ili9341.py`. The HAL degrades gracefully if it is absent (`_HAS_DRIVER = False`).

On first boot the Pico creates a WiFi Soft-AP:

| Setting | Value |
|---------|-------|
| SSID | `PestiSafe_AP` |
| Password | `pestisafe2024` |
| IP | `192.168.4.1` |
| WebSocket | `ws://192.168.4.1:8080/ws` |

Connect your phone to `PestiSafe_AP`, open the app, tap **Connect** (WiFi mode, Dev Mode **off**).

---

## Running Tests

### Firmware (pytest)

```powershell
# From repo root, venv active
python -m pytest firmware/tests/ -v
```

54 tests across sensor, protocol, calibration, and BLE server modules.

### Flutter

```powershell
cd pestisafe
flutter test          # 16 tests: HomeScreen + ConnectScreen widget tests + math utils
flutter analyze       # must report 0 errors, 0 warnings
```

---

## Architecture

| Layer | Technology | Role |
|-------|-----------|------|
| Hardware | Raspberry Pi Pico WH (RP2040 + CYW43439) | Reads FL/CL sensors, drives TFT, serves WiFi/BLE |
| Firmware | MicroPython + Microdot + aioble | WebSocket server, GATT server, HAL abstraction |
| Transport | WiFi WebSocket **or** BLE (Nordic UART Service) | Same JSON protocol over both |
| App | Flutter (Dart) | Calibration, measurement, safety classification, history |
| State | Provider (`AppState`) + SharedPreferences + SQLite | Persists calibration, history, preferences |

### Communication protocol

All messages are JSON with `"v": 1`. Defined in `firmware/protocol.py` (Python) and `pestisafe/lib/protocol.dart` (Dart) — both files must stay in sync.

| Direction | Type | Purpose |
|-----------|------|---------|
| App → firmware | `measure` | Request one ADC reading |
| App → firmware | `heartbeat` | Keep-alive ping |
| App → firmware | `cal_start` | Begin calibration level |
| App → firmware | `cal_sample` | Collect one sample |
| App → firmware | `cal_end` | Finish calibration |
| Firmware → app | `sensor` | Normalised CL/FL values [0, 1] |
| Firmware → app | `cal_ack` | Sample acknowledgement |
| Firmware → app | `status` | `waiting` / `measuring` / `calibrating` |
| Firmware → app | `heartbeat` | Ping echo |
| Firmware → app | `error` | Error string |

### Calibration

Beer-Lambert law: absorbance is linear with concentration. Least-squares fit per channel → `concentration = slope × reading + intercept`. R² thresholds enforce quality: ≥ 0.99 proceeds silently, 0.95–0.99 warns, < 0.95 blocks.

### Safety classification

FL-preferred dual-mode rule: if `|CL − FL| / mean ≤ 5%` use average; otherwise use FL only and flag mismatch. Result compared against CODEX ALIMENTARIUS MRLs (8 pesticides, `assets/json/mrl_data.json`). Binary classification: SAFE ≤ MRL, UNSAFE > MRL.

### MRL Data

MRL values are sourced from **CODEX Alimentarius, CXL 2023, Maximum Residue Limits** (FAO/WHO). The database covers 8 pesticides selected for their prevalence in Indian agriculture and measurability in the 0.01–50 mg/kg range of this sensor:

| Pesticide | Class | Chemical family |
|-----------|-------|-----------------|
| Imidacloprid | Insecticide | Neonicotinoid |
| Malathion | Insecticide | Organophosphate |
| Acetamiprid | Insecticide | Neonicotinoid |
| Carbendazim | Fungicide | Benzimidazole |
| Cypermethrin | Insecticide | Pyrethroid |
| Glyphosate | Herbicide | Phosphonoglycine |
| Profenofos | Insecticide | Organophosphate |
| Methamidophos | Insecticide | Organophosphate |

**Note on Monocrotophos:** Monocrotophos (widely used in India, 0.1–1 ppm detection range) has no CODEX MRL because it is banned in India, the EU, and the US. Its primary metabolite, Methamidophos, retains a CODEX entry and is included here instead. Each pesticide record also stores its Acceptable Daily Intake (ADI in mg/kg body weight/day), which is displayed on the Measurement screen.

---

## Hardware Pin Assignments

| Signal | GPIO |
|--------|------|
| CL sensor | GP26 (ADC0) |
| FL sensor | GP27 (ADC1) |
| TFT SCK | GP18 |
| TFT MOSI | GP19 |
| TFT MISO | GP16 |
| TFT CS | GP17 |
| TFT DC | GP15 |
| TFT RST | GP14 |
| TFT backlight | Hardwired to 3V3 |

---

## Funding

SERB (Science and Engineering Research Board), Government of India — Grant CRG/2022/008002.
