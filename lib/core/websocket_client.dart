import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;

enum WsMessageType {
  play, pause, seek, clockSync, clockSyncReply,
  memberJoined, memberLeft, roomState, trackLoaded, queueUpdate, error
}

class WsMessage {
  final WsMessageType type;
  final Map<String, dynamic> data;
  const WsMessage(this.type, this.data);
}

class WebSocketClient {
  WebSocketChannel? _channel;
  final StreamController<WsMessage> _messageController = StreamController.broadcast();
  bool _connected = false;
  String? _currentUrl;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;

  Stream<WsMessage> get messages => _messageController.stream;
  bool get isConnected => _connected;

  Future<void> connect(String wsUrl) async {
    _currentUrl = wsUrl;
    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _connected = true;
      _reconnectAttempts = 0;

      _channel!.stream.listen(
        (data) => _handleMessage(data),
        onError: (e) => _handleDisconnect(),
        onDone: () => _handleDisconnect(),
      );
    } catch (e) {
      _handleDisconnect();
    }
  }

  void _handleMessage(dynamic raw) {
    try {
      final json = jsonDecode(raw as String) as Map<String, dynamic>;
      final typeStr = json['type'] as String;
      final type = _parseType(typeStr);
      if (type != null) {
        _messageController.add(WsMessage(type, json));
      }
    } catch (_) {}
  }

  WsMessageType? _parseType(String t) {
    switch (t) {
      case 'PLAY': return WsMessageType.play;
      case 'PAUSE': return WsMessageType.pause;
      case 'SEEK': return WsMessageType.seek;
      case 'CLOCK_SYNC': return WsMessageType.clockSync;
      case 'CLOCK_SYNC_REPLY': return WsMessageType.clockSyncReply;
      case 'MEMBER_JOINED': return WsMessageType.memberJoined;
      case 'MEMBER_LEFT': return WsMessageType.memberLeft;
      case 'ROOM_STATE': return WsMessageType.roomState;
      case 'TRACK_LOADED': return WsMessageType.trackLoaded;
      case 'QUEUE_UPDATE': return WsMessageType.queueUpdate;
      case 'ERROR': return WsMessageType.error;
      default: return null;
    }
  }

  void send(Map<String, dynamic> message) {
    if (_connected && _channel != null) {
      _channel!.sink.add(jsonEncode(message));
    }
  }

  void _handleDisconnect() {
    _connected = false;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_reconnectAttempts >= 5) return;
    final delay = Duration(seconds: 2 * (++_reconnectAttempts));
    _reconnectTimer = Timer(delay, () {
      if (_currentUrl != null) connect(_currentUrl!);
    });
  }

  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    await _channel?.sink.close(status.goingAway);
    _connected = false;
  }

  void dispose() {
    _reconnectTimer?.cancel();
    _messageController.close();
    _channel?.sink.close();
  }
}
