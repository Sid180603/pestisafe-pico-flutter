// lib/mrl_data.dart
// Loads and caches the CODEX Alimentarius MRL database from assets/json/mrl_data.json.
// Call MrlData.load() once at app startup (before runApp).
// All query methods throw StateError if load() has not been called.

import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;

class CommodityInfo {
  final String name;
  final double mrlMgKg;
  final bool atLod;

  const CommodityInfo({
    required this.name,
    required this.mrlMgKg,
    this.atLod = false,
  });

  factory CommodityInfo.fromJson(Map<String, dynamic> j) => CommodityInfo(
        name: j['name'] as String,
        mrlMgKg: (j['mrl_mg_kg'] as num).toDouble(),
        atLod: (j['at_lod'] as bool?) ?? false,
      );
}

class PesticideInfo {
  final String name;
  final String functionalClass;
  final String chemicalFamily;
  final double adiMgKgBw;
  final List<CommodityInfo> commodities;

  const PesticideInfo({
    required this.name,
    required this.functionalClass,
    required this.chemicalFamily,
    required this.adiMgKgBw,
    required this.commodities,
  });

  factory PesticideInfo.fromJson(Map<String, dynamic> j) => PesticideInfo(
        name: j['name'] as String,
        functionalClass: (j['functional_class'] as String?) ?? '',
        chemicalFamily: (j['chemical_family'] as String?) ?? '',
        adiMgKgBw: (j['adi_mg_kg_bw'] as num?)?.toDouble() ?? 0.0,
        commodities: (j['commodities'] as List)
            .map((c) => CommodityInfo.fromJson(c as Map<String, dynamic>))
            .toList(),
      );
}

class MrlData {
  MrlData._();

  static List<PesticideInfo>? _cache;

  /// Load and parse mrl_data.json. Must be called once before any other method.
  static Future<void> load() async {
    if (_cache != null) return; // already loaded
    final raw = await rootBundle.loadString('assets/json/mrl_data.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    _cache = (json['pesticides'] as List)
        .map((p) => PesticideInfo.fromJson(p as Map<String, dynamic>))
        .toList();
  }

  static List<PesticideInfo> get _data {
    if (_cache == null) throw StateError('MrlData.load() has not been called');
    return _cache!;
  }

  /// List of all pesticide names in JSON file order.
  static List<String> get pesticideNames => _data.map((p) => p.name).toList();

  /// Commodity names that have a CODEX MRL for [pesticide].
  /// Returns an empty list if [pesticide] is not found (e.g. stale saved state).
  static List<String> commoditiesFor(String pesticide) {
    final p = _data.where((p) => p.name == pesticide).firstOrNull;
    if (p == null) return [];
    return p.commodities.map((c) => c.name).toList();
  }

  /// MRL (mg/kg) for [pesticide] × [commodity].
  /// Returns 0.0 if either [pesticide] or [commodity] is not found.
  static double getMrl(String pesticide, String commodity) {
    final p = _data.where((p) => p.name == pesticide).firstOrNull;
    if (p == null) return 0.0;
    final c = p.commodities.where((c) => c.name == commodity).firstOrNull;
    return c?.mrlMgKg ?? 0.0;
  }

  /// Returns the full [PesticideInfo] object for [pesticide], or null if not found.
  static PesticideInfo? pesticideInfo(String pesticide) =>
      _data.where((p) => p.name == pesticide).firstOrNull;
}
