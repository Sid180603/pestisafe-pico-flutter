# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Project overview

**PestiSafe 2.0** — portable dual-mode optical pesticide detection system. Thesis deliverable at MMNE Lab (MEMS, Microfluidics & Nanoelectronics), SERB-funded (CRG/2022/008002), Government of India.

Two independent deliverables in the same repo:

| Directory | Language | What it is |
|-----------|----------|------------|
| `pestisafe/` | Dart/Flutter | Android/Web app — connect, calibrate, measure, classify |
| `firmware/` | MicroPython | Pico WH firmware — sensors, TFT display, WebSocket server |

Hardware target: **Raspberry Pi Pico WH** (RP2040 + CYW43439 WiFi). No hardware is available during development — everything runs on PC via simulation.

---

## Commands

### Flutter app

```bash
cd pestisafe
flutter pub get                          # install / update dependencies
flutter analyze                          # lint — must stay at 0 errors/warnings
flutter test                             # run all tests (widget + math_utils)
flutter test test/widget_test.dart       # run a single test file
flutter test test/math_utils_test.dart   # run math utils unit tests
flutter run -d chrome \
  --web-header "Cross-Origin-Opener-Policy=same-origin" \
  --web-header "Cross-Origin-Embedder-Policy=require-corp"   # web (required for SQLite WASM)
flutter run -d <device-id>              # run on connected Android device
```

### Firmware (Python / pytest)

A `.venv` exists at the project root (`Thesis/.venv`, Python 3.11.9).
Run all firmware commands from the **project root** (`Thesis/`):

```bash
# Activate venv (PowerShell)
.venv\Scripts\Activate.ps1

# One-time setup (already done — microdot + pytest installed in .venv)
pip install microdot pytest

# Start firmware server on PC
python firmware/main.py                  # ws://127.0.0.1:8080/ws

# Run all firmware tests (54 total: 17 sensor + 14 protocol + 12 calibration + 11 BLE server)
python -m pytest firmware/tests/ -v
python -m pytest firmware/tests/test_sensor.py               # single file
python -m pytest firmware/tests/test_ble_server.py           # BLE config + PC stub
python -m pytest firmware/tests/ -k "TestMedianOutlierRejection"  # single class
```

`firmware/tests/conftest.py` adds `firmware/` to `sys.path`, so test files import `sensor`, `protocol`, `config` by name directly — no package prefix needed.

### Deploying firmware to real Pico WH

```bash
# Install Microdot on the Pico (requires Pico connected via USB)
mpremote mip install microdot

# Install aioble on the Pico (Phase 3 BLE transport)
mpremote mip install aioble

# Copy all firmware .py files to Pico root
mpremote cp firmware/config.py :config.py
mpremote cp firmware/hal.py :hal.py
mpremote cp firmware/sensor.py :sensor.py
mpremote cp firmware/protocol.py :protocol.py
mpremote cp firmware/server.py :server.py
mpremote cp firmware/ble_server.py :ble_server.py
mpremote cp firmware/main.py :main.py

# The nano-gui ILI9341 driver must be installed separately:
# Copy drivers/ili9341/ili9341.py to the Pico at /drivers/ili9341/ili9341.py
# HAL degrades gracefully (_HAS_DRIVER = False) if driver is absent
# aioble degrades gracefully (_HAS_AIOBLE = False) if not installed (e.g. Wokwi)
```

### End-to-end local test (no hardware)

1. `python firmware/main.py` — WebSocket server starts at `ws://127.0.0.1:8080/ws`
2. Run the Flutter web command above in a second terminal — enable **Dev Mode** toggle on the Connect screen to point at `127.0.0.1`

---

## Architecture

### Libraries

