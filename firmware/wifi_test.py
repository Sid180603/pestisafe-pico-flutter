# wifi_test.py — minimal AP bring-up to isolate the "invisible AP" problem.
# No asyncio, no microdot, no display — just the radio.
import network
import time

SSID = "PestiSafe_AP"
PWD = "pestisafe2024"
COUNTRY = "IN"

print("[TEST] setting country:", COUNTRY)
try:
    network.country(COUNTRY)
except Exception as e:
    print("[TEST] country() failed:", e)

ap = network.WLAN(network.AP_IF)

# Configure BEFORE activating (some CYW43 builds need this order).
ap.config(essid=SSID, password=PWD)
ap.active(True)

# Wait for the interface to report active.
t0 = time.ticks_ms()
while not ap.active():
    time.sleep_ms(100)
    if time.ticks_diff(time.ticks_ms(), t0) > 5000:
        print("[TEST] timeout waiting for active")
        break

# Re-apply config after active (belt and braces).
ap.config(essid=SSID, password=PWD)

print("[TEST] AP active:", ap.active())
print("[TEST] essid:", ap.config("essid"))
print("[TEST] channel:", ap.config("channel"))
print("[TEST] ifconfig:", ap.ifconfig())

# Keep the script alive so the radio keeps beaconing; print status each loop.
n = 0
while True:
    n += 1
    try:
        print("[TEST] alive", n, "active=", ap.active(), "ch=", ap.config("channel"))
    except Exception as e:
        print("[TEST] loop error:", e)
    time.sleep(3)
