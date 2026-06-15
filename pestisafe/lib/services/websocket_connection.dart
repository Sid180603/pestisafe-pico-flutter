// lib/services/websocket_connection.dart
// WebSocket implementation of DeviceConnection using web_socket_channel.

import 'dart:async';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'device_connection.dart';

class WebSocketConnection implements DeviceConnection {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  final _controller = StreamController<String>.broadcast();
  bool _connected = false;

  @override
  Stream<String> get messages => _controller.stream;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect(String uri) async {
    _channel = WebSocketChannel.connect(Uri.parse(uri));
    // wait for the handshake to complete (throws on failure)
    await _channel!.ready;
    _connected = true;

    _sub = _channel!.stream.listen(
      (data) {
        if (!_controller.isClosed) _controller.add(data.toString());
      },
      onDone: () {
        _connected = false;
        if (!_controller.isClosed) {
          _controller.add('{"v":1,"type":"status","state":"disconnected"}');
        }
      },
      onError: (e) {
        _connected = false;
        if (!_controller.isClosed) {
          _controller.add(
              '{"v":1,"type":"error","msg":"${e.toString().replaceAll('"', "'")}"}');
        }
      },
      cancelOnError: true,
    );
  }

  @override
  Future<void> send(String message) async {
    if (_connected && _channel != null) {
      _channel!.sink.add(message);
    }
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
  }

  void dispose() {
    // Cancel listener first — callbacks stop immediately even though the
    // returned Future resolves later.  This prevents onDone/onError from
    // firing after the StreamController is closed.
    _sub?.cancel();
    _sub = null;
    _connected = false;
    if (!_controller.isClosed) _controller.close();
    _channel?.sink.close(); // fire-and-forget: channel cleanup continues async
    _channel = null;
  }
}
