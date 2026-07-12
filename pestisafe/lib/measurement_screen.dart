// lib/measurement_screen.dart
// Collects 5 sensor readings, applies calibration from AppState, validates
// CL/FL agreement via FL-preferred rule (math_utils.flPreferred), classifies
// result as SAFE / UNSAFE against CODEX MRLs (loaded from mrl_data.json),
// and persists each measurement to the local SQLite database.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_state.dart';
import 'database_helper.dart';
import 'history_screen.dart';
import 'math_utils.dart';
import 'mrl_data.dart';
import 'protocol.dart';

enum _SafetyTier { safe, unsafe, unknown }

class MeasurementScreen extends StatefulWidget {
  const MeasurementScreen({super.key});

  @override
  State<MeasurementScreen> createState() => _MeasurementScreenState();
}

class _MeasurementScreenState extends State<MeasurementScreen> {
  // 5 readings averaged per measurement — same rationale as calibration:
  // suppresses ADC shot noise while keeping total acquisition time ~2 seconds.
  static const int _samples = 5;

  String? _selectedCommodity;
  bool _measuring      = false;
  int  _count          = 0;
  int  _stabilizeRemain = 0; // countdown seconds; 0 = not stabilizing

  String get _unit =>
      Provider.of<AppState>(context, listen: false).selectedUnit;
  double get _fromPpm =>
      Provider.of<AppState>(context, listen: false).selectedUnit == 'ppb'
          ? 1000.0
          : 1.0;

