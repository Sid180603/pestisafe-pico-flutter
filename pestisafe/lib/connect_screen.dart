// lib/connect_screen.dart
// Transport-aware connection screen.
//
// Presents a WiFi / BLE segment selector at the top.
//   WiFi mode: same behaviour as Phase 2 — enter/toggle URI, tap Connect.
//   BLE mode:  scan for nearby "PestiSafe_AP" devices, tap one to connect.
//
// BLE is hidden on Web (kIsWeb) because flutter_blue_plus is not supported
// in Chrome.  On Android the BLE option is always shown.
//
// After a successful connection (either transport) the screen stores the
// DeviceConnection in AppState and navigates to CalibrationScreen.
// CalibrationScreen, MeasurementScreen, HistoryScreen are unchanged.

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'app_state.dart';
import 'services/device_connection.dart';
import 'services/websocket_connection.dart';
import 'services/ble_connection.dart';
import 'calibration_screen.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  // -- Transport selector ---------------------------------------------------
  String _transport = 'wifi'; // 'wifi' | 'ble'

  // -- WiFi state -----------------------------------------------------------
  static const _picoHost = '192.168.4.1';
  static const _devHost  = '127.0.0.1';
  static const _port     = 8080;
  static const _path     = '/ws';

  bool _devMode = false;

  String get _uri {
    final host = _devMode ? _devHost : _picoHost;
    return 'ws://$host:$_port$_path';
  }

  // -- BLE state ------------------------------------------------------------
  bool _scanning = false;
  final List<ScanResult> _scanResults = [];
  String? _selectedBleId; // remote ID of the chosen device
  StreamSubscription<List<ScanResult>>? _scanSub;

  // -- Shared state ---------------------------------------------------------
  bool _connecting = false;
  String _status   = 'Not connected';

  // Active connection (WebSocketConnection or BleConnection).
  DeviceConnection? _connection;

  bool get _connected => _connection?.isConnected ?? false;

  @override
  void dispose() {
    _connection?.disconnect();
    if (_connection is BleConnection) {
      (_connection as BleConnection).dispose();
    } else if (_connection is WebSocketConnection) {
      (_connection as WebSocketConnection).dispose();
    }
    _scanSub?.cancel();
    // FlutterBluePlus.stopScan() is a no-op when not scanning, but the
    // platform channel is unavailable in widget-test environments, so
    // we swallow any error here rather than crashing dispose().
    try {
      FlutterBluePlus.stopScan();
    } catch (_) {}
    super.dispose();
  }

  // -- WiFi connect ---------------------------------------------------------

  Future<void> _connectWifi() async {
    setState(() {
      _connecting = true;
      _status = 'Connecting to $_uri ...';
    });

    final conn = WebSocketConnection();
    try {
      await conn.connect(_uri);
      _connection = conn;
      setState(() => _status = 'Connected  •  $_uri');
      if (!mounted) return;
      final appState = Provider.of<AppState>(context, listen: false);
      appState.setConnection(conn);
      appState.setDevMode(_devMode);
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const CalibrationScreen()),
      );
    } catch (e) {
      conn.dispose();
      if (!mounted) return;
      setState(() => _status =
          'Cannot connect — make sure the firmware is running '
          '(python firmware/main.py) and Dev Mode is enabled.');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  // -- BLE scan -------------------------------------------------------------

  Future<void> _startScan() async {
    setState(() {
      _scanning = true;
      _scanResults.clear();
      _selectedBleId = null;
      _status = 'Scanning for BLE devices...';
    });

    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 10),
      withNames: ['PestiSafe_AP'],
    );

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) return;
      setState(() {
        _scanResults
          ..clear()
          ..addAll(results);
      });
    });

    await FlutterBluePlus.isScanning.firstWhere((v) => !v);

    if (mounted) setState(() => _scanning = false);
  }

  // -- BLE connect ----------------------------------------------------------

  Future<void> _connectBle() async {
    if (_selectedBleId == null) return;

    setState(() {
      _connecting = true;
      _status = 'Connecting via BLE...';
    });

    final conn = BleConnection();
    try {
      await conn.connect(_selectedBleId!);
      _connection = conn;
      setState(() => _status = 'BLE connected  •  $_selectedBleId');
      if (!mounted) return;
      final appState = Provider.of<AppState>(context, listen: false);
      appState.setConnection(conn);
      appState.setDevMode(false);
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const CalibrationScreen()),
      );
    } catch (e) {
      conn.dispose();
      if (!mounted) return;
      setState(() => _status =
          'BLE connection failed — make sure the Pico is powered, '
          'aioble is installed, and the device is in range.');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  // -- Disconnect -----------------------------------------------------------

  Future<void> _disconnect() async {
    if (mounted) {
      await Provider.of<AppState>(context, listen: false).clearConnection();
    }
    if (_connection is BleConnection) {
      (_connection as BleConnection).dispose();
    } else if (_connection is WebSocketConnection) {
      (_connection as WebSocketConnection).dispose();
    }
    _connection = null;
    if (!mounted) return;
    setState(() => _status = 'Disconnected');
  }

  // -- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connect Device'),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'How to connect',
            onPressed: () => showDialog(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Connection Guide'),
                content: const Text(
                  'WiFi mode:\n'
                  '1. Power on the Pico WH.\n'
                  '2. Join Wi-Fi "PestiSafe_AP" (password: pestisafe2024).\n'
                  '3. Tap Connect.\n\n'
                  'BLE mode:\n'
                  '1. Power on the Pico WH.\n'
                  '2. Tap Scan, select PestiSafe_AP from the list.\n'
                  '3. Tap Connect.\n\n'
                  'For PC testing: enable Dev Mode and run:\n'
                  '  python firmware/main.py',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('OK'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // -- Transport selector (hidden on Web) -----------------------
              if (!kIsWeb) ...[
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'wifi',
                      icon: Icon(Icons.wifi),
                      label: Text('WiFi'),
                    ),
                    ButtonSegment(
                      value: 'ble',
                      icon: Icon(Icons.bluetooth),
                      label: Text('BLE'),
                    ),
                  ],
                  selected: {_transport},
                  onSelectionChanged: _connected
                      ? null
                      : (s) => setState(() {
                            _transport = s.first;
                            _status = 'Not connected';
                          }),
                ),
                const SizedBox(height: 20),
              ],

              // -- Status card ----------------------------------------------
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                  child: Row(
                    children: [
                      Icon(
                        _transport == 'ble' && !kIsWeb
                            ? (_connected
                                ? Icons.bluetooth_connected
                                : Icons.bluetooth_disabled)
                            : (_connected ? Icons.wifi : Icons.wifi_off),
                        color: _connected
                            ? Colors.green.shade700
                            : Colors.grey,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _status,
                          style: TextStyle(
                            color: _connected
                                ? Colors.green.shade700
                                : null,
                            fontWeight:
                                _connected ? FontWeight.w600 : null,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // -- WiFi-specific controls -----------------------------------
              if (_transport == 'wifi' || kIsWeb) ...[
                Text(
                  'Target: $_uri',
                  style: const TextStyle(
                      fontSize: 13, color: Colors.black54),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                SwitchListTile(
                  title: const Text('Dev Mode'),
                  subtitle: const Text(
                      'Connect to 127.0.0.1 (PC firmware running locally)'),
                  value: _devMode,
                  onChanged: _connected
                      ? null
                      : (v) => setState(() => _devMode = v),
                  activeThumbColor: cs.primary,
                ),
              ],

              // -- BLE-specific controls ------------------------------------
              if (_transport == 'ble' && !kIsWeb) ...[
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: _scanning
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Icon(Icons.search),
                        label: Text(_scanning ? 'Scanning...' : 'Scan'),
                        onPressed: (_scanning || _connected)
                            ? null
                            : _startScan,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_scanResults.isEmpty && !_scanning)
                  const Text(
                    'No BLE devices found. Tap Scan to search.',
                    style:
                        TextStyle(fontSize: 13, color: Colors.black54),
                    textAlign: TextAlign.center,
                  )
                else
                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _scanResults.length,
                    itemBuilder: (context, index) {
                      final r = _scanResults[index];
                      final id = r.device.remoteId.str;
                      final name = r.device.platformName.isNotEmpty
                          ? r.device.platformName
                          : 'Unknown';
                      final rssi = r.rssi;
                      final selected = _selectedBleId == id;
                      return ListTile(
                        leading: Icon(
                          Icons.bluetooth,
                          color: selected ? cs.primary : null,
                        ),
                        title: Text(name),
                        subtitle:
                            Text('ID: $id  •  RSSI: $rssi dBm'),
                        selected: selected,
                        onTap: _connected
                            ? null
                            : () => setState(
                                () => _selectedBleId = id),
                      );
                    },
                  ),
              ],

              const Spacer(),

              // -- Action buttons -------------------------------------------
              if (!_connected) ...[
                FilledButton.icon(
                  icon: _connecting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : Icon(_transport == 'ble' && !kIsWeb
                          ? Icons.bluetooth_searching
                          : Icons.wifi_tethering),
                  label: Text(_connecting ? 'Connecting...' : 'Connect'),
                  onPressed: _connecting
                      ? null
                      : (_transport == 'ble' && !kIsWeb
                          ? (_selectedBleId != null ? _connectBle : null)
                          : _connectWifi),
                ),
              ] else ...[
                FilledButton.icon(
                  icon: const Icon(Icons.science_outlined),
                  label: const Text('Go to Calibration'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const CalibrationScreen(),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  icon: Icon(_transport == 'ble' && !kIsWeb
                      ? Icons.bluetooth_disabled
                      : Icons.wifi_off),
                  label: const Text('Disconnect'),
                  onPressed: _disconnect,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