| Library | Side | Purpose |
|---------|------|---------|
| **Microdot** | Firmware | Flask-like MicroPython WebSocket server; handles `/ws` endpoint via `@app.route("/ws") @with_websocket` |
| **nano-gui** (Peter Hinch) | Firmware | TFT widget library for MicroPython; wraps ILI9341 driver |
| **aioble** | Firmware | Official MicroPython BLE library for RP2040; used in `firmware/ble_server.py`; degrades gracefully when absent (`_HAS_AIOBLE = False`) |
| `web_socket_channel` | Flutter | WebSocket client |
| `provider` | Flutter | Root `ChangeNotifier` state (AppState) |
| `shared_preferences` | Flutter | Persists calibration coefficients and selected pesticide across restarts |
| `fl_chart` | Flutter | Calibration curve chart (scatter + regression line per channel) |
| `sqflite`, `sqflite_common_ffi_web` | Flutter | SQLite measurement history; web uses WASM via COOP/COEP headers |
| `path`, `path_provider` | Flutter | File path resolution for SQLite on native targets |
| `share_plus`, `csv` | Flutter | CSV export and OS share sheet |
| `intl` | Flutter | Timestamp formatting in HistoryScreen |

### Communication protocol

Pico creates a WiFi Soft-AP (`PestiSafe_AP` / `pestisafe2024`, IP `192.168.4.1`). **The phone connects directly to the Pico's hotspot — no router or external network needed.** Flutter connects via WebSocket to `ws://192.168.4.1:8080/ws`. On PC, the simulated firmware binds to `127.0.0.1:8080`.

All messages are JSON with a `"v": 1` protocol version field — including synthetic disconnect/error messages generated by `WebSocketConnection`. The **canonical definitions live in two mirrored files that must stay in sync**:

| File | Side |
|------|------|
| `firmware/protocol.py` | Python — encodes firmware→app responses, decodes app→firmware commands |
| `pestisafe/lib/protocol.dart` | Dart — `Protocol.encodeMeasure()`, `Protocol.parseSensor()`, etc. |

**Full message catalogue:**

| Direction | Type | Payload | Purpose |
|-----------|------|---------|---------|
| App → firmware | `measure` | — | Request one ADC reading |
| App → firmware | `heartbeat` | — | Keep-alive ping |
| App → firmware | `cal_start` | `level` | Begin calibration level |
| App → firmware | `cal_sample` | `level`, `sample` | Collect one calibration sample |
| App → firmware | `cal_end` | — | All levels collected; firmware resets mode to "waiting" |
| Firmware → app | `sensor` | `cl`, `fl` | Normalised ADC values [0, 1] |
| Firmware → app | `cal_ack` | `level`, `sample`, `cl`, `fl` | Single calibration sample result |
| Firmware → app | `status` | `state` | `"waiting"` \| `"measuring"` \| `"calibrating"` |
| Firmware → app | `heartbeat` | — | Echo of keep-alive |
| Firmware → app | `error` | `msg` | Firmware-side error string |

`Protocol.parseSensor()` and `Protocol.parseCalAck()` throw `FormatException` (not `TypeError`) on missing/non-numeric fields so screen-level `on FormatException catch (_) {}` handlers catch them correctly. Never use bare `catch (_) {}` in message listeners.

### Firmware HAL pattern

`firmware/hal.py` detects `sys.platform == "rp2"` and provides two class implementations under the same name: one for real Pico hardware, one stub for PC. All other firmware files import only from `hal.py`—never from `machine` or `network` directly. This is why the firmware runs unchanged on both platforms.

`firmware/config.py` is the single source of truth for every pin number, WiFi credential, and protocol constant. Nothing is hardcoded elsewhere.

