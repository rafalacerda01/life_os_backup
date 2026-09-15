import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/premium/data/remote/billing_remote_data_source.dart';
import 'package:life_os/features/premium/data/services/google_play_billing_client.dart';
import 'package:life_os/features/premium/domain/entities/premium_plan_offer_entity.dart';
import 'package:life_os/features/premium/domain/entities/premium_status_entity.dart';
import 'package:life_os/features/premium/domain/repositories/i_premium_repository.dart';

typedef PremiumCurrentUserIdProvider = String? Function();
typedef PremiumRootStreamProvider =
    Stream<Map<String, dynamic>?> Function(String uid);

class PremiumPurchaseException implements Exception {
  const PremiumPurchaseException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'PremiumPurchaseException($code)';
}

String sha256UserId(String uid) => sha256.convert(utf8.encode(uid)).toString();

class GooglePlayPremiumRepository implements IPremiumRepository {
  factory GooglePlayPremiumRepository({
    FirebaseFirestore? firestore,
    required GooglePlayBillingClient billingClient,
    required BillingRemoteDataSource remoteDataSource,
    PremiumCurrentUserIdProvider? currentUserIdProvider,
    PremiumRootStreamProvider? rootStreamProvider,
    Duration purchaseWaitTimeout = const Duration(minutes: 10),
  }) {
    if (firestore == null && rootStreamProvider == null) {
      throw ArgumentError('firestore or rootStreamProvider is required.');
    }
    return GooglePlayPremiumRepository._(
      billingClient,
      remoteDataSource,
      currentUserIdProvider,
      rootStreamProvider ??
          (uid) => firestore!
              .collection('users')
              .doc(uid)
              .snapshots()
              .map((snapshot) => snapshot.data()),
      purchaseWaitTimeout,
    );
  }

  GooglePlayPremiumRepository._(
    this._billingClient,
    this._remoteDataSource,
    PremiumCurrentUserIdProvider? currentUserIdProvider,
    this._rootStreamProvider,
    this._purchaseWaitTimeout,
  ) : _currentUserIdProvider =
          currentUserIdProvider ??
          (() => FirebaseAuth.instance.currentUser?.uid) {
    _purchaseSubscription = _billingClient.purchaseStream.listen(
      _enqueuePurchaseUpdates,
      onError: (_) {
        AppLogger.w('[Billing] Falha no stream de compras.');
        _finishActiveWithError(_storeFailure);
      },
    );
  }

  static const productId = 'life_os_premium';
  static const _entitledStates = {
    'SUBSCRIPTION_STATE_ACTIVE',
    'SUBSCRIPTION_STATE_IN_GRACE_PERIOD',
    'SUBSCRIPTION_STATE_CANCELED',
  };
  static const _free = PremiumStatusEntity(
    isPremium: false,
    tier: PremiumTier.free,
    activatedFeatures: ['Recursos essenciais'],
  );
  static const _storeFailure = PremiumPurchaseException(
    'PLAY_BILLING_UNAVAILABLE',
    'Não foi possível acessar a Google Play agora. Tente novamente.',
  );

  final GooglePlayBillingClient _billingClient;
  final BillingRemoteDataSource _remoteDataSource;
  final PremiumCurrentUserIdProvider _currentUserIdProvider;
  final PremiumRootStreamProvider _rootStreamProvider;
  final Duration _purchaseWaitTimeout;
  late final StreamSubscription<List<PlayStorePurchase>> _purchaseSubscription;
  final Map<PremiumTier, PlayStoreOffer> _offers = {};
  Future<void> _purchaseQueue = Future.value();
  _ActivePurchase? _activePurchase;
  bool _operationInFlight = false;
  bool _disposed = false;

  @override
  Stream<PremiumStatusEntity> watchPremiumStatus() {
    final uid = _currentUserIdProvider();
    if (uid == null || uid.isEmpty) return Stream.value(_free);
    return _rootStreamProvider(uid).map((data) {
      if (_currentUserIdProvider() != uid) return _free;
      return premiumStatusFromRoot(data, now: DateTime.now().toUtc());
    });
  }

  @override
  Future<List<PremiumPlanOfferEntity>> loadAvailablePlans() async {
    try {
      if (!await _billingClient.isAvailable()) throw _storeFailure;
      final rawOffers = await _billingClient.queryOffers({productId});
      final selected = <PremiumTier, PlayStoreOffer>{};
      for (final offer in rawOffers) {
        if (offer.productId != productId) throw _storeFailure;
        final tier = _tierForBasePlan(offer.basePlanId);
        if (tier == null) continue;
        if (offer.offerToken.trim().isEmpty ||
            offer.formattedPrice.trim().isEmpty ||
            offer.currencyCode.trim().isEmpty ||
            !offer.rawPrice.isFinite ||
            offer.rawPrice <= 0) {
          throw _storeFailure;
        }
        if (offer.offerId != null) continue;
        if (selected.containsKey(tier)) throw _storeFailure;
        selected[tier] = offer;
      }
      if (selected.length != 2 ||
          !selected.containsKey(PremiumTier.monthly) ||
          !selected.containsKey(PremiumTier.annual)) {
        throw _storeFailure;
      }
      _offers
        ..clear()
        ..addAll(selected);
      return [PremiumTier.monthly, PremiumTier.annual]
          .map((tier) {
            final offer = selected[tier]!;
            return PremiumPlanOfferEntity(
              tier: tier,
              productId: offer.productId,
              basePlanId: offer.basePlanId,
              formattedPrice: offer.formattedPrice,
              rawPrice: offer.rawPrice,
              currencyCode: offer.currencyCode,
            );
          })
          .toList(growable: false);
    } on PremiumPurchaseException {
      rethrow;
    } catch (_) {
      throw _storeFailure;
    }
  }

