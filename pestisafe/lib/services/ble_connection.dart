// lib/services/ble_connection.dart
// BLE GATT implementation of DeviceConnection using flutter_blue_plus.
//
// Connects to the PestiSafe Pico over the Nordic UART Service (NUS) UUIDs
// defined in firmware/ble_server.py and firmware/config.py.
//
// TX characteristic (BLE_TX_UUID): firmware→app via notifications.
// RX characteristic (BLE_RX_UUID): app→firmware via write-with-response.
//
// The connect(uri) parameter is the device remote ID (MAC address string on
// Android, UUID string on iOS) — obtained from FlutterBluePlus.scanResults.

import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'device_connection.dart';

class BleConnection implements DeviceConnection {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _txChar; // firmware→app (notify)
  BluetoothCharacteristic? _rxChar; // app→firmware (write)
  StreamSubscription<BluetoothConnectionState>? _stateSub;
  StreamSubscription<List<int>>? _valueSub;

  final _controller = StreamController<String>.broadcast();
  bool _connected = false;

  // UUIDs — must match firmware/config.py BLE_*_UUID constants exactly.
  static final _serviceUuid = Guid('6E400001-B5A3-F393-E0A9-E50E24DCCA9E');
  static final _txUuid      = Guid('6E400003-B5A3-F393-E0A9-E50E24DCCA9E');
  static final _rxUuid      = Guid('6E400002-B5A3-F393-E0A9-E50E24DCCA9E');

  @override
  Stream<String> get messages => _controller.stream;

  @override
  bool get isConnected => _connected;

  /// [uri] is the device remote ID string (e.g. MAC address on Android).
  @override
  Future<void> connect(String uri) async {
    _device = BluetoothDevice.fromId(uri);
    await _device!.connect(timeout: const Duration(seconds: 10));

    // Listen for disconnect events so the app can react promptly.
    _stateSub = _device!.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _connected = false;
        if (!_controller.isClosed) {
          _controller.add('{"v":1,"type":"status","state":"disconnected"}');
        }
      }
    });

    final services = await _device!.discoverServices();
    final svc = services.firstWhere(
      (s) => s.serviceUuid == _serviceUuid,
      orElse: () => throw StateError(
        'PestiSafe BLE service not found — is the firmware running?',
      ),
    );

    _txChar = svc.characteristics.firstWhere(
      (c) => c.characteristicUuid == _txUuid,
      orElse: () => throw StateError('TX characteristic not found'),
    );
    _rxChar = svc.characteristics.firstWhere(
      (c) => c.characteristicUuid == _rxUuid,
      orElse: () => throw StateError('RX characteristic not found'),
    );

    // Subscribe to TX notifications (firmware → app).
    await _txChar!.setNotifyValue(true);
    _valueSub = _txChar!.onValueReceived.listen((bytes) {
      final json = utf8.decode(bytes);
      if (!_controller.isClosed) _controller.add(json);
    });

    _connected = true;
  }

  @override
  Future<void> send(String message) async {
    if (_connected && _rxChar != null) {
      await _rxChar!.write(
        utf8.encode(message),
        withoutResponse: false, // write-with-response for reliability
      );
    }
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    await _valueSub?.cancel();
    _valueSub = null;
    await _txChar?.setNotifyValue(false);
    await _stateSub?.cancel();
    _stateSub = null;
    await _device?.disconnect();
    _device = null;
    _txChar = null;
    _rxChar = null;
  }

  void dispose() {
    _connected = false;
    _valueSub?.cancel();
    _stateSub?.cancel();
    _valueSub = null;
    _stateSub = null;
    if (!_controller.isClosed) _controller.close();
    _device?.disconnect();
    _device = null;
  }
}
