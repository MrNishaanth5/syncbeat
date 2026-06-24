import 'dart:async';
import 'dart:math';
import 'package:just_audio/just_audio.dart';
import 'sync_engine.dart';

enum AudioSourceType { localFile, url }

class TrackInfo {
  final String id;
  final String title;
  final String artist;
  final AudioSourceType sourceType;
  final String sourcePath; // file path or URL
  final Duration? duration;

  const TrackInfo({
    required this.id,
    required this.title,
    required this.artist,
    required this.sourceType,
    required this.sourcePath,
    this.duration,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'sourceType': sourceType.name,
    'sourcePath': sourcePath,
  };

  factory TrackInfo.fromJson(Map<String, dynamic> j) => TrackInfo(
    id: j['id'],
    title: j['title'],
    artist: j['artist'],
    sourceType: AudioSourceType.values.byName(j['sourceType']),
    sourcePath: j['sourcePath'],
  );
}

class AudioController {
  final AudioPlayer _player = AudioPlayer();
  final SyncEngine _syncEngine;
  Timer? _driftCheckTimer;
  Timer? _scheduledPlayTimer;
  int? _expectedStartGlobalMs;
  int? _expectedPositionAtStart;
  bool _isPlaying = false;

  // Drift correction thresholds
  static const int _hardSeekThresholdMs = 50;
  static const int _softAdjustThresholdMs = 10;

  TrackInfo? currentTrack;

  // Streams
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<Duration?> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;

  AudioController(this._syncEngine);

  Future<void> loadTrack(TrackInfo track) async {
    currentTrack = track;
    try {
      if (track.sourceType == AudioSourceType.localFile) {
        await _player.setAudioSource(AudioSource.file(track.sourcePath));
      } else {
        await _player.setAudioSource(AudioSource.uri(Uri.parse(track.sourcePath)));
      }
    } catch (e) {
      debugPrint('AudioController: Failed to load track: $e');
      rethrow;
    }
  }

  /// Schedule playback at a specific global timestamp, from a given position
  Future<void> schedulePlay({
    required int globalPlayAtMs,
    required int positionMs,
  }) async {
    _scheduledPlayTimer?.cancel();
    _expectedStartGlobalMs = globalPlayAtMs;
    _expectedPositionAtStart = positionMs;

    // Seek to position first
    await _player.seek(Duration(milliseconds: positionMs));
    await _player.pause();

    final delayMs = max(0, _syncEngine.msUntil(globalPlayAtMs));
    debugPrint('AudioController: Scheduling play in ${delayMs}ms');

    _scheduledPlayTimer = Timer(Duration(milliseconds: delayMs), () async {
      await _player.play();
      _isPlaying = true;
      _startDriftCorrection();
    });
  }

  /// Immediately pause (called when server says pause_at is now)
  Future<void> schedulePause({required int globalPauseAtMs}) async {
    final delayMs = max(0, _syncEngine.msUntil(globalPauseAtMs));
    Timer(Duration(milliseconds: delayMs), () async {
      await _player.pause();
      _isPlaying = false;
      _stopDriftCorrection();
    });
  }

  void _startDriftCorrection() {
    _driftCheckTimer?.cancel();
    _driftCheckTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _checkAndCorrectDrift();
    });
  }

  void _stopDriftCorrection() {
    _driftCheckTimer?.cancel();
  }

  void _checkAndCorrectDrift() {
    if (!_isPlaying || _expectedStartGlobalMs == null || _expectedPositionAtStart == null) return;

    final elapsedSinceStart = _syncEngine.globalTimeMs() - _expectedStartGlobalMs!;
    final expectedPositionMs = _expectedPositionAtStart! + elapsedSinceStart;
    final actualPositionMs = _player.position.inMilliseconds;
    final drift = actualPositionMs - expectedPositionMs;

    debugPrint('Drift: ${drift}ms');

    if (drift.abs() > _hardSeekThresholdMs) {
      // Hard correction
      _player.seek(Duration(milliseconds: expectedPositionMs));
      debugPrint('Hard seek correction: ${drift}ms drift');
    } else if (drift.abs() > _softAdjustThresholdMs) {
      // Soft rate adjustment (inaudible ±2%)
      final rate = drift > 0 ? 0.98 : 1.02;
      _player.setSpeed(rate);
      // Reset rate after 2s
      Timer(const Duration(seconds: 2), () => _player.setSpeed(1.0));
      debugPrint('Soft rate adjustment: $rate for ${drift}ms drift');
    }
  }

  Future<void> stop() async {
    _scheduledPlayTimer?.cancel();
    _stopDriftCorrection();
    await _player.stop();
    _isPlaying = false;
    _expectedStartGlobalMs = null;
    _expectedPositionAtStart = null;
  }

  int get currentPositionMs => _player.position.inMilliseconds;
  bool get isPlaying => _isPlaying;

  void dispose() {
    _scheduledPlayTimer?.cancel();
    _stopDriftCorrection();
    _player.dispose();
  }
}

void debugPrint(String msg) {
  // ignore: avoid_print
  print('[SyncBeat] $msg');
}
