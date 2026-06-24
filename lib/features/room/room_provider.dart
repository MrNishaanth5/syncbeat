import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import '../../core/sync_engine.dart';
import '../../core/audio_controller.dart';
import '../../core/websocket_client.dart';

// ---- Config ----
// Replace with your deployed backend URL or use local server
const String kServerBaseUrl = 'https://syncbeat-server-production-9ccc.up.railway.app';
const String kServerWsUrl  = 'wss://syncbeat-server-production-9ccc.up.railway.app';

// For LOCAL DEMO mode (no server needed), set this to true
const bool kDemoMode = false;

// ---- Models ----
enum RoomStatus { idle, creating, joining, connected, error }
enum PlaybackState { idle, loading, playing, paused }

class RoomMember {
  final String userId;
  final String displayName;
  final bool isHost;
  const RoomMember({required this.userId, required this.displayName, required this.isHost});
}

class RoomState {
  final RoomStatus status;
  final String? roomCode;
  final String? errorMessage;
  final bool isHost;
  final List<RoomMember> members;
  final PlaybackState playbackState;
  final TrackInfo? currentTrack;
  final int currentPositionMs;
  final int clockOffsetMs;

  const RoomState({
    this.status = RoomStatus.idle,
    this.roomCode,
    this.errorMessage,
    this.isHost = false,
    this.members = const [],
    this.playbackState = PlaybackState.idle,
    this.currentTrack,
    this.currentPositionMs = 0,
    this.clockOffsetMs = 0,
  });

  RoomState copyWith({
    RoomStatus? status, String? roomCode, String? errorMessage,
    bool? isHost, List<RoomMember>? members, PlaybackState? playbackState,
    TrackInfo? currentTrack, int? currentPositionMs, int? clockOffsetMs,
  }) => RoomState(
    status: status ?? this.status,
    roomCode: roomCode ?? this.roomCode,
    errorMessage: errorMessage ?? this.errorMessage,
    isHost: isHost ?? this.isHost,
    members: members ?? this.members,
    playbackState: playbackState ?? this.playbackState,
    currentTrack: currentTrack ?? this.currentTrack,
    currentPositionMs: currentPositionMs ?? this.currentPositionMs,
    clockOffsetMs: clockOffsetMs ?? this.clockOffsetMs,
  );
}

// ---- Notifier ----
class RoomNotifier extends StateNotifier<RoomState> {
  final SyncEngine _syncEngine = SyncEngine();
  late final AudioController _audioController;
  final WebSocketClient _wsClient = WebSocketClient();
  final String _userId = const Uuid().v4().substring(0, 8);
  StreamSubscription? _wsSub;

  RoomNotifier() : super(const RoomState()) {
    _audioController = AudioController(_syncEngine);
    _syncEngine.onClockSynced = (offset) {
      state = state.copyWith(clockOffsetMs: offset);
    };
  }

  AudioController get audioController => _audioController;

  // ---- DEMO MODE (no server) ----
  Future<void> createRoomDemo() async {
    final code = _generateCode();
    state = state.copyWith(
      status: RoomStatus.connected,
      roomCode: code,
      isHost: true,
      members: [RoomMember(userId: _userId, displayName: 'You (Host)', isHost: true)],
    );
  }

  Future<void> joinRoomDemo(String code) async {
    state = state.copyWith(
      status: RoomStatus.connected,
      roomCode: code.toUpperCase(),
      isHost: false,
      members: [
        RoomMember(userId: 'host', displayName: 'Host', isHost: true),
        RoomMember(userId: _userId, displayName: 'You', isHost: false),
      ],
    );
  }

