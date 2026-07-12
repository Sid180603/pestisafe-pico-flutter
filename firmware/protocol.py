# firmware/protocol.py
# Wire-format definitions for all WebSocket messages.
# Single place where the JSON protocol is encoded and decoded.
# Flutter app must mirror these message types exactly.
# All outbound messages include "v": PROTOCOL_VERSION for cross-side validation.

import json
from config import (MSG_SENSOR, MSG_STATUS, MSG_HEARTBEAT, MSG_ERROR,
                    MSG_CAL_ACK, PROTOCOL_VERSION)


def encode_sensor(cl: float, fl: float) -> str:
    """{"v":1,"type":"sensor","cl":1.5023,"fl":1.3891}  — values are TIA voltages in V"""
    return json.dumps({"v": PROTOCOL_VERSION, "type": MSG_SENSOR,
                       "cl": round(cl, 4), "fl": round(fl, 4)})


def encode_status(state: str) -> str:
    """{"v":1,"type":"status","state":"waiting"|"measuring"|"done"|"disconnected"}"""
    return json.dumps({"v": PROTOCOL_VERSION, "type": MSG_STATUS, "state": state})


def encode_heartbeat() -> str:
    """{"v":1,"type":"heartbeat"}"""
    return json.dumps({"v": PROTOCOL_VERSION, "type": MSG_HEARTBEAT})


def encode_error(msg: str) -> str:
    """{"v":1,"type":"error","msg":"..."}"""
    return json.dumps({"v": PROTOCOL_VERSION, "type": MSG_ERROR, "msg": msg})


def encode_cal_ack(level: str, sample: int, cl: float, fl: float) -> str:
    """{"v":1,"type":"cal_ack","level":"0.10","sample":2,"cl":1.5023,"fl":1.3891}  — cl/fl are voltages in V"""
    return json.dumps({"v": PROTOCOL_VERSION, "type": MSG_CAL_ACK,
                       "level": level, "sample": sample,
                       "cl": round(cl, 4), "fl": round(fl, 4)})


def decode(raw: str) -> dict:
    """Parse an incoming JSON string from Flutter. Returns error dict on failure.
    Logs a warning if the sender's protocol version does not match ours."""
    try:
        msg = json.loads(raw)
        v = msg.get("v")
        if v is not None and v != PROTOCOL_VERSION:
            print(f"[PROTOCOL] WARNING: version mismatch — expected {PROTOCOL_VERSION}, got {v}")
        return msg
    except Exception:
        return {"type": MSG_ERROR, "msg": "parse_error"}