  @override
  Future<bool> purchasePlan(PremiumTier tier) async {
    if (tier == PremiumTier.free) {
      throw const PremiumPurchaseException(
        'INVALID_PREMIUM_PLAN',
        'Selecione um plano Premium válido.',
      );
    }
    final uid = _requireUser();
    if (_operationInFlight || _activePurchase != null) {
      throw const PremiumPurchaseException(
        'PURCHASE_IN_PROGRESS',
        'Uma compra já está em andamento.',
      );
    }
    _operationInFlight = true;
    try {
      if (!_offers.containsKey(tier)) await loadAvailablePlans();
      _requireSameUser(uid);
      final offer = _offers[tier];
      if (offer == null) throw _storeFailure;
      final active = _ActivePurchase(uid, tier);
      _activePurchase = active;
      bool started;
      try {
        started = await _billingClient.buy(offer, sha256UserId(uid));
      } catch (_) {
        _finishActiveWithError(_storeFailure);
        throw _storeFailure;
      }
      if (!started) _finishActive(false);
      try {
        return await active.completer.future.timeout(_purchaseWaitTimeout);
      } on TimeoutException {
        throw const PremiumPurchaseException(
          'PURCHASE_CONFIRMATION_TIMEOUT',
          'A compra ainda não foi confirmada. Use Restaurar compras para verificar.',
        );
      } finally {
        if (identical(_activePurchase, active)) _activePurchase = null;
      }
    } finally {
      _operationInFlight = false;
    }
  }

  @override
  Future<bool> restorePurchases() async {
    final uid = _requireUser();
    if (_operationInFlight || _activePurchase != null) {
      throw const PremiumPurchaseException(
        'PURCHASE_IN_PROGRESS',
        'Uma operação de compra já está em andamento.',
      );
    }
    _operationInFlight = true;
    try {
      final accountId = sha256UserId(uid);
      final purchases = await _billingClient.queryPastPurchases(accountId);
      _requireSameUser(uid);
      for (final purchase in purchases) {
        _requireSameUser(uid);
        if (!_isVerifiable(purchase, accountId)) continue;
        final verified = await _remoteDataSource.verifyPurchase(
          expectedUid: uid,
          purchaseToken: purchase.purchaseToken,
        );
        _requireSameUser(uid);
        if (!verified.isPremium) continue;
        await _completeBestEffort(purchase);
        return true;
      }
      return false;
    } on PremiumPurchaseException {
      rethrow;
    } on BillingRemoteException catch (error) {
      throw PremiumPurchaseException(error.code, error.message);
    } catch (_) {
      throw _storeFailure;
    } finally {
      _operationInFlight = false;
    }
  }

  void _enqueuePurchaseUpdates(List<PlayStorePurchase> purchases) {
    _purchaseQueue = _purchaseQueue.then((_) => _handlePurchases(purchases));
    _purchaseQueue = _purchaseQueue.catchError((_) {
      AppLogger.w('[Billing] Falha ao processar atualização de compra.');
    });
  }

  Future<void> _handlePurchases(List<PlayStorePurchase> purchases) async {
    if (_disposed) return;
    for (final purchase in purchases) {
      final active = _activePurchase;
      if (purchase.state == PlayPurchaseState.canceled ||
          purchase.state == PlayPurchaseState.error) {
        if (active == null ||
            !purchase.isGooglePlay ||
            _currentUserIdProvider() != active.uid) {
          continue;
        }
        // Play can terminate the sole active flow without a PurchaseWrapper.
        final anonymous =
            purchase.productId.isEmpty &&
            purchase.purchaseToken.isEmpty &&
            purchase.obfuscatedAccountId == null;
        final identified =
            purchase.productId == productId &&
            purchase.obfuscatedAccountId == sha256UserId(active.uid);
        if (!anonymous && !identified) continue;
      }
      switch (purchase.state) {
        case PlayPurchaseState.pending:
          continue;
        case PlayPurchaseState.canceled:
          if (active != null) _finishActive(false);
          continue;
        case PlayPurchaseState.error:
          if (active != null) _finishActiveWithError(_storeFailure);
          continue;
        case PlayPurchaseState.purchased:
        case PlayPurchaseState.restored:
          break;
      }

      final uid = active?.uid ?? _currentUserIdProvider();
      if (uid == null || uid.isEmpty) continue;
      if (!purchase.isGooglePlay || purchase.productId != productId) continue;
      final accountId = sha256UserId(uid);
      if (!_isVerifiable(purchase, accountId)) {
        if (active != null) {
          _finishActiveWithError(
            const PremiumPurchaseException(
              'PURCHASE_ACCOUNT_MISMATCH',
              'Esta compra não pertence à sessão atual.',
            ),
          );
        }
        continue;
      }
      try {
        _requireSameUser(uid);
        final verified = await _remoteDataSource.verifyPurchase(
          expectedUid: uid,
          purchaseToken: purchase.purchaseToken,
        );
        _requireSameUser(uid);
        if (verified.isPremium) await _completeBestEffort(purchase);
        if (active != null &&
            verified.isPremium &&
            verified.tier == active.tier) {
          _finishActive(true);
        } else if (active != null && !verified.isPremium) {
          _finishActive(false);
        } else if (active != null) {
          _finishActiveWithError(
            const PremiumPurchaseException(
              'PURCHASE_TIER_MISMATCH',
              'Não foi possível confirmar o plano solicitado.',
            ),
          );
        }
      } on BillingRemoteException catch (error) {
        if (active != null) {
          _finishActiveWithError(
            PremiumPurchaseException(error.code, error.message),
          );
        }
      } on PremiumPurchaseException catch (error) {
        if (active != null) _finishActiveWithError(error);
      } catch (_) {
        if (active != null) _finishActiveWithError(_storeFailure);
      }
    }
  }

