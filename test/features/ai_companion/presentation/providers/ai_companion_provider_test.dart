import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/ai_companion/data/models/ai_insight.dart';
import 'package:life_os/features/ai_companion/data/repositories/ai_companion_repository.dart';
import 'package:life_os/features/ai_companion/data/services/ai_insight_context_builder.dart';
import 'package:life_os/features/ai_companion/presentation/providers/ai_companion_provider.dart';
import 'package:life_os/features/ai_companion/presentation/providers/ai_consent_provider.dart';
import 'package:life_os/features/premium/domain/entities/premium_status_entity.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';

class _Premium extends PremiumNotifier {
  @override
  PremiumStatusEntity build() => const PremiumStatusEntity(
    isPremium: true,
    tier: PremiumTier.monthly,
    activatedFeatures: ['AI Companion'],
  );
}

class _Free extends PremiumNotifier {
  @override
  PremiumStatusEntity build() => const PremiumStatusEntity(
    isPremium: false,
    tier: PremiumTier.free,
    activatedFeatures: [],
  );
}

class _Consent extends AiConsentNotifier {
  @override
  Future<bool> build() async => true;

  void setAllowed(bool allowed) => state = AsyncData(allowed);
}

class _NoConsent extends AiConsentNotifier {
  @override
  Future<bool> build() async => false;
}

class _Notifier extends AICompanionNotifier {
  @override
  AICompanionState build() => AICompanionState();
}

class _Builder extends AIInsightContextBuilder {
  _Builder(super.db) : super(currentUserIdProvider: () => 'user-a');

  int calls = 0;
  final started = Completer<void>();
  final release = Completer<void>();
  bool block = false;

  @override
  Future<Map<String, Object?>> buildContext(
    AIInsightIntent intent, {
    required String expectedUserId,
  }) async {
    calls++;
    if (!started.isCompleted) started.complete();
    if (block) await release.future;
    return {
      'tasks': {'pending': 1},
    };
  }
}

class _Repository extends AICompanionRepository {
  _Repository()
    : super(
        client: MockClient((_) async => throw StateError('unexpected HTTP')),
      );

  int calls = 0;
  final started = Completer<void>();
  final release = Completer<void>();
  Object? failure;
  bool block = false;

  @override
  Future<AIInsight> requestInsight(
    AIInsightIntent intent,
    Map<String, Object?> trustedContext, {
    required String expectedUserId,
  }) async {
    calls++;
    expect(expectedUserId, 'user-a');
    expect(trustedContext, {
      'tasks': {'pending': 1},
    });
    if (!started.isCompleted) started.complete();
    if (block) await release.future;
    if (failure != null) throw failure!;
    return const AIInsight(
      headline: 'Headline',
      summary: 'Summary',
      recommendation: 'Recommendation',
    );
  }
}

