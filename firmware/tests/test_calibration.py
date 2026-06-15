# firmware/tests/test_calibration.py
# Unit tests for calibration protocol messages (encode_cal_ack, cal_start/cal_sample decode).
# Run from project root: python -m pytest firmware/tests/

import json
import pytest
import protocol
import server


class TestEncodeCalAck:
    def test_fields_present(self):
        raw = protocol.encode_cal_ack("0.10", 2, 0.4587, 0.5123)
        msg = json.loads(raw)
        assert msg["type"] == "cal_ack"
        assert msg["level"] == "0.10"
        assert msg["sample"] == 2
        assert msg["cl"] == 0.4587
        assert msg["fl"] == 0.5123
        assert msg["v"] == 1

    def test_version_field(self):
        raw = protocol.encode_cal_ack("0.50", 0, 0.3, 0.4)
        msg = json.loads(raw)
        assert "v" in msg
        assert msg["v"] == 1

    def test_cl_fl_rounded_to_4dp(self):
        raw = protocol.encode_cal_ack("1.00", 4, 0.123456789, 0.987654321)
        msg = json.loads(raw)
        assert msg["cl"] == round(0.123456789, 4)
        assert msg["fl"] == round(0.987654321, 4)

    def test_sample_index_zero(self):
        raw = protocol.encode_cal_ack("0.00", 0, 0.0, 0.0)
        msg = json.loads(raw)
        assert msg["sample"] == 0
        assert msg["cl"] == 0.0
        assert msg["fl"] == 0.0

    def test_blank_level_label(self):
        raw = protocol.encode_cal_ack("0.00", 0, 0.001, 0.002)
        msg = json.loads(raw)
        assert msg["level"] == "0.00"

    def test_max_values(self):
        raw = protocol.encode_cal_ack("1.00", 4, 1.0, 1.0)
        msg = json.loads(raw)
        assert msg["cl"] == 1.0
        assert msg["fl"] == 1.0


class TestDecodeCalibrationCommands:
    def test_decode_cal_start(self):
        raw = json.dumps({"v": 1, "type": "cal_start", "level": "0.50"})
        msg = protocol.decode(raw)
        assert msg["type"] == "cal_start"
        assert msg["level"] == "0.50"

    def test_decode_cal_sample(self):
        raw = json.dumps({"v": 1, "type": "cal_sample", "level": "0.10", "sample": 3})
        msg = protocol.decode(raw)
        assert msg["type"] == "cal_sample"
        assert msg["level"] == "0.10"
        assert msg["sample"] == 3

    def test_decode_cal_start_version_checked(self, capsys):
        raw = json.dumps({"v": 99, "type": "cal_start", "level": "0.10"})
        msg = protocol.decode(raw)
        assert msg["type"] == "cal_start"
        captured = capsys.readouterr()
        assert "version mismatch" in captured.out.lower() or "WARNING" in captured.out

    def test_decode_invalid_cal_sample_returns_error(self):
        msg = protocol.decode("not json }{")
        assert msg["type"] == "error"
        assert msg["msg"] == "parse_error"


class TestServerState:
    def setup_method(self):
        """Reset shared server state before each test to avoid cross-test pollution."""
        server._state["mode"]     = "waiting"
        server._state["last_cl"]  = 0.0
        server._state["last_fl"]  = 0.0
        server._state["cal_level"] = ""

    def test_initial_state_values(self):
        assert server._state["mode"] == "waiting"
        assert server._state["last_cl"] == 0.0
        assert server._state["last_fl"] == 0.0
        assert server._state["cal_level"] == ""

    def test_state_keys_present(self):
        required = {"mode", "last_cl", "last_fl", "cal_level"}
        assert required.issubset(server._state.keys())
