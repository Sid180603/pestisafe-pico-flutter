// lib/history_screen.dart
// Browse, filter, swipe-delete, and CSV-export past measurements.
// Filtering is done client-side; data is loaded from the local SQLite database.

import 'dart:io';
import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'app_state.dart';
import 'database_helper.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Map<String, dynamic>> _records = [];
  bool _loading = true;

  String? _filterPesticide; // null = all
  String? _filterResult;    // null | 'SAFE' | 'UNSAFE'

  static final _dtFmt = DateFormat('dd MMM yyyy  HH:mm');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rows = await DatabaseHelper.instance.getAllMeasurements();
    if (!mounted) return;
    setState(() {
      _records = rows;
      _loading = false;
    });
  }

  // ── Filtered view ──────────────────────────────────────────────────────────

  List<Map<String, dynamic>> get _filtered {
    return _records.where((r) {
      if (_filterPesticide != null && r['pesticide'] != _filterPesticide) {
        return false;
      }
      if (_filterResult != null && r['result'] != _filterResult) return false;
      return true;
    }).toList();
  }

  // ── CSV export ─────────────────────────────────────────────────────────────

  Future<void> _exportCsv() async {
    // Export only the currently visible (filtered) records.
    final export = _filtered;
    final appState = Provider.of<AppState>(context, listen: false);
    final unit = appState.selectedUnit;
    final scale = unit == 'ppb' ? 1000.0 : 1.0;
    final rows = <List<dynamic>>[
      [
        'ID', 'Timestamp', 'Pesticide', 'Commodity',
        'CL ($unit)', 'FL ($unit)', 'Avg ($unit)',
        'MRL ($unit)', 'CL (V)', 'FL (V)', 'Result', 'CL/FL Agreed',
        'Low Confidence',
      ],
      ...export.map((r) => [
        r['id'],
        r['timestamp'],
        r['pesticide'],
        r['commodity'],
        (r['cl_conc']  as num).toDouble() * scale,
        (r['fl_conc']  as num).toDouble() * scale,
        (r['avg_conc'] as num).toDouble() * scale,
        (r['mrl']      as num).toDouble() * scale,
        (r['cl_voltage'] as num?)?.toDouble() ?? 0.0,
        (r['fl_voltage'] as num?)?.toDouble() ?? 0.0,
        r['result'],
        r['agreement'] == 1 ? 'Yes' : 'No',
        (r['low_confidence'] as int?) == 1 ? 'Yes' : 'No',
      ]),
    ];

    final csv = const ListToCsvConverter().convert(rows);

    if (kIsWeb) {
      // Web: share raw text content
      await Share.share(csv, subject: 'PestiSafe Measurements');
      return;
    }

    final dir  = await getTemporaryDirectory();
    final ts   = DateTime.now().millisecondsSinceEpoch;
    final file = File('${dir.path}/pestisafe_$ts.csv');
    await file.writeAsString(csv);
    await Share.shareXFiles(
      [XFile(file.path)],
      subject: 'PestiSafe Measurements',
    );
  }

  // ── Delete helpers ─────────────────────────────────────────────────────────

  Future<void> _deleteRow(Map<String, dynamic> row) async {
    await DatabaseHelper.instance.deleteMeasurement(row['id'] as int);
    await _load();
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear all history?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await DatabaseHelper.instance.deleteAll();
      if (!mounted) return;
      await _load();
    }
  }

  // ── Unique pesticide names for the filter dropdown ─────────────────────────

  List<String> get _knownPesticides {
    final names = _records.map((r) => r['pesticide'] as String).toSet().toList();
    names.sort();
    return names;
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs       = Theme.of(context).colorScheme;
    final filtered = _filtered;

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          if (_records.isNotEmpty) ...[
            IconButton(
              icon: const Icon(Icons.share_outlined),
              tooltip: 'Export CSV',
              onPressed: _exportCsv,
            ),
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Clear all',
              onPressed: _clearAll,
            ),
          ],
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // ── Filter bar ────────────────────────────────────────────────
            if (_records.isNotEmpty)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  children: [
                    // Pesticide filter
                    Expanded(
                      child: DropdownButton<String>(
                        value: _filterPesticide,
                        isExpanded: true,
                        hint: const Text('All pesticides'),
                        items: [
                          const DropdownMenuItem(
                              value: null, child: Text('All')),
                          ..._knownPesticides.map(
                            (p) => DropdownMenuItem(value: p, child: Text(p)),
                          ),
                        ],
                        onChanged: (v) =>
                            setState(() => _filterPesticide = v),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Result filter chips
                    _resultChip('SAFE',   Colors.green.shade700, cs),
                    const SizedBox(width: 4),
                    _resultChip('UNSAFE', Colors.red.shade700,   cs),
                  ],
                ),
              ),

            // ── Record count ──────────────────────────────────────────────
            if (_records.isNotEmpty)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${filtered.length} record${filtered.length == 1 ? '' : 's'}',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.black45),
                  ),
                ),
              ),

            // ── Main list / empty state ───────────────────────────────────
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : filtered.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.history_toggle_off_outlined,
                                  size: 64, color: Colors.grey.shade400),
                              const SizedBox(height: 12),
                              Text(
                                _records.isEmpty
                                    ? 'No measurements yet'
                                    : 'No records match the filter',
                                style: const TextStyle(color: Colors.black45),
                              ),
                            ],
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                            itemCount: filtered.length,
                            itemBuilder: (_, i) {
                              final r = filtered[i];
                              return _RecordCard(
                                record: r,
                                dtFmt: _dtFmt,
                                onDelete: () => _deleteRow(r),
                              );
                            },
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultChip(String label, Color color, ColorScheme cs) {
    final selected = _filterResult == label;
    return GestureDetector(
      onTap: () => setState(
          () => _filterResult = selected ? null : label),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? color : Colors.grey.shade400,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected ? color : Colors.black54,
            fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

// ── Single record card ────────────────────────────────────────────────────────

class _RecordCard extends StatelessWidget {
  final Map<String, dynamic> record;
  final DateFormat dtFmt;
  final VoidCallback onDelete;

  const _RecordCard({
    required this.record,
    required this.dtFmt,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isSafe = record['result'] == 'SAFE';
    final color  = isSafe ? Colors.green.shade700 : Colors.red.shade700;
    final agreed = (record['agreement'] as int?) == 1;

    String tsDisplay;
    try {
      final dt = DateTime.parse(record['timestamp'] as String);
      tsDisplay = dtFmt.format(dt.toLocal());
    } catch (_) {
      tsDisplay = record['timestamp'] as String;
    }

    final avgPpm = (record['avg_conc'] as num).toDouble();
    final mrlPpm = (record['mrl']     as num).toDouble();
    final clV    = (record['cl_voltage'] as num?)?.toDouble() ?? 0.0;
    final flV    = (record['fl_voltage'] as num?)?.toDouble() ?? 0.0;
    final lowConf = (record['low_confidence'] as int?) == 1;

    // Retrieve a safe name for the pesticide from MrlData if possible.
    final pesticideName = record['pesticide'] as String;
    final commodityName = record['commodity'] as String;

    // Unit-aware display
    final appState = Provider.of<AppState>(context, listen: false);
    final unit = appState.selectedUnit;
    final scale = unit == 'ppb' ? 1000.0 : 1.0;
    final avg = avgPpm * scale;
    final mrl = mrlPpm * scale;

    return Dismissible(
      key: ValueKey(record['id']),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: Colors.red.shade100,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(Icons.delete_outline, color: Colors.red.shade700),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Delete this record?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child:
                    const Text('Delete', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        );
      },
      onDismissed: (_) => onDelete(),
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Row 1: timestamp + result badge
              Row(
                children: [
                  Expanded(
                    child: Text(
                      tsDisplay,
                      style: const TextStyle(
                          fontSize: 12, color: Colors.black54),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      record['result'] as String,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),

              // Row 2: pesticide + commodity
              Text(
                '$pesticideName  ·  $commodityName',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),

              // Row 3: avg conc vs MRL + agreement indicator
              Row(
                children: [
                  Text(
                    'Avg ${avg.toStringAsFixed(3)} $unit  '
                    '/ MRL ${mrl.toStringAsFixed(2)} $unit',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const Spacer(),
                  if (!agreed)
                    Tooltip(
                      message: 'CL/FL mismatch — FL used',
                      child: Icon(Icons.warning_amber_outlined,
                          size: 16, color: Colors.orange.shade700),
                    ),
                ],
              ),
              const SizedBox(height: 2),

              // Row 4: raw TIA voltages
              Text(
                'CL ${clV.toStringAsFixed(3)} V  ·  FL ${flV.toStringAsFixed(3)} V',
                style: const TextStyle(fontSize: 11, color: Colors.black45),
              ),

              // Row 5: low-confidence badge (overridden low-R² calibration)
              if (lowConf) ...[
                const SizedBox(height: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.orange.shade300),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.warning_amber_outlined,
                          size: 13, color: Colors.orange.shade800),
                      const SizedBox(width: 4),
                      Text(
                        'Low confidence (low R² calibration)',
                        style: TextStyle(
                            fontSize: 10.5, color: Colors.orange.shade900),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
