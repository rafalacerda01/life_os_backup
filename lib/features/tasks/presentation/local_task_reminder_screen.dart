import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/tasks/data/services/local_task_reminder.dart';

final localTaskReminderProvider = Provider<LocalTaskReminder>((ref) {
  throw StateError('LOCAL_TASK_REMINDER_SCOPE_REQUIRED');
});

final _reminderStatus = FutureProvider.autoDispose<TaskReminderStatus>((ref) {
  return ref.watch(localTaskReminderProvider).status();
});

class LocalTaskReminderScreen extends ConsumerStatefulWidget {
  const LocalTaskReminderScreen({super.key});

  @override
  ConsumerState<LocalTaskReminderScreen> createState() =>
      _LocalTaskReminderScreenState();
}

class _LocalTaskReminderScreenState
    extends ConsumerState<LocalTaskReminderScreen> {
  bool _busy = false;

  Future<void> _update(
    Future<void> Function(LocalTaskReminder) operation,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation(ref.read(localTaskReminderProvider));
    } catch (_) {
      if (mounted) _note('Não foi possível confirmar a mudança do lembrete.');
    } finally {
      if (mounted) {
        ref.invalidate(_reminderStatus);
        setState(() => _busy = false);
      }
    }
  }

  void _note(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _chooseTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 9, minute: 0),
    );
    if (!mounted || time == null) return;
    await _update((service) async {
      final scheduled = await service.create(time.hour * 60 + time.minute);
      if (!scheduled && mounted)
        _note('O Android não autorizou a notificação.');
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Lembrete de tarefas')),
    body: ref
        .watch(_reminderStatus)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text('Não foi possível verificar o lembrete.'),
              TextButton(
                onPressed: _busy ? null : () => ref.invalidate(_reminderStatus),
                child: const Text('Tentar novamente'),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _update((service) => service.remove()),
                child: const Text('Remover meu lembrete'),
              ),
            ],
          ),
          data: (status) {
            final minuteOfDay = status.minuteOfDay;
            final time = minuteOfDay == null
                ? null
                : TimeOfDay(hour: minuteOfDay ~/ 60, minute: minuteOfDay % 60);
            final message = time != null
                ? 'Todos os dias às ${time.format(context)}'
                : status.needsRecovery
                ? 'Há um agendamento pendente de confirmação.'
                : 'Nenhum lembrete diário ativo.';
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(message),
                const SizedBox(height: 16),
                if (time == null && !status.needsRecovery)
                  FilledButton(
                    onPressed: _busy ? null : _chooseTime,
                    child: const Text('Agendar lembrete'),
                  )
                else
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _update((service) => service.remove()),
                    child: const Text('Remover meu lembrete'),
                  ),
              ],
            );
          },
        ),
  );
}
