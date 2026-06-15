// test/math_utils_test.dart
// Unit tests for linearFit() and flPreferred() in lib/math_utils.dart.
// Pure Dart — no Flutter dependencies, no assets required.

import 'package:flutter_test/flutter_test.dart';
import 'package:pestisafe/math_utils.dart';

void main() {
  // ── linearFit ──────────────────────────────────────────────────────────────

  group('linearFit', () {
    test('known 4-point data produces correct slope, intercept, R²', () {
      // y = 2x + 1  →  slope=2, intercept=1, R²=1.0
      final x = [0.0, 1.0, 2.0, 3.0];
      final y = [1.0, 3.0, 5.0, 7.0];
      final fit = linearFit(x, y);
      expect(fit[0], closeTo(2.0, 1e-9));   // slope
      expect(fit[1], closeTo(1.0, 1e-9));   // intercept
      expect(fit[2], closeTo(1.0, 1e-9));   // R²
    });

    test('perfect linear data gives R² == 1.0', () {
      final x = [0.1, 0.3, 0.6, 0.9];
      final y = [0.5, 1.5, 3.0, 4.5];
      final fit = linearFit(x, y);
      expect(fit[2], closeTo(1.0, 1e-6));
    });

    test('single point returns [0, y, 0]', () {
      final fit = linearFit([0.5], [3.0]);
      expect(fit[0], closeTo(0.0, 1e-9));
      expect(fit[1], closeTo(3.0, 1e-9));
      expect(fit[2], closeTo(0.0, 1e-9));
    });

    test('all-same x values returns [0, mean_y, 0]', () {
      final fit = linearFit([0.5, 0.5, 0.5], [1.0, 2.0, 3.0]);
      expect(fit[0], closeTo(0.0, 1e-9));   // slope undefined → 0
      expect(fit[1], closeTo(2.0, 1e-9));   // mean of y
      expect(fit[2], closeTo(0.0, 1e-9));   // R² undefined → 0
    });

    test('noisy data gives R² between 0 and 1', () {
      final x = [0.0, 1.0, 2.0, 3.0];
      final y = [1.1, 2.9, 5.2, 6.8];
      final fit = linearFit(x, y);
      expect(fit[2], greaterThan(0.9));
      expect(fit[2], lessThanOrEqualTo(1.0));
    });
  });

  // ── flPreferred ────────────────────────────────────────────────────────────

  group('flPreferred', () {
    test('|diff|/mean ≤ 5% → agrees, returns average', () {
      // diff = 0.04, mean = 1.02, relDiff ≈ 0.039 ≤ 0.05
      final r = flPreferred(1.00, 1.04);
      expect(r.agreementOk, isTrue);
      expect(r.avgConc, closeTo(1.02, 1e-9));
    });

    test('|diff|/mean > 5% → disagrees, returns FL value', () {
      // diff = 0.2, mean = 1.1, relDiff ≈ 0.182 > 0.05
      final r = flPreferred(1.0, 1.2);
      expect(r.agreementOk, isFalse);
      expect(r.avgConc, closeTo(1.2, 1e-9)); // FL value
    });

    test('both near-zero → agrees', () {
      final r = flPreferred(0.0, 0.0);
      expect(r.agreementOk, isTrue);
      expect(r.avgConc, closeTo(0.0, 1e-9));
    });

    test('exactly at 5% boundary → agrees (≤ not <)', () {
      // |diff|/mean == 0.05 exactly → should agree
      // diff = 0.05, mean = 1.025 → relDiff = 0.05/1.025 ≠ 0.05
      // Use values where relDiff is exactly 0.05:
      //   CL=1.0, FL=x: |1-x|/((1+x)/2) = 0.05
      //   |1-x| = 0.05*(1+x)/2 → 2|1-x| = 0.05+0.05x
      //   Assume x>1: 2(x-1) = 0.05+0.05x → 2x-2=0.05+0.05x → 1.95x=2.05 → x≈1.05128
      // Let's just use a value that lands cleanly at the threshold:
      // CL=0.975, FL=1.025: mean=1.0, diff=0.05, relDiff=0.05 → agrees
      final r = flPreferred(0.975, 1.025);
      expect(r.agreementOk, isTrue);
    });

    test('custom threshold respected', () {
      // With threshold=0.10, 8% diff should agree
      // diff=0.08, mean=1.04, relDiff≈0.077 < 0.10
      final r = flPreferred(1.0, 1.08, threshold: 0.10);
      expect(r.agreementOk, isTrue);
    });

    test('FL value used when mismatch, regardless of sign', () {
      // CL > FL mismatch — still returns FL
      final r = flPreferred(1.5, 1.0);
      expect(r.agreementOk, isFalse);
      expect(r.avgConc, closeTo(1.0, 1e-9));
    });
  });
}