**Confirmed hardware pin assignments (from professor's wiring):**

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
| TFT backlight | hardwired to 3V3 — no GPIO |

### Flutter state and navigation

`AppState` (`lib/app_state.dart`) is a `ChangeNotifier` mounted at the root via `Provider`. It holds the live `DeviceConnection`, calibration coefficients, selected R² values, and selected pesticide. Screens read it via `Provider.of<AppState>(context, listen: false)`.

`DeviceConnection` (`lib/services/device_connection.dart`) is an **abstract interface** — screens never import `WebSocketConnection` directly. This is intentional: a `BleConnection` can be added in Phase 3 without touching any screen code.

Navigation flow: **HomeScreen → ConnectScreen → CalibrationScreen → MeasurementScreen → HistoryScreen** (HistoryScreen also reachable directly from HomeScreen). All Phase 2 screens read `DeviceConnection` and calibration coefficients from `AppState` via `Provider.of<AppState>(context, listen: false)` — no constructor parameters.

`AppState.updateCalibration()` accepts an optional `pesticide:` parameter so both coefficients and the selected pesticide are persisted in a **single** `SharedPreferences` write. Do not call `setSelectedPesticide()` separately after `updateCalibration()` — it causes a redundant second disk write.

### Calibration

Scientific basis: **Beer-Lambert law** — absorbance is linearly proportional to concentration, so a single-channel ADC reading maps linearly to mg/L. This justifies the least-squares linear fit: `concentration = slope × reading + intercept`.

N levels: Blank (0.00 fixed) + N user-editable standards (starts at 3: Std 1/2/3, defaults 0.10/0.50/1.00). Unit is **ppm (mg/kg)** or **ppb (μg/kg)** — selected via dropdown; internal math always uses ppm. Before each level, a **10-second stabilisation delay** lets the sample settle; then 5 × `cal_sample` commands are sent. After all levels are collected, the app calls `_computeCalibration()`, which:

1. Calls `linearFit()` from `math_utils.dart` → slope, intercept, R² per channel
2. Applies tiered R² logic:
   - R² ≥ 0.99 → excellent, proceeds silently
   - 0.95 ≤ R² < 0.99 → warns user, offers "Add Point" to collect an extra level and refit
   - R² < 0.95 → blocks proceeding; user must add a point or recalibrate
3. Calls `AppState.updateCalibration(... pesticide: ...)` — single write to SharedPreferences (skipped if R² < 0.95)
4. Sends `cal_end` to firmware — resets firmware TFT display back to "waiting" state (skipped if R² < 0.95)
5. Navigates to `MeasurementScreen`

`AppState.isCalibrated` returns true only when both `clR2 > 0` and `flR2 > 0`. `AppState.selectedUnit` ('ppm'/'ppb') is persisted in SharedPreferences and used by calibration, measurement, and history screens for display and CSV export.

### Measurement and safety classification

**FL-preferred agreement rule** (professor's specification): if `|CL − FL| / mean ≤ 5%` → use average; if `> 5%` → use FL reading only, flag mismatch in UI. Implemented in `flPreferred()` in `math_utils.dart`.

**2-tier MRL classification** (CODEX Alimentarius uses binary thresholds): SAFE ≤ MRL → UNSAFE > MRL.

MRL reference data lives in `pestisafe/assets/json/mrl_data.json` (CODEX ALIMENTARIUS, 8 pesticides). Loaded via `MrlData.load()` in `main()` before first frame. `MrlData.commoditiesFor()` and `MrlData.getMrl()` return safe defaults (empty list / 0.0) rather than throwing if a stale pesticide name from SharedPreferences is not present in the current JSON — prevents crashes after data updates.

Each completed measurement is saved to the local SQLite database via `DatabaseHelper.instance.insertMeasurement()`.

### History screen

`HistoryScreen` loads all records from SQLite and applies client-side filtering by pesticide name and result (SAFE/UNSAFE). CSV export uses the currently filtered view, not the full record set. Swipe-to-delete confirms via dialog before deleting.

**Fixed:** `_load()` now has `if (!mounted) return;` before the second `setState` (fixed in Phase 3 audit).

### BLE transport (Phase 3)

`firmware/ble_server.py` is a GATT server using Nordic UART Service (NUS) UUIDs:

| Characteristic | UUID | Direction |
|---|---|---|
| Service | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` | — |
| TX (notify) | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` | firmware → app |
| RX (write) | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` | app → firmware |

Both WiFi WebSocket and BLE GATT carry the **same JSON protocol** — no protocol changes. The two transports run concurrently: `asyncio.gather(run_server(), ble_task(), ...)`.

**Graceful degradation:**
- On PC: `sys.platform != "rp2"` → PC no-op stub
- On Wokwi (rp2, no aioble): `ImportError` → `_HAS_AIOBLE = False` → `ble_task()` returns immediately
- On real Pico with aioble installed: full GATT server runs

`ConnectScreen` shows a WiFi/BLE `SegmentedButton`. BLE segment is hidden on web (`kIsWeb`). In BLE mode: tap Scan → list of nearby `PestiSafe_AP` devices → tap to connect → same `CalibrationScreen` / `MeasurementScreen` flow (transport-agnostic via `DeviceConnection` interface).

### Wokwi demo

`wokwi/diagram.json` + `wokwi/wokwi.toml` define the Wokwi simulation project:
- **Parts:** `wokwi-pi-pico-w` + `wokwi-ili9341` TFT + two `wokwi-potentiometer` (GP26/ADC0 = CL, GP27/ADC1 = FL)
- **Purpose:** visual demo of TFT boot sequence and live ADC from potentiometers — WiFi/BLE not simulated
- Open in VS Code with the Wokwi extension, or upload to wokwi.com

---

## Phase roadmap

| Phase | Status | Scope |
|-------|--------|-------|
| 1 | **Done** | Firmware skeleton, WebSocket layer, calibration (4-level + R²), measurement (FL-preferred), Provider/AppState |
| 2 | **Done** | History screen, SQLite (`sqflite`), CSV export, `fl_chart` calibration curve, MRLs from JSON, SharedPreferences startup load, user-editable calibration levels, firmware cal_start/cal_sample/cal_end/cal_ack, `math_utils.dart`, 2-tier classification |
| 3 | **Done** | BLE transport (`aioble`) — `BleConnection implements DeviceConnection`; `ConnectScreen` WiFi/BLE segment picker; `firmware/ble_server.py` GATT server; `wokwi/` demo project |

**Wokwi note:** Wokwi simulates Pico hardware but does not simulate WiFi or BLE — the firmware WebSocket and GATT servers cannot reach a Flutter app via Wokwi. The Wokwi project (`wokwi/diagram.json` + `wokwi/wokwi.toml`) is for visual hardware demo only: TFT display boot sequence and live CL/FL ADC readings driven by potentiometers. `ble_server.py` degrades gracefully when `aioble` is absent (`_HAS_AIOBLE = False`), so Wokwi boots without crashing.

---

## Key constraints

- **No hardware available.** All testing is PC-simulation + end-to-end with `python firmware/main.py`.
- `flutter analyze` must report **0 errors and 0 warnings** before any commit.
- `flutter_blue_plus: ^1.35.5` is active (Phase 3). `BleConnection` (`lib/services/ble_connection.dart`) implements `DeviceConnection` using Nordic UART Service (NUS) UUIDs. UUIDs are defined in `firmware/config.py` as `BLE_SERVICE_UUID`, `BLE_TX_UUID`, `BLE_RX_UUID` and must stay in sync with `ble_connection.dart`.
- Deprecated `withOpacity()` → use `withValues(alpha: x)` (Flutter 3.41.6+).
- The TFT driver (`drivers/ili9341/ili9341.py`) must be installed separately on the Pico via `mip` or manual copy. The HAL gracefully degrades if it is absent (`_HAS_DRIVER = False`).
- The original text-based protocol format (`CL:X.XX,FL:X.XX`) is fully superseded by JSON. Never revert to the old format.
- `asyncio.gather(run_server(), ble_task(), heartbeat_task(), display_task())` is the concurrency model in `main.py` — all four tasks run cooperatively; blocking calls must use `await asyncio.sleep()` not `time.sleep()`. On PC, `ble_task()` is a no-op coroutine (PC stub). On Pico without aioble installed (e.g. Wokwi), it returns immediately (`_HAS_AIOBLE = False`).
- Web SQLite (`sqflite_common_ffi_web`) requires COOP/COEP HTTP headers — always use the `--web-header` flags shown in the Flutter run command above.
- `MrlData.commoditiesFor()` and `MrlData.getMrl()` return safe defaults on unknown pesticide/commodity names — do not assume they throw.
- `Protocol.encodeHeartbeat()` sends `"heartbeat"` (matches firmware handler). The old `encodePing()` no longer exists — do not re-add it.
