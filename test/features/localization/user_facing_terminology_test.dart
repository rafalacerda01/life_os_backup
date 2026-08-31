import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/features/auth/domain/entities/user_entity.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/features/circles/data/repositories/circles_repository.dart';
import 'package:life_os/features/circles/domain/entities/circle_entity.dart';
import 'package:life_os/features/circles/presentation/circle_detail_screen.dart';
import 'package:life_os/features/circles/presentation/circles_provider.dart';
import 'package:life_os/features/circles/presentation/circles_screen.dart';
import 'package:life_os/features/home/presentation/screens/main_navigation_screen.dart';
import 'package:life_os/features/premium/domain/entities/premium_status_entity.dart';
import 'package:life_os/features/premium/domain/repositories/i_premium_repository.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';
import 'package:life_os/features/premium/presentation/premium_screen.dart';
import 'package:life_os/features/settings/presentation/screens/account_management_screen.dart';
import 'package:life_os/features/settings/presentation/screens/appearance_screen.dart';
import 'package:life_os/features/settings/presentation/screens/privacy_policy_screen.dart';
import 'package:life_os/features/settings/presentation/screens/subscription_screen.dart';

const _freeStatus = PremiumStatusEntity(
  isPremium: false,
  tier: PremiumTier.free,
  activatedFeatures: ['Tarefas Básicas'],
);

const _premiumStatus = PremiumStatusEntity(
  isPremium: true,
  tier: PremiumTier.monthly,
  activatedFeatures: ['AI Companion'],
);

const _premiumUser = UserEntity(
  uid: 'user-a',
  email: 'user@example.test',
  displayName: 'Usuário',
  isPremium: true,
  xp: 0,
  level: 1,
  streak: 0,
);

const _freeUser = UserEntity(
  uid: 'user-a',
  email: 'user@example.test',
  displayName: 'Usuário',
  isPremium: false,
  xp: 0,
  level: 1,
  streak: 0,
);

class _StaticAuthNotifier extends AuthNotifier {
  _StaticAuthNotifier(this.user);

  final UserEntity user;

  @override
  AuthState build() => AuthState.authenticated(user);
}

class _StaticPremiumNotifier extends PremiumNotifier {
  _StaticPremiumNotifier(this.status);

  final PremiumStatusEntity status;

  @override
  PremiumStatusEntity build() => status;
}

class _PendingPremiumRepository implements IPremiumRepository {
  final purchase = Completer<bool>();

  @override
  Future<bool> purchasePlan(PremiumTier tier) => purchase.future;

  @override
  Future<bool> restorePurchases() async => true;

  @override
  Stream<PremiumStatusEntity> watchPremiumStatus() => Stream.value(_freeStatus);
}

class _StaticCirclesNotifier extends CirclesNotifier {
  _StaticCirclesNotifier(this.circle);

  final CircleEntity circle;

  @override
  CirclesState build() => CirclesState(
    availableCircles: const [],
    joinedCircle: circle,
    isLoading: false,
  );
}

class _StaticCirclesRepository extends Fake implements CirclesRepository {
  @override
  Future<String?> getUserActiveCircleId() async => null;
}

