# firmware/server.py
# Microdot WebSocket server — Flutter connects to ws://<ip>:8080/ws
#
# PC setup:  pip install microdot   (installs the asyncio-compatible version)
# Pico setup: copy microdot.py + microdot/websocket.py from
#             https://github.com/miguelgrinberg/microdot  to the Pico filesystem

import asyncio
from microdot import Microdot                      # type: ignore
from microdot.websocket import with_websocket      # type: ignore

import protocol
from sensor import read_sensors
from config import WIFI_HOST, WIFI_PORT, MSG_CAL_END

app = Microdot()

# Active WebSocket connections (broadcast support)
_clients: list = []

# Shared state — read by main.py display_task for TFT display
_state: dict = {
    "mode":      "waiting",   # "waiting" | "measuring" | "calibrating"
    "last_cl":   0.0,         # most recent normalised CL reading
    "last_fl":   0.0,         # most recent normalised FL reading
    "cal_level": "",          # active calibration concentration label (e.g. "0.10")
}


async def _broadcast(msg: str):
    """Send a message to all connected clients; silently drop dead ones."""
    dead = []
    for ws in list(_clients):
        try:
            await ws.send(msg)
        except Exception:
            dead.append(ws)
    for ws in dead:
        _clients.remove(ws)


@app.route("/ws")
@with_websocket
async def websocket_handler(request, ws):
    _clients.append(ws)
    await ws.send(protocol.encode_status("waiting"))

    try:
        while True:
            raw = await ws.receive()
            if raw is None:
                break
            msg = protocol.decode(raw)
            cmd = msg.get("type", "")

            if cmd == "measure":
                _state["mode"] = "measuring"
                await _broadcast(protocol.encode_status("measuring"))
                cl, fl = await read_sensors()
                _state["last_cl"] = cl
                _state["last_fl"] = fl
                # Sensor data goes only to the requesting client; status
                # broadcasts are global so all connected UIs stay in sync.
                await ws.send(protocol.encode_sensor(cl, fl))
                _state["mode"] = "waiting"
                await _broadcast(protocol.encode_status("waiting"))

            elif cmd == "heartbeat":
                await ws.send(protocol.encode_heartbeat())

            elif cmd == "cal_start":
                level = msg.get("level", "")
                _state["mode"] = "calibrating"
                _state["cal_level"] = level
                await _broadcast(protocol.encode_status("calibrating"))

            elif cmd == "cal_sample":
                level      = msg.get("level", "")
                sample_idx = msg.get("sample", 0)
                cl, fl     = await read_sensors()
                _state["last_cl"] = cl
                _state["last_fl"] = fl
                # Calibration data goes only to the requesting client.
                await ws.send(protocol.encode_cal_ack(level, sample_idx, cl, fl))

            elif cmd == MSG_CAL_END:
                # All calibration levels collected — reset mode so TFT shows waiting.
                _state["mode"] = "waiting"
                _state["cal_level"] = ""
                await _broadcast(protocol.encode_status("waiting"))

    except Exception as exc:
        print(f"[server] websocket_handler error: {exc}")
    finally:
        if ws in _clients:
            _clients.remove(ws)
        _state["mode"] = "waiting"


async def run_server():
    """Start the Microdot server. Called from main.py via asyncio.gather()."""
    await app.start_server(host=WIFI_HOST, port=WIFI_PORT, debug=False)
