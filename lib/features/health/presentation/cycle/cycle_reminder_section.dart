import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/health/data/models/health_model.dart';

import 'cycle_daily_pill_control.dart';
import 'cycle_reminder_notification_controller.dart';
import 'cycle_reminder_preferences.dart';

typedef CycleReminderTimePicker =
    Future<TimeOfDay?> Function(BuildContext context);

class CycleReminderSection extends ConsumerWidget {
  const CycleReminderSection({super.key, required this.health});

  final HealthModel health;

  static const Color _background = Color(0xFF070B14);
  static const Color _surface = Color(0xFF11182E);
  static const Color _primary = Color(0xFFB026FF);
  static const Color _rose = Color(0xFFFF6B9F);
  static const Color _lilac = Color(0xFFC58CFF);
  static const Color _turquoise = Color(0xFF58D6C7);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preferencesAsync = ref.watch(cycleReminderPreferencesProvider);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_surface, _surface, _primary.withOpacity(0.07)],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _primary.withOpacity(0.22)),
        boxShadow: [
          BoxShadow(
            color: _primary.withOpacity(0.06),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: preferencesAsync.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(color: _primary)),
        error: (_, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'ROTINA PESSOAL',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Não foi possível carregar a configuração local.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => ref.invalidate(cycleReminderPreferencesProvider),
              child: const Text('Tentar novamente'),
            ),
          ],
        ),
        data: (preferences) => _CycleReminderSummary(
          health: health,
          preferences: preferences,
          onConfigure: () => _openEditor(context, ref, preferences),
          onEnabledChanged: preferences == null
              ? null
              : (enabled) => _setEnabled(context, ref, enabled),
        ),
      ),
    );
  }

  Future<void> _openEditor(
    BuildContext context,
    WidgetRef ref,
    CycleReminderPreferences? preferences,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: CycleReminderEditor(
          initialValue: preferences,
          onSave: (value) =>
              ref.read(cycleReminderNotificationControllerProvider).save(value),
        ),
      ),
    );
  }

  Future<void> _setEnabled(
    BuildContext context,
    WidgetRef ref,
    bool enabled,
  ) async {
    try {
      await ref
          .read(cycleReminderNotificationControllerProvider)
          .setEnabled(
            ref.read(cycleReminderPreferencesProvider).requireValue!,
            enabled,
          );
    } on Object {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Não foi possível atualizar o lembrete local.'),
        ),
      );
    }
  }
}

class _CycleReminderSummary extends StatelessWidget {
  const _CycleReminderSummary({
    required this.health,
    required this.preferences,
    required this.onConfigure,
    required this.onEnabledChanged,
  });

  final HealthModel health;
  final CycleReminderPreferences? preferences;
  final VoidCallback onConfigure;
  final ValueChanged<bool>? onEnabledChanged;

  @override
  Widget build(BuildContext context) {
    final value = preferences;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: value == null
          ? _CycleReminderEmptyState(onConfigure: onConfigure)
          : _ConfiguredCycleRoutine(
              key: ValueKey('${value.type.name}-${value.enabled}'),
              health: health,
              preferences: value,
              onConfigure: onConfigure,
              onEnabledChanged: onEnabledChanged,
            ),
    );
  }
}

class _CycleReminderEmptyState extends StatelessWidget {
  const _CycleReminderEmptyState({required this.onConfigure});

  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('cycle-reminder-empty'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _RoutineEyebrow(),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: CycleReminderSection._primary.withOpacity(0.12),
                borderRadius: BorderRadius.circular(15),
              ),
              child: const Icon(
                Icons.notifications_none_rounded,
                color: CycleReminderSection._lilac,
              ),
            ),
            const SizedBox(width: 13),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Crie uma rotina pessoal',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  SizedBox(height: 5),
                  Text(
                    'Configure um lembrete discreto para acompanhar algo importante na sua rotina.',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const ValueKey('cycle-reminder-configure'),
          onPressed: onConfigure,
          style: FilledButton.styleFrom(
            backgroundColor: CycleReminderSection._primary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
          ),
          icon: const Icon(Icons.add_rounded, size: 19),
          label: const Text('Configurar lembrete'),
        ),
      ],
    );
  }
}

