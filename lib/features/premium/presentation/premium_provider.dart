import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/premium/data/remote/billing_remote_data_source.dart';
import 'package:life_os/features/premium/data/repositories/google_play_premium_repository.dart';
import 'package:life_os/features/premium/data/services/google_play_billing_client.dart';
import 'package:life_os/features/premium/domain/entities/premium_plan_offer_entity.dart';
import 'package:url_launcher/url_launcher.dart';
import '../domain/entities/premium_status_entity.dart';
import '../domain/repositories/i_premium_repository.dart';

final googlePlayBillingClientProvider = Provider<GooglePlayBillingClient>((
  ref,
) {
  return InAppPurchaseGooglePlayBillingClient();
});

final billingRemoteDataSourceProvider = Provider<BillingRemoteDataSource>((
  ref,
) {
  final dataSource = BillingRemoteDataSource();
  ref.onDispose(dataSource.close);
  return dataSource;
});

final premiumRepositoryProvider = Provider<IPremiumRepository>((ref) {
  final repository = GooglePlayPremiumRepository(
    firestore: FirebaseFirestore.instance,
    billingClient: ref.watch(googlePlayBillingClientProvider),
    remoteDataSource: ref.watch(billingRemoteDataSourceProvider),
    currentUserIdProvider: () => FirebaseAuth.instance.currentUser?.uid,
  );
  ref.onDispose(repository.dispose);
  return repository;
});

final premiumCatalogProvider = FutureProvider<List<PremiumPlanOfferEntity>>((
  ref,
) {
  return ref.watch(premiumRepositoryProvider).loadAvailablePlans();
});

final subscriptionManagementLauncherProvider = Provider<Future<bool> Function()>((
  ref,
) {
  return () => launchUrl(
    Uri.parse(
      'https://play.google.com/store/account/subscriptions?sku=life_os_premium&package=com.rafalacerda.lifeos',
    ),
    mode: LaunchMode.externalApplication,
  );
});

class PremiumNotifier extends Notifier<PremiumStatusEntity> {
  StreamSubscription? _subscription;
  Timer? _expiryTimer;

  static const _free = PremiumStatusEntity(
    isPremium: false,
    tier: PremiumTier.free,
    activatedFeatures: ['Recursos essenciais'],
  );

  @override
  PremiumStatusEntity build() {
    ref.onDispose(() {
      _expiryTimer?.cancel();
      _subscription?.cancel();
    });

    final repository = ref.watch(premiumRepositoryProvider);

    _subscription = repository.watchPremiumStatus().listen(_applyStatus);

    return _free;
  }

  void _applyStatus(PremiumStatusEntity status) {
    _expiryTimer?.cancel();
    _expiryTimer = null;

    final expiry = status.expirationDate;
    if (!status.isPremium || expiry == null) {
      state = _free;
      return;
    }

    final remaining = expiry.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      state = _free;
      return;
    }

    state = status;
    _expiryTimer = Timer(remaining, () {
      if (!ref.mounted || !state.isPremium || state.expirationDate != expiry) {
        return;
      }
      state = _free;
    });
  }

  Future<bool> restorePurchase() {
    return ref.read(premiumRepositoryProvider).restorePurchases();
  }

  Future<bool> processSecureCheckout(PremiumTier tier) {
    return ref.read(premiumRepositoryProvider).purchasePlan(tier);
  }
}

final premiumProvider = NotifierProvider<PremiumNotifier, PremiumStatusEntity>(
  PremiumNotifier.new,
);
