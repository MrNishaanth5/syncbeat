import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import '../../features/room/room_provider.dart';
import '../../core/audio_controller.dart';
import '../theme.dart';
import 'home_screen.dart';

const int _kMaxPlaylistBytes = kMaxPlaylistBytes;

class RoomScreen extends ConsumerStatefulWidget {
  const RoomScreen({super.key});
  @override
  ConsumerState<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends ConsumerState<RoomScreen> {
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    final notifier = ref.read(roomProvider.notifier);
    final ac = notifier.audioController;

    ac.positionStream.listen((pos) {
      if (!_dragging && mounted) setState(() => _position = pos ?? Duration.zero);
    });
    ac.durationStream.listen((dur) {
      if (mounted) setState(() => _duration = dur ?? Duration.zero);
    });
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _fmtBytes(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';

  /// Opens multi-select picker, checks total size against the limit,
  /// and either starts a fresh playlist or appends to the running one.
  Future<void> _pickPlaylist({required bool append}) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;

    int totalBytes = 0;
    final tracks = <TrackInfo>[];
    for (final f in result.files) {
      if (f.path == null) continue;
      totalBytes += f.size;
      tracks.add(TrackInfo(
        id: f.name,
        title: p.basenameWithoutExtension(f.name),
        artist: 'Local File',
        sourceType: AudioSourceType.localFile,
        sourcePath: f.path!,
      ));
    }

    if (totalBytes > _kMaxPlaylistBytes) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: AppTheme.card,
          title: const Text('Playlist too large', style: TextStyle(color: AppTheme.textPrimary)),
          content: Text(
            'Selected songs total ${_fmtBytes(totalBytes)}, which is over the ${_fmtBytes(_kMaxPlaylistBytes)} limit. '
            'Please pick fewer or smaller songs.',
            style: const TextStyle(color: AppTheme.textSecondary),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK', style: TextStyle(color: AppTheme.cyan))),
          ],
        ),
      );
      return;
    }

    final notifier = ref.read(roomProvider.notifier);
    if (append) {
      notifier.addToPlaylist(tracks);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added ${tracks.length} song(s) to queue'), backgroundColor: AppTheme.card),
      );
    } else {
      notifier.setLocalPlaylist(tracks);
      await notifier.startPlaylist();
    }
  }

  @override
  Widget build(BuildContext context) {
    final room = ref.watch(roomProvider);
    final notifier = ref.read(roomProvider.notifier);
    final isHost = room.isHost;
    final track = room.currentTrack;
    final isPlaying = room.playbackState == PlaybackState.playing;
    final isLoading = room.playbackState == PlaybackState.loading || room.isPreparingNext;
    final queue = room.queueInfo;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () {
                      notifier.leaveRoom();
                      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const HomeScreen()));
                    },
                    child: const Icon(Icons.arrow_back_ios, color: AppTheme.textSecondary, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('ROOM  ${room.roomCode ?? ''}',
                          style: const TextStyle(color: AppTheme.cyan, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 2)),
                        Text(isHost ? 'You are the host' : 'Listening along',
                          style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: room.roomCode ?? ''));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Room code copied!'), backgroundColor: AppTheme.card, duration: Duration(seconds: 1)),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(color: AppTheme.card, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
                      child: const Row(children: [
                        Icon(Icons.copy, color: AppTheme.textSecondary, size: 14),
                        SizedBox(width: 4),
                        Text('Copy Code', style: TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
                      ]),
                    ),
                  ),
                ],
              ),
            ),

            // Members
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: room.members.map((m) => _MemberChip(member: m)).toList(),
              ),
            ),

            const SizedBox(height: 8),
            const Divider(color: AppTheme.border, height: 1),

            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Art
                    Container(
                      width: 180,
                      height: 180,
                      decoration: BoxDecoration(
                        color: AppTheme.card,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: AppTheme.border, width: 1.5),
                        boxShadow: track != null
                          ? [BoxShadow(color: AppTheme.cyan.withOpacity(0.15), blurRadius: 40, spreadRadius: 5)]
                          : null,
                      ),
                      child: track != null
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(isLoading ? Icons.cloud_upload_outlined : Icons.music_note, color: AppTheme.cyan, size: 48),
                              const SizedBox(height: 8),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: Text(track.title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.bold)),
                              ),
                            ],
                          )
                        : Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.queue_music, color: AppTheme.textMuted, size: 44),
                              const SizedBox(height: 8),
                              Text(isHost ? 'Pick songs below' : 'Waiting for host...',
                                style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                            ],
                          ),
                    ),

                    const SizedBox(height: 12),

                    // Queue position indicator
                    if (queue.total > 0)
                      Text(
                        'Track ${queue.currentIndex + 1} of ${queue.total}'
                        '${queue.nextTitle != null ? "  ·  Up next: ${queue.nextTitle}" : ""}',
                        style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                      ),

                    const SizedBox(height: 28),

                    if (track != null) ...[
                      SliderTheme(
                        data: SliderThemeData(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                          activeTrackColor: AppTheme.cyan,
                          inactiveTrackColor: AppTheme.border,
                          thumbColor: AppTheme.cyan,
                          overlayColor: AppTheme.cyan.withOpacity(0.2),
                        ),
                        child: Slider(
                          value: _duration.inMilliseconds > 0 ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0) : 0.0,
                          onChangeStart: isHost ? (_) => setState(() => _dragging = true) : null,
                          onChangeEnd: isHost ? (v) {
                            setState(() => _dragging = false);
                            notifier.seek((v * _duration.inMilliseconds).toInt());
                          } : null,
                          onChanged: isHost ? (v) => setState(() => _position = Duration(milliseconds: (v * _duration.inMilliseconds).toInt())) : null,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          Text(_fmt(_position), style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
                          Text(_fmt(_duration), style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
                        ]),
                      ),
                      const SizedBox(height: 14),
                    ],

                    // Controls
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (isHost) ...[
                          _ControlBtn(icon: Icons.library_music, color: AppTheme.textSecondary, size: 22,
                            onTap: () => _pickPlaylist(append: false)),
                          const SizedBox(width: 16),
                        ],
                        GestureDetector(
                          onTap: isHost ? () => isPlaying ? notifier.pause() : notifier.play() : null,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width: 64, height: 64,
                            decoration: BoxDecoration(
                              color: isHost ? AppTheme.cyan : AppTheme.textMuted.withOpacity(0.3),
                              shape: BoxShape.circle,
                              boxShadow: isHost ? [BoxShadow(color: AppTheme.cyan.withOpacity(0.4), blurRadius: 20)] : null,
                            ),
                            child: isLoading
                              ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2)))
                              : Icon(isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.black, size: 30),
                          ),
                        ),
                        if (isHost) ...[
                          const SizedBox(width: 16),
                          _ControlBtn(icon: Icons.playlist_add, color: AppTheme.textSecondary, size: 22,
                            onTap: () => _pickPlaylist(append: true)),
                        ],
                      ],
                    ),

                    if (isHost && room.queueInfo.total > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text('Tap + to add more songs to the queue', style: const TextStyle(color: AppTheme.textMuted, fontSize: 10)),
                      ),

                    if (!isHost)
                      const Padding(
                        padding: EdgeInsets.only(top: 14),
                        child: Text('Only the host can control playback', style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                      ),
                  ],
                ),
              ),
            ),

            _SyncBar(clockOffset: room.clockOffsetMs),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _MemberChip extends StatelessWidget {
  final RoomMember member;
  const _MemberChip({required this.member});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: member.isHost ? AppTheme.cyan.withOpacity(0.1) : AppTheme.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: member.isHost ? AppTheme.cyan.withOpacity(0.5) : AppTheme.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(member.isHost ? Icons.star : Icons.person, color: member.isHost ? AppTheme.cyan : AppTheme.textSecondary, size: 13),
        const SizedBox(width: 5),
        Text(member.displayName, style: TextStyle(color: member.isHost ? AppTheme.cyan : AppTheme.textSecondary, fontSize: 12)),
      ]),
    );
  }
}

class _ControlBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  final VoidCallback onTap;
  const _ControlBtn({required this.icon, required this.color, required this.size, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 44, height: 44,
      decoration: BoxDecoration(color: AppTheme.card, shape: BoxShape.circle, border: Border.all(color: AppTheme.border)),
      child: Icon(icon, color: color, size: size),
    ),
  );
}

class _SyncBar extends StatelessWidget {
  final int clockOffset;
  const _SyncBar({required this.clockOffset});
  @override
  Widget build(BuildContext context) {
    final color = clockOffset.abs() < 20 ? AppTheme.green : clockOffset.abs() < 50 ? AppTheme.cyan : AppTheme.orange;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withOpacity(0.3))),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.sync, color: color, size: 14),
          const SizedBox(width: 6),
          Text('Clock offset: ${clockOffset}ms', style: TextStyle(color: color, fontSize: 11)),
        ]),
      ),
    );
  }
}