class _ConfiguredCycleRoutine extends StatelessWidget {
  const _ConfiguredCycleRoutine({
    super.key,
    required this.health,
    required this.preferences,
    required this.onConfigure,
    required this.onEnabledChanged,
  });

  final HealthModel health;
  final CycleReminderPreferences preferences;
  final VoidCallback onConfigure;
  final ValueChanged<bool>? onEnabledChanged;

  @override
  Widget build(BuildContext context) {
    final isPill = preferences.type == CycleReminderType.pill;
    final statusLabel = preferences.enabled
        ? 'Lembrete ativo'
        : 'Notificações pausadas';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: _RoutineEyebrow()),
            TextButton.icon(
              key: const ValueKey('cycle-reminder-adjust'),
              onPressed: onConfigure,
              style: TextButton.styleFrom(
                foregroundColor: CycleReminderSection._lilac,
                minimumSize: const Size(48, 48),
              ),
              icon: const Icon(Icons.tune_rounded, size: 18),
              label: const Text('Ajustar'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: CycleReminderSection._background.withOpacity(0.72),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: preferences.type.accent.withOpacity(0.13),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(
                      preferences.type.icon,
                      color: preferences.type.accent,
                      size: 21,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      preferences.type.label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              LayoutBuilder(
                builder: (context, constraints) => Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _RoutineDetail(
                      icon: Icons.schedule_rounded,
                      label: _formatTime(preferences.hour, preferences.minute),
                      maxWidth: constraints.maxWidth,
                    ),
                    _RoutineDetail(
                      icon: Icons.repeat_rounded,
                      label: preferences.frequency.summary(
                        preferences.weekdays,
                      ),
                      maxWidth: constraints.maxWidth,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 13),
              Row(
                children: [
                  Semantics(
                    label: statusLabel,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: preferences.enabled
                            ? CycleReminderSection._turquoise
                            : Colors.white38,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      statusLabel,
                      style: TextStyle(
                        color: preferences.enabled
                            ? Colors.white70
                            : Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Tooltip(
                    message: preferences.enabled
                        ? 'Pausar notificações'
                        : 'Ativar notificações',
                    child: Switch(
                      value: preferences.enabled,
                      activeColor: CycleReminderSection._primary,
                      onChanged: onEnabledChanged,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  const Icon(
                    Icons.lock_outline_rounded,
                    color: Colors.white38,
                    size: 14,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'Privacidade: ${preferences.privacyMode.label}',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (isPill) ...[
          const SizedBox(height: 14),
          CycleDailyPillControl(health: health),
        ],
      ],
    );
  }
}

class _RoutineEyebrow extends StatelessWidget {
  const _RoutineEyebrow();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'ROTINA PESSOAL',
      style: TextStyle(
        color: Colors.white54,
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.1,
      ),
    );
  }
}

class _RoutineDetail extends StatelessWidget {
  const _RoutineDetail({
    required this.icon,
    required this.label,
    required this.maxWidth,
  });

  final IconData icon;
  final String label;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.045),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: CycleReminderSection._lilac, size: 15),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CycleReminderEditor extends StatefulWidget {
  const CycleReminderEditor({
    super.key,
    required this.onSave,
    this.initialValue,
    this.timePicker,
  });

  final CycleReminderPreferences? initialValue;
  final Future<void> Function(CycleReminderPreferences value) onSave;
  final CycleReminderTimePicker? timePicker;

  @override
  State<CycleReminderEditor> createState() => _CycleReminderEditorState();
}

class _CycleReminderEditorState extends State<CycleReminderEditor> {
  static const Color _background = Color(0xFF0A0F1E);
  static const Color _surface = Color(0xFF11182E);
  static const Color _primary = Color(0xFFB026FF);
  static const Color _rose = Color(0xFFFF6B9F);
  static const Color _lilac = Color(0xFFC58CFF);
  static const Color _turquoise = Color(0xFF58D6C7);

  late CycleReminderType? _type;
  late TimeOfDay? _time;
  late CycleReminderFrequency? _frequency;
  late Set<int> _weekdays;
  late CycleReminderPrivacyMode _privacyMode;
  late final TextEditingController _titleController;
  late final TextEditingController _bodyController;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialValue;
    _type = initial?.type;
    _time = initial == null
        ? null
        : TimeOfDay(hour: initial.hour, minute: initial.minute);
    _frequency = initial?.frequency;
    _weekdays = Set<int>.of(initial?.weekdays ?? const <int>{});
    _privacyMode = initial?.privacyMode ?? CycleReminderPrivacyMode.discreet;
    _titleController = TextEditingController(text: initial?.customTitle ?? '');
    _bodyController = TextEditingController(text: initial?.customBody ?? '');
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.92,
      ),
      decoration: const BoxDecoration(
        color: _background,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 18),
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _EditorHeaderIcon(),
                SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Lembrete pessoal',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                        ),
                      ),
                      SizedBox(height: 5),
                      Text(
                        'Escolha cada detalhe. Nenhum horário ou frequência é inferido.',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 26),
            _label('Tipo'),
            Wrap(
              spacing: 9,
              runSpacing: 9,
              children: CycleReminderType.values
                  .map(
                    (type) => _selectionChip(
                      label: type.label,
                      icon: type.icon,
                      accent: type.accent,
                      selected: _type == type,
                      onSelected: () => setState(() => _type = type),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 22),
            _label('Horário'),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const ValueKey('cycle-reminder-time'),
                onPressed: _pickTime,
                style: OutlinedButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  foregroundColor: _time == null ? Colors.white60 : _lilac,
                  backgroundColor: _surface,
                  side: BorderSide(
                    color: _time == null
                        ? Colors.white12
                        : _lilac.withOpacity(0.48),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 15,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(17),
                  ),
                ),
                icon: const Icon(Icons.schedule_rounded),
                label: Text(
                  _time == null
                      ? 'Escolher horário'
                      : _formatTime(_time!.hour, _time!.minute),
                  style: TextStyle(
                    fontSize: _time == null ? 14 : 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: _time == null ? 0 : 0.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 22),
            _label('Frequência'),
            Wrap(
              spacing: 9,
              runSpacing: 9,
              children: CycleReminderFrequency.values
                  .map(
                    (frequency) => _selectionChip(
                      label: frequency.label,
                      icon: frequency == CycleReminderFrequency.daily
                          ? Icons.today_rounded
                          : Icons.date_range_rounded,
                      accent: _turquoise,
                      selected: _frequency == frequency,
                      onSelected: () => setState(() => _frequency = frequency),
                    ),
                  )
                  .toList(),
            ),
            if (_frequency == CycleReminderFrequency.specificWeekdays) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: List<Widget>.generate(7, (index) {
                  final day = index + 1;
                  final selected = _weekdays.contains(day);
                  return FilterChip(
                    label: Text(_weekdayLabels[index]),
                    selected: selected,
                    onSelected: (selected) {
                      setState(() {
                        if (selected) {
                          _weekdays.add(day);
                        } else {
                          _weekdays.remove(day);
                        }
                      });
                    },
                    selectedColor: _primary.withOpacity(0.24),
                    backgroundColor: _surface,
                    checkmarkColor: Colors.white,
                    side: BorderSide(
                      color: selected
                          ? _lilac.withOpacity(0.85)
                          : Colors.white12,
                      width: selected ? 1.5 : 1,
                    ),
                    labelStyle: TextStyle(
                      color: selected ? Colors.white : Colors.white60,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  );
                }),
              ),
            ],
            const SizedBox(height: 22),
            _label('Privacidade'),
            ...CycleReminderPrivacyMode.values.map(_privacyOption),
            if (_privacyMode == CycleReminderPrivacyMode.custom) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _titleController,
                maxLength: 60,
                onChanged: (_) => setState(() {}),
                decoration: _inputDecoration('Título personalizado'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _bodyController,
                maxLength: 160,
                maxLines: 3,
                onChanged: (_) => setState(() {}),
                decoration: _inputDecoration('Mensagem personalizada'),
              ),
            ],
            const SizedBox(height: 22),
            _label('Prévia da notificação'),
            CycleReminderPreview(
              type: _type,
              privacyMode: _privacyMode,
              customTitle: _titleController.text,
              customBody: _bodyController.text,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('cycle-reminder-save'),
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                  backgroundColor: _primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: _saving
                      ? const SizedBox(
                          key: ValueKey('cycle-reminder-saving'),
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'Salvar lembrete',
                          key: ValueKey('cycle-reminder-save-label'),
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickTime() async {
    final selected = await (widget.timePicker ?? _defaultTimePicker)(context);
    if (selected != null && mounted) setState(() => _time = selected);
  }

  Future<TimeOfDay?> _defaultTimePicker(BuildContext context) {
    return showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 12, minute: 0),
      helpText: 'Escolha o horário do lembrete',
      cancelText: 'Cancelar',
      confirmText: 'OK',
      builder: (pickerContext, child) {
        final mediaQuery = MediaQuery.of(pickerContext);
        return MediaQuery(
          data: mediaQuery.copyWith(alwaysUse24HourFormat: true),
          child: child!,
        );
      },
    );
  }

  Future<void> _save() async {
    final type = _type;
    final time = _time;
    final frequency = _frequency;
    if (type == null || time == null || frequency == null) {
      setState(() {
        _error = 'Escolha tipo, horário e frequência.';
      });
      return;
    }

    try {
      final preferences = CycleReminderPreferences(
        enabled: widget.initialValue?.enabled ?? true,
        type: type,
        hour: time.hour,
        minute: time.minute,
        frequency: frequency,
        weekdays: _weekdays,
        privacyMode: _privacyMode,
        customTitle: _titleController.text,
        customBody: _bodyController.text,
      );

      setState(() {
        _saving = true;
        _error = null;
      });
      await widget.onSave(preferences);
      if (mounted) Navigator.of(context).pop();
    } on ArgumentError catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.message == 'CYCLE_REMINDER_WEEKDAYS_REQUIRED'
            ? 'Escolha pelo menos um dia da semana.'
            : error.message == 'CYCLE_REMINDER_CUSTOM_TEXT_REQUIRED'
            ? 'Preencha título e mensagem personalizados.'
            : 'Revise os dados do lembrete.';
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Não foi possível salvar a configuração local.';
      });
    }
  }

