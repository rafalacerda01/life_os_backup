import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';

import 'cycle_reminder_preferences.dart';

class CycleDailyPillControl extends ConsumerWidget {
  const CycleDailyPillControl({
    super.key,
    required this.health,
    this.compact = false,
  });

  final HealthModel health;
  final bool compact;

  static const Color _background = Color(0xFF070B14);
  static const Color _surface = Color(0xFF11182E);
  static const Color _rose = Color(0xFFFF6B9F);
  static const Color _softRose = Color(0xFFFF9FBA);

  void _showSnackBar(BuildContext context, String message) {
    if (!context.mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      );
  }

  Future<bool> _updatePillStatus(
    BuildContext context,
    WidgetRef ref,
    String? expectedUid,
    bool value,
  ) async {
    if (expectedUid == null) {
      _showSnackBar(context, 'Não foi possível atualizar o status.');
      return false;
    }

    try {
      final updated = await ref
          .read(healthRepositoryProvider)
          .updatePillStatus(value, expectedUid: expectedUid);
      if (!updated) {
        _showSnackBar(context, 'Não foi possível atualizar o status.');
        return false;
      }
      return true;
    } on Object {
      AppLogger.w('[CycleDailyStatus] Falha ao atualizar registro diário.');
      _showSnackBar(context, 'Não foi possível atualizar o status.');
      return false;
    }
  }

  Future<bool> _confirmUndo(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (confirmationContext) => AlertDialog(
        backgroundColor: _surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text(
          'Desmarcar registro de hoje?',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
        ),
        content: const Text(
          'O registro de que a pílula foi tomada hoje será removido.',
          style: TextStyle(color: Colors.white70, height: 1.45),
        ),
        actions: [
          TextButton(
            key: const ValueKey('cycle-pill-undo-cancel'),
            onPressed: () => Navigator.pop(confirmationContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            key: const ValueKey('cycle-pill-undo-confirm'),
            onPressed: () => Navigator.pop(confirmationContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: _rose,
              foregroundColor: Colors.black,
            ),
            child: const Text('Desmarcar'),
          ),
        ],
      ),
    );

    return confirmed == true;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final takenToday = health.hasTakenPillToday;
    final expectedUid = ref.read(cycleReminderUserIdReaderProvider)();

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final scale = Tween<double>(begin: 0.97, end: 1).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(scale: scale, child: child),
        );
      },
      child: DecoratedBox(
        key: ValueKey<bool>(takenToday),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(15),
          boxShadow: takenToday
              ? [
                  BoxShadow(
                    color: _rose.withOpacity(0.16),
                    blurRadius: 18,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: OutlinedButton.icon(
          key: const ValueKey('cycle-pill-daily-control'),
          onPressed: () async {
            if (!takenToday) {
              await _updatePillStatus(context, ref, expectedUid, true);
              return;
            }

            final confirmed = await _confirmUndo(context);
            if (!confirmed || !context.mounted) return;
            await _updatePillStatus(context, ref, expectedUid, false);
          },
          style: OutlinedButton.styleFrom(
            foregroundColor: takenToday ? _softRose : Colors.white70,
            backgroundColor: takenToday
                ? _rose.withOpacity(0.10)
                : _background.withOpacity(0.68),
            side: BorderSide(
              color: takenToday ? _softRose.withOpacity(0.55) : Colors.white12,
            ),
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 12 : 15,
              vertical: compact ? 10 : 12,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
          ),
          icon: Icon(
            takenToday ? Icons.check_circle_rounded : Icons.medication_rounded,
            size: compact ? 18 : 19,
          ),
          label: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                takenToday ? 'Tomada hoje' : 'Registrar pílula',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              if (takenToday) ...[
                const SizedBox(width: 6),
                const Icon(Icons.auto_awesome_rounded, size: 13),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