  double _concCL = 0, _concFL = 0, _avgConc = 0;
  bool   _agreementOk = true;
  _SafetyTier _tier = _SafetyTier.unknown;
  String _message = '';

  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    // Set initial commodity selection after the first frame so that the
    // AppState/MrlData are available via context without mutating state
    // inside build().
    WidgetsBinding.instance.addPostFrameCallback((_) => _initCommodity());
  }

  void _initCommodity() {
    if (!mounted) return;
    final pesticide   = Provider.of<AppState>(context, listen: false)
        .selectedPesticide ?? MrlData.pesticideNames.first;
    final commodities = MrlData.commoditiesFor(pesticide);
    setState(() {
      if (_selectedCommodity == null ||
          !commodities.contains(_selectedCommodity)) {
        _selectedCommodity = commodities.isNotEmpty ? commodities.first : null;
      }
    });
  }

  // ── Measurement logic ──────────────────────────────────────────────────────

  Future<void> _measure() async {
    final appState   = Provider.of<AppState>(context, listen: false);
    final conn       = appState.connection;
    final pesticide  = appState.selectedPesticide ?? MrlData.pesticideNames.first;
    final commodity  = _selectedCommodity;

    if (conn == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected — go back and reconnect.')),
      );
      return;
    }

    if (commodity == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a commodity first.')),
      );
      return;
    }

    setState(() {
      _measuring      = true;
      _count          = 0;
      _stabilizeRemain = 0;
      _tier        = _SafetyTier.unknown;
      _message     = '';
      _agreementOk = true;
      _concCL = _concFL = _avgConc = 0;
    });

    // 10-second stabilization delay — let the sample settle.
    for (int s = 10; s > 0; s--) {
      if (!mounted) return;
      setState(() => _stabilizeRemain = s);
      await Future.delayed(const Duration(seconds: 1));
    }
    if (!mounted) return;
    setState(() => _stabilizeRemain = 0);

    double clSum = 0, flSum = 0;
    int received = 0;
    final completer = Completer<void>();

    _sub = conn.messages.listen((raw) {
      if (!mounted) return;
      try {
        final msg    = Protocol.decode(raw);
        final sensor = Protocol.parseSensor(msg);
        if (sensor != null) {
          clSum += sensor.cl;
          flSum += sensor.fl;
          received++;
          setState(() => _count = received);
          if (received >= _samples && !completer.isCompleted) {
            completer.complete();
          }
        }
      } on FormatException catch (_) {}
    });

    // Request _samples readings from firmware, 400 ms apart.
    for (int i = 0; i < _samples; i++) {
      if (!completer.isCompleted) {
        await conn.send(Protocol.encodeMeasure());
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }

    await completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {},
    );
    await _sub?.cancel();
    _sub = null;

    if (!mounted) return;

    if (received == 0) {
      setState(() {
        _measuring = false;
        _message   = 'No data received. Check connection.';
        _tier      = _SafetyTier.unknown;
      });
      return;
    }

    if (received < _samples) {
      setState(() {
        _measuring = false;
        _message   = 'Insufficient data ($received/$_samples readings). '
            'Check connection and re-measure.';
        _tier      = _SafetyTier.unknown;
      });
      return;
    }

    final clMean = clSum / received;
    final flMean = flSum / received;

    // Apply calibration: model is V = m·C + b → invert to C = (V − b) / m.
    // Clamp to ≥ 0: a voltage below the blank intercept is unphysical (sub-zero conc).
    _concCL = appState.clSlope.abs() < 1e-9
        ? 0.0
        : ((clMean - appState.clIntercept) / appState.clSlope)
            .clamp(0.0, double.infinity);
    _concFL = appState.flSlope.abs() < 1e-9
        ? 0.0
        : ((flMean - appState.flIntercept) / appState.flSlope)
            .clamp(0.0, double.infinity);

    // FL-preferred agreement rule (professor's specification, 5 % threshold)
    final fp     = flPreferred(_concCL, _concFL);
    _agreementOk = fp.agreementOk;
    _avgConc     = fp.avgConc;

    // 2-tier MRL classification (CODEX MRLs are binary thresholds)
    final mrl = MrlData.getMrl(pesticide, commodity);
    if (mrl <= 0) {
      _tier    = _SafetyTier.unknown;
      _message = 'No MRL reference for $commodity — cannot classify.';
    } else if (_avgConc <= mrl) {
      _tier    = _SafetyTier.safe;
      _message = 'SAFE — ${(_avgConc / mrl * 100).toStringAsFixed(1)} % of MRL';
    } else {
      _tier    = _SafetyTier.unsafe;
      _message = 'UNSAFE — ${(_avgConc / mrl * 100).toStringAsFixed(1)} % of MRL';
    }

    // Show result immediately — DB save must not block or hide the result.
    setState(() => _measuring = false);

    // Only persist classifiable results — unknown tier means no CODEX MRL
    // exists for this commodity, so recording it as UNSAFE would be incorrect.
    if (_tier == _SafetyTier.unknown) return;

    // Persist to history database (best-effort; failure doesn't discard the result).
    try {
      await DatabaseHelper.instance.insertMeasurement({
        'timestamp':  DateTime.now().toIso8601String(),
        'pesticide':  pesticide,
        'commodity':  commodity,
        'cl_conc':    _concCL,
        'fl_conc':    _concFL,
        'avg_conc':   _avgConc,
        'mrl':        mrl,
        'result':     _tier == _SafetyTier.safe ? 'SAFE' : 'UNSAFE',
        'agreement':  _agreementOk ? 1 : 0,
        'cl_voltage': clMean,
        'fl_voltage': flMean,
        'low_confidence': appState.calibrationLowConfidence ? 1 : 0,
      });
    } catch (_) {
      // DB unavailable (e.g. sqflite_sw.js not yet installed on web) —
      // result is still shown; history will not contain this entry.
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  // ── UI helpers ─────────────────────────────────────────────────────────────

  Color get _tierColor => switch (_tier) {
    _SafetyTier.safe    => Colors.green.shade700,
    _SafetyTier.unsafe  => Colors.red.shade700,
    _SafetyTier.unknown => Colors.grey,
  };

  IconData get _tierIcon => switch (_tier) {
    _SafetyTier.safe    => Icons.check_circle_outline,
    _SafetyTier.unsafe  => Icons.dangerous_outlined,
    _SafetyTier.unknown => Icons.help_outline,
  };

  @override
  Widget build(BuildContext context) {
    final cs         = Theme.of(context).colorScheme;
    final appState   = Provider.of<AppState>(context, listen: false);
    final pesticide  = appState.selectedPesticide ?? MrlData.pesticideNames.first;
    final commodities = MrlData.commoditiesFor(pesticide);

    final mrl = _selectedCommodity != null
        ? MrlData.getMrl(pesticide, _selectedCommodity!)
        : 0.0;
    final info = MrlData.pesticideInfo(pesticide);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Measurement'),
            Text(
              pesticide,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Step 3 • Measurement',
                style: TextStyle(color: cs.primary, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              const Text(
                'Place the prepared food sample. Tap Measure Now.',
                style: TextStyle(fontSize: 13, color: Colors.black54),
              ),
              const SizedBox(height: 6),

              // ── Pesticide info row ─────────────────────────────────────────
              // Surfaces chemical_family, functional_class, and ADI from
              // mrl_data.json so the data model is visible to the user.
              if (info != null)
                Text(
                  '${info.chemicalFamily} ${info.functionalClass.toLowerCase()}'
                  ' — ADI: ${info.adiMgKgBw} mg/kg bw/day',
                  style: TextStyle(fontSize: 12, color: cs.primary),
                ),
              const SizedBox(height: 8),

              // ── Commodity selector ─────────────────────────────────────────
              Row(
                children: [
                  const Icon(Icons.eco_outlined, size: 20),
                  const SizedBox(width: 8),
                  const Text('Commodity:'),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButton<String>(
                      value: _selectedCommodity,
                      isExpanded: true,
                      hint: const Text('Select commodity'),
                      items: commodities
                          .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                          .toList(),
                      onChanged: _measuring
                          ? null
                          : (v) => setState(() => _selectedCommodity = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'MRL: ${(mrl * _fromPpm).toStringAsFixed(2)} $_unit',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),

              const SizedBox(height: 10),

              // ── Progress card ──────────────────────────────────────────────
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.analytics_outlined, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            _measuring
                                ? (_stabilizeRemain > 0
                                    ? 'Stabilizing… (${_stabilizeRemain}s)'
                                    : 'Measuring… ($_count/$_samples)')
                                : _tier == _SafetyTier.unknown
                                    ? 'Ready'
                                    : 'Done',
                            style: TextStyle(
                              color: _measuring ? cs.primary : Colors.black54,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      LinearProgressIndicator(
                        value: _measuring
                            ? (_stabilizeRemain > 0
                                ? null // indeterminate during stabilization
                                : (_samples > 0 ? _count / _samples : null))
                            : _tier != _SafetyTier.unknown
                                ? 1.0
                                : 0.0,
                        color: cs.primary,
                        backgroundColor: cs.primary.withValues(alpha: 0.15),
                        minHeight: 6,
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 10),

              // ── Measure button ─────────────────────────────────────────────
              FilledButton.icon(
                icon: _measuring
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.science),
                label: Text(_measuring
                    ? (_stabilizeRemain > 0 ? 'Stabilizing…' : 'Measuring…')
                    : 'Measure Now'),
                onPressed: _measuring ? null : _measure,
              ),

              const SizedBox(height: 16),

              // ── Results ────────────────────────────────────────────────────
              if (_tier != _SafetyTier.unknown) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        // Concentration detail
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _ConcChip(label: 'CL',  value: _concCL  * _fromPpm, unit: _unit),
                            _ConcChip(label: 'FL',  value: _concFL  * _fromPpm, unit: _unit),
                            _ConcChip(label: 'Avg', value: _avgConc * _fromPpm, unit: _unit, bold: true),
                          ],
                        ),
                        const SizedBox(height: 10),

                        // Agreement badge
                        if (!_agreementOk)
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.orange.shade50,
                              borderRadius: BorderRadius.circular(8),
                              border:
                                  Border.all(color: Colors.orange.shade300),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.warning_amber,
                                    color: Colors.orange.shade700, size: 16),
                                const SizedBox(width: 6),
                                Text(
                                  'CL/FL mismatch (>5 %) — FL signal used',
                                  style: TextStyle(
                                    color: Colors.orange.shade800,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),

                        // Safety tier badge
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: _tierColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            children: [
                              Icon(_tierIcon, color: _tierColor, size: 32),
                              const SizedBox(height: 4),
                              Text(
                                _message,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: _tierColor,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 10),

                // "View History" shortcut after a result is shown
                OutlinedButton.icon(
                  icon: const Icon(Icons.history),
                  label: const Text('View History'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const HistoryScreen()),
                  ),
                ),
              ],

              const Spacer(),
              const Text(
                'MRL reference: CODEX ALIMENTARIUS (FAO/WHO)',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.black38, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Small helper widget ───────────────────────────────────────────────────────

class _ConcChip extends StatelessWidget {
  final String label;
  final double value;
  final String unit;
  final bool bold;

  const _ConcChip({
    required this.label,
    required this.value,
    this.unit = 'ppm',
    this.bold = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Colors.black54,
            fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
          ),
        ),
        Text(
          '${value.toStringAsFixed(4)} $unit',
          style: TextStyle(
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
            fontSize: bold ? 15 : 13,
          ),
        ),
      ],
    );
  }
}
