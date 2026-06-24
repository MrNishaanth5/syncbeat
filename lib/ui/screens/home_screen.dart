import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/room/room_provider.dart';
import '../theme.dart';
import 'room_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> with TickerProviderStateMixin {
  final _codeController = TextEditingController();
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    _pulseAnim = Tween(begin: 0.6, end: 1.0).animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final roomState = ref.watch(roomProvider);
    final notifier = ref.read(roomProvider.notifier);

    // Navigate to room screen when connected
    if (roomState.status == RoomStatus.connected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const RoomScreen()),
        );
      });
    }

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Logo
              AnimatedBuilder(
                animation: _pulseAnim,
                builder: (_, __) => Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppTheme.cyan.withOpacity(_pulseAnim.value),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [BoxShadow(color: AppTheme.cyan.withOpacity(0.4 * _pulseAnim.value), blurRadius: 20, spreadRadius: 2)],
                      ),
                      child: const Icon(Icons.music_note, color: Colors.black, size: 22),
                    ),
                    const SizedBox(width: 12),
                    const Text('SYNCBEAT', style: TextStyle(color: AppTheme.textPrimary, fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 3)),
                  ],
                ),
              ),

              const SizedBox(height: 12),
              const Text('Synchronized music. Every beat, together.', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),

              const SizedBox(height: 52),

              // Error
              if (roomState.status == RoomStatus.error) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.red.shade900.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.red.shade800),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
                      const SizedBox(width: 10),
                      Expanded(child: Text(roomState.errorMessage ?? 'Something went wrong', style: const TextStyle(color: Colors.redAccent, fontSize: 13))),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],

              // Create Room
              _SectionLabel(label: 'START A LISTENING PARTY'),
              const SizedBox(height: 12),
              _GlowButton(
                label: 'Create Room',
                icon: Icons.add_circle_outline,
                loading: roomState.status == RoomStatus.creating,
                onTap: () => notifier.createRoom(),
              ),

              const SizedBox(height: 40),
              _Divider(),
              const SizedBox(height: 40),

              // Join Room
              _SectionLabel(label: 'JOIN A ROOM'),
              const SizedBox(height: 12),
              TextField(
                controller: _codeController,
                textCapitalization: TextCapitalization.characters,
                maxLength: 6,
                style: const TextStyle(color: AppTheme.textPrimary, fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 6),
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                  hintText: 'ROOM CODE',
                  counterText: '',
                  contentPadding: EdgeInsets.symmetric(vertical: 18),
                ),
              ),
              const SizedBox(height: 14),
              _GlowButton(
                label: 'Join Room',
                icon: Icons.login,
                color: AppTheme.purple,
                loading: roomState.status == RoomStatus.joining,
                onTap: () {
                  final code = _codeController.text.trim();
                  if (code.length == 6) notifier.joinRoom(code);
                },
              ),

              const SizedBox(height: 60),
              _InfoCard(),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});
  @override
  Widget build(BuildContext context) => Text(
    label,
    style: const TextStyle(color: AppTheme.textMuted, fontSize: 11, letterSpacing: 2, fontWeight: FontWeight.bold),
  );
}

class _GlowButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool loading;
  final VoidCallback onTap;

  const _GlowButton({
    required this.label, required this.icon, required this.onTap,
    this.color = AppTheme.cyan, this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: loading ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: double.infinity,
        height: 56,
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.6), width: 1.5),
          boxShadow: [BoxShadow(color: color.withOpacity(0.15), blurRadius: 16, spreadRadius: 0)],
        ),
        child: loading
          ? Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: color, strokeWidth: 2)))
          : Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 10),
                Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 15, letterSpacing: 1)),
              ],
            ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: Container(height: 1, color: AppTheme.border)),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text('OR', style: TextStyle(color: AppTheme.textMuted, fontSize: 11, letterSpacing: 2)),
      ),
      Expanded(child: Container(height: 1, color: AppTheme.border)),
    ],
  );
}

class _InfoCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('HOW IT WORKS', style: TextStyle(color: AppTheme.textMuted, fontSize: 10, letterSpacing: 2)),
          const SizedBox(height: 12),
          ...[
            ('1', 'Host creates a room and gets a 6-digit code'),
            ('2', 'Friends join using the code'),
            ('3', 'Host picks a song from local files'),
            ('4', 'Everyone hears it in perfect sync'),
          ].map((e) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 20, height: 20,
                  decoration: BoxDecoration(color: AppTheme.cyan.withOpacity(0.15), shape: BoxShape.circle),
                  child: Center(child: Text(e.$1, style: const TextStyle(color: AppTheme.cyan, fontSize: 10, fontWeight: FontWeight.bold))),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(e.$2, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
              ],
            ),
          )),
        ],
      ),
    );
  }
}
