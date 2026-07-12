// lib/app_state.dart
// Central app state — single ChangeNotifier that lives above all screens.
// Holds the active DeviceConnection, calibration coefficients, and selected pesticide.
// All calibration values (including R²) and the selected pesticide are persisted
// to SharedPreferences so they survive app restarts.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/device_connection.dart';

class AppState extends ChangeNotifier {
  // ── Device Connection ────────────────────────────────────────────────────
  DeviceConnection? _connection;

  DeviceConnection? get connection => _connection;
  bool get isConnected => _connection?.isConnected ?? false;

  /// Store a newly established connection and notify listeners.
  void setConnection(DeviceConnection conn) {
    _connection = conn;
    notifyListeners();
  }

  /// Close the connection and clear state.
  Future<void> clearConnection() async {
    await _connection?.disconnect();
    _connection = null;
    isDevMode = false;
    notifyListeners();
  }

  // ── Calibration Coefficients ─────────────────────────────────────────────
  // Model: V = slope · C + intercept  (voltage on Y, concentration on X)
  // Measurement inversion: C = (V − intercept) / slope
  double clSlope = 0;
  double clIntercept = 0;
  double flSlope = 0;
  double flIntercept = 0;
  double clR2 = 0;
  double flR2 = 0;

  /// True when the stored calibration was accepted via "Proceed Anyway"
  /// despite R² being below the 0.95 minimum. Measurements taken under such a
  /// calibration are tagged low-confidence in the history database.
  bool calibrationLowConfidence = false;

  /// True once a successful calibration has been stored.
  bool get isCalibrated => clR2 > 0 && flR2 > 0;

  /// Persist calibration results and notify all listeners.
  /// Optionally sets [pesticide] at the same time, avoiding a redundant
  /// second call to [setSelectedPesticide] (and a second disk write).
  void updateCalibration({
    required double clSlope,
    required double clIntercept,
    required double flSlope,
    required double flIntercept,
    required double clR2,
    required double flR2,
    String? pesticide,
    bool lowConfidence = false,
  }) {
    this.clSlope     = clSlope;
    this.clIntercept = clIntercept;
    this.flSlope     = flSlope;
    this.flIntercept = flIntercept;
    this.clR2        = clR2;
    this.flR2        = flR2;
    calibrationLowConfidence = lowConfidence;
    if (pesticide != null) selectedPesticide = pesticide;
    notifyListeners();
    _saveToPrefs(); // single write covers both coefficients and pesticide
  }

  // ── Pesticide / Commodity Selection ──────────────────────────────────────
  String? selectedPesticide;

  /// Set the selected pesticide and persist it.
  /// Use the [pesticide] parameter on [updateCalibration] instead when updating
  /// both at the same time (avoids a redundant extra disk write).
  void setSelectedPesticide(String name) {
    selectedPesticide = name;
    notifyListeners();
    _saveToPrefs();
  }

  // ── Dev Mode ──────────────────────────────────────────────────────────────
  /// True when connected via Dev Mode (127.0.0.1 mock server).
  /// Bypasses R² quality checks in CalibrationScreen so mock data
  /// (which is random and will never reach 0.95) can proceed freely.
  bool isDevMode = false;

  void setDevMode(bool val) {
    isDevMode = val;
    notifyListeners();
  }

  // ── Unit Selection (ppm / ppb) ────────────────────────────────────────────
  String selectedUnit = 'ppm'; // 'ppm' or 'ppb'

  /// Set the display/entry unit and persist it.
  void setSelectedUnit(String unit) {
    selectedUnit = unit;
    notifyListeners();
    _saveToPrefs();
  }

  void clearCalibration() {
    clSlope = clIntercept = flSlope = flIntercept = 0;
    clR2 = flR2 = 0;
    calibrationLowConfidence = false;
    selectedPesticide = null;
    selectedUnit = 'ppm';
    notifyListeners();
    _clearPrefs();
  }

  // ── SharedPreferences persistence ────────────────────────────────────────

  Future<void> _saveToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('cl_slope',      clSlope);
    await prefs.setDouble('cl_intercept',  clIntercept);
    await prefs.setDouble('fl_slope',      flSlope);
    await prefs.setDouble('fl_intercept',  flIntercept);
    await prefs.setDouble('cl_r2',         clR2);
    await prefs.setDouble('fl_r2',         flR2);
    await prefs.setBool('cal_low_confidence', calibrationLowConfidence);
    if (selectedPesticide != null) {
      await prefs.setString('selected_pesticide', selectedPesticide!);
    }
    await prefs.setString('selected_unit', selectedUnit);
  }

  Future<void> _clearPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in ['cl_slope','cl_intercept','fl_slope','fl_intercept',
                     'cl_r2','fl_r2','cal_low_confidence',
                     'selected_pesticide','selected_unit']) {
      await prefs.remove(k);
    }
  }

  /// Load previously saved calibration from SharedPreferences.
  /// No-op if no coefficients are stored (fresh install or after clear).
  Future<void> loadSavedCalibration() async {
    final prefs = await SharedPreferences.getInstance();
    final savedCl = prefs.getDouble('cl_slope');
    final savedFl = prefs.getDouble('fl_slope');
    if (savedCl == null || savedFl == null) return; // nothing saved yet
    clSlope     = savedCl;
    clIntercept = prefs.getDouble('cl_intercept') ?? 0;
    flSlope     = savedFl;
    flIntercept = prefs.getDouble('fl_intercept') ?? 0;
    clR2        = prefs.getDouble('cl_r2') ?? 0;
    flR2        = prefs.getDouble('fl_r2') ?? 0;
    calibrationLowConfidence = prefs.getBool('cal_low_confidence') ?? false;
    selectedPesticide = prefs.getString('selected_pesticide');
    selectedUnit = prefs.getString('selected_unit') ?? 'ppm';
    notifyListeners();
  }
}
