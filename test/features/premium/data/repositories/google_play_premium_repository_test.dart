import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_os/features/premium/data/remote/billing_remote_data_source.dart';
import 'package:life_os/features/premium/data/repositories/google_play_premium_repository.dart';
import 'package:life_os/features/premium/data/services/google_play_billing_client.dart';
import 'package:life_os/features/premium/domain/entities/premium_status_entity.dart';

void main() {
  const uid = 'user-a';
  const otherUid = 'user-b';

  test('SHA-256 UID is deterministic lowercase hexadecimal with 64 chars', () {
    final first = sha256UserId(uid);
    expect(first, sha256UserId(uid));
    expect(first, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(first, isNot(uid));
  });

  test('dispose cancels the single purchase stream subscription', () async {
    final fixture = _fixture();
    expect(fixture.billing.controller.hasListener, isTrue);
    fixture.repository.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(fixture.billing.controller.hasListener, isFalse);
  });

  test(
    'dispose interrupts an active purchase and cancels its listener',
    () async {
      final fixture = _fixture();
      final purchase = fixture.repository.purchasePlan(PremiumTier.monthly);
      await fixture.billing.buyStarted.future;
      final interrupted = expectLater(
        purchase,
        throwsA(
          isA<PremiumPurchaseException>().having(
            (error) => error.code,
            'code',
            'PURCHASE_INTERRUPTED',
          ),
        ),
      );
      fixture.repository.dispose();
      await interrupted;
      expect(fixture.billing.controller.hasListener, isFalse);
      expect(fixture.remote.calls, 0);
    },
  );

  group('catalog', () {
    test('selects exactly monthly and annual with store prices', () async {
      final fixture = _fixture();
      final plans = await fixture.repository.loadAvailablePlans();
      expect(plans.map((plan) => plan.basePlanId), ['monthly', 'annual']);
      expect(plans.map((plan) => plan.formattedPrice), [
        'US\$ 2.99',
        'US\$ 24.99',
      ]);
    });

    test('store unavailable fails closed', () async {
      final fixture = _fixture()..billing.available = false;
      await expectLater(
        fixture.repository.loadAvailablePlans(),
        throwsA(isA<PremiumPurchaseException>()),
      );
    });

    for (final invalid in [
      [_offer('wrong', 'monthly'), _offer('life_os_premium', 'annual')],
      [
        _offer('life_os_premium', 'weekly'),
        _offer('life_os_premium', 'annual'),
      ],
      [
        _offer('life_os_premium', 'monthly'),
        _offer('life_os_premium', 'monthly'),
        _offer('life_os_premium', 'annual'),
      ],
      [_offer('life_os_premium', 'monthly')],
    ]) {
      test('invalid, ambiguous or incomplete catalog fails closed', () async {
        final fixture = _fixture()..billing.offers = invalid;
        await expectLater(
          fixture.repository.loadAvailablePlans(),
          throwsA(isA<PremiumPurchaseException>()),
        );
      });
    }

    test('promotional offer is not selected', () async {
      final fixture = _fixture();
      fixture.billing.offers = [
        _offer('life_os_premium', 'monthly', offerId: 'trial'),
        _offer('life_os_premium', 'monthly'),
        _offer('life_os_premium', 'annual'),
      ];
      final plans = await fixture.repository.loadAvailablePlans();
      expect(plans, hasLength(2));
    });

    test(
      'unknown base plan metadata cannot invalidate monthly and annual',
      () async {
        final fixture = _fixture();
        fixture.billing.offers.add(
          PlayStoreOffer(
            productId: 'life_os_premium',
            basePlanId: 'weekly',
            offerId: null,
            offerToken: '',
            formattedPrice: '',
            rawPrice: double.nan,
            currencyCode: '',
            nativeProduct: Object(),
          ),
        );
        final plans = await fixture.repository.loadAvailablePlans();
        expect(plans.map((plan) => plan.basePlanId), ['monthly', 'annual']);
      },
    );

    test('duplicate annual remains fail closed', () async {
      final fixture = _fixture();
      fixture.billing.offers.add(_offer('life_os_premium', 'annual'));
      await expectLater(
        fixture.repository.loadAvailablePlans(),
        throwsA(isA<PremiumPurchaseException>()),
      );
    });
  });

  group('Firestore entitlement parser', () {
    Map<String, dynamic> root({
      String tier = 'monthly',
      String state = 'SUBSCRIPTION_STATE_ACTIVE',
      DateTime? expiry,
    }) => {
      'isPremium': true,
      'premiumTier': tier,
      'premiumProvider': 'google_play',
      'premiumProductId': 'life_os_premium',
      'premiumBasePlanId': tier,
      'premiumSubscriptionState': state,
      'premiumExpiresAt': Timestamp.fromDate(expiry ?? DateTime.utc(2099)),
    };

    for (final state in [
      'SUBSCRIPTION_STATE_ACTIVE',
      'SUBSCRIPTION_STATE_IN_GRACE_PERIOD',
      'SUBSCRIPTION_STATE_CANCELED',
    ]) {
      test('$state with future expiry is Premium', () {
        expect(
          premiumStatusFromRoot(
            root(state: state),
            now: DateTime.utc(2026),
          ).isPremium,
          isTrue,
        );
      });
    }

    for (final state in [
      'SUBSCRIPTION_STATE_ON_HOLD',
      'SUBSCRIPTION_STATE_PAUSED',
    ]) {
      test('$state is Free', () {
        expect(
          premiumStatusFromRoot(
            root(state: state),
            now: DateTime.utc(2026),
          ).isPremium,
          isFalse,
        );
      });
    }

    test('expired, missing metadata and tier mismatch are Free', () {
      expect(
        premiumStatusFromRoot(
          root(expiry: DateTime.utc(2025)),
          now: DateTime.utc(2026),
        ).isPremium,
        isFalse,
      );
      expect(
        premiumStatusFromRoot({
          'isPremium': true,
        }, now: DateTime.utc(2026)).isPremium,
        isFalse,
      );
      final mismatch = root(tier: 'annual')..['premiumBasePlanId'] = 'monthly';
      expect(
        premiumStatusFromRoot(mismatch, now: DateTime.utc(2026)).isPremium,
        isFalse,
      );
    });
  });

  group('purchase', () {
    for (final state in [PlayPurchaseState.canceled, PlayPurchaseState.error]) {
      testWidgets(
        'anonymous Google Play ${state.name} ends active flow immediately',
        (tester) async {
          final fixture = _fixture();
          Object? outcome;
          unawaited(
            fixture.repository
                .purchasePlan(PremiumTier.monthly)
                .then<void>(
                  (result) => outcome = result,
                  onError: (Object error) => outcome = error,
                ),
          );
          await fixture.billing.buyStarted.future;
          fixture.billing.emit([
            _purchase(
              uid,
              state,
              productId: '',
              purchaseToken: '',
              accountId: null,
            ),
          ]);
          await tester.pump();
          if (state == PlayPurchaseState.canceled) {
            expect(outcome, isFalse);
          } else {
            expect(
              outcome,
              isA<PremiumPurchaseException>()
                  .having(
                    (error) => error.code,
                    'code',
                    'PLAY_BILLING_UNAVAILABLE',
                  )
                  .having(
                    (error) => error.message,
                    'safe message',
                    'Não foi possível acessar a Google Play agora. Tente novamente.',
                  ),
            );
          }
          expect(fixture.remote.calls, 0);
          expect(fixture.billing.completeCalls, 0);
        },
      );

      testWidgets(
        'anonymous ${state.name} cannot end a different session flow',
        (tester) async {
          final fixture = _fixture();
          Object? outcome;
          unawaited(
            fixture.repository
                .purchasePlan(PremiumTier.monthly)
                .then<void>(
                  (result) => outcome = result,
                  onError: (Object error) => outcome = error,
                ),
          );
          await fixture.billing.buyStarted.future;
          fixture.currentUid = otherUid;
          fixture.billing.emit([
            _purchase(
              uid,
              state,
              productId: '',
              purchaseToken: '',
              accountId: null,
            ),
          ]);
          await tester.pump();
          expect(outcome, isNull);
          expect(fixture.remote.calls, 0);
          fixture.currentUid = uid;
          fixture.billing.emit([_purchase(uid, PlayPurchaseState.canceled)]);
          await tester.pump();
          expect(outcome, isFalse);
          expect(fixture.billing.completeCalls, 0);
        },
      );
    }

    for (final state in [PlayPurchaseState.canceled, PlayPurchaseState.error]) {
      final irrelevant = {
        'other product': _purchase(uid, state, productId: 'other'),
        'other account': _purchase(otherUid, state),
        'non Google Play': _purchase(uid, state, isGooglePlay: false),
        'missing account': _purchase(uid, state, accountId: null),
        'anonymous non Google': _purchase(
          uid,
          state,
          productId: '',
          purchaseToken: '',
          accountId: null,
          isGooglePlay: false,
        ),
        'partial token': _purchase(uid, state, productId: '', accountId: null),
        'partial account': _purchase(
          uid,
          state,
          productId: '',
          purchaseToken: '',
        ),
        'whitespace product': _purchase(
          uid,
          state,
          productId: ' ',
          purchaseToken: '',
          accountId: null,
        ),
        'whitespace token': _purchase(
          uid,
          state,
          productId: '',
          purchaseToken: ' ',
          accountId: null,
        ),
      };
      for (final candidate in irrelevant.entries) {
        test(
          '${state.name} from ${candidate.key} does not end active checkout',
          () async {
            final fixture = _fixture();
            final verification = Completer<BillingVerificationResponse>();
            fixture.remote.pending = verification;
            var completed = false;
            final purchase = fixture.repository.purchasePlan(
              PremiumTier.monthly,
            );
            final observed = purchase.then((result) {
              completed = true;
              return result;
            });
            await fixture.billing.buyStarted.future;
            fixture.billing.emit([
              candidate.value,
              _purchase(uid, PlayPurchaseState.purchased),
            ]);
            await fixture.remote.started.future;
            expect(completed, isFalse);
            expect(fixture.remote.calls, 1);
            expect(fixture.billing.completeCalls, 0);
            verification.complete(_premiumResponse(PremiumTier.monthly));
            expect(await observed, isTrue);
          },
        );
      }
    }

    for (final requested in [PremiumTier.monthly, PremiumTier.annual]) {
      testWidgets(
        '${requested.name} checkout fails immediately for different verified tier',
        (tester) async {
          final fixture = _fixture();
          fixture.remote.response = _premiumResponse(
            requested == PremiumTier.monthly
                ? PremiumTier.annual
                : PremiumTier.monthly,
          );
          Object? outcome;
          final purchase = fixture.repository.purchasePlan(requested);
          unawaited(
            purchase.then<void>(
              (_) => outcome = 'unexpected success',
              onError: (Object error) => outcome = error,
            ),
          );
          await fixture.billing.buyStarted.future;
          fixture.billing.emit([_purchase(uid, PlayPurchaseState.purchased)]);
          // Flush microtasks without advancing the interactive timeout clock.
          await tester.pump();
          expect(
            outcome,
            isA<PremiumPurchaseException>()
                .having((error) => error.code, 'code', 'PURCHASE_TIER_MISMATCH')
                .having(
                  (error) => error.message,
                  'message',
                  'Não foi possível confirmar o plano solicitado.',
                ),
          );
          expect(fixture.billing.completeCalls, 1);
        },
      );
    }

    test('unauthenticated is blocked before store flow', () async {
      final fixture = _fixture(currentUid: null);
      await expectLater(
        fixture.repository.purchasePlan(PremiumTier.monthly),
        throwsA(isA<PremiumPurchaseException>()),
      );
      expect(fixture.billing.buyCalls, 0);
    });

    test('passes SHA-256 UID and selected offer token to Play', () async {
      final fixture = _fixture();
      final purchase = fixture.repository.purchasePlan(PremiumTier.monthly);
      await fixture.billing.buyStarted.future;
      expect(fixture.billing.applicationUserName, sha256UserId(uid));
      expect(fixture.billing.boughtOffer?.basePlanId, 'monthly');
      expect(fixture.billing.boughtOffer?.offerToken, 'monthly-token');
      fixture.billing.emit([_purchase(uid, PlayPurchaseState.canceled)]);
      expect(await purchase, isFalse);
    });

    test('buy false does not grant Premium', () async {
      final fixture = _fixture()..billing.buyResult = false;
      expect(
        await fixture.repository.purchasePlan(PremiumTier.monthly),
        isFalse,
      );
      expect(fixture.remote.calls, 0);
    });

    test('second checkout is rejected while one is active', () async {
      final fixture = _fixture();
      final first = fixture.repository.purchasePlan(PremiumTier.monthly);
      await fixture.billing.buyStarted.future;
      await expectLater(
        fixture.repository.purchasePlan(PremiumTier.annual),
        throwsA(
          isA<PremiumPurchaseException>().having(
            (error) => error.code,
            'code',
            'PURCHASE_IN_PROGRESS',
          ),
        ),
      );
      fixture.billing.emit([_purchase(uid, PlayPurchaseState.canceled)]);
      expect(await first, isFalse);
    });

    test(
      'pending does not grant Premium and canceled resolves false',
      () async {
        final fixture = _fixture();
        var completed = false;
        final purchase = fixture.repository.purchasePlan(PremiumTier.monthly)
          ..then((_) => completed = true);
        await fixture.billing.buyStarted.future;
        fixture.billing.emit([_purchase(uid, PlayPurchaseState.pending)]);
        await Future<void>.delayed(Duration.zero);
        expect(completed, isFalse);
        fixture.billing.emit([_purchase(uid, PlayPurchaseState.canceled)]);
        expect(await purchase, isFalse);
      },
    );

    test('purchased resolves only after backend Premium response', () async {
      final fixture = _fixture();
      final verification = Completer<BillingVerificationResponse>();
      fixture.remote.pending = verification;
      var completed = false;
      final purchase = fixture.repository.purchasePlan(PremiumTier.monthly)
        ..then((_) => completed = true);
      await fixture.billing.buyStarted.future;
      fixture.billing.emit([_purchase(uid, PlayPurchaseState.purchased)]);
      await fixture.remote.started.future;
      expect(completed, isFalse);
      expect(fixture.billing.completeCalls, 0);
      verification.complete(_premiumResponse(PremiumTier.monthly));
      expect(await purchase, isTrue);
      expect(fixture.billing.completeCalls, 1);
    });

    test('purchase error is sanitized and never calls backend', () async {
      final fixture = _fixture();
      final purchase = fixture.repository.purchasePlan(PremiumTier.monthly);
      await fixture.billing.buyStarted.future;
      fixture.billing.emit([_purchase(uid, PlayPurchaseState.error)]);
      await expectLater(
        purchase,
        throwsA(
          isA<PremiumPurchaseException>().having(
            (error) => error.toString(),
            'safe',
            isNot(contains('purchase-token')),
          ),
        ),
      );
      expect(fixture.remote.calls, 0);
    });

    test('backend free does not grant or complete purchase', () async {
      final fixture = _fixture();
      fixture.remote.response = const BillingVerificationResponse(
        isPremium: false,
        tier: PremiumTier.free,
        subscriptionState: 'SUBSCRIPTION_STATE_EXPIRED',
        expiresAt: null,
      );
      final purchase = fixture.repository.purchasePlan(PremiumTier.monthly);
      await fixture.billing.buyStarted.future;
      fixture.billing.emit([_purchase(uid, PlayPurchaseState.purchased)]);
      expect(await purchase, isFalse);
      expect(fixture.billing.completeCalls, 0);
    });

    test('wrong product is ignored without calling backend', () async {
      final fixture = _fixture();
      final purchase = fixture.repository.purchasePlan(PremiumTier.monthly);
      await fixture.billing.buyStarted.future;
      fixture.billing.emit([
        _purchase(uid, PlayPurchaseState.purchased, productId: 'other'),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(fixture.remote.calls, 0);
      fixture.billing.emit([_purchase(uid, PlayPurchaseState.canceled)]);
      expect(await purchase, isFalse);
    });

    test('missing or mismatched account never calls backend', () async {
      for (final candidate in [
        _purchase(otherUid, PlayPurchaseState.purchased),
        _purchase(uid, PlayPurchaseState.purchased, accountId: null),
      ]) {
        final fixture = _fixture();
        final purchase = fixture.repository.purchasePlan(PremiumTier.monthly);
        await fixture.billing.buyStarted.future;
        fixture.billing.emit([candidate]);
        await expectLater(purchase, throwsA(isA<PremiumPurchaseException>()));
        expect(fixture.remote.calls, 0);
      }
    });

    test('session change during verification fails closed', () async {
      final fixture = _fixture();
      final verification = Completer<BillingVerificationResponse>();
      fixture.remote.pending = verification;
      final purchase = fixture.repository.purchasePlan(PremiumTier.monthly);
      await fixture.billing.buyStarted.future;
      fixture.billing.emit([_purchase(uid, PlayPurchaseState.purchased)]);
      await fixture.remote.started.future;
      fixture.currentUid = otherUid;
      verification.complete(_premiumResponse(PremiumTier.monthly));
      await expectLater(purchase, throwsA(isA<PremiumPurchaseException>()));
      expect(fixture.billing.completeCalls, 0);
    });

    test(
      'completePurchase failure after backend Premium does not revoke success',
      () async {
        final fixture = _fixture()..billing.completeFails = true;
        final purchase = fixture.repository.purchasePlan(PremiumTier.monthly);
        await fixture.billing.buyStarted.future;
        fixture.billing.emit([_purchase(uid, PlayPurchaseState.purchased)]);
        expect(await purchase, isTrue);
        expect(fixture.billing.completeCalls, 1);
      },
    );
  });

  group('restore', () {
    test('no purchases returns false', () async {
      final fixture = _fixture();
      expect(await fixture.repository.restorePurchases(), isFalse);
    });

    test('invalid candidates are ignored without backend call', () async {
      final fixture = _fixture();
      fixture.billing.pastPurchases = [
        _purchase(uid, PlayPurchaseState.purchased, productId: 'other'),
        _purchase(otherUid, PlayPurchaseState.purchased),
      ];
      expect(await fixture.repository.restorePurchases(), isFalse);
      expect(fixture.remote.calls, 0);
    });

    test('valid purchase sends canonical token and returns true', () async {
      final fixture = _fixture();
      fixture.billing.pastPurchases = [
        _purchase(uid, PlayPurchaseState.restored),
      ];
      expect(await fixture.repository.restorePurchases(), isTrue);
      expect(fixture.remote.tokens, ['purchase-token']);
      expect(fixture.billing.completeCalls, 1);
    });

    test('backend free returns false and backend error is sanitized', () async {
      final freeFixture = _fixture();
      freeFixture.billing.pastPurchases = [
        _purchase(uid, PlayPurchaseState.purchased),
      ];
      freeFixture.remote.response = const BillingVerificationResponse(
        isPremium: false,
        tier: PremiumTier.free,
        subscriptionState: 'SUBSCRIPTION_STATE_EXPIRED',
        expiresAt: null,
      );
      expect(await freeFixture.repository.restorePurchases(), isFalse);

      final failed = _fixture();
      failed.billing.pastPurchases = [
        _purchase(uid, PlayPurchaseState.purchased),
      ];
      failed.remote.error = const BillingRemoteException(
        code: 'GOOGLE_PLAY_UNAVAILABLE',
        message: 'Não foi possível validar a compra.',
      );
      await expectLater(
        failed.repository.restorePurchases(),
        throwsA(
          isA<PremiumPurchaseException>().having(
            (e) => e.toString(),
            'safe',
            isNot(contains('purchase-token')),
          ),
        ),
      );
    });
  });
}

PlayStoreOffer _offer(String productId, String basePlanId, {String? offerId}) =>
    PlayStoreOffer(
      productId: productId,
      basePlanId: basePlanId,
      offerId: offerId,
      offerToken: '$basePlanId-token',
      formattedPrice: basePlanId == 'annual' ? 'US\$ 24.99' : 'US\$ 2.99',
      rawPrice: basePlanId == 'annual' ? 24.99 : 2.99,
      currencyCode: 'USD',
      nativeProduct: Object(),
    );

PlayStorePurchase _purchase(
  String uid,
  PlayPurchaseState state, {
  String productId = 'life_os_premium',
  String? accountId = 'default',
  bool isGooglePlay = true,
  String purchaseToken = 'purchase-token',
}) => PlayStorePurchase(
  state: state,
  productId: productId,
  purchaseToken: purchaseToken,
  obfuscatedAccountId: accountId == 'default' ? sha256UserId(uid) : accountId,
  pendingCompletePurchase: true,
  isGooglePlay: isGooglePlay,
  nativePurchase: Object(),
);

BillingVerificationResponse _premiumResponse(PremiumTier tier) =>
    BillingVerificationResponse(
      isPremium: true,
      tier: tier,
      subscriptionState: 'SUBSCRIPTION_STATE_ACTIVE',
      expiresAt: DateTime.utc(2099),
    );

_Fixture _fixture({String? currentUid = 'user-a'}) => _Fixture(currentUid);

class _Fixture {
  _Fixture(this.currentUid) {
    billing.offers = [
      _offer('life_os_premium', 'monthly'),
      _offer('life_os_premium', 'annual'),
    ];
    repository = GooglePlayPremiumRepository(
      billingClient: billing,
      remoteDataSource: remote,
      currentUserIdProvider: () => currentUid,
      rootStreamProvider: (_) => const Stream.empty(),
      purchaseWaitTimeout: const Duration(seconds: 2),
    );
    addTearDown(repository.dispose);
    addTearDown(billing.close);
  }

  String? currentUid;
  final billing = _FakeBilling();
  final remote = _FakeRemote();
  late final GooglePlayPremiumRepository repository;
}

class _FakeBilling implements GooglePlayBillingClient {
  final controller = StreamController<List<PlayStorePurchase>>.broadcast(
    sync: true,
  );
  bool available = true;
  bool buyResult = true;
  bool completeFails = false;
  int buyCalls = 0;
  int completeCalls = 0;
  String? applicationUserName;
  PlayStoreOffer? boughtOffer;
  List<PlayStoreOffer> offers = [];
  List<PlayStorePurchase> pastPurchases = [];
  final buyStarted = Completer<void>();

  @override
  Stream<List<PlayStorePurchase>> get purchaseStream => controller.stream;
  @override
  Future<bool> isAvailable() async => available;
  @override
  Future<List<PlayStoreOffer>> queryOffers(Set<String> productIds) async =>
      offers;
  @override
  Future<bool> buy(PlayStoreOffer offer, String applicationUserName) async {
    buyCalls++;
    boughtOffer = offer;
    this.applicationUserName = applicationUserName;
    if (!buyStarted.isCompleted) buyStarted.complete();
    return buyResult;
  }

  @override
  Future<List<PlayStorePurchase>> queryPastPurchases(
    String applicationUserName,
  ) async {
    this.applicationUserName = applicationUserName;
    return pastPurchases;
  }

  @override
  Future<void> completePurchase(PlayStorePurchase purchase) async {
    completeCalls++;
    if (completeFails) throw StateError('private-complete-error');
  }

  void emit(List<PlayStorePurchase> purchases) => controller.add(purchases);
  Future<void> close() => controller.close();
}

class _FakeRemote extends BillingRemoteDataSource {
  _FakeRemote()
    : super(
        client: MockClient((_) async => http.Response('{}', 500)),
        idTokenProvider: (_) async => 'unused',
        appCheckTokenProvider: () async => 'unused',
        currentUserIdProvider: () => 'unused',
      );

  int calls = 0;
  final tokens = <String>[];
  final started = Completer<void>();
  Completer<BillingVerificationResponse>? pending;
  BillingRemoteException? error;
  BillingVerificationResponse response = _premiumResponse(PremiumTier.monthly);

  @override
  Future<BillingVerificationResponse> verifyPurchase({
    required String expectedUid,
    required String purchaseToken,
  }) async {
    calls++;
    tokens.add(purchaseToken);
    if (!started.isCompleted) started.complete();
    final failure = error;
    if (failure != null) throw failure;
    return pending?.future ?? response;
  }
}
