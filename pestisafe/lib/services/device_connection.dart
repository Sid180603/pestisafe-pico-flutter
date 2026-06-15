// lib/services/device_connection.dart
// Abstract transport interface — screens talk to this, never to a specific transport.
// Phase 1: implemented by WebSocketConnection.
// Phase 3: a BleConnection can be added without touching any screen code.

abstract class DeviceConnection {
  /// Stream of raw JSON strings received from the device.
  /// e.g. '{"type":"sensor","cl":0.4587,"fl":0.5123}'
  Stream<String> get messages;

  /// True while the connection is open and healthy.
  bool get isConnected;

  /// Open a connection to [uri].  For WebSocket: 'ws://192.168.4.1:8080/ws'
  Future<void> connect(String uri);

  /// Send a JSON command string to the device.
  Future<void> send(String message);

  /// Gracefully close the connection.
  Future<void> disconnect();
}
