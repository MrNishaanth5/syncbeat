import 'dart:async';
import 'dart:math';

/// NTP-style clock synchronization engine.
/// Computes offset between local device clock and server clock,
/// then schedules audio playback at precise global timestamps.
class SyncEngine {
  int _clockOffset = 0; // milliseconds: serverTime = localTime + offset
  final List<int> _offsetSamples = [];
  static const int _sampleCount = 5;
  static const int _driftCheckIntervalSec = 30;
  Timer? _driftTimer;

  // Callbacks
  Function(int offsetMs)? onClockSynced;
  Function(int driftMs)? onDriftDetected;

  /// Start periodic drift correction
  void startDriftCorrection(Future<int> Function() getServerTime) {
    _driftTimer?.cancel();
    _driftTimer = Timer.periodic(
      const Duration(seconds: _driftCheckIntervalSec),
      (_) => _resync(getServerTime),
    );
  }

  void stopDriftCorrection() {
    _driftTimer?.cancel();
  }

  /// Run NTP handshake. Returns offset in ms.
  /// [getServerTime] is a function that sends T1 to server and returns T2 (server receive time).
  Future<int> syncClock(Future<int> Function(int t1) getServerTimeFor) async {
    _offsetSamples.clear();
    for (int i = 0; i < _sampleCount; i++) {
      final t1 = localTimeMs();
      final t2 = await getServerTimeFor(t1);
      final t3 = localTimeMs();
      final rtt = t3 - t1;
      final offset = t2 - t1 - (rtt ~/ 2);
      _offsetSamples.add(offset);
      await Future.delayed(const Duration(milliseconds: 100));
    }
    // Use median to filter outliers
    final sorted = List<int>.from(_offsetSamples)..sort();
    _clockOffset = sorted[_sampleCount ~/ 2];
    onClockSynced?.call(_clockOffset);
    return _clockOffset;
  }

  Future<void> _resync(Future<int> Function() getServerTime) async {
    final t1 = localTimeMs();
    final t2 = await getServerTime();
    final t3 = localTimeMs();
    final rtt = t3 - t1;
    final newOffset = t2 - t1 - (rtt ~/ 2);
    final drift = (newOffset - _clockOffset).abs();
    if (drift > 5) {
      _clockOffset = newOffset;
      onDriftDetected?.call(drift);
    }
  }

  /// Current local time in ms since epoch
  int localTimeMs() => DateTime.now().millisecondsSinceEpoch;

  /// Estimated server/global time in ms
  int globalTimeMs() => localTimeMs() + _clockOffset;

  /// Convert a global timestamp to local time
  int globalToLocal(int globalMs) => globalMs - _clockOffset;

  /// How many ms until a global timestamp fires?
  int msUntil(int globalTargetMs) => globalToLocal(globalTargetMs) - localTimeMs();

  /// Schedule a callback at a specific global timestamp
  Timer scheduleAt(int globalTargetMs, void Function() callback) {
    final delayMs = max(0, msUntil(globalTargetMs));
    return Timer(Duration(milliseconds: delayMs), callback);
  }

  int get clockOffset => _clockOffset;

  void dispose() {
    _driftTimer?.cancel();
  }
}
