# firmware/sensor.py
# Reads CL and FL ADC channels with median filtering (noise reduction).
# Returns TIA output voltages in [0, ADC_VREF] V — NOT normalised ratios.
# The calibration curve is V = m·C + b (voltage on Y, concentration on X),
# so firmware reports physical volts and the app inverts C = (V − b) / m.

import asyncio
from config import CL_ADC_PIN, FL_ADC_PIN, ADC_SAMPLES, ADC_MAX, ADC_VREF
from hal import ADCChannel


def _median(values):
    """Return the median of a list of numbers."""
    s = sorted(values)
    n = len(s)
    mid = n // 2
    return s[mid] if n % 2 else (s[mid - 1] + s[mid]) / 2.0


async def read_sensors(samples=ADC_SAMPLES, conc=None):
    """
    Collect `samples` readings from both ADC channels with a short delay between
    each, apply median filter, and return (cl_volts, fl_volts) as floats in
    [0, ADC_VREF] (i.e. 0–3.3 V).

    conc (float, ppm) is forwarded to the ADC stub on PC (Option B simulator) so
    calibration calls produce a realistic linear voltage-vs-concentration curve
    for hardware-free demos.  On real Pico hardware conc is silently ignored.
    """
    cl_adc = ADCChannel(CL_ADC_PIN)
    fl_adc = ADCChannel(FL_ADC_PIN)

    cl_raw = []
    fl_raw = []

    for _ in range(samples):
        cl_raw.append(cl_adc.read_u16(conc))
        fl_raw.append(fl_adc.read_u16(conc))
        await asyncio.sleep(0.05)   # 50 ms between samples

    cl_volts = round(_median(cl_raw) / ADC_MAX * ADC_VREF, 4)
    fl_volts = round(_median(fl_raw) / ADC_MAX * ADC_VREF, 4)
    return cl_volts, fl_volts
