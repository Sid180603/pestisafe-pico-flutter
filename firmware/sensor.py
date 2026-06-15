# firmware/sensor.py
# Reads CL and FL ADC channels with median filtering (noise reduction).
# Returns normalised floats in [0.0, 1.0].

import asyncio
from config import CL_ADC_PIN, FL_ADC_PIN, ADC_SAMPLES, ADC_MAX
from hal import ADCChannel


def _median(values):
    """Return the median of a list of numbers."""
    s = sorted(values)
    n = len(s)
    mid = n // 2
    return s[mid] if n % 2 else (s[mid - 1] + s[mid]) / 2.0


async def read_sensors(samples=ADC_SAMPLES):
    """
    Collect `samples` readings from both ADC channels with a short delay between
    each, apply median filter, and return (cl_norm, fl_norm) as floats in [0, 1].
    """
    cl_adc = ADCChannel(CL_ADC_PIN)
    fl_adc = ADCChannel(FL_ADC_PIN)

    cl_raw = []
    fl_raw = []

    for _ in range(samples):
        cl_raw.append(cl_adc.read_u16())
        fl_raw.append(fl_adc.read_u16())
        await asyncio.sleep(0.05)   # 50 ms between samples

    cl_norm = round(_median(cl_raw) / ADC_MAX, 4)
    fl_norm = round(_median(fl_raw) / ADC_MAX, 4)
    return cl_norm, fl_norm
