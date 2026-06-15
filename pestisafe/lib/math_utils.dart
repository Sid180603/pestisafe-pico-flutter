// lib/math_utils.dart
// Pure math functions — no Flutter dependencies, fully unit-testable.
// Used by CalibrationScreen (linearFit) and MeasurementScreen (flPreferred).
//
// WHY a linear fit (not a polynomial):
//   Beer-Lambert law: A = ε·c·l, where A = absorbance, ε = molar absorptivity,
//   c = concentration, l = path length. Because ε and l are constants of the
//   optical cell, A is strictly linear in c. A polynomial would introduce
//   curvature that has no physical basis and would overfit the small calibration
//   set (4–8 points), inflating R² without improving prediction accuracy.
//
// WHY FL is preferred over CL when they disagree:
//   Fluorescence emission is measured against a near-zero background (excitation
//   wavelength is filtered out), whereas colorimetry measures transmitted light
//   against a bright baseline. At sub-ppm concentrations the FL signal-to-noise
//   ratio is therefore 10–100× higher than CL, making FL the more reliable
//   reading when the two channels diverge. CL is retained as a corroborating
//   channel; when both agree within 5 % their average reduces random noise.

/// Least-squares linear fit for calibration curve.
///
/// [x] = normalised ADC readings (0–1), [y] = known concentrations in ppm (mg/kg).
/// Returns [slope, intercept, r²] such that  y ≈ slope·x + intercept.
///
/// Scientific rationale: Beer-Lambert law states that absorbance is linearly
/// proportional to concentration (A = ε·c·l). A linear fit is therefore the
/// correct model for this system — a polynomial would overfit the small N
/// calibration set and have no physical basis.
List<double> linearFit(List<double> x, List<double> y) {
  final n = x.length;
  if (n < 2) return [0.0, y.isNotEmpty ? y[0] : 0.0, 0.0];

  double sx = 0, sy = 0, sxx = 0, sxy = 0;
  for (int i = 0; i < n; i++) {
    sx  += x[i];
    sy  += y[i];
    sxx += x[i] * x[i];
    sxy += x[i] * y[i];
  }
  final denom = n * sxx - sx * sx;
  if (denom.abs() < 1e-12) return [0.0, sy / n, 0.0];

  final m = (n * sxy - sx * sy) / denom;
  final b = (sy - m * sx) / n;

  // R² = 1 − SS_res / SS_tot
  final yMean = sy / n;
  double ssTot = 0, ssRes = 0;
  for (int i = 0; i < n; i++) {
    ssTot += (y[i] - yMean) * (y[i] - yMean);
    final yHat = m * x[i] + b;
    ssRes += (y[i] - yHat) * (y[i] - yHat);
  }
  final r2 = ssTot < 1e-12 ? 1.0 : 1.0 - ssRes / ssTot;
  return [m, b, r2];
}

/// FL-preferred dual-mode agreement rule (professor's specification).
///
/// If |CL − FL| / mean ≤ [threshold] (default 5 %) → modes agree → use average.
/// If > [threshold]                                  → modes disagree → use FL only.
/// Edge case: both values near zero → treated as agreement.
///
/// Returns a record: (avgConc, agreementOk).
///
/// Scientific rationale: Fluorescence (FL) is intrinsically more sensitive to
/// trace organophosphate residues than colorimetric (CL) absorbance because it
/// measures emitted photons rather than transmitted ones, giving a higher
/// signal-to-noise ratio at sub-ppm concentrations. CL is retained as a
/// corroborating channel; when both agree the average reduces random noise,
/// but FL is the authoritative reading when they diverge.
({double avgConc, bool agreementOk}) flPreferred(
  double concCL,
  double concFL, {
  double threshold = 0.05,
}) {
  final provisionalMean = (concCL + concFL) / 2.0;
  if (provisionalMean.abs() <= 1e-6) {
    // Both near-zero — agreement by definition.
    return (avgConc: provisionalMean, agreementOk: true);
  }
  final relDiff = (concCL - concFL).abs() / provisionalMean.abs();
  final ok = relDiff <= threshold;
  return (avgConc: ok ? provisionalMean : concFL, agreementOk: ok);
}
