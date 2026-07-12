// lib/database_helper.dart
// SQLite-backed history storage for measurement results.
// On web: uses sqflite_common_ffi_web (WASM SQLite — requires COOP/COEP headers).
// On Android/desktop: uses native sqflite.
//
// Web run command:
//   flutter run -d chrome \
//     --web-header "Cross-Origin-Opener-Policy=same-origin" \
//     --web-header "Cross-Origin-Embedder-Policy=require-corp"

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' show join;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

// ── Schema ───────────────────────────────────────────────────────────────────

const _kDb      = 'pestisafe.db';
const _kVersion = 3;   // v2 adds cl/fl_voltage; v3 adds low_confidence
const _kTable   = 'measurements';

const _kCreate = '''
CREATE TABLE $_kTable (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp   TEXT    NOT NULL,
  pesticide   TEXT    NOT NULL,
  commodity   TEXT    NOT NULL,
  cl_conc     REAL    NOT NULL,
  fl_conc     REAL    NOT NULL,
  avg_conc    REAL    NOT NULL,
  mrl         REAL    NOT NULL,
  result      TEXT    NOT NULL,
  agreement   INTEGER NOT NULL,
  cl_voltage  REAL    NOT NULL DEFAULT 0,
  fl_voltage  REAL    NOT NULL DEFAULT 0,
  low_confidence INTEGER NOT NULL DEFAULT 0
)
''';

// ── Singleton ────────────────────────────────────────────────────────────────

class DatabaseHelper {
  DatabaseHelper._();
  static final DatabaseHelper instance = DatabaseHelper._();

  Database? _db;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    if (kIsWeb) {
      databaseFactory = databaseFactoryFfiWeb;
      _db = await openDatabase(_kDb, version: _kVersion,
          onCreate: _onCreate, onUpgrade: _onUpgrade);
    } else {
      final dir  = await getApplicationDocumentsDirectory();
      final path = join(dir.path, _kDb);
      _db = await openDatabase(path, version: _kVersion,
          onCreate: _onCreate, onUpgrade: _onUpgrade);
    }
    return _db!;
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute(_kCreate);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // v1 → v2: add raw voltage columns for CL and FL channels.
      await db.execute(
          'ALTER TABLE $_kTable ADD COLUMN cl_voltage REAL NOT NULL DEFAULT 0');
      await db.execute(
          'ALTER TABLE $_kTable ADD COLUMN fl_voltage REAL NOT NULL DEFAULT 0');
    }
    if (oldVersion < 3) {
      // v2 → v3: flag measurements taken under an overridden (low-R²) calibration.
      await db.execute(
          'ALTER TABLE $_kTable ADD COLUMN low_confidence INTEGER NOT NULL DEFAULT 0');
    }
  }

  // ── CRUD ────────────────────────────────────────────────────────────────────

  /// Insert a measurement row. [row] must contain all schema fields except [id].
  /// Returns the auto-assigned id.
  Future<int> insertMeasurement(Map<String, dynamic> row) async {
    final db = await _database;
    return db.insert(_kTable, row, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// All measurements, newest first.
  Future<List<Map<String, dynamic>>> getAllMeasurements() async {
    final db = await _database;
    return db.query(_kTable, orderBy: 'id DESC');
  }

  /// Delete a single row by id. Returns number of rows affected.
  Future<int> deleteMeasurement(int id) async {
    final db = await _database;
    return db.delete(_kTable, where: 'id = ?', whereArgs: [id]);
  }

  /// Delete all rows (used by clear-history action).
  Future<void> deleteAll() async {
    final db = await _database;
    await db.delete(_kTable);
  }
}
