import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cycle_reminder_notification_controller.dart';
import 'cycle_reminder_preferences.dart';

typedef CycleReminderTimePicker =
    Future<TimeOfDay?> Function(BuildContext context);

class CycleReminderSection extends ConsumerWidget {
  const CycleReminderSection({super.key});

  static const Color _surface = Color(0xFF11182E);
  static const Color _primary = Color(0xFFB026FF);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preferencesAsync = ref.watch(cycleReminderPreferencesProvider);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _primary.withOpacity(0.16)),
      ),
      child: preferencesAsync.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(color: _primary)),
        error: (_, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Lembrete pessoal',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
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
    required this.preferences,
    required this.onConfigure,
    required this.onEnabledChanged,
  });

  final CycleReminderPreferences? preferences;
  final VoidCallback onConfigure;
  final ValueChanged<bool>? onEnabledChanged;

  @override
  Widget build(BuildContext context) {
    final value = preferences;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Lembrete pessoal',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (value != null)
              Switch(
                value: value.enabled,
                activeColor: CycleReminderSection._primary,
                onChanged: onEnabledChanged,
              ),
          ],
        ),
        if (value == null) ...[
          const SizedBox(height: 6),
          const Text(
            'Configure um lembrete privado no horário que você escolher.',
            style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
          ),
        ] else ...[
          Text(
            value.enabled
                ? value.type.label
                : '${value.type.label} · Desativado',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${_formatTime(value.hour, value.minute)} · ${value.frequency.summary(value.weekdays)}',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            'Privacidade: ${value.privacyMode.label}',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonal(
            onPressed: onConfigure,
            style: FilledButton.styleFrom(
              foregroundColor: CycleReminderSection._primary,
              backgroundColor: CycleReminderSection._primary.withOpacity(0.10),
            ),
            child: Text(value == null ? 'Configurar' : 'Editar'),
          ),
        ),
      ],
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
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Lembrete pessoal',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Escolha cada detalhe do lembrete. Nenhum horário ou frequência é inferido.',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 22),
            _label('Tipo'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: CycleReminderType.values
                  .map(
                    (type) => ChoiceChip(
                      label: Text(type.label),
                      selected: _type == type,
                      onSelected: (_) => setState(() => _type = type),
                      selectedColor: _primary.withOpacity(0.28),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 18),
            _label('Horário'),
            OutlinedButton.icon(
              key: const ValueKey('cycle-reminder-time'),
              onPressed: _pickTime,
              icon: const Icon(Icons.schedule_rounded),
              label: Text(
                _time == null
                    ? 'Escolher horário'
                    : _formatTime(_time!.hour, _time!.minute),
              ),
            ),
            const SizedBox(height: 18),
            _label('Frequência'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: CycleReminderFrequency.values
                  .map(
                    (frequency) => ChoiceChip(
                      label: Text(frequency.label),
                      selected: _frequency == frequency,
                      onSelected: (_) => setState(() => _frequency = frequency),
                      selectedColor: _primary.withOpacity(0.28),
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
                  return FilterChip(
                    label: Text(_weekdayLabels[index]),
                    selected: _weekdays.contains(day),
                    onSelected: (selected) {
                      setState(() {
                        if (selected) {
                          _weekdays.add(day);
                        } else {
                          _weekdays.remove(day);
                        }
                      });
                    },
                    selectedColor: _primary.withOpacity(0.28),
                  );
                }),
              ),
            ],
            const SizedBox(height: 18),
            _label('Privacidade'),
            ...CycleReminderPrivacyMode.values.map(
              (mode) => Material(
                color: Colors.transparent,
                child: RadioListTile<CycleReminderPrivacyMode>(
                  value: mode,
                  groupValue: _privacyMode,
                  onChanged: (value) {
                    if (value != null) setState(() => _privacyMode = value);
                  },
                  contentPadding: EdgeInsets.zero,
                  activeColor: _primary,
                  title: Text(
                    mode.label,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  subtitle: Text(
                    mode.description,
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ),
              ),
            ),
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
            const SizedBox(height: 18),
            _label('Preview'),
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
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: Text(_saving ? 'Salvando...' : 'Salvar'),
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
        color: _CycleReminderEditorState._surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white10),
      ),
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
            style: const TextStyle(color: Colors.white60, fontSize: 12),
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
}

extension on CycleReminderFrequency {
  String get label => switch (this) {
    CycleReminderFrequency.daily => 'Diariamente',
    CycleReminderFrequency.specificWeekdays => 'Dias específicos',
  };

  String summary(Set<int> weekdays) => switch (this) {
    CycleReminderFrequency.daily => 'Todos os dias',
    CycleReminderFrequency.specificWeekdays =>
      (weekdays.toList()..sort())
          .map((day) => _weekdayLabels[day - 1])
          .join(', '),
  };
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
