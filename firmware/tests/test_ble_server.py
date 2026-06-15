# firmware/tests/test_ble_server.py
# Tests for firmware/ble_server.py (PC stub) and BLE configuration constants.
#
# On PC (sys.platform != 'rp2') ble_server exposes a no-op ble_task() coroutine
# so that main.py can import and await it unconditionally on both platforms.
# These tests verify:
#   1. The BLE UUID constants in config.py are well-formed and distinct.
#   2. The PC stub ble_task() is a proper coroutine and completes immediately.
#
# The Pico-side GATT server (aioble / _handle_command) is gated behind
# `sys.platform == 'rp2'` and therefore cannot be imported on PC.

import re
import inspect
import asyncio
import time

import pytest

# RFC 4122 UUID pattern — 8-4-4-4-12 hex digits, case-insensitive.
_UUID_RE = re.compile(
    r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}'
    r'-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
)


# ─── BLE configuration constants ─────────────────────────────────────────────

class TestBleConfigUuids:
    """BLE UUID constants in config.py must be valid and mutually distinct."""

    def test_service_uuid_is_valid_format(self):
        from config import BLE_SERVICE_UUID
        assert _UUID_RE.match(BLE_SERVICE_UUID), (
            f"BLE_SERVICE_UUID '{BLE_SERVICE_UUID}' is not a valid UUID"
        )

    def test_tx_uuid_is_valid_format(self):
        from config import BLE_TX_UUID
        assert _UUID_RE.match(BLE_TX_UUID), (
            f"BLE_TX_UUID '{BLE_TX_UUID}' is not a valid UUID"
        )

    def test_rx_uuid_is_valid_format(self):
        from config import BLE_RX_UUID
        assert _UUID_RE.match(BLE_RX_UUID), (
            f"BLE_RX_UUID '{BLE_RX_UUID}' is not a valid UUID"
        )

    def test_all_three_uuids_are_distinct(self):
        """Service, TX, and RX UUIDs must be different from each other."""
        from config import BLE_SERVICE_UUID, BLE_TX_UUID, BLE_RX_UUID
        uuids = [BLE_SERVICE_UUID.upper(), BLE_TX_UUID.upper(), BLE_RX_UUID.upper()]
        assert len(set(uuids)) == 3, (
            "BLE_SERVICE_UUID, BLE_TX_UUID and BLE_RX_UUID must all be distinct"
        )

    def test_device_name_is_pestisafe_ap(self):
        """BLE advertisement name must match the WiFi Soft-AP SSID."""
        from config import BLE_DEVICE_NAME
        assert BLE_DEVICE_NAME == 'PestiSafe_AP'

    def test_uuids_are_nus_compatible(self):
        """Verify the base UUID matches Nordic UART Service (NUS) convention."""
        from config import BLE_SERVICE_UUID
        # NUS base: 6E4000xx-B5A3-F393-E0A9-E50E24DCCA9E
        base = BLE_SERVICE_UUID.upper()
        assert base.endswith('-B5A3-F393-E0A9-E50E24DCCA9E'), (
            "UUIDs should use NUS base (B5A3-F393-E0A9-E50E24DCCA9E)"
        )


# ─── PC stub ble_task() ───────────────────────────────────────────────────────

class TestBleTaskPcStub:
    """ble_task() on PC must be a coroutine that completes without blocking."""

    def test_ble_task_is_importable(self):
        """ble_server must be importable on PC without aioble/bluetooth."""
        from ble_server import ble_task  # noqa: F401

    def test_ble_task_is_a_coroutine_function(self):
        from ble_server import ble_task
        assert inspect.iscoroutinefunction(ble_task), (
            "ble_task must be declared `async def` so asyncio.gather() can await it"
        )

    def test_ble_task_completes_without_error(self):
        """The no-op stub must run to completion without raising."""
        from ble_server import ble_task
        asyncio.run(ble_task())   # raises on error, hangs on block

    def test_ble_task_completes_quickly(self):
        """No-op stub must yield immediately — must not sleep for any meaningful time."""
        from ble_server import ble_task
        start = time.monotonic()
        asyncio.run(ble_task())
        elapsed = time.monotonic() - start
        assert elapsed < 0.5, (
            f"ble_task (PC stub) took {elapsed:.3f}s — expected < 0.5s"
        )

    def test_ble_task_is_awaitable_multiple_times(self):
        """ble_task() must return a fresh coroutine each call (not a one-shot object)."""
        from ble_server import ble_task
        asyncio.run(ble_task())
        asyncio.run(ble_task())  # second call must not raise
