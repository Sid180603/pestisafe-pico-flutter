// lib/protocol.dart
// Client-side mirror of firmware/protocol.py.
// Encodes commands (app → firmware) and decodes responses (firmware → app).
// All outbound messages carry "v":1. Inbound messages are version-checked.
// Uses Dart 3 records for typed, zero-boilerplate return values.
//
// WHY transport-agnostic JSON:
//   The same protocol runs identically over WiFi WebSocket (Phase 2) and BLE
//   GATT Nordic UART Service (Phase 3). This was a deliberate design choice:
//   keeping the protocol layer independent of the transport layer means
//   CalibrationScreen, MeasurementScreen, and HistoryScreen required zero
//   changes when BLE was added. Any future transport (e.g. USB serial) can
//   be introduced by implementing DeviceConnection without touching protocol.dart.

import 'dart:convert';

class Protocol {
  static const int version = 1;

  // ── Decode (firmware → app) ─────────────────────────────────────────────

  /// Decode a raw JSON string from the firmware.
  /// Throws [FormatException] on invalid JSON or missing 'type' field.
  /// Logs a console warning on version mismatch (does not throw).
  static Map<String, dynamic> decode(String raw) {
    final dynamic parsed;
    try {
      parsed = jsonDecode(raw);
    } on FormatException catch (e) {
      throw FormatException('Invalid JSON from firmware: $e');
    }

    if (parsed is! Map<String, dynamic>) {
      throw const FormatException('Message must be a JSON object');
    }

    // Version check [F5]
    final v = parsed['v'];
    if (v == null) {
      // Older firmware without version field — accepted silently.
    } else if (v != version) {
      // ignore: avoid_print
      print('[Protocol] WARNING: version mismatch — expected $version, got $v');
    }

    if (parsed['type'] == null) {
      throw const FormatException("Missing 'type' field in firmware message");
    }

    return parsed;
  }

  /// Extract a sensor reading from an already-decoded message.
  /// Returns null if the message type is not 'sensor'.
  /// Throws [FormatException] (not TypeError) if 'cl' or 'fl' are missing or
  /// non-numeric, so callers using `on FormatException catch` catch it correctly.
  static ({double cl, double fl})? parseSensor(Map<String, dynamic> msg) {
    if (msg['type'] != 'sensor') return null;
    final cl = msg['cl'];
    final fl = msg['fl'];
    if (cl is! num) {
      throw const FormatException("sensor message missing numeric 'cl'");
    }
    if (fl is! num) {
      throw const FormatException("sensor message missing numeric 'fl'");
    }
    return (cl: cl.toDouble(), fl: fl.toDouble());
  }

  /// Extract a status string from an already-decoded message.
  /// Returns null if the message type is not 'status'.
  static String? parseStatus(Map<String, dynamic> msg) {
    if (msg['type'] != 'status') return null;
    return msg['state'] as String?;
  }

  /// Extract an error string from an already-decoded message.
  /// Returns null if the message type is not 'error'.
  static String? parseError(Map<String, dynamic> msg) {
    if (msg['type'] != 'error') return null;
    return msg['msg'] as String?;
  }

  /// Extract a calibration acknowledgment from an already-decoded message.
  /// Returns null if the message type is not 'cal_ack'.
  /// Throws [FormatException] (not TypeError) if 'cl' or 'fl' are missing or
  /// non-numeric, so callers using `on FormatException catch` catch it correctly.
  static ({String level, int sample, double cl, double fl})? parseCalAck(
      Map<String, dynamic> msg) {
    if (msg['type'] != 'cal_ack') return null;
    final cl = msg['cl'];
    final fl = msg['fl'];
    if (cl is! num) {
      throw const FormatException("cal_ack missing numeric 'cl'");
    }
    if (fl is! num) {
      throw const FormatException("cal_ack missing numeric 'fl'");
    }
    return (
      level:  (msg['level'] as String?) ?? '',
      sample: (msg['sample'] as num?)?.toInt() ?? 0,
      cl:     cl.toDouble(),
      fl:     fl.toDouble(),
    );
  }

  // ── Encode (app → firmware) ─────────────────────────────────────────────

  static String _encode(String type, [Map<String, dynamic>? extra]) {
    final msg = <String, dynamic>{'v': version, 'type': type};
    if (extra != null) msg.addAll(extra);
    return jsonEncode(msg);
  }

  /// Request the firmware to take a sensor reading.
  static String encodeMeasure() => _encode('measure');

  /// Send a keep-alive heartbeat. Firmware echoes back a heartbeat message.
  static String encodeHeartbeat() => _encode('heartbeat');

  /// Notify firmware that calibration is starting for a named level.
  /// [level] is the concentration label, e.g. "0.10".
  static String encodeCalStart(String level) =>
      _encode('cal_start', {'level': level});

  /// Request the N-th calibration sample at a given level.
  static String encodeCalSample(String level, int sample) =>
      _encode('cal_sample', {'level': level, 'sample': sample});

  /// Notify firmware that all calibration levels have been collected.
  /// Firmware resets its mode back to "waiting".
  static String encodeCalEnd() => _encode('cal_end');
}