  bool _isVerifiable(PlayStorePurchase purchase, String accountId) {
    return purchase.isGooglePlay &&
        purchase.productId == productId &&
        purchase.purchaseToken.trim().isNotEmpty &&
        purchase.obfuscatedAccountId == accountId &&
        (purchase.state == PlayPurchaseState.purchased ||
            purchase.state == PlayPurchaseState.restored);
  }

  Future<void> _completeBestEffort(PlayStorePurchase purchase) async {
    if (!purchase.pendingCompletePurchase) return;
    try {
      await _billingClient.completePurchase(purchase);
    } catch (_) {
      AppLogger.w('[Billing] Falha ao concluir compra já validada.');
    }
  }

  String _requireUser() {
    final uid = _currentUserIdProvider();
    if (uid == null || uid.isEmpty) {
      throw const PremiumPurchaseException(
        'UNAUTHENTICATED',
        'Sua sessão não é válida. Entre novamente e tente de novo.',
      );
    }
    return uid;
  }

  void _requireSameUser(String uid) {
    if (_disposed || _currentUserIdProvider() != uid) {
      throw const PremiumPurchaseException(
        'UNAUTHENTICATED',
        'Sua sessão mudou. Entre novamente e tente de novo.',
      );
    }
  }

  void _finishActive(bool result) {
    final active = _activePurchase;
    if (active != null && !active.completer.isCompleted) {
      active.completer.complete(result);
    }
  }

  void _finishActiveWithError(PremiumPurchaseException error) {
    final active = _activePurchase;
    if (active != null && !active.completer.isCompleted) {
      active.completer.completeError(error);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finishActiveWithError(
      const PremiumPurchaseException(
        'PURCHASE_INTERRUPTED',
        'A operação de compra foi interrompida.',
      ),
    );
    unawaited(_purchaseSubscription.cancel());
  }

  static PremiumTier? _tierForBasePlan(String basePlanId) =>
      switch (basePlanId) {
        'monthly' => PremiumTier.monthly,
        'annual' => PremiumTier.annual,
        _ => null,
      };
}

PremiumStatusEntity premiumStatusFromRoot(
  Map<String, dynamic>? data, {
  required DateTime now,
}) {
  if (data == null || data['isPremium'] != true) {
    return GooglePlayPremiumRepository._free;
  }
  final tier = switch (data['premiumTier']) {
    'monthly' => PremiumTier.monthly,
    'annual' => PremiumTier.annual,
    _ => null,
  };
  final expectedBasePlan = switch (tier) {
    PremiumTier.monthly => 'monthly',
    PremiumTier.annual => 'annual',
    _ => null,
  };
  final expiryValue = data['premiumExpiresAt'];
  final expiry = expiryValue is Timestamp ? expiryValue.toDate().toUtc() : null;
  final state = data['premiumSubscriptionState'];
  if (tier == null ||
      data['premiumProvider'] != 'google_play' ||
      data['premiumProductId'] != GooglePlayPremiumRepository.productId ||
      data['premiumBasePlanId'] != expectedBasePlan ||
      state is! String ||
      !GooglePlayPremiumRepository._entitledStates.contains(state) ||
      expiry == null ||
      !expiry.isAfter(now.toUtc())) {
    return GooglePlayPremiumRepository._free;
  }
  return PremiumStatusEntity(
    isPremium: true,
    tier: tier,
    expirationDate: expiry,
    activatedFeatures: const [
      'Companion IA',
      'Limites ampliados',
      'Análises avançadas',
    ],
  );
}

class _ActivePurchase {
  _ActivePurchase(this.uid, this.tier);

  final String uid;
  final PremiumTier tier;
  final Completer<bool> completer = Completer<bool>();
}
