# firmware/ble_server.py
# BLE GATT server — runs concurrently with the WiFi WebSocket server.
#
# Uses aioble (official MicroPython BLE library for RP2040).
# Install on Pico: mpremote mip install aioble
#
# Service layout (Nordic UART Service-compatible UUIDs):
#   TX characteristic (BLE_TX_UUID) — firmware→app, notify
#   RX characteristic (BLE_RX_UUID) — app→firmware, write
#
# All messages are the same JSON protocol defined in protocol.py.
# No protocol changes — BLE is purely an alternative transport.
#
# On PC (sys.platform != "rp2") this module defines a no-op ble_task()
# so main.py can import it unconditionally on both platforms.

import sys
import asyncio
import protocol
from sensor import read_sensors
from config import (
    BLE_SERVICE_UUID, BLE_TX_UUID, BLE_RX_UUID, BLE_DEVICE_NAME,
    MSG_CAL_END,
)

# Shared state — same dict used by server.py and display_task in main.py.
# Imported from server so both transports update a single source of truth.
from server import _state

# ─── PC stub — BLE not available on PC ───────────────────────────────────────

if sys.platform != "rp2":
    async def ble_task():
        """No-op on PC — BLE hardware only available on RP2040."""
        print("[BLE] Not running: platform is not rp2")
        # Yield control immediately so asyncio.gather() is not blocked.
        await asyncio.sleep(0)

# ─── Pico implementation ──────────────────────────────────────────────────────
#
# aioble is not a built-in MicroPython module — it must be installed separately
# via `mpremote mip install aioble`.  Wokwi runs MicroPython on rp2 but has no
# package manager, so aioble will not be present there.  We follow the same
# graceful-degradation pattern used by hal.py for the ILI9341 driver:
# wrap the import in try/except and set a flag so ble_task() can skip the real
# GATT server and return immediately when the library is absent.

else:
    try:
        import aioble      # type: ignore  (MicroPython library)
        import bluetooth   # type: ignore  (MicroPython built-in)

        _SERVICE_UUID = bluetooth.UUID(BLE_SERVICE_UUID)
        _TX_UUID      = bluetooth.UUID(BLE_TX_UUID)
        _RX_UUID      = bluetooth.UUID(BLE_RX_UUID)

        _service = aioble.Service(_SERVICE_UUID)
        _tx_char = aioble.Characteristic(_service, _TX_UUID, notify=True)
        _rx_char = aioble.Characteristic(_service, _RX_UUID, write=True, capture=True)

        _HAS_AIOBLE = True

    except ImportError:
        # aioble not installed (e.g. Wokwi simulator) — BLE silently disabled.
        _HAS_AIOBLE = False


    async def _notify(conn, msg: str):
        """Send a JSON string to the app via BLE notification."""
        data = msg.encode()
        # If payload exceeds negotiated MTU the stack will fragment automatically
        # on modern MicroPython / Android pairs (247-byte MTU negotiated).
        _tx_char.notify(conn, data)


    async def _handle_command(msg: dict, conn) -> None:
        """
        Dispatch a decoded command dict to the correct action and send replies
        back via BLE notify.  Mirrors the dispatch in server.py websocket_handler.
        """
        cmd = msg.get("type", "")

        if cmd == "measure":
            _state["mode"] = "measuring"
            await _notify(conn, protocol.encode_status("measuring"))
            cl, fl = await read_sensors()
            _state["last_cl"] = cl
            _state["last_fl"] = fl
            await _notify(conn, protocol.encode_sensor(cl, fl))
            _state["mode"] = "waiting"
            await _notify(conn, protocol.encode_status("waiting"))

        elif cmd == "heartbeat":
            await _notify(conn, protocol.encode_heartbeat())

        elif cmd == "cal_start":
            level = msg.get("level", "")
            _state["mode"] = "calibrating"
            _state["cal_level"] = level
            await _notify(conn, protocol.encode_status("calibrating"))

        elif cmd == "cal_sample":
            level      = msg.get("level", "")
            sample_idx = msg.get("sample", 0)
            try:
                conc_val = float(level)
            except (ValueError, TypeError):
                conc_val = None
            cl, fl     = await read_sensors(conc=conc_val)
            _state["last_cl"] = cl
            _state["last_fl"] = fl
            await _notify(conn, protocol.encode_cal_ack(level, sample_idx, cl, fl))

        elif cmd == MSG_CAL_END:
            _state["mode"] = "waiting"
            _state["cal_level"] = ""
            await _notify(conn, protocol.encode_status("waiting"))


    async def ble_task():
        """
        Advertise as PestiSafe_AP and serve one client at a time.
        Runs forever inside asyncio.gather() alongside run_server().

        If aioble is not installed (e.g. Wokwi simulator), returns immediately
        so the rest of the firmware (WiFi server, TFT display) is unaffected.
        """
        if not _HAS_AIOBLE:
            print("[BLE] aioble not installed — BLE disabled (Wokwi or bare MicroPython)")
            return

        aioble.register_services(_service)
        print(f"[BLE] Advertising as '{BLE_DEVICE_NAME}'")

        while True:
            # Block here until a central connects.
            conn = await aioble.advertise(
                250_000,          # interval_us  ≈ 250 ms
                name=BLE_DEVICE_NAME,
                services=[_SERVICE_UUID],
            )
            print(f"[BLE] Client connected: {conn.device}")
            await _notify(conn, protocol.encode_status("waiting"))

            try:
                while conn.is_connected():
                    # Wait for the app to write to the RX characteristic.
                    # capture=True on the characteristic stores writes in a queue.
                    # TimeoutError is caught *inside* the loop so a 1-second
                    # silence does not break the connection.
                    try:
                        _, raw = await _rx_char.written(timeout_ms=1000)
                        if raw is None:
                            continue
                        msg = protocol.decode(raw.decode())
                        await _handle_command(msg, conn)
                    except asyncio.TimeoutError:
                        pass  # no command in 1 s — keep polling same connection
                    except Exception as exc:
                        print(f"[BLE] command error: {exc}")
                        await _notify(conn, protocol.encode_error(str(exc)))

            except Exception as exc:
                print(f"[BLE] connection error: {exc}")
            finally:
                print("[BLE] Client disconnected")
                _state["mode"] = "waiting"
                try:
                    await conn.disconnect()
                except Exception:
                    pass
