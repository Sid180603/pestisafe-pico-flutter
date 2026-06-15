# firmware/tests/test_sensor.py
# Unit tests for the _median() helper in sensor.py.
# DualSensor itself is tested via end-to-end (firmware on PC reads simulated ADC).
# Run from firmware/ directory: python -m pytest tests/
# or from project root: python -m pytest firmware/tests/

import pytest
from sensor import _median


class TestMedianOddCount:
    def test_three_sorted(self):
        assert _median([1, 2, 3]) == 2

    def test_three_unsorted(self):
        assert _median([3, 1, 2]) == 2

    def test_five_typical(self):
        assert _median([44, 45, 45, 46, 91]) == 45

    def test_single_element(self):
        assert _median([42]) == 42

    def test_five_all_same(self):
        assert _median([7, 7, 7, 7, 7]) == 7


class TestMedianEvenCount:
    def test_two_elements(self):
        assert _median([1, 3]) == 2.0

    def test_four_elements(self):
        assert _median([1, 2, 3, 4]) == 2.5

    def test_four_unsorted(self):
        assert _median([4, 1, 3, 2]) == 2.5

    def test_six_elements(self):
        assert _median([10, 20, 30, 40, 50, 60]) == 35.0


class TestMedianOutlierRejection:
    def test_single_high_spike_rejected(self):
        """ADC spike (e.g., 65535) must not pull the median."""
        samples = [100, 102, 101, 99, 65535]
        result = _median(samples)
        assert result == 101  # spike at 65535 has no effect on median

    def test_single_low_spike_rejected(self):
        """Near-zero spike (e.g., stuck pin) must not pull the median."""
        samples = [100, 102, 101, 99, 0]
        # Sorted: [0, 99, 100, 101, 102] → median at index 2 = 100
        result = _median(samples)
        assert result == 100

    def test_two_outliers_out_of_five(self):
        """With 5 samples, 2 outliers still don't affect median (picks 3rd)."""
        samples = [0, 0, 100, 65535, 65535]
        result = _median(samples)
        assert result == 100


class TestMedianNormalization:
    def test_adc_max_normalises_to_1(self):
        """65535 / 65535 = 1.0 — ensure integer division doesn't truncate."""
        from config import ADC_MAX
        normalised = _median([ADC_MAX] * 5) / ADC_MAX
        assert abs(normalised - 1.0) < 1e-9

    def test_adc_mid_normalises_correctly(self):
        from config import ADC_MAX
        mid = ADC_MAX // 2
        normalised = _median([mid] * 5) / ADC_MAX
        assert abs(normalised - 0.5) < 0.001


class TestMedianEdgeCases:
    def test_all_zeros(self):
        assert _median([0, 0, 0, 0, 0]) == 0

    def test_large_values(self):
        assert _median([60000, 61000, 62000, 63000, 64000]) == 62000

    def test_floats(self):
        result = _median([1.5, 2.5, 3.5])
        assert abs(result - 2.5) < 1e-9
