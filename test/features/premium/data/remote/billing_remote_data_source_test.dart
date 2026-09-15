import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_os/features/premium/data/remote/billing_remote_data_source.dart';
import 'package:life_os/features/premium/domain/entities/premium_status_entity.dart';

void main() {
  const uid = 'user-a';
  const purchaseToken = 'private-purchase-token';
  const idToken = 'private-firebase-token';
  const appCheck = 'private-app-check-token';

  BillingRemoteDataSource source(
    MockClient client, {
    String? Function()? currentUid,
    Future<String?> Function(String)? tokenProvider,
    Future<String?> Function()? appCheckProvider,
    Duration timeout = const Duration(seconds: 1),
  }) => BillingRemoteDataSource(
    client: client,
    currentUserIdProvider: currentUid ?? () => uid,
    idTokenProvider: tokenProvider ?? (_) async => idToken,
    appCheckTokenProvider: appCheckProvider ?? () async => appCheck,
    timeout: timeout,
  );

  String response({
    bool premium = true,
    String tier = 'monthly',
    String state = 'SUBSCRIPTION_STATE_ACTIVE',
    Object? expiresAt = '2099-10-13T12:00:00.000Z',
  }) => jsonEncode({
    'isPremium': premium,
    'tier': tier,
    'subscriptionState': state,
    'expiresAt': expiresAt,
  });

  test('sends only purchaseToken to the fixed authorized endpoint', () async {
    late http.Request request;
    final dataSource = source(
      MockClient((received) async {
        request = received;
        return http.Response(response(), 200);
      }),
    );

    await dataSource.verifyPurchase(
      expectedUid: uid,
      purchaseToken: purchaseToken,
    );

    expect(request.url, BillingRemoteDataSource.verifyUri);
    expect(
      request.url.toString(),
      'https://life-os-backend-gray.vercel.app/api/billing/google/verify',
    );
    expect(jsonDecode(request.body), {'purchaseToken': purchaseToken});
    expect((jsonDecode(request.body) as Map).length, 1);
    expect(request.headers['authorization'], 'Bearer $idToken');
    expect(request.headers['x-firebase-appcheck'], appCheck);
  });

  test('parses monthly, annual and free contracts', () async {
    for (final contract in [
      (true, 'monthly', PremiumTier.monthly, '2099-01-01T00:00:00Z'),
      (true, 'annual', PremiumTier.annual, '2099-01-01T00:00:00Z'),
      (false, 'free', PremiumTier.free, null),
    ]) {
      final dataSource = source(
        MockClient(
          (_) async => http.Response(
            response(
              premium: contract.$1,
              tier: contract.$2,
              expiresAt: contract.$4,
            ),
            200,
          ),
        ),
      );
      final result = await dataSource.verifyPurchase(
        expectedUid: uid,
        purchaseToken: purchaseToken,
      );
      expect(result.isPremium, contract.$1);
      expect(result.tier, contract.$3);
    }
  });

  test('missing Firebase token blocks request', () async {
    var calls = 0;
    final dataSource = source(
      MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
      tokenProvider: (_) async => null,
    );
    await expectLater(
      dataSource.verifyPurchase(expectedUid: uid, purchaseToken: purchaseToken),
      throwsA(
        isA<BillingRemoteException>().having(
          (e) => e.code,
          'code',
          'UNAUTHENTICATED',
        ),
      ),
    );
    expect(calls, 0);
  });

  for (final state in [
    'SUBSCRIPTION_STATE_ACTIVE',
    'SUBSCRIPTION_STATE_IN_GRACE_PERIOD',
    'SUBSCRIPTION_STATE_CANCELED',
  ]) {
    test('Premium $state with future expiry is valid', () async {
      final dataSource = source(
        MockClient((_) async => http.Response(response(state: state), 200)),
      );
      final result = await dataSource.verifyPurchase(
        expectedUid: uid,
        purchaseToken: purchaseToken,
      );
      expect(result.isPremium, isTrue);
    });
  }

  for (final contract in [
    (true, 'SUBSCRIPTION_STATE_ON_HOLD'),
    (true, 'SUBSCRIPTION_STATE_PAUSED'),
    (true, 'UNKNOWN_STATE'),
    (false, 'UNKNOWN_STATE'),
  ]) {
    test(
      '${contract.$1 ? 'Premium' : 'Free'} ${contract.$2} fails closed',
      () async {
        final dataSource = source(
          MockClient(
            (_) async => http.Response(
              response(
                premium: contract.$1,
                tier: contract.$1 ? 'monthly' : 'free',
                state: contract.$2,
                expiresAt: contract.$1 ? '2099-01-01T00:00:00Z' : null,
              ),
              200,
            ),
          ),
        );
        await expectLater(
          dataSource.verifyPurchase(
            expectedUid: uid,
            purchaseToken: purchaseToken,
          ),
          throwsA(
            isA<BillingRemoteException>().having(
              (error) => error.code,
              'code',
              'BILLING_VERIFY_INVALID_RESPONSE',
            ),
          ),
        );
      },
    );
  }

  test('Free accepts each known state with consistent free contract', () async {
    for (final state in [
      'SUBSCRIPTION_STATE_UNSPECIFIED',
      'SUBSCRIPTION_STATE_PENDING',
      'SUBSCRIPTION_STATE_ACTIVE',
      'SUBSCRIPTION_STATE_PAUSED',
      'SUBSCRIPTION_STATE_IN_GRACE_PERIOD',
      'SUBSCRIPTION_STATE_ON_HOLD',
      'SUBSCRIPTION_STATE_CANCELED',
      'SUBSCRIPTION_STATE_EXPIRED',
      'SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED',
    ]) {
      final dataSource = source(
        MockClient(
          (_) async => http.Response(
            response(
              premium: false,
              tier: 'free',
              state: state,
              expiresAt: null,
            ),
            200,
          ),
        ),
      );
      final result = await dataSource.verifyPurchase(
        expectedUid: uid,
        purchaseToken: purchaseToken,
      );
      expect(result.isPremium, isFalse);
      expect(result.tier, PremiumTier.free);
      expect(result.expiresAt, isNull);
    }
  });

  test('UID change during token refresh blocks request', () async {
    var currentUid = uid;
    var calls = 0;
    final dataSource = source(
      MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
      currentUid: () => currentUid,
      tokenProvider: (_) async {
        currentUid = 'user-b';
        return idToken;
      },
    );
    await expectLater(
      dataSource.verifyPurchase(expectedUid: uid, purchaseToken: purchaseToken),
      throwsA(
        isA<BillingRemoteException>().having(
          (e) => e.code,
          'code',
          'UNAUTHENTICATED',
        ),
      ),
    );
    expect(calls, 0);
  });

  test('missing App Check blocks request', () async {
    var calls = 0;
    final dataSource = source(
      MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
      appCheckProvider: () async => null,
    );
    await expectLater(
      dataSource.verifyPurchase(expectedUid: uid, purchaseToken: purchaseToken),
      throwsA(
        isA<BillingRemoteException>().having(
          (e) => e.code,
          'code',
          'APP_CHECK_REQUIRED',
        ),
      ),
    );
    expect(calls, 0);
  });

  test('timeout is typed and sanitized', () async {
    final dataSource = source(
      MockClient((_) => Completer<http.Response>().future),
      timeout: const Duration(milliseconds: 5),
    );
    await expectLater(
      dataSource.verifyPurchase(expectedUid: uid, purchaseToken: purchaseToken),
      throwsA(
        isA<BillingRemoteException>()
            .having((e) => e.code, 'code', 'BILLING_VERIFY_TIMEOUT')
            .having(
              (e) => e.toString(),
              'safe',
              isNot(contains(purchaseToken)),
            ),
      ),
    );
  });

  for (final status in [401, 403, 429, 500]) {
    test('HTTP $status is typed without exposing private values', () async {
      final dataSource = source(
        MockClient(
          (_) async => http.Response(
            jsonEncode({'error': purchaseToken, 'token': idToken}),
            status,
          ),
        ),
      );
      try {
        await dataSource.verifyPurchase(
          expectedUid: uid,
          purchaseToken: purchaseToken,
        );
        fail('Expected failure');
      } on BillingRemoteException catch (error) {
        expect('${error.message}$error', isNot(contains(purchaseToken)));
        expect('${error.message}$error', isNot(contains(idToken)));
        expect(error.isRetryable, status == 429 || status >= 500);
      }
    });
  }

  for (final body in [
    '{invalid',
    '{}',
    '{"isPremium":"true","tier":"monthly","subscriptionState":"SUBSCRIPTION_STATE_ACTIVE","expiresAt":"2099-01-01T00:00:00Z"}',
    '{"isPremium":true,"tier":"weekly","subscriptionState":"SUBSCRIPTION_STATE_ACTIVE","expiresAt":"2099-01-01T00:00:00Z"}',
    '{"isPremium":true,"tier":"monthly","subscriptionState":"SUBSCRIPTION_STATE_ACTIVE","expiresAt":"invalid"}',
  ]) {
    test('malformed response fails closed', () async {
      final dataSource = source(
        MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(
        dataSource.verifyPurchase(
          expectedUid: uid,
          purchaseToken: purchaseToken,
        ),
        throwsA(
          isA<BillingRemoteException>().having(
            (e) => e.code,
            'code',
            'BILLING_VERIFY_INVALID_RESPONSE',
          ),
        ),
      );
    });
  }
}
