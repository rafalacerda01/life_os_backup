import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/features/settings/presentation/screens/notifications_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('tela exibe apenas categorias com produtores reais', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: NotificationsScreen())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Notificações Gerais'), findsOneWidget);
    expect(find.text('Provas e Estudos'), findsOneWidget);
    expect(find.text('Hábitos'), findsOneWidget);
    expect(find.text('Medicamentos'), findsOneWidget);
    expect(find.text('Revisões do Anki'), findsNothing);
    expect(find.text('Lembretes de Foco'), findsNothing);
  });

  testWidgets('chave geral desabilita categorias sem alterar seus valores', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      NotificationPreferenceKeys.allNotifications: false,
      NotificationPreferenceKeys.studyReminders: false,
      NotificationPreferenceKeys.habitReminders: true,
      NotificationPreferenceKeys.medicationReminders: false,
    });

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: NotificationsScreen())),
    );
    await tester.pumpAndSettle();

    final switches = tester.widgetList<SwitchListTile>(
      find.byType(SwitchListTile),
    );
    expect(switches.map((item) => item.value), [false, false, true, false]);
    expect(switches.first.onChanged, isNotNull);
    expect(switches.skip(1).every((item) => item.onChanged == null), isTrue);
  });
}
