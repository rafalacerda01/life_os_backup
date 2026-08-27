import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/services/cycle_reminder_session_authority.dart';

void main() {
  test('admissão exige sessão preparada e Firebase com o mesmo UID', () {
    String? firebaseUserId = 'user-a';
    final container = ProviderContainer(
      overrides: [
        cycleReminderFirebaseUserIdReaderProvider.overrideWithValue(
          () => firebaseUserId,
        ),
      ],
    );
    addTearDown(container.dispose);
    final authority = container.read(cycleReminderSessionAuthorityProvider);
    final admittedUserId = container.read(cycleReminderUserIdReaderProvider);

    expect(admittedUserId(), isNull);

    authority.prepare('user-a');
    expect(admittedUserId(), 'user-a');

    firebaseUserId = 'user-b';
    expect(admittedUserId(), isNull);

    firebaseUserId = 'user-a';
    authority.clear();
    expect(admittedUserId(), isNull);
  });

  test('clear é síncrono e reprepare explícito reabre a admissão', () {
    final authority = CycleReminderSessionAuthority()..prepare('user-a');

    expect(authority.clear(), 'user-a');
    expect(authority.admittedUserId('user-a'), isNull);

    authority.prepare('user-a');
    expect(authority.admittedUserId('user-a'), 'user-a');
  });
}
