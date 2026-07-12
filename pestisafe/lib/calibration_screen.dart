// lib/calibration_screen.dart
// N-level calibration: Blank (0.00 fixed) + N user-entered concentrations.
// Starts with 3 levels (Low/Mid/High, default 0.10/0.50/1.00) and can grow.
// Supports ppm and ppb entry. 10-second stabilisation delay before each level.
// Tiered R² acceptance: ≥0.99 excellent, 0.95–0.99 warn+offer add-point,
// <0.95 blocks and requires add-point or full recalibration.

import 'dart:async';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_state.dart';
import 'math_utils.dart';
import 'mrl_data.dart';
import 'protocol.dart';
import 'measurement_screen.dart';

class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({super.key});

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  // ── Calibration constants ──────────────────────────────────────────────────
  // 5 samples per level: enough to suppress single-point ADC noise via averaging
  // while keeping each level collection under 3 seconds. Analytical chemistry
  // triplicate (n=3) is the accepted minimum; 5 adds one guard against outliers
  // without requiring median filtering or a longer dwell time.
  static const int _samplesPerLevel = 5;

  // ── User-editable concentration controllers (dynamic — grows with add-point) ─
  final List<TextEditingController> _concControllers = [
    TextEditingController(text: '0.10'),
    TextEditingController(text: '0.50'),
    TextEditingController(text: '1.00'),
  ];

  List<String> get _levelNames => [
    'Blank',
    for (int i = 0; i < _concControllers.length; i++) 'Std ${i + 1}',
  ];

  List<double> get _concentrations => [
    0.00,
    ..._concControllers.map(
      (c) => (double.tryParse(c.text.trim()) ?? 0.0) * _toPpm,
    ),
  ];

  // ── Unit helpers (read from AppState) ─────────────────────────────────────
  String get _unit =>
      Provider.of<AppState>(context, listen: false).selectedUnit;

  /// User-entered value → internal ppm.
  double get _toPpm =>
      Provider.of<AppState>(context, listen: false).selectedUnit == 'ppb'
          ? 0.001
          : 1.0;

  /// Internal ppm → display unit.
  double get _fromPpm =>
      Provider.of<AppState>(context, listen: false).selectedUnit == 'ppb'
          ? 1000.0
          : 1.0;

  // ── Pesticide selection ────────────────────────────────────────────────────
  late String _selectedPesticide;

  // ── Calibration state ──────────────────────────────────────────────────────
  final List<double> _clMeans = [];
  final List<double> _flMeans = [];

  int  _currentLevel       = 0;
  int  _sampleCount        = 0;
  bool _collecting         = false;
  bool _calibrated         = false;
  bool _stabilizing        = false; // true during 10-second countdown
  int  _stabilizeRemain    = 0;     // seconds left in countdown
  bool _showAddPointOption = false;
  bool _allowProceedAnyway = false; // true when R² < 0.95 in production mode
  String? _warning;

  double _clSlope = 0, _clIntercept = 0, _clR2 = 0;
  double _flSlope = 0, _flIntercept = 0, _flR2 = 0;

  StreamSubscription<String>? _sub;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    // Default pesticide to first in the loaded MRL table.
    _selectedPesticide = MrlData.pesticideNames.first;

    // Restore saved pesticide/calibration from previous session.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final appState = Provider.of<AppState>(context, listen: false);
      appState.loadSavedCalibration().then((_) {
        if (!mounted) return; // guard: widget may be disposed before future resolves
        if (appState.selectedPesticide != null &&
            MrlData.pesticideNames.contains(appState.selectedPesticide)) {
          setState(() => _selectedPesticide = appState.selectedPesticide!);
        }
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    for (final c in _concControllers) {
      c.dispose();
    }
    super.dispose();
  }

  // ── Calibration logic ──────────────────────────────────────────────────────

  Future<void> _collectLevel() async {
    final conn = Provider.of<AppState>(context, listen: false).connection;
    if (conn == null) {
      setState(() => _warning = 'Not connected. Go back and reconnect.');
      return;
    }

    final concs      = _concentrations;
    final levelLabel = concs[_currentLevel].toStringAsFixed(2);

    setState(() {
      _collecting  = true;
      _sampleCount = 0;
      _warning     = null;
    });

    double clSum = 0, flSum = 0;
    int received = 0;
    final completer = Completer<void>();

    _sub = conn.messages.listen((raw) {
      if (!mounted) return;
      try {
        final msg = Protocol.decode(raw);
        final ack = Protocol.parseCalAck(msg);
        if (ack != null) {
          clSum += ack.cl;
          flSum += ack.fl;
          received++;
          setState(() => _sampleCount = received);
          if (received >= _samplesPerLevel && !completer.isCompleted) {
            completer.complete();
          }
        }
      } on FormatException catch (_) {}
    });

    // Notify firmware that calibration for this level is starting.
    await conn.send(Protocol.encodeCalStart(levelLabel));

    // 10-second stabilisation delay — let the standard settle in the cuvette.
    for (int s = 10; s > 0; s--) {
      if (!mounted) return;
      setState(() {
        _stabilizing     = true;
        _stabilizeRemain = s;
      });
      await Future.delayed(const Duration(seconds: 1));
    }
    if (!mounted) return;
    setState(() => _stabilizing = false);

    // Request _samplesPerLevel readings, 400 ms apart.
    for (int i = 0; i < _samplesPerLevel; i++) {
      if (!completer.isCompleted) {
        await conn.send(Protocol.encodeCalSample(levelLabel, i));
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }

    // Wait up to 15 s for any still-in-flight responses.
    await completer.future.timeout(const Duration(seconds: 15), onTimeout: () {});
    await _sub?.cancel();
    _sub = null;

    if (!mounted) return;

    if (received >= _samplesPerLevel) {
      _clMeans.add(clSum / received);
      _flMeans.add(flSum / received);
      setState(() {
        _collecting = false;
        if (_currentLevel < _concentrations.length - 1) {
          _currentLevel++;
        }
      });
    } else {
      setState(() {
        _collecting = false;
        _warning = 'Only $received/$_samplesPerLevel readings received for '
            '${_levelNames[_currentLevel]}. '
            'Check the connection and tap Collect again.';
      });
    }
  }

  void _computeCalibration() {
    final concs = _concentrations;
    // x = known concentrations (ppm internally), y = measured TIA voltages (V)
    // Model: V = m·C + b  →  slope = V per ppm, intercept = blank voltage
    final clFit = linearFit(concs.sublist(0, _clMeans.length), _clMeans);
    final flFit = linearFit(concs.sublist(0, _flMeans.length), _flMeans);

    _clSlope = clFit[0]; _clIntercept = clFit[1]; _clR2 = clFit[2];
    _flSlope = flFit[0]; _flIntercept = flFit[1]; _flR2 = flFit[2];

    final minR2 = _clR2 < _flR2 ? _clR2 : _flR2;
    final devMode = Provider.of<AppState>(context, listen: false).isDevMode;

    if (devMode) {
      // Dev mode: skip R² quality checks — mock server returns random ADC
      // values that will never produce a meaningful R².
      _showAddPointOption = false;
      _allowProceedAnyway = false;
      _warning = 'Dev mode — R² check bypassed (R² = ${minR2.toStringAsFixed(4)})';
    } else if (minR2 < 0.95) {
      // Below minimum — block proceeding; offer add-point, recalibrate, or
      // an explicit "Proceed Anyway" override (guarded by a confirmation).
      _calibrated = false;
      _showAddPointOption = true;
      _allowProceedAnyway = true;
      _warning = 'R² = ${minR2.toStringAsFixed(4)} (below 0.95). '
          'Add another calibration point, recalibrate, or proceed anyway.';
      setState(() {});
      return;
    } else if (minR2 < 0.99) {
      // Acceptable but not ideal — warn and offer improvement.
      _showAddPointOption = true;
      _allowProceedAnyway = false;
      _warning = 'R² = ${minR2.toStringAsFixed(4)} (below 0.99). '
          'Consider adding a point to improve linearity.';
    } else {
      // Excellent.
      _showAddPointOption = false;
      _allowProceedAnyway = false;
      _warning = null;
    }

    _calibrated = true;

    final appState = Provider.of<AppState>(context, listen: false);
    // Single call persists pesticide + coefficients in one SharedPreferences write.
    appState.updateCalibration(
      clSlope:     _clSlope,
      clIntercept: _clIntercept,
      flSlope:     _flSlope,
      flIntercept: _flIntercept,
      clR2:        _clR2,
      flR2:        _flR2,
      pesticide:   _selectedPesticide,
      lowConfidence: false,
    );

    // Tell the firmware calibration is done — resets its TFT display to "waiting".
    appState.connection?.send(Protocol.encodeCalEnd());

    setState(() {});
  }

  /// Override the R² < 0.95 block after an explicit user confirmation.
  /// Persists the coefficients flagged as low-confidence, informs the firmware,
  /// and reveals the normal "Proceed to Measurement" flow.
  Future<void> _proceedAnyway() async {
    final minR2 = _clR2 < _flR2 ? _clR2 : _flR2;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Proceed with low R²?'),
        content: Text(
          'R² = ${minR2.toStringAsFixed(4)} is below the recommended minimum '
          'of 0.95. The calibration line does not fit the data well, so '
          'measurements may be inaccurate.\n\n'
          'These measurements will be tagged "low confidence" in the history. '
          'Proceed anyway?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Proceed Anyway',
                style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final appState = Provider.of<AppState>(context, listen: false);
    appState.updateCalibration(
      clSlope:     _clSlope,
      clIntercept: _clIntercept,
      flSlope:     _flSlope,
      flIntercept: _flIntercept,
      clR2:        _clR2,
      flR2:        _flR2,
      pesticide:   _selectedPesticide,
      lowConfidence: true,
    );
    appState.connection?.send(Protocol.encodeCalEnd());

    setState(() {
      _calibrated = true;
      _showAddPointOption = false;
      _allowProceedAnyway = false;
      _warning = 'Proceeding with low R² = ${minR2.toStringAsFixed(4)} — '
          'measurements are tagged low confidence.';
    });
  }

  /// Append one more calibration level; keep existing collected data.
  void _addCalibrationPoint() {
    setState(() {
      _concControllers.add(TextEditingController(text: ''));
      _calibrated = false;
      _showAddPointOption = false;
      _allowProceedAnyway = false;
      _warning = null;
      _currentLevel = _clMeans.length; // next uncollected level index
    });
  }

  void _reset() {
    Provider.of<AppState>(context, listen: false).clearCalibration();
    // Dispose controllers before setState — calling dispose() inside setState
    // triggers notifyListeners() mid-rebuild and can cause assertion errors.
    for (final c in _concControllers) { c.dispose(); }
    _concControllers
      ..clear()
      ..addAll([
        TextEditingController(text: '0.10'),
        TextEditingController(text: '0.50'),
        TextEditingController(text: '1.00'),
      ]);
    setState(() {
      _clMeans.clear();
      _flMeans.clear();
      _currentLevel       = 0;
      _sampleCount        = 0;
      _collecting         = false;
      _calibrated         = false;
      _stabilizing        = false;
      _stabilizeRemain    = 0;
      _showAddPointOption = false;
      _allowProceedAnyway = false;
      _warning            = null;
      _clSlope = _clIntercept = _clR2 = 0;
      _flSlope = _flIntercept = _flR2 = 0;
    });
  }

  // ── fl_chart helpers ───────────────────────────────────────────────────────

  /// Regression line only — two endpoints, no dots.
  /// The model is V = slope·C + intercept; X axis is concentration in display
  /// units, Y axis is voltage in V.
  LineChartBarData _chartLine(
    List<double> means,
    double slope,
    double intercept,
    Color color,
  ) {
    final concs = _concentrations;
    final n = means.length;
    final scale = _fromPpm;
    // X endpoints in display units; Y = m·C_ppm + b (voltage, no unit scale)
    final xMin = concs.sublist(0, n).reduce((a, b) => a < b ? a : b) * scale;
    final xMax = concs.sublist(0, n).reduce((a, b) => a > b ? a : b) * scale;
    return LineChartBarData(
      spots: [
        FlSpot(xMin, slope * (xMin / scale) + intercept),
        FlSpot(xMax, slope * (xMax / scale) + intercept),
      ],
      color: color,
      isCurved: false,
      barWidth: 1.5,
      dotData: const FlDotData(show: false),
    );
  }

  /// Scatter dots only — no connecting line between points.
  LineChartBarData _chartDots(List<double> means, Color color) {
    final concs = _concentrations;
    final scale = _fromPpm;
    // X = concentration in display units, Y = measured voltage (no scale)
    return LineChartBarData(
      spots: List.generate(
          means.length, (i) => FlSpot(concs[i] * scale, means[i])),
      color: color,
      isCurved: false,
      barWidth: 0,
      dotData: FlDotData(
        show: true,
        getDotPainter: (_, __, ___, ____) =>
            FlDotCirclePainter(radius: 5, color: color),
      ),
    );
  }

  /// Build a single-channel calibration chart (CL or FL).
  Widget _buildSingleChart({
    required List<double> means,
    required double slope,
    required double intercept,
    required Color color,
  }) {
    final unit = _unit;
    return SizedBox(
      height: 180,
      child: LineChart(
        LineChartData(
          gridData: const FlGridData(show: true),
          borderData: FlBorderData(show: true),
          titlesData: FlTitlesData(
            bottomTitles: AxisTitles(
              axisNameWidget: Text('Conc. ($unit)',
                  style: const TextStyle(fontSize: 10)),
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 28,
                getTitlesWidget: (v, _) => Text(
                  v.toStringAsFixed(2),
                  style: const TextStyle(fontSize: 9),
                ),
              ),
            ),
            leftTitles: AxisTitles(
              axisNameWidget: const Text('Voltage (V)',
                  style: TextStyle(fontSize: 10)),
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 36,
                getTitlesWidget: (v, _) => Text(
                  v.toStringAsFixed(2),
                  style: const TextStyle(fontSize: 9),
                ),
              ),
            ),
            topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
          ),
          lineBarsData: [
            _chartLine(means, slope, intercept, color),
            _chartDots(means, color),
          ],
        ),
      ),
    );
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final concs              = _concentrations;
    final allLevelsCollected = _clMeans.length == concs.length;
    // canEdit: allow changing pesticide/unit only before any level is collected.
    final canEdit            = _clMeans.isEmpty && !_collecting;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Calibration'),
        actions: [
          if (_calibrated || _showAddPointOption)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Recalibrate',
              onPressed: _reset,
            ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Step 2 • Calibration',
                style: TextStyle(
                    color: cs.primary, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              const Text(
                'Select pesticide, set concentration levels, then collect each standard.',
                style: TextStyle(fontSize: 13, color: Colors.black54),
              ),
              const SizedBox(height: 12),

              // ── Pesticide + unit selector ──────────────────────────────
              Row(
                children: [
                  const Icon(Icons.biotech_outlined, size: 20),
                  const SizedBox(width: 8),
                  const Text('Pesticide:',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButton<String>(
                      value: _selectedPesticide,
                      isExpanded: true,
                      items: MrlData.pesticideNames
                          .map((n) =>
                              DropdownMenuItem(value: n, child: Text(n)))
                          .toList(),
                      onChanged: canEdit
                          ? (v) =>
                              setState(() => _selectedPesticide = v!)
                          : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButton<String>(
                    value: _unit,
                    underline: const SizedBox(),
                    style: const TextStyle(
                        fontSize: 13, color: Colors.black87),
                    items: const [
                      DropdownMenuItem(value: 'ppm', child: Text('ppm')),
                      DropdownMenuItem(value: 'ppb', child: Text('ppb')),
                    ],
                    onChanged: canEdit
                        ? (v) {
                            Provider.of<AppState>(context, listen: false)
                                .setSelectedUnit(v!);
                            setState(() {});
                          }
                        : null,
                  ),
                ],
              ),

              const SizedBox(height: 10),

              // ── Concentration entry (shown when not calibrated/collecting) ─
              if (!_calibrated && !_collecting)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Set calibration concentrations',
                          style: TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            SizedBox(
                                width: 72,
                                child: _concField('Blank', null,
                                    enabled: false)),
                            for (int i = 0;
                                i < _concControllers.length;
                                i++)
                              SizedBox(
                                width: 72,
                                child: _concField(
                                  'Std ${i + 1}',
                                  _concControllers[i],
                                  enabled: !_collecting &&
                                      _clMeans.length <= i + 1,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

              const SizedBox(height: 10),

              // ── Level table / calibration results ──────────────────────
              Expanded(
                child: _calibrated
                    ? SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Coefficients card
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Calibration complete — $_selectedPesticide',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'CL  m=${_clSlope.toStringAsFixed(4)}  '
                                      'b=${_clIntercept.toStringAsFixed(4)}  '
                                      'R²=${_clR2.toStringAsFixed(4)}',
                                      style:
                                          const TextStyle(fontSize: 13),
                                    ),
                                    Text(
                                      'FL  m=${_flSlope.toStringAsFixed(4)}  '
                                      'b=${_flIntercept.toStringAsFixed(4)}  '
                                      'R²=${_flR2.toStringAsFixed(4)}',
                                      style:
                                          const TextStyle(fontSize: 13),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            // CL calibration chart
                            Card(
                              child: Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(12, 12, 12, 8),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'CL Calibration  •  R² = ${_clR2.toStringAsFixed(4)}',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13,
                                        color: Colors.blue.shade600,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    _buildSingleChart(
                                      means: _clMeans,
                                      slope: _clSlope,
                                      intercept: _clIntercept,
                                      color: Colors.blue.shade600,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            // FL calibration chart
                            Card(
                              child: Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(12, 12, 12, 8),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'FL Calibration  •  R² = ${_flR2.toStringAsFixed(4)}',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13,
                                        color: Colors.orange.shade600,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    _buildSingleChart(
                                      means: _flMeans,
                                      slope: _flSlope,
                                      intercept: _flIntercept,
                                      color: Colors.orange.shade600,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            // Warning (R² 0.95–0.99 range)
                            if (_warning != null) ...[
                              const SizedBox(height: 8),
                              Card(
                                color: Colors.orange.shade50,
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Row(
                                    children: [
                                      Icon(Icons.warning_amber,
                                          color: Colors.orange.shade700),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          _warning!,
                                          style: TextStyle(
                                              color:
                                                  Colors.orange.shade800),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                            // Add-point option (R² 0.95–0.99 range)
                            if (_showAddPointOption) ...[
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      icon: const Icon(
                                          Icons.add_circle_outline),
                                      label: const Text('Add Point'),
                                      onPressed: _addCalibrationPoint,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      icon: const Icon(Icons.refresh),
                                      label: const Text('Start Over'),
                                      onPressed: _reset,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      )
                    : ListView.separated(
                        itemCount: concs.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 8),
                        itemBuilder: (_, i) {
                          final done   = i < _clMeans.length;
                          final active = !_calibrated &&
                              i == _currentLevel &&
                              !_collecting;
                          final label = _levelNames[i];
                          final dispConc =
                              (concs[i] * _fromPpm).toStringAsFixed(2);
                          final unit = _unit;

                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            decoration: BoxDecoration(
                              color: done
                                  ? cs.primaryContainer
                                      .withValues(alpha: 0.18)
                                  : active
                                      ? cs.secondaryContainer
                                          .withValues(alpha: 0.25)
                                      : Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(12),
                              border: active
                                  ? Border.all(
                                      color: cs.primary, width: 1.5)
                                  : null,
                            ),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: done
                                    ? Colors.green.shade700
                                    : active
                                        ? cs.primary
                                        : Colors.grey.shade400,
                                radius: 16,
                                child: Text(
                                  '${i + 1}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                              title: Text(
                                '$label  •  $dispConc $unit',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600),
                              ),
                              subtitle: done
                                  ? Text(
                                      'CL: ${_clMeans[i].toStringAsFixed(4)}   '
                                      'FL: ${_flMeans[i].toStringAsFixed(4)}',
                                    )
                                  : (i == _currentLevel &&
                                          _collecting &&
                                          _stabilizing)
                                      ? Text(
                                          'Stabilising… ${_stabilizeRemain}s',
                                          style: TextStyle(
                                              color: cs.primary),
                                        )
                                      : (i == _currentLevel && _collecting)
                                          ? Text(
                                              'Collecting… ($_sampleCount/$_samplesPerLevel)',
                                              style: TextStyle(
                                                  color: cs.primary),
                                            )
                                          : Text(
                                              active
                                                  ? 'Ready — place standard'
                                                  : 'Waiting…',
                                              style: const TextStyle(
                                                  color: Colors.black45),
                                            ),
                              trailing: done
                                  ? Icon(Icons.check_circle,
                                      color: Colors.green.shade700)
                                  : (i == _currentLevel &&
                                          _collecting &&
                                          _stabilizing)
                                      ? Text(
                                          '${_stabilizeRemain}s',
                                          style: TextStyle(
                                            color: cs.primary,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 14,
                                          ),
                                        )
                                      : (i == _currentLevel && _collecting)
                                          ? SizedBox.square(
                                              dimension: 20,
                                              child:
                                                  CircularProgressIndicator(
                                                strokeWidth: 2,
                                                value: _sampleCount /
                                                    _samplesPerLevel,
                                              ),
                                            )
                                          : null,
                            ),
                          );
                        },
                      ),
              ),

              const SizedBox(height: 10),

              // ── Action buttons ─────────────────────────────────────────
              if (!_calibrated) ...[
                if (!allLevelsCollected)
                  FilledButton.icon(
                    icon: _collecting
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.science_outlined),
                    label: Text(
                      _collecting
                          ? (_stabilizing
                              ? 'Stabilising… (${_stabilizeRemain}s)'
                              : 'Collecting… ($_sampleCount/$_samplesPerLevel)')
                          : 'Collect Level ${_currentLevel + 1} '
                              '(${_levelNames[_currentLevel]})',
                    ),
                    onPressed: _collecting ? null : _collectLevel,
                  )
                else
                  FilledButton.icon(
                    icon: const Icon(Icons.analytics),
                    label: const Text('Compute Calibration'),
                    onPressed: _computeCalibration,
                  ),
              ],

              if (!_calibrated && _warning != null) ...[
                const SizedBox(height: 8),
                Card(
                  color: Colors.orange.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber,
                            color: Colors.orange.shade700),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _warning!,
                            style:
                                TextStyle(color: Colors.orange.shade800),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              if (!_calibrated && _showAddPointOption) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.add_circle_outline),
                        label: const Text('Add Point'),
                        onPressed: _addCalibrationPoint,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.refresh),
                        label: const Text('Start Over'),
                        onPressed: _reset,
                      ),
                    ),
                  ],
                ),
                if (_allowProceedAnyway) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.warning_amber_outlined),
                    label: const Text('Proceed Anyway (low R²)'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red.shade700,
                      side: BorderSide(color: Colors.red.shade300),
                    ),
                    onPressed: _proceedAnyway,
                  ),
                ],
              ],

              if (_calibrated) ...[
                const SizedBox(height: 10),
                FilledButton.icon(
                  icon: const Icon(Icons.navigate_next),
                  label: const Text('Proceed to Measurement'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const MeasurementScreen(),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── Small helpers ──────────────────────────────────────────────────────────

  Widget _concField(
    String label,
    TextEditingController? ctrl, {
    bool enabled = true,
  }) {
    final unit = _unit;
    return Column(
      children: [
        Text(label,
            style: const TextStyle(fontSize: 11, color: Colors.black54)),
        const SizedBox(height: 4),
        ctrl == null
            ? Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('0.00',
                    style:
                        TextStyle(fontSize: 13, color: Colors.black45)),
              )
            : TextField(
                controller: ctrl,
                enabled: enabled,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 8),
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                  suffix: Text(unit,
                      style: const TextStyle(fontSize: 10)),
                ),
              ),
      ],
    );
  }
}
