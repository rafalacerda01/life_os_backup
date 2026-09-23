import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/auth/domain/entities/user_entity.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/features/premium/domain/entities/premium_status_entity.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';
import 'package:life_os/features/settings/presentation/screens/account_management_screen.dart';
import 'package:life_os/features/settings/presentation/screens/appearance_screen.dart';

class _StaticAuthNotifier extends AuthNotifier {
  _StaticAuthNotifier(this.isPremium);

  final bool isPremium;

  @override
  AuthState build() => AuthState.authenticated(
    UserEntity(
      uid: 'user-a',
      email: 'user@example.test',
      displayName: 'Usuário',
      isPremium: isPremium,
      xp: 0,
      level: 1,
      streak: 0,
    ),
  );
}

class _StaticPremiumNotifier extends PremiumNotifier {
  _StaticPremiumNotifier(this.isPremium);

  final bool isPremium;

  @override
  PremiumStatusEntity build() => isPremium
      ? PremiumStatusEntity(
          isPremium: true,
          tier: PremiumTier.monthly,
          expirationDate: DateTime.now().add(const Duration(days: 30)),
          activatedFeatures: const ['Companion IA'],
        )
      : const PremiumStatusEntity(
          isPremium: false,
          tier: PremiumTier.free,
          activatedFeatures: ['Recursos essenciais'],
        );
}

Widget _app(Widget screen, {bool authPremium = false, bool premium = false}) {
  return ProviderScope(
    overrides: [
      authNotifierProvider.overrideWith(() => _StaticAuthNotifier(authPremium)),
      premiumProvider.overrideWith(() => _StaticPremiumNotifier(premium)),
    ],
    child: MaterialApp(home: screen),
  );
}

Future<void> _pumpAccount(
  WidgetTester tester, {
  bool authPremium = false,
  bool premium = false,
}) async {
  final originalOnError = FlutterError.onError;
  final knownWarnings = <FlutterErrorDetails>[];
  FlutterError.onError = (details) {
    if (details.exceptionAsString().startsWith(
      'ListTile background color or ink splashes may be invisible.',
    )) {
      knownWarnings.add(details);
    } else {
      originalOnError?.call(details);
    }
  };
  try {
    await tester.pumpWidget(
      _app(
        const AccountManagementScreen(),
        authPremium: authPremium,
        premium: premium,
      ),
    );
  } finally {
    FlutterError.onError = originalOnError;
  }
  expect(knownWarnings, hasLength(3));
}

void main() {
  testWidgets('Appearance shows paywall for Free provider', (tester) async {
    await tester.pumpWidget(_app(const AppearanceScreen()));

    expect(find.text('Acesso Premium Necessário'), findsOneWidget);
    expect(find.text('Aparência: Modo Premium Ativo'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Appearance shows active mode for Premium provider', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const AppearanceScreen(), premium: true));

    expect(find.text('Aparência: Modo Premium Ativo'), findsOneWidget);
    expect(find.text('Acesso Premium Necessário'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Account badge follows Premium despite Free Auth flag', (
    tester,
  ) async {
    await _pumpAccount(tester, premium: true);

    expect(find.text('PREMIUM'), findsOneWidget);
    expect(find.text('GRATUITO'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Account badge stays Free despite stale Premium Auth flag', (
    tester,
  ) async {
    await _pumpAccount(tester, authPremium: true);

    expect(find.text('GRATUITO'), findsOneWidget);
    expect(find.text('PREMIUM'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
