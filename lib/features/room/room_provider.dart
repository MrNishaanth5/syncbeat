import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:uuid/uuid.dart';
import '../../core/sync_engine.dart';
import '../../core/audio_controller.dart';
import '../../core/websocket_client.dart';

// ---- Config ----
const String kServerBaseUrl = 'https://syncbeat-server-production-9ccc.up.railway.app';
const String kServerWsUrl  = 'wss://syncbeat-server-production-9ccc.up.railway.app';
const bool kDemoMode = false;

// A public domain test track — fallback for quick single-song testing.
const String kDemoTrackUrl = 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3';

// Max total size of a host's local playlist before upload (50MB)
const int kMaxPlaylistBytes = 50 * 1024 * 1024;

// ---- Models ----
enum RoomStatus { idle, creating, joining, connected, error }
enum PlaybackState { idle, loading, playing, paused }

class RoomMember {
  final String userId;
  final String displayName;
  final bool isHost;
  const RoomMember({required this.userId, required this.displayName, required this.isHost});
}

class QueueInfo {
  final int currentIndex;
  final int total;
  final String? nextTitle;
  final String? nextArtist;
  const QueueInfo({this.currentIndex = -1, this.total = 0, this.nextTitle, this.nextArtist});
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
  final QueueInfo queueInfo;
  final bool isPreparingNext;

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
    this.queueInfo = const QueueInfo(),
    this.isPreparingNext = false,
  });

  RoomState copyWith({
    RoomStatus? status, String? roomCode, String? errorMessage,
    bool? isHost, List<RoomMember>? members, PlaybackState? playbackState,
    TrackInfo? currentTrack, int? currentPositionMs, int? clockOffsetMs,
    QueueInfo? queueInfo, bool? isPreparingNext,
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
    queueInfo: queueInfo ?? this.queueInfo,
    isPreparingNext: isPreparingNext ?? this.isPreparingNext,
  );
}

// ---- Notifier ----
class RoomNotifier extends StateNotifier<RoomState> {
  final SyncEngine _syncEngine = SyncEngine();
  late final AudioController _audioController;
  final WebSocketClient _wsClient = WebSocketClient();
  final String _userId = const Uuid().v4().substring(0, 8);
  StreamSubscription? _wsSub;
  StreamSubscription? _playerStateSub;

  // Host-only: the full local playlist (file paths not yet uploaded)
  final List<TrackInfo> _localPlaylist = [];
  // Host-only: cache of already-uploaded tracks by playlist index
  final Map<int, TrackInfo> _uploadedTracks = {};
  int _currentIndex = -1;

  // Used so the host waits for its OWN broadcasted TRACK_LOADED message
  // to finish loading locally before issuing Play — avoids double-loading
  // the audio source and racing the schedule.
  String? _pendingLoadTrackId;
  Completer<void>? _loadCompleter;

  RoomNotifier() : super(const RoomState()) {
    _audioController = AudioController(_syncEngine);
    _syncEngine.onClockSynced = (offset) {
      state = state.copyWith(clockOffsetMs: offset);
    };
  }

  AudioController get audioController => _audioController;
  int get playlistLength => _localPlaylist.length;