void main() {
  late AppDatabase db;
  late _Builder builder;
  late _Repository repository;
  String? uid;

  setUp(() {
    db = AppDatabase(executor: NativeDatabase.memory());
    builder = _Builder(db);
    repository = _Repository();
    uid = 'user-a';
  });
  tearDown(() async {
    repository.client.close();
    await db.close();
  });

  ProviderContainer container({bool premium = true, bool consent = true}) {
    final value = ProviderContainer(
      overrides: [
        premiumProvider.overrideWith(premium ? _Premium.new : _Free.new),
        aiConsentProvider.overrideWith(consent ? _Consent.new : _NoConsent.new),
        aiCompanionProvider.overrideWith(_Notifier.new),
        aiCompanionCurrentUserIdProvider.overrideWithValue(() => uid),
        aiInsightContextBuilderProvider.overrideWithValue(builder),
        aiCompanionRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(value.dispose);
    return value;
  }

  test(
    'premium and consent failures never build context or call repository',
    () async {
      final free = container(premium: false);
      await free.read(aiConsentProvider.future);
      await free
          .read(aiCompanionProvider.notifier)
          .requestInsight(
            AIInsightIntent.dailyOverview,
            expectedUserId: 'user-a',
          );
      expect(
        free.read(aiCompanionProvider).sanitizedError,
        contains('Premium'),
      );
      final noConsent = container(consent: false);
      await noConsent.read(aiConsentProvider.future);
      await noConsent
          .read(aiCompanionProvider.notifier)
          .requestInsight(
            AIInsightIntent.dailyOverview,
            expectedUserId: 'user-a',
          );
      expect(
        noConsent.read(aiCompanionProvider).sanitizedError,
        contains('consentimento'),
      );
      expect(builder.calls, 0);
      expect(repository.calls, 0);
    },
  );

  test(
    'valid request sets loading, blocks double-tap and publishes insight',
    () async {
      repository.block = true;
      final scope = container();
      await scope.read(aiConsentProvider.future);
      final notifier = scope.read(aiCompanionProvider.notifier);
      final first = notifier.requestInsight(
        AIInsightIntent.dailyOverview,
        expectedUserId: 'user-a',
      );
      await repository.started.future;
      expect(scope.read(aiCompanionProvider).isLoading, isTrue);
      await notifier.requestInsight(
        AIInsightIntent.weeklyOverview,
        expectedUserId: 'user-a',
      );
      expect(repository.calls, 1);
      repository.release.complete();
      await first;
      expect(scope.read(aiCompanionProvider).insight?.headline, 'Headline');
      expect(
        scope.read(aiCompanionProvider).lastIntent,
        AIInsightIntent.dailyOverview,
      );
    },
  );

  test('session switch prevents A success from appearing in B', () async {
    repository.block = true;
    final scope = container();
    await scope.read(aiConsentProvider.future);
    final pending = scope
        .read(aiCompanionProvider.notifier)
        .requestInsight(
          AIInsightIntent.dailyOverview,
          expectedUserId: 'user-a',
        );
    await repository.started.future;
    uid = 'user-b';
    repository.release.complete();
    await pending;
    expect(scope.read(aiCompanionProvider).insight, isNull);
    expect(scope.read(aiCompanionProvider).sanitizedError, isNull);
  });

  test('consent revocation during POST discards the result', () async {
    repository.block = true;
    final scope = container();
    await scope.read(aiConsentProvider.future);
    final pending = scope
        .read(aiCompanionProvider.notifier)
        .requestInsight(
          AIInsightIntent.dailyOverview,
          expectedUserId: 'user-a',
        );
    await repository.started.future;
    (scope.read(aiConsentProvider.notifier) as _Consent).setAllowed(false);
    repository.release.complete();
    await pending;
    expect(scope.read(aiCompanionProvider).insight, isNull);
    expect(scope.read(aiCompanionProvider).sanitizedError, isNull);
  });

  test(
    'stale error is discarded and active error is sanitized with explicit retry',
    () async {
      repository.block = true;
      repository.failure = StateError('PRIVATE_ERROR_MARKER');
      final scope = container();
      await scope.read(aiConsentProvider.future);
      final notifier = scope.read(aiCompanionProvider.notifier);
      final pending = notifier.requestInsight(
        AIInsightIntent.dailyOverview,
        expectedUserId: 'user-a',
      );
      await repository.started.future;
      uid = 'user-b';
      repository.release.complete();
      await pending;
      expect(scope.read(aiCompanionProvider).sanitizedError, isNull);
      uid = 'user-a';
      repository.block = false;
      await notifier.requestInsight(
        AIInsightIntent.dailyOverview,
        expectedUserId: 'user-a',
      );
      expect(
        scope.read(aiCompanionProvider).sanitizedError,
        isNot(contains('PRIVATE_ERROR_MARKER')),
      );
      repository.failure = null;
      await notifier.requestInsight(
        AIInsightIntent.dailyOverview,
        expectedUserId: 'user-a',
      );
      expect(repository.calls, 3);
      expect(scope.read(aiCompanionProvider).insight?.headline, 'Headline');
    },
  );
}
