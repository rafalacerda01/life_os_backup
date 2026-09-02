import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';

class _MemoryStorage implements CycleReminderPreferencesStorage {
  final values = <String, String>{};
  int writeCount = 0;
  Object? readError;
  Object? deleteError;

  @override
  Future<void> delete(String key) async {
    final error = deleteError;
    if (error != null) throw error;
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async {
    final error = readError;
    if (error != null) throw error;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writeCount += 1;
    values[key] = value;
  }
}

void main() {
  late _MemoryStorage storage;
  late CycleReminderPreferencesStore store;

  setUp(() {
    storage = _MemoryStorage();
    store = CycleReminderPreferencesStore(storage);
  });

  Map<String, Object> validStoredJson() {
    return CycleReminderPreferences(
      enabled: true,
      type: CycleReminderType.personal,
      hour: 10,
      minute: 30,
      frequency: CycleReminderFrequency.daily,
    ).toJson();
  }

  Future<void> seedStoredContent(Object content) async {
    await store.save(
      'user-a',
      CycleReminderPreferences(
        enabled: true,
        type: CycleReminderType.personal,
        hour: 10,
        minute: 30,
        frequency: CycleReminderFrequency.daily,
      ),
    );
    final key = storage.values.keys.single;
    storage.values[key] = content is String ? content : jsonEncode(content);
  }

  test('estado inicial é não configurado', () async {
    expect(await store.load('user-a'), isNull);
  });

  test('hora semanticamente inválida retorna configuração ausente', () async {
    await seedStoredContent({...validStoredJson(), 'hour': 99});

    expect(await store.load('user-a'), isNull);
  });

  test('dias específicos vazios retornam configuração ausente', () async {
    await seedStoredContent({
      ...validStoredJson(),
      'frequency': CycleReminderFrequency.specificWeekdays.name,
      'weekdays': <int>[],
    });

    expect(await store.load('user-a'), isNull);
  });

  test('texto custom vazio retorna configuração ausente', () async {
    await seedStoredContent({
      ...validStoredJson(),
      'privacyMode': CycleReminderPrivacyMode.custom.name,
      'customTitle': '',
      'customBody': '',
    });

    expect(await store.load('user-a'), isNull);
  });

  test('versão de storage diferente retorna configuração ausente', () async {
    await seedStoredContent({...validStoredJson(), 'version': 999});

    expect(await store.load('user-a'), isNull);
  });

  test('JSON malformado retorna configuração ausente', () async {
    await seedStoredContent('{');

    expect(await store.load('user-a'), isNull);
  });

  test('falha real de leitura do storage continua propagando', () async {
    storage.readError = StateError('STORAGE_READ_FAILED');

    await expectLater(store.load('user-a'), throwsStateError);
  });

  test('modo Discreto é padrão e horário diário explícito persiste', () async {
    final preferences = CycleReminderPreferences(
      enabled: true,
      type: CycleReminderType.pill,
      hour: 21,
      minute: 5,
      frequency: CycleReminderFrequency.daily,
    );

    await store.save('user-a', preferences);
    final loaded = await store.load('user-a');

    expect(loaded?.hour, 21);
    expect(loaded?.minute, 5);
    expect(loaded?.frequency, CycleReminderFrequency.daily);
    expect(loaded?.privacyMode, CycleReminderPrivacyMode.discreet);
  });

  test('dias específicos exige ao menos um dia', () {
    expect(
      () => CycleReminderPreferences(
        enabled: true,
        type: CycleReminderType.personal,
        hour: 8,
        minute: 30,
        frequency: CycleReminderFrequency.specificWeekdays,
      ),
      throwsArgumentError,
    );
  });

  test('dias específicos persistem sem inferência', () async {
    final preferences = CycleReminderPreferences(
      enabled: true,
      type: CycleReminderType.otherContraceptive,
      hour: 7,
      minute: 45,
      frequency: CycleReminderFrequency.specificWeekdays,
      weekdays: const {DateTime.monday, DateTime.friday},
    );

    await store.save('user-a', preferences);

    expect((await store.load('user-a'))?.weekdays, {
      DateTime.monday,
      DateTime.friday,
    });
  });

  test('privacidade Informativo persiste', () async {
    final preferences = CycleReminderPreferences(
      enabled: true,
      type: CycleReminderType.pill,
      hour: 20,
      minute: 0,
      frequency: CycleReminderFrequency.daily,
      privacyMode: CycleReminderPrivacyMode.informative,
    );

    await store.save('user-a', preferences);

    expect(
      (await store.load('user-a'))?.privacyMode,
      CycleReminderPrivacyMode.informative,
    );
  });

  test(
    'texto Personalizado é sanitizado e limitado antes de persistir',
    () async {
      final preferences = CycleReminderPreferences(
        enabled: true,
        type: CycleReminderType.personal,
        hour: 18,
        minute: 15,
        frequency: CycleReminderFrequency.daily,
        privacyMode: CycleReminderPrivacyMode.custom,
        customTitle: '  Meu\n  lembrete  ',
        customBody: '  ${List<String>.filled(200, 'x').join()}  ',
      );

      await store.save('user-a', preferences);
      final loaded = await store.load('user-a');

      expect(loaded?.customTitle, 'Meu lembrete');
      expect(loaded?.customBody.runes.length, 160);
    },
  );

  test('desabilitar preserva toda a configuração', () async {
    final configured = CycleReminderPreferences(
      enabled: true,
      type: CycleReminderType.otherContraceptive,
      hour: 22,
      minute: 10,
      frequency: CycleReminderFrequency.specificWeekdays,
      weekdays: const {DateTime.tuesday, DateTime.thursday},
      privacyMode: CycleReminderPrivacyMode.informative,
    );

    await store.save('user-a', configured.copyWith(enabled: false));
    final disabled = await store.load('user-a');

    expect(disabled?.enabled, isFalse);
    expect(disabled?.type, configured.type);
    expect(disabled?.hour, configured.hour);
    expect(disabled?.weekdays, configured.weekdays);
    expect(disabled?.privacyMode, configured.privacyMode);
  });

  test('preferências ficam isoladas por UID', () async {
    final preferences = CycleReminderPreferences(
      enabled: true,
      type: CycleReminderType.personal,
      hour: 9,
      minute: 0,
      frequency: CycleReminderFrequency.daily,
    );

    await store.save('user-a', preferences);

    expect(await store.load('user-b'), isNull);
    expect(await store.load('user-a'), isNotNull);
  });

  test('excluir preferências de A preserva preferências de B', () async {
    final preferences = CycleReminderPreferences(
      enabled: true,
      type: CycleReminderType.personal,
      hour: 9,
      minute: 0,
      frequency: CycleReminderFrequency.daily,
    );
    await store.save('user-a', preferences);
    await store.save('user-b', preferences);

    await store.delete('user-a');

    expect(await store.load('user-a'), isNull);
    expect(await store.load('user-b'), isNotNull);
    expect(storage.values, hasLength(1));
  });

  test('falha ao excluir preferências continua propagando', () async {
    final preferences = CycleReminderPreferences(
      enabled: true,
      type: CycleReminderType.personal,
      hour: 9,
      minute: 0,
      frequency: CycleReminderFrequency.daily,
    );
    await store.save('user-a', preferences);
    storage.deleteError = StateError('STORAGE_DELETE_FAILED');

    await expectLater(store.delete('user-a'), throwsStateError);
    expect(await store.load('user-a'), isNotNull);
  });

  test('salvar apenas persiste e não agenda notificações', () async {
    final preferences = CycleReminderPreferences(
      enabled: true,
      type: CycleReminderType.personal,
      hour: 10,
      minute: 0,
      frequency: CycleReminderFrequency.daily,
    );

    await store.save('user-a', preferences);

    expect(storage.writeCount, 1);
    expect(storage.values, hasLength(1));
  });
}
