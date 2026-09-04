import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/services/analytics_service.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:life_os/main.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';

import 'helpers/recording_analytics_platform.dart';

class FakeAuthNotifier extends AuthNotifier {
  @override
  AuthState build() {
    return AuthState.unauthenticated();
  }
}

void main() {
  testWidgets(
    'LifeOSApp smoke test',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith(
              FakeAuthNotifier.new,
            ),
            analyticsServiceProvider.overrideWithValue(
              AnalyticsService(platform: RecordingAnalyticsPlatform()),
            ),
          ],
          child: const LifeOSApp(),
        ),
      );

      // Aguarda o SplashScreen concluir o timer de 4 segundos.
      await tester.pump(const Duration(seconds: 4));

      // Processa a navegação para /onboarding.
      await tester.pump();

      // O aplicativo deve ter sido construído.
      expect(
        find.byType(MaterialApp),
        findsOneWidget,
      );

      // Pode haver mais de um Scaffold durante a composição/navegação.
      expect(
        find.byType(Scaffold),
        findsWidgets,
      );

      // Confirma que o Splash navegou para o Onboarding.
      expect(
        find.text('Vamos te conhecer melhor'),
        findsOneWidget,
      );
    },
  );
}