  // ---- Room creation / joining ----
  Future<void> createRoom() async {
    if (kDemoMode) { await _createRoomDemo(); return; }
    state = state.copyWith(status: RoomStatus.creating);
    try {
      final res = await http.post(
        Uri.parse('$kServerBaseUrl/api/rooms'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'userId': _userId}),
      );
      final data = jsonDecode(res.body);
      final code = data['room_code'] as String;
      await _connectWebSocket(code);
      await _performClockSync();
      state = state.copyWith(
        status: RoomStatus.connected,
        roomCode: code,
        isHost: true,
        members: [RoomMember(userId: _userId, displayName: 'You (Host)', isHost: true)],
      );
    } catch (e) {
      state = state.copyWith(status: RoomStatus.error, errorMessage: e.toString());
    }
  }

  Future<void> joinRoom(String code) async {
    if (kDemoMode) { await _joinRoomDemo(code); return; }
    state = state.copyWith(status: RoomStatus.joining);
    try {
      final upperCode = code.toUpperCase();
      final res = await http.post(
        Uri.parse('$kServerBaseUrl/api/rooms/$upperCode/join'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'userId': _userId}),
      );
      if (res.statusCode != 200) throw Exception('Room not found or full');
      await _connectWebSocket(upperCode);
      await _performClockSync();
      state = state.copyWith(
        status: RoomStatus.connected,
        roomCode: upperCode,
        isHost: false,
        members: [
          RoomMember(userId: 'host', displayName: 'Host', isHost: true),
          RoomMember(userId: _userId, displayName: 'You', isHost: false),
        ],
      );
    } catch (e) {
      state = state.copyWith(status: RoomStatus.error, errorMessage: e.toString());
    }
  }

  Future<void> _createRoomDemo() async {
    final code = _generateCode();
    state = state.copyWith(
      status: RoomStatus.connected, roomCode: code, isHost: true,
      members: [RoomMember(userId: _userId, displayName: 'You (Host)', isHost: true)],
    );
  }

  Future<void> _joinRoomDemo(String code) async {
    state = state.copyWith(
      status: RoomStatus.connected, roomCode: code.toUpperCase(), isHost: false,
      members: [
        RoomMember(userId: 'host', displayName: 'Host', isHost: true),
        RoomMember(userId: _userId, displayName: 'You', isHost: false),
      ],
    );
  }

  Future<void> _connectWebSocket(String code) async {
    await _wsClient.connect('$kServerWsUrl/ws/$code?userId=$_userId');
    _wsSub = _wsClient.messages.listen(_handleWsMessage);
    await Future.delayed(const Duration(milliseconds: 300));
  }

  Future<void> _performClockSync() async {
    await _syncEngine.syncClock((t1) async {
      final completer = Completer<int>();
      late StreamSubscription sub;
      sub = _wsClient.messages.listen((msg) {
        if (msg.type == WsMessageType.clockSyncReply) {
          completer.complete(msg.data['T2'] as int);
          sub.cancel();
        }
      });
      _wsClient.send({'type': 'CLOCK_SYNC', 'T1': t1});
      return completer.future.timeout(const Duration(seconds: 5));
    });
  }

  // ---- Incoming WS messages (guest + host both listen) ----
  void _handleWsMessage(WsMessage msg) {
    switch (msg.type) {
      case WsMessageType.play:
        _handlePlay(msg.data);
      case WsMessageType.pause:
        _handlePause(msg.data);
      case WsMessageType.seek:
        _handleSeek(msg.data);
      case WsMessageType.trackLoaded:
        _handleTrackLoaded(msg.data);
      case WsMessageType.queueUpdate:
        _handleQueueUpdate(msg.data);
      case WsMessageType.roomState:
        _handleRoomState(msg.data);
      case WsMessageType.memberJoined:
      case WsMessageType.memberLeft:
        break;
      default:
        break;
    }
  }

  Future<void> _handleTrackLoaded(Map<String, dynamic> data) async {
    final track = TrackInfo(
      id: data['track_id'] ?? 'unknown',
      title: data['title'] ?? 'Unknown Track',
      artist: data['artist'] ?? '',
      sourceType: AudioSourceType.url,
      sourcePath: data['track_id'],
    );
    state = state.copyWith(playbackState: PlaybackState.loading, currentTrack: track);
    await _audioController.loadTrack(track);
    state = state.copyWith(playbackState: PlaybackState.paused);

    // If we (host) are waiting on confirmation that OUR own broadcast
    // round-tripped and finished loading, signal it now.
    if (_pendingLoadTrackId != null && _pendingLoadTrackId == track.sourcePath) {
      _pendingLoadTrackId = null;
      _loadCompleter?.complete();
      _loadCompleter = null;
    }
  }

  void _handleQueueUpdate(Map<String, dynamic> data) {
    state = state.copyWith(
      queueInfo: QueueInfo(
        currentIndex: data['current_index'] ?? -1,
        total: data['total'] ?? 0,
        nextTitle: data['next_title'],
        nextArtist: data['next_artist'],
      ),
    );
  }

  void _handleRoomState(Map<String, dynamic> data) {
    final trackId = data['track_id'];
    if (trackId != null && state.currentTrack == null) {
      _handleTrackLoaded({'track_id': trackId, 'title': 'Synced Track', 'artist': ''});
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

  // ---- Host: manual transport controls (used mid-track) ----
  Future<void> play() async {
    if (!state.isHost) return;
    final playAt = _syncEngine.globalTimeMs() + 500;
    final posMs = _audioController.currentPositionMs;

    if (kDemoMode) {
      await _audioController.schedulePlay(globalPlayAtMs: playAt, positionMs: posMs);
      state = state.copyWith(playbackState: PlaybackState.playing);
      return;
    }
    _wsClient.send({'type': 'PLAY', 'track_id': state.currentTrack?.id, 'position_ms': posMs, 'play_at': playAt});
  }

  Future<void> pause() async {
    if (!state.isHost) return;
    final pauseAt = _syncEngine.globalTimeMs() + 200;
    if (kDemoMode) {
      await _audioController.schedulePause(globalPauseAtMs: pauseAt);
      state = state.copyWith(playbackState: PlaybackState.paused);
      return;
    }
    _wsClient.send({'type': 'PAUSE', 'pause_at': pauseAt});
  }

  Future<void> seek(int positionMs) async {
    if (!state.isHost) return;
    final playAt = _syncEngine.globalTimeMs() + 500;
    if (kDemoMode) {
      await _audioController.schedulePlay(globalPlayAtMs: playAt, positionMs: positionMs);
      state = state.copyWith(playbackState: PlaybackState.playing);
      return;
    }
    _wsClient.send({'type': 'SEEK', 'position_ms': positionMs, 'play_at': playAt});
  }

  /// Load a single track. In demo mode, loads directly. In real mode,
  /// broadcasts and waits for our OWN loopback message to confirm the
  /// load finished (same device, but routed through the server like
  /// every other client — keeps one consistent code path).
  Future<void> loadTrack(TrackInfo track) async {
    if (kDemoMode) {
      state = state.copyWith(playbackState: PlaybackState.loading, currentTrack: track);
      await _audioController.loadTrack(track);
      state = state.copyWith(playbackState: PlaybackState.paused);
      return;
    }

    if (track.sourceType != AudioSourceType.url) {
      // Single local-file testing on one device only (no broadcast possible)
      state = state.copyWith(playbackState: PlaybackState.loading, currentTrack: track);
      await _audioController.loadTrack(track);
      state = state.copyWith(playbackState: PlaybackState.paused);
      return;
    }

    state = state.copyWith(playbackState: PlaybackState.loading, currentTrack: track);
    _pendingLoadTrackId = track.sourcePath;
    _loadCompleter = Completer<void>();
    _wsClient.send({
      'type': 'TRACK_LOADED',
      'track_id': track.sourcePath,
      'title': track.title,
      'artist': track.artist,
    });
    try {
      await _loadCompleter!.future.timeout(const Duration(seconds: 15));
    } catch (_) {
      // Timed out waiting for our own loopback — clear pending state so
      // we don't get stuck; playback may need a manual retry.
      _pendingLoadTrackId = null;
    }
  }

  Future<void> loadDemoTrack() async {
    if (!state.isHost) return;
    final track = TrackInfo(
      id: kDemoTrackUrl, title: 'SoundHelix Demo Track', artist: 'Demo Stream',
      sourceType: AudioSourceType.url, sourcePath: kDemoTrackUrl,
    );
    await loadTrack(track);
  }

  // ---- Playlist / Queue feature ----

  /// Host sets the local playlist (file paths, not yet uploaded).
  /// Caller (UI) is responsible for checking total size against kMaxPlaylistBytes first.
  void setLocalPlaylist(List<TrackInfo> tracks) {
    _localPlaylist..clear()..addAll(tracks);
    _uploadedTracks.clear();
    _currentIndex = -1;
  }

  /// Begin playing the playlist from the start. Uploads track 0, plays it,
  /// then prefetches track 1 in the background while it plays.
  Future<void> startPlaylist() async {
    if (!state.isHost || _localPlaylist.isEmpty) return;
    _currentIndex = 0;
    state = state.copyWith(playbackState: PlaybackState.loading);
    await _loadAndBroadcastIndex(_currentIndex);
    _listenForTrackEnd();
    _prefetch(_currentIndex + 1);
  }

  /// Host can append more songs to the playlist mid-session.
  /// They'll play after the current queue finishes.
  void addToPlaylist(List<TrackInfo> tracks) {
    final wasEmpty = _currentIndex == -1 || _currentIndex >= _localPlaylist.length - 1;
    _localPlaylist.addAll(tracks);
    // If the queue had run out and was idle, prefetch the next one now
    if (wasEmpty && _currentIndex + 1 < _localPlaylist.length) {
      _prefetch(_currentIndex + 1);
    }
  }

  void _listenForTrackEnd() {
    _playerStateSub?.cancel();
    _playerStateSub = _audioController.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        _advanceQueue();
      }
    });
  }

  Future<void> _advanceQueue() async {
    if (_currentIndex + 1 >= _localPlaylist.length) {
      // Playlist finished — nothing more queued (yet)
      state = state.copyWith(playbackState: PlaybackState.paused);
      _broadcastQueueUpdate();
      return;
    }
    _currentIndex++;
    state = state.copyWith(isPreparingNext: true);
    await _loadAndBroadcastIndex(_currentIndex);
    state = state.copyWith(isPreparingNext: false);
    _prefetch(_currentIndex + 1);
  }

  Future<void> _loadAndBroadcastIndex(int index) async {
    if (index >= _localPlaylist.length) return;
    TrackInfo uploaded;
    if (_uploadedTracks.containsKey(index)) {
      uploaded = _uploadedTracks[index]!;
    } else {
      state = state.copyWith(isPreparingNext: true);
      uploaded = await _uploadAtIndex(index);
      state = state.copyWith(isPreparingNext: false);
    }
    await loadTrack(uploaded);
    _broadcastQueueUpdate();
    await play();
  }

  Future<TrackInfo> _uploadAtIndex(int index) async {
    final local = _localPlaylist[index];
    final url = await _uploadLocalFile(local.sourcePath, '${index}_${_sanitize(local.title)}.mp3');
    final uploaded = TrackInfo(
      id: url, title: local.title, artist: local.artist,
      sourceType: AudioSourceType.url, sourcePath: url,
    );
    _uploadedTracks[index] = uploaded;
    return uploaded;
  }

  /// Prefetch (upload) the song at [index] in the background, if not already done.
  Future<void> _prefetch(int index) async {
    if (index >= _localPlaylist.length || _uploadedTracks.containsKey(index)) return;
    try {
      await _uploadAtIndex(index);
    } catch (_) {
      // Will retry naturally when _advanceQueue reaches this index
    }
  }

  void _broadcastQueueUpdate() {
    if (kDemoMode) return;
    final nextIdx = _currentIndex + 1;
    final hasNext = nextIdx < _localPlaylist.length;
    _wsClient.send({
      'type': 'QUEUE_UPDATE',
      'current_index': _currentIndex,
      'total': _localPlaylist.length,
      'next_title': hasNext ? _localPlaylist[nextIdx].title : null,
      'next_artist': hasNext ? _localPlaylist[nextIdx].artist : null,
    });
  }

  Future<String> _uploadLocalFile(String localPath, String filename) async {
    final uri = Uri.parse('$kServerBaseUrl/api/rooms/${state.roomCode}/upload');
    final request = http.MultipartRequest('POST', uri);
    request.fields['userId'] = _userId;
    request.files.add(await http.MultipartFile.fromPath('file', localPath, filename: filename));
    final streamed = await request.send();
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200) throw Exception('Upload failed: $body');
    final data = jsonDecode(body);
    return data['url'] as String; // server already returns a full absolute URL
  }

  String _sanitize(String s) => s.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');

  void leaveRoom() {
    _wsSub?.cancel();
    _playerStateSub?.cancel();
    _wsClient.disconnect();
    _audioController.stop();
    _localPlaylist.clear();
    _uploadedTracks.clear();
    _currentIndex = -1;
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
    _playerStateSub?.cancel();
    super.dispose();
  }
}

final roomProvider = StateNotifierProvider<RoomNotifier, RoomState>((ref) => RoomNotifier());
