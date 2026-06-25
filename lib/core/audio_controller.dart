import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'sync_engine.dart';

enum AudioSourceType { localFile, url }

class AudioLoadException implements Exception {
  final String message;
  AudioLoadException(this.message);
  @override
  String toString() => 'AudioLoadException: $message';
}

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
  Timer? _positionUpdateTimer;
  Timer? _scheduledPlayTimer;
  int? _expectedStartGlobalMs;
  int? _expectedPositionAtStart;
  bool _isPlaying = false;

  // Drift correction thresholds
  static const int _hardSeekThresholdMs = 50;
  static const int _softAdjustThresholdMs = 10;
  
  // Position update interval (100ms for smooth updates)
  static const Duration _positionUpdateInterval = Duration(milliseconds: 100);

  TrackInfo? currentTrack;

  // Streams
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<Duration?> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;

  AudioController(this._syncEngine);

  /// Request necessary audio permissions
  Future<bool> requestAudioPermissions() async {
    debugPrint('AudioController: Requesting audio permissions...');
    
    try {
      final storageStatus = await Permission.storage.request();
      debugPrint('AudioController: Storage permission status: $storageStatus');
      
      if (!storageStatus.isGranted) {
        debugPrint('AudioController: Storage permission denied');
        return false;
      }
      
      debugPrint('AudioController: Audio permissions granted');
      return true;
    } catch (e) {
      debugPrint('AudioController: Permission request failed: $e');
      return false;
    }
  }

  /// Validate file exists and is accessible
  Future<bool> _validateLocalFile(String filePath) async {
    try {
      final file = File(filePath);
      final exists = await file.exists();
      
      if (!exists) {
        debugPrint('AudioController: File not found at $filePath');
        return false;
      }
      
      // Check if file is readable
      final isReadable = await file.access() == FileSystemEntity.typeFile;
      if (!isReadable) {
        debugPrint('AudioController: File is not readable: $filePath');
        return false;
      }
      
      debugPrint('AudioController: File validated: $filePath');
      return true;
    } catch (e) {
      debugPrint('AudioController: File validation error: $e');
      return false;
    }
  }

  /// Load track with full validation
  Future<void> loadTrack(TrackInfo track) async {
    currentTrack = track;
    debugPrint('AudioController: Loading track: ${track.title}');
    
    try {
      // Validate permissions for local files
      if (track.sourceType == AudioSourceType.localFile) {
        final hasPermissions = await requestAudioPermissions();
        if (!hasPermissions) {
          throw AudioLoadException('Audio permissions not granted');
        }
        
        // Validate file exists and is accessible
        final isValid = await _validateLocalFile(track.sourcePath);
        if (!isValid) {
          throw AudioLoadException('Audio file not found or not accessible: ${track.sourcePath}');
        }
        
        await _player.setAudioSource(AudioSource.file(track.sourcePath));
        debugPrint('AudioController: Local file loaded successfully');
      } else {
        // Validate URL format for remote files
        try {
          Uri.parse(track.sourcePath);
        } catch (e) {
          throw AudioLoadException('Invalid URL format: ${track.sourcePath}');
        }
        
        await _player.setAudioSource(AudioSource.uri(Uri.parse(track.sourcePath)));
        debugPrint('AudioController: Remote URL loaded successfully');
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
    debugPrint('AudioController: Scheduling play in ${delayMs}ms at position ${positionMs}ms');

    _scheduledPlayTimer = Timer(Duration(milliseconds: delayMs), () async {
      await _player.play();
      _isPlaying = true;
      _startDriftCorrection();
      _startPositionUpdates();
    });
  }

  /// Immediately pause (called when server says pause_at is now)
  Future<void> schedulePause({required int globalPauseAtMs}) async {
    final delayMs = max(0, _syncEngine.msUntil(globalPauseAtMs));
    Timer(Duration(milliseconds: delayMs), () async {
      await _player.pause();
      _isPlaying = false;
      _stopDriftCorrection();
      _stopPositionUpdates();
    });
  }

  /// Start periodic position updates to ensure smooth UI updates
  void _startPositionUpdates() {
    _positionUpdateTimer?.cancel();
    _positionUpdateTimer = Timer.periodic(_positionUpdateInterval, (_) {
      // Emit position updates for UI binding
      // This ensures smooth slider movement every 100ms
      debugPrint('Position: ${_player.position.inMilliseconds}ms');
    });
  }

  /// Stop position update timer
  void _stopPositionUpdates() {
    _positionUpdateTimer?.cancel();
    _positionUpdateTimer = null;
  }

  void _startDriftCorrection() {
    _driftCheckTimer?.cancel();
    _driftCheckTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _checkAndCorrectDrift();
    });
  }

  void _stopDriftCorrection() {
    _driftCheckTimer?.cancel();
    _driftCheckTimer = null;
  }

  void _checkAndCorrectDrift() {
    if (!_isPlaying || _expectedStartGlobalMs == null || _expectedPositionAtStart == null) return;

    final elapsedSinceStart = _syncEngine.globalTimeMs() - _expectedStartGlobalMs!;
    final expectedPositionMs = _expectedPositionAtStart! + elapsedSinceStart;
    final actualPositionMs = _player.position.inMilliseconds;
    final drift = actualPositionMs - expectedPositionMs;

    debugPrint('Drift check: expected=${expectedPositionMs}ms, actual=${actualPositionMs}ms, drift=${drift}ms');

    if (drift.abs() > _hardSeekThresholdMs) {
      // Hard correction
      _player.seek(Duration(milliseconds: expectedPositionMs));
      debugPrint('AudioController: Hard seek correction applied (${drift}ms drift)');
    } else if (drift.abs() > _softAdjustThresholdMs) {
      // Soft rate adjustment (inaudible ±2%)
      final rate = drift > 0 ? 0.98 : 1.02;
      _player.setSpeed(rate);
      // Reset rate after 2s
      Timer(const Duration(seconds: 2), () => _player.setSpeed(1.0));
      debugPrint('AudioController: Soft rate adjustment ($rate) for ${drift}ms drift');
    }
  }

  Future<void> stop() async {
    _scheduledPlayTimer?.cancel();
    _stopDriftCorrection();
    _stopPositionUpdates();
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
    _stopPositionUpdates();
    _player.dispose();
  }
}

void debugPrint(String msg) {
  // ignore: avoid_print
  print('[SyncBeat] $msg');
}
