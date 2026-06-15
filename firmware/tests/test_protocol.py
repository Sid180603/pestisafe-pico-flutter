# firmware/tests/test_protocol.py
# Unit tests for protocol.py — encode/decode round-trips, version checks,
# error handling. Run from firmware/ directory: python -m pytest tests/
# or from project root: python -m pytest firmware/tests/

import json
import pytest
import protocol


class TestEncodeDecodeRoundtrip:
    def test_sensor_roundtrip(self):
        raw = protocol.encode_sensor(cl=0.4523, fl=0.3891)
        msg = json.loads(raw)
        assert msg["type"] == "sensor"
        assert msg["cl"] == 0.4523
        assert msg["fl"] == 0.3891
        assert msg["v"] == 1

    def test_status_roundtrip(self):
        for state in ("waiting", "measuring", "done", "disconnected"):
            raw = protocol.encode_status(state)
            msg = json.loads(raw)
            assert msg["type"] == "status"
            assert msg["state"] == state
            assert msg["v"] == 1

    def test_heartbeat_roundtrip(self):
        raw = protocol.encode_heartbeat()
        msg = json.loads(raw)
        assert msg["type"] == "heartbeat"
        assert msg["v"] == 1

    def test_error_roundtrip(self):
        raw = protocol.encode_error("ADC overflow")
        msg = json.loads(raw)
        assert msg["type"] == "error"
        assert msg["msg"] == "ADC overflow"
        assert msg["v"] == 1


class TestEncodeRounding:
    def test_sensor_floats_rounded_to_4dp(self):
        raw = protocol.encode_sensor(cl=0.123456789, fl=0.987654321)
        msg = json.loads(raw)
        # round() in Python rounds to 4 decimal places
        assert msg["cl"] == round(0.123456789, 4)
        assert msg["fl"] == round(0.987654321, 4)

    def test_sensor_zero_values(self):
        raw = protocol.encode_sensor(cl=0.0, fl=0.0)
        msg = json.loads(raw)
        assert msg["cl"] == 0.0
        assert msg["fl"] == 0.0

    def test_sensor_max_values(self):
        raw = protocol.encode_sensor(cl=1.0, fl=1.0)
        msg = json.loads(raw)
        assert msg["cl"] == 1.0
        assert msg["fl"] == 1.0


class TestDecode:
    def test_decode_valid_flutter_command(self):
        """Simulate a command sent by the Flutter app."""
        raw = json.dumps({"v": 1, "type": "measure"})
        msg = protocol.decode(raw)
        assert msg["type"] == "measure"
        assert msg["v"] == 1

    def test_decode_invalid_json_returns_error(self):
        msg = protocol.decode("not json {{{{")
        assert msg["type"] == "error"
        assert msg["msg"] == "parse_error"

    def test_decode_empty_string_returns_error(self):
        msg = protocol.decode("")
        assert msg["type"] == "error"
        assert msg["msg"] == "parse_error"

    def test_decode_version_mismatch_still_returns_message(self, capsys):
        """A version mismatch logs a warning but still returns the decoded dict."""
        raw = json.dumps({"v": 99, "type": "measure"})
        msg = protocol.decode(raw)
        # Message still returned (degraded tolerance, not a hard reject)
        assert msg["type"] == "measure"
        # Warning was printed
        captured = capsys.readouterr()
        assert "version mismatch" in captured.out.lower() or "WARNING" in captured.out

    def test_decode_missing_version_no_warning(self, capsys):
        """Messages without 'v' (older clients) are accepted silently."""
        raw = json.dumps({"type": "measure"})
        msg = protocol.decode(raw)
        assert msg["type"] == "measure"
        captured = capsys.readouterr()
        # No warning expected for missing v (v is None → condition not triggered)
        assert "version mismatch" not in captured.out.lower()


class TestProtocolVersion:
    def test_protocol_version_is_1(self):
        from config import PROTOCOL_VERSION
        assert PROTOCOL_VERSION == 1

    def test_all_outbound_messages_carry_version(self):
        """Every encode function must include the version field."""
        messages = [
            protocol.encode_sensor(0.5, 0.4),
            protocol.encode_status("waiting"),
            protocol.encode_heartbeat(),
            protocol.encode_error("test error"),
            protocol.encode_cal_ack("0.10", 0, 0.5, 0.4),  # Phase 2 addition
        ]
        for raw in messages:
            msg = json.loads(raw)
            assert "v" in msg, f"Missing 'v' in: {raw}"
            assert msg["v"] == 1, f"Wrong version in: {raw}"