  // ---- REAL SERVER MODE ----
  Future<void> createRoom() async {
    if (kDemoMode) { await createRoomDemo(); return; }
    state = state.copyWith(status: RoomStatus.creating);
    try {
      final res = await http.post(
        Uri.parse('$kServerBaseUrl/api/rooms'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'userId': _userId, 'displayName': 'User'}),
      );
      final data = jsonDecode(res.body);
      final code = data['room_code'] as String;
      await _connectWebSocket(code);
      await _performClockSync();
      state = state.copyWith(
        status: RoomStatus.connected,
        roomCode: code,
        isHost: true,
      );
    } catch (e) {
      state = state.copyWith(status: RoomStatus.error, errorMessage: e.toString());
    }
  }

  Future<void> joinRoom(String code) async {
    if (kDemoMode) { await joinRoomDemo(code); return; }
    state = state.copyWith(status: RoomStatus.joining);
    try {
      final res = await http.post(
        Uri.parse('$kServerBaseUrl/api/rooms/$code/join'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'userId': _userId}),
      );
      if (res.statusCode != 200) throw Exception('Room not found or full');
      await _connectWebSocket(code);
      await _performClockSync();
      state = state.copyWith(
        status: RoomStatus.connected,
        roomCode: code.toUpperCase(),
        isHost: false,
      );
    } catch (e) {
      state = state.copyWith(status: RoomStatus.error, errorMessage: e.toString());
    }
  }

  Future<void> _connectWebSocket(String code) async {
    await _wsClient.connect('$kServerWsUrl/ws/$code?userId=$_userId');
    _wsSub = _wsClient.messages.listen(_handleWsMessage);
  }

  Future<void> _performClockSync() async {
    await _syncEngine.syncClock((t1) async {
      // Send T1 to server, get T2 back
      _wsClient.send({'type': 'CLOCK_SYNC', 'T1': t1});
      final completer = Completer<int>();
      late StreamSubscription sub;
      sub = _wsClient.messages.listen((msg) {
        if (msg.type == WsMessageType.clockSyncReply) {
          completer.complete(msg.data['T2'] as int);
          sub.cancel();
        }
      });
      return completer.future.timeout(const Duration(seconds: 5));
    });
  }

  void _handleWsMessage(WsMessage msg) {
    switch (msg.type) {
      case WsMessageType.play:
        _handlePlay(msg.data);
      case WsMessageType.pause:
        _handlePause(msg.data);
      case WsMessageType.seek:
        _handleSeek(msg.data);
      case WsMessageType.memberJoined:
        // Refresh member list
        break;
      default:
        break;
    }
  }

  void _handlePlay(Map<String, dynamic> data) {
    final posMs = data['position_ms'] as int? ?? 0;
    final playAt = data['play_at'] as int;
    _audioController.schedulePlay(globalPlayAtMs: playAt, positionMs: posMs);
    state = state.copyWith(playbackState: PlaybackState.playing);
  }

  void _handlePause(Map<String, dynamic> data) {
    final pauseAt = data['pause_at'] as int;
    _audioController.schedulePause(globalPauseAtMs: pauseAt);
    state = state.copyWith(playbackState: PlaybackState.paused);
  }

  void _handleSeek(Map<String, dynamic> data) {
    final posMs = data['position_ms'] as int;
    final playAt = data['play_at'] as int;
    _audioController.schedulePlay(globalPlayAtMs: playAt, positionMs: posMs);
    state = state.copyWith(playbackState: PlaybackState.playing, currentPositionMs: posMs);
  }

  // ---- Host controls ----
  Future<void> play() async {
    if (!state.isHost) return;
    final globalNow = _syncEngine.globalTimeMs();
    final playAt = globalNow + 500; // 500ms scheduling window
    final posMs = _audioController.currentPositionMs;

    if (kDemoMode) {
      await _audioController.schedulePlay(globalPlayAtMs: playAt, positionMs: posMs);
      state = state.copyWith(playbackState: PlaybackState.playing);
      return;
    }
    _wsClient.send({'type': 'PLAY', 'position_ms': posMs, 'play_at': playAt});
  }

  Future<void> pause() async {
    if (!state.isHost) return;
    final globalNow = _syncEngine.globalTimeMs();
    final pauseAt = globalNow + 200;

    if (kDemoMode) {
      await _audioController.schedulePause(globalPauseAtMs: pauseAt);
      state = state.copyWith(playbackState: PlaybackState.paused);
      return;
    }
    _wsClient.send({'type': 'PAUSE', 'pause_at': pauseAt});
  }

  Future<void> seek(int positionMs) async {
    if (!state.isHost) return;
    final globalNow = _syncEngine.globalTimeMs();
    final playAt = globalNow + 500;

    if (kDemoMode) {
      await _audioController.schedulePlay(globalPlayAtMs: playAt, positionMs: positionMs);
      state = state.copyWith(playbackState: PlaybackState.playing);
      return;
    }
    _wsClient.send({'type': 'SEEK', 'position_ms': positionMs, 'play_at': playAt});
  }

  Future<void> loadTrack(TrackInfo track) async {
    state = state.copyWith(playbackState: PlaybackState.loading, currentTrack: track);
    await _audioController.loadTrack(track);
    state = state.copyWith(playbackState: PlaybackState.paused);
  }

  void leaveRoom() {
    _wsSub?.cancel();
    _wsClient.disconnect();
    _audioController.stop();
    state = const RoomState();
  }

  String _generateCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rand = DateTime.now().millisecondsSinceEpoch;
    return List.generate(6, (i) => chars[(rand >> (i * 3)) % chars.length]).join();
  }

  @override
  void dispose() {
    _syncEngine.dispose();
    _audioController.dispose();
    _wsClient.dispose();
    _wsSub?.cancel();
    super.dispose();
  }
}

final roomProvider = StateNotifierProvider<RoomNotifier, RoomState>((ref) => RoomNotifier());