  Widget _selectionChip({
    required String label,
    required IconData icon,
    required Color accent,
    required bool selected,
    required VoidCallback onSelected,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: accent.withOpacity(0.16),
                  blurRadius: 15,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: ChoiceChip(
        label: Text(label),
        avatar: Icon(
          selected ? Icons.check_rounded : icon,
          size: 17,
          color: selected ? Colors.white : Colors.white54,
        ),
        selected: selected,
        showCheckmark: false,
        onSelected: (_) => onSelected(),
        selectedColor: accent.withOpacity(0.22),
        backgroundColor: _surface,
        side: BorderSide(
          color: selected ? accent.withOpacity(0.9) : Colors.white12,
          width: selected ? 1.6 : 1,
        ),
        labelStyle: TextStyle(
          color: selected ? Colors.white : Colors.white60,
          fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  Widget _privacyOption(CycleReminderPrivacyMode mode) {
    final selected = _privacyMode == mode;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: selected ? _primary.withOpacity(0.10) : _surface,
          borderRadius: BorderRadius.circular(17),
          border: Border.all(
            color: selected ? _lilac.withOpacity(0.72) : Colors.white10,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(17),
          clipBehavior: Clip.antiAlias,
          child: RadioListTile<CycleReminderPrivacyMode>(
            value: mode,
            groupValue: _privacyMode,
            onChanged: (value) {
              if (value != null) setState(() => _privacyMode = value);
            },
            selected: selected,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10),
            activeColor: _primary,
            title: Text(
              mode.label,
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
            subtitle: Text(
              mode.description,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 11,
                height: 1.35,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 9),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white70,
        fontSize: 13,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: _surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
    );
  }
}

class _EditorHeaderIcon extends StatelessWidget {
  const _EditorHeaderIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _CycleReminderEditorState._primary.withOpacity(0.24),
            _CycleReminderEditorState._rose.withOpacity(0.14),
          ],
        ),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: _CycleReminderEditorState._lilac.withOpacity(0.35),
        ),
      ),
      child: const Icon(
        Icons.notifications_active_outlined,
        color: _CycleReminderEditorState._lilac,
      ),
    );
  }
}