void main() {
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  testWidgets('navegação e logout usam terminologia pt-BR', (tester) async {
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        ShellRoute(
          builder: (_, _, child) => MainNavigationScreen(child: child),
          routes: [
            GoRoute(path: '/home', builder: (_, _) => const SizedBox.shrink()),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pumpAndSettle();

    final navigation = tester.widget<BottomNavigationBar>(
      find.byType(BottomNavigationBar),
    );
    expect(
      navigation.items.map((item) => item.label),
      containsAllInOrder(['Início', 'Estudos', 'Saúde', 'Finanças', 'IA']),
    );
    expect(navigation.items.map((item) => item.label), isNot(contains('Home')));
    expect(navigation.items.map((item) => item.label), isNot(contains('AI')));

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.text('Análises'), findsOneWidget);
    expect(find.text('Analytics'), findsNothing);

    await tester.tap(find.text('Sair'));
    await tester.pumpAndSettle();
    expect(find.text('Encerrar sessão'), findsOneWidget);
    expect(find.text('Encerrar Core'), findsNothing);
  });

  testWidgets('Premium usa carregamento e plano gratuito localizados', (
    tester,
  ) async {
    final repository = _PendingPremiumRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [premiumRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(home: PremiumScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('NÍVEL DE ACESSO: GRATUITO'), findsOneWidget);
    expect(find.text('Acesso Premium'), findsOneWidget);
    expect(find.text('Acesso Cyber-Premium'), findsNothing);
    expect(find.text('Gráficos semanais de análise'), findsOneWidget);
    expect(find.textContaining('Gratuito:'), findsNWidgets(4));
    expect(find.textContaining('Free:'), findsNothing);

    final subscribeButton = find.text('Assinar Mensal');
    await tester.ensureVisible(subscribeButton);
    await tester.pumpAndSettle();
    await tester.tap(subscribeButton);
    await tester.pump();
    expect(find.text('Processando assinatura...'), findsOneWidget);
    expect(find.text('Handshake de Segurança...'), findsNothing);

    repository.purchase.complete(false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('assinatura preserva Premium sem promessa de IA ilimitada', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authNotifierProvider.overrideWith(
            () => _StaticAuthNotifier(_premiumUser),
          ),
          premiumProvider.overrideWith(
            () => _StaticPremiumNotifier(_premiumStatus),
          ),
        ],
        child: const MaterialApp(home: SubscriptionScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Acesso ao Companion IA'), findsOneWidget);
    expect(find.textContaining('Ilimitada'), findsNothing);
    expect(find.text('Plano Premium ativo'), findsOneWidget);
    expect(find.text('Plano PRO Ativo'), findsNothing);
  });

  testWidgets('assinatura gratuita usa CTA Premium oficial', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authNotifierProvider.overrideWith(
            () => _StaticAuthNotifier(_freeUser),
          ),
          premiumProvider.overrideWith(
            () => _StaticPremiumNotifier(_freeStatus),
          ),
        ],
        child: const MaterialApp(home: SubscriptionScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Assinar Premium'), findsOneWidget);
    expect(find.text('Tornar-se PRO agora'), findsNothing);
  });

  testWidgets('badge de conta usa Gratuito e preserva Premium', (tester) async {
    final originalOnError = FlutterError.onError;
    final knownListTileWarnings = <FlutterErrorDetails>[];
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains(
        'ListTile background color or ink splashes may be invisible.',
      )) {
        knownListTileWarnings.add(details);
        return;
      }
      originalOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = originalOnError);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authNotifierProvider.overrideWith(
            () => _StaticAuthNotifier(_freeUser),
          ),
        ],
        child: const MaterialApp(home: AccountManagementScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('GRATUITO'), findsOneWidget);
    expect(find.text('FREE'), findsNothing);
    expect(knownListTileWarnings, isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('aparência e política exibem somente a redação autorizada', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authNotifierProvider.overrideWith(
            () => _StaticAuthNotifier(_premiumUser),
          ),
        ],
        child: const MaterialApp(home: AppearanceScreen()),
      ),
    );
    expect(find.text('NOVIDADES PLANEJADAS'), findsOneWidget);
    expect(find.text('ROADMAP VISUAL'), findsNothing);
    expect(find.textContaining('assinantes Premium'), findsOneWidget);
    expect(find.textContaining('membros Pro'), findsNothing);
    expect(find.textContaining('Cyber-Minimal'), findsOneWidget);
    expect(find.textContaining('Deep Focus'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: PrivacyPolicyScreen()));
    expect(find.textContaining('(Privacy-First)'), findsNothing);
    expect(find.textContaining('SQLCipher'), findsOneWidget);
    expect(find.textContaining('Offline-First'), findsOneWidget);
    expect(find.textContaining('Batch Commit'), findsOneWidget);
  });

  testWidgets('badge Administrador cabe em viewport realista', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final circle = CircleEntity(
      id: 'circle-a',
      name: 'Círculo de teste',
      description: 'Descrição',
      adminId: 'admin-a',
      memberCount: 1,
      memberLimit: 3,
      schemaVersion: 2,
      members: [
        CircleMemberEntity(
          userId: 'admin-a',
          displayName: 'Nome de administrador bastante extenso',
          photoUrl: null,
          role: CircleMemberRole.admin,
          joinedAt: DateTime(2026, 8, 31),
        ),
      ],
      challenges: const [],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          circlesRepositoryProvider.overrideWithValue(
            _StaticCirclesRepository(),
          ),
          circlesProvider.overrideWith(() => _StaticCirclesNotifier(circle)),
        ],
        child: const MaterialApp(home: CirclesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final screen = find.byType(CirclesScreen);
    expect(
      find.descendant(of: screen, matching: find.text('Administrador')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: screen, matching: find.text('Admin')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('detalhe do círculo usa badge Administrador sem overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final circle = CircleEntity(
      id: 'circle-detail',
      name: 'Círculo de teste',
      description: 'Descrição',
      adminId: 'admin-a',
      memberCount: 1,
      memberLimit: 3,
      schemaVersion: 2,
      members: [
        CircleMemberEntity(
          userId: 'admin-a',
          displayName: 'Nome de administrador bastante extenso',
          photoUrl: null,
          role: CircleMemberRole.admin,
          joinedAt: DateTime(2026, 8, 31),
        ),
      ],
      challenges: const [],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          circlesProvider.overrideWith(() => _StaticCirclesNotifier(circle)),
        ],
        child: const MaterialApp(
          home: CircleDetailScreen(circleId: 'circle-detail'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final detail = find.byType(CircleDetailScreen);
    expect(
      find.descendant(of: detail, matching: find.text('Administrador')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: detail, matching: find.text('Admin')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
