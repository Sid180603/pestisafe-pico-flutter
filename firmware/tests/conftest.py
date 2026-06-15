# firmware/tests/conftest.py
# Adds the firmware/ directory to sys.path so test files can import
# firmware modules (config, protocol, sensor) directly by name,
# mirroring the import style used by the firmware itself.

import sys
import os

# __file__ → .../firmware/tests/conftest.py
# parent   → .../firmware/
# grandparent → project root (not needed, but firmware/ must be in path)
_FIRMWARE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _FIRMWARE_DIR not in sys.path:
    sys.path.insert(0, _FIRMWARE_DIR)
