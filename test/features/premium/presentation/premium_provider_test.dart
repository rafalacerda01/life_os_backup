import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/premium/domain/entities/premium_plan_offer_entity.dart';
import 'package:life_os/features/premium/domain/entities/premium_status_entity.dart';
import 'package:life_os/features/premium/domain/repositories/i_premium_repository.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';

class _PremiumRepository implements IPremiumRepository {
  final _statuses = StreamController<PremiumStatusEntity>.broadcast(sync: true);

  bool get hasListener => _statuses.hasListener;

  void emit(PremiumStatusEntity status) => _statuses.add(status);

  Future<void> close() => _statuses.close();

  @override
  Stream<PremiumStatusEntity> watchPremiumStatus() => _statuses.stream;

  @override
  Future<List<PremiumPlanOfferEntity>> loadAvailablePlans() async => const [];

  @override
  Future<bool> purchasePlan(PremiumTier tier) async => false;

  @override
  Future<bool> restorePurchases() async => false;

  @override
  void dispose() {}
}

PremiumStatusEntity _premium(DateTime expiry) => PremiumStatusEntity(
  isPremium: true,
  tier: PremiumTier.monthly,
  expirationDate: expiry,
  activatedFeatures: const ['Companion IA'],
);

const _free = PremiumStatusEntity(
  isPremium: false,
  tier: PremiumTier.free,
  activatedFeatures: ['Recursos essenciais'],
);

ProviderContainer _container(_PremiumRepository repository) {
  final container = ProviderContainer(
    overrides: [premiumRepositoryProvider.overrideWithValue(repository)],
  );
  addTearDown(() async {
    container.dispose();
    await repository.close();
  });
  container.read(premiumProvider);
  return container;
}

void main() {
  testWidgets('Premium expires without another snapshot', (tester) async {
    final repository = _PremiumRepository();
    final container = _container(repository);
    final expiry = DateTime.now().add(const Duration(minutes: 10));

    expect(container.read(premiumProvider), _free);
    repository.emit(_premium(expiry));
    expect(container.read(premiumProvider).isPremium, true);

    await tester.pump(const Duration(minutes: 11));
    expect(container.read(premiumProvider), _free);
  });

  testWidgets('renewal cancels the old expiry timer', (tester) async {
    final repository = _PremiumRepository();
    final container = _container(repository);
    final now = DateTime.now();
    final firstExpiry = now.add(const Duration(minutes: 10));
    final renewedExpiry = now.add(const Duration(minutes: 30));

    repository.emit(_premium(firstExpiry));
    await tester.pump(const Duration(minutes: 5));
    repository.emit(_premium(renewedExpiry));

    await tester.pump(const Duration(minutes: 6));
    expect(container.read(premiumProvider).isPremium, true);
    expect(container.read(premiumProvider).expirationDate, renewedExpiry);

    await tester.pump(const Duration(minutes: 30));
    expect(container.read(premiumProvider), _free);
  });

  testWidgets('Free snapshot cancels the previous expiry', (tester) async {
    final repository = _PremiumRepository();
    final container = _container(repository);
    final updates = <PremiumStatusEntity>[];
    container.listen(premiumProvider, (_, next) => updates.add(next));

    repository.emit(_premium(DateTime.now().add(const Duration(minutes: 10))));
    await tester.pump(const Duration(minutes: 5));
    repository.emit(_free);
    await tester.pump(const Duration(minutes: 20));

    expect(container.read(premiumProvider), _free);
    expect(updates.length, 2);
    expect(updates.first.isPremium, true);
    expect(updates.last, _free);
  });

  testWidgets('already expired Premium fails closed immediately', (
    tester,
  ) async {
    final repository = _PremiumRepository();
    final container = _container(repository);

    repository.emit(
      _premium(DateTime.now().subtract(const Duration(seconds: 1))),
    );
    expect(container.read(premiumProvider), _free);
  });

  testWidgets('Premium without expiration fails closed', (tester) async {
    final repository = _PremiumRepository();
    final container = _container(repository);

    repository.emit(
      const PremiumStatusEntity(
        isPremium: true,
        tier: PremiumTier.monthly,
        activatedFeatures: ['Companion IA'],
      ),
    );

    final status = container.read(premiumProvider);
    expect(status.isPremium, false);
    expect(status.tier, PremiumTier.free);
    expect(status, _free);
  });

  testWidgets('dispose cancels subscription and expiry timer', (tester) async {
    final repository = _PremiumRepository();
    addTearDown(repository.close);
    final container = ProviderContainer(
      overrides: [premiumRepositoryProvider.overrideWithValue(repository)],
    );
    final updates = <PremiumStatusEntity>[];
    container.listen(premiumProvider, (_, next) => updates.add(next));
    expect(repository.hasListener, true);

    repository.emit(_premium(DateTime.now().add(const Duration(minutes: 10))));
    expect(updates.length, 1);
    container.dispose();
    expect(repository.hasListener, false);

    await tester.pump(const Duration(minutes: 11));
    expect(updates.length, 1);
    expect(tester.takeException(), isNull);
  });
}