class CycleReminderPreview extends StatelessWidget {
  const CycleReminderPreview({
    super.key,
    required this.type,
    required this.privacyMode,
    this.customTitle = '',
    this.customBody = '',
  });

  final CycleReminderType? type;
  final CycleReminderPrivacyMode privacyMode;
  final String customTitle;
  final String customBody;

  @override
  Widget build(BuildContext context) {
    final (title, body) = switch (privacyMode) {
      CycleReminderPrivacyMode.discreet => (
        'Lembrete pessoal',
        'Você tem um lembrete programado.',
      ),
      CycleReminderPrivacyMode.informative => (
        type?.informativeTitle ?? 'Lembrete pessoal',
        'Horário do seu lembrete.',
      ),
      CycleReminderPrivacyMode.custom => (
        customTitle.trim().isEmpty ? 'Seu título' : customTitle.trim(),
        customBody.trim().isEmpty ? 'Sua mensagem' : customBody.trim(),
      ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _CycleReminderEditorState._surface,
            _CycleReminderEditorState._primary.withOpacity(0.07),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: _CycleReminderEditorState._lilac.withOpacity(0.22),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: _CycleReminderEditorState._primary.withOpacity(0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.notifications_none_rounded,
              color: _CycleReminderEditorState._lilac,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

extension on CycleReminderType {
  String get label => switch (this) {
    CycleReminderType.pill => 'Pílula',
    CycleReminderType.otherContraceptive => 'Outro contraceptivo',
    CycleReminderType.personal => 'Lembrete pessoal',
  };

  String get informativeTitle => switch (this) {
    CycleReminderType.pill => 'Lembrete de pílula',
    CycleReminderType.otherContraceptive => 'Lembrete de contraceptivo',
    CycleReminderType.personal => 'Lembrete pessoal',
  };

  IconData get icon => switch (this) {
    CycleReminderType.pill => Icons.medication_rounded,
    CycleReminderType.otherContraceptive => Icons.health_and_safety_rounded,
    CycleReminderType.personal => Icons.auto_awesome_rounded,
  };

  Color get accent => switch (this) {
    CycleReminderType.pill => CycleReminderSection._rose,
    CycleReminderType.otherContraceptive => CycleReminderSection._turquoise,
    CycleReminderType.personal => CycleReminderSection._lilac,
  };
}

extension on CycleReminderFrequency {
  String get label => switch (this) {
    CycleReminderFrequency.daily => 'Diariamente',
    CycleReminderFrequency.specificWeekdays => 'Dias específicos',
  };

  String summary(Set<int> weekdays) {
    if (this == CycleReminderFrequency.daily) return 'Todos os dias';

    final labels = (weekdays.toList()..sort())
        .map((day) => _weekdayLabels[day - 1])
        .toList();
    if (labels.length < 2) return labels.join();

    return '${labels.take(labels.length - 1).join(', ')} e ${labels.last}';
  }
}

extension on CycleReminderPrivacyMode {
  String get label => switch (this) {
    CycleReminderPrivacyMode.discreet => 'Discreto',
    CycleReminderPrivacyMode.informative => 'Informativo',
    CycleReminderPrivacyMode.custom => 'Personalizado',
  };

  String get description => switch (this) {
    CycleReminderPrivacyMode.discreet => 'Oculta o tipo e o conteúdo pessoal.',
    CycleReminderPrivacyMode.informative => 'Mostra apenas o tipo escolhido.',
    CycleReminderPrivacyMode.custom =>
      'Usa o título e a mensagem que você definir.',
  };
}

const List<String> _weekdayLabels = <String>[
  'Seg',
  'Ter',
  'Qua',
  'Qui',
  'Sex',
  'Sáb',
  'Dom',
];

String _formatTime(int hour, int minute) =>
    '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
