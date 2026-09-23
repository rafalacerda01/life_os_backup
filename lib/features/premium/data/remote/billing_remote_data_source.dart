import 'dart:async';
import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:life_os/features/premium/domain/entities/premium_status_entity.dart';

typedef BillingIdTokenProvider = Future<String?> Function(String expectedUid);
typedef BillingAppCheckTokenProvider = Future<String?> Function();
typedef BillingCurrentUserIdProvider = String? Function();

class BillingVerificationResponse {
  const BillingVerificationResponse({
    required this.isPremium,
    required this.tier,
    required this.subscriptionState,
    required this.expiresAt,
  });

  final bool isPremium;
  final PremiumTier tier;
  final String subscriptionState;
  final DateTime? expiresAt;
}

class BillingRemoteException implements Exception {
  const BillingRemoteException({
    required this.code,
    required this.message,
    this.statusCode,
    this.isRetryable = false,
  });

  final String code;
  final String message;
  final int? statusCode;
  final bool isRetryable;

  @override
  String toString() => 'BillingRemoteException($code)';
}

class BillingRemoteDataSource {
  static final Uri verifyUri = Uri.https(
    'life-os-backend-gray.vercel.app',
    '/api/billing/google/verify',
  );
  static const Duration defaultTimeout = Duration(seconds: 45);
  static const _knownSubscriptionStates = {
    'SUBSCRIPTION_STATE_UNSPECIFIED',
    'SUBSCRIPTION_STATE_PENDING',
    'SUBSCRIPTION_STATE_ACTIVE',
    'SUBSCRIPTION_STATE_PAUSED',
    'SUBSCRIPTION_STATE_IN_GRACE_PERIOD',
    'SUBSCRIPTION_STATE_ON_HOLD',
    'SUBSCRIPTION_STATE_CANCELED',
    'SUBSCRIPTION_STATE_EXPIRED',
    'SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED',
  };
  static const _premiumSubscriptionStates = {
    'SUBSCRIPTION_STATE_ACTIVE',
    'SUBSCRIPTION_STATE_IN_GRACE_PERIOD',
    'SUBSCRIPTION_STATE_CANCELED',
  };

  BillingRemoteDataSource({
    http.Client? client,
    BillingIdTokenProvider? idTokenProvider,
    BillingAppCheckTokenProvider? appCheckTokenProvider,
    BillingCurrentUserIdProvider? currentUserIdProvider,
    Duration timeout = defaultTimeout,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _idTokenProvider = idTokenProvider ?? _firebaseIdTokenProvider,
       _appCheckTokenProvider =
           appCheckTokenProvider ?? _firebaseAppCheckTokenProvider,
       _currentUserIdProvider =
           currentUserIdProvider ??
           (() => FirebaseAuth.instance.currentUser?.uid),
       _timeout = timeout {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be positive.');
    }
  }

  final http.Client _client;
  final bool _ownsClient;
  final BillingIdTokenProvider _idTokenProvider;
  final BillingAppCheckTokenProvider _appCheckTokenProvider;
  final BillingCurrentUserIdProvider _currentUserIdProvider;
  final Duration _timeout;

  Future<BillingVerificationResponse> verifyPurchase({
    required String expectedUid,
    required String purchaseToken,
  }) async {
    final uid = expectedUid.trim();
    final token = purchaseToken.trim();
    if (uid.isEmpty || token.isEmpty) {
      throw const BillingRemoteException(
        code: 'INVALID_PURCHASE',
        message: 'Não foi possível validar esta compra.',
      );
    }

    final idToken = await _loadIdToken(uid);
    final appCheckToken = await _loadAppCheckToken();
    _requireCurrentUser(uid);

    http.Response response;
    try {
      response = await _client
          .post(
            verifyUri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $idToken',
              'X-Firebase-AppCheck': appCheckToken,
            },
            body: jsonEncode({'purchaseToken': token}),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const BillingRemoteException(
        code: 'BILLING_VERIFY_TIMEOUT',
        message:
            'A validação da compra demorou para responder. Tente novamente.',
        isRetryable: true,
      );
    } on http.ClientException {
      throw const BillingRemoteException(
        code: 'BILLING_VERIFY_UNAVAILABLE',
        message: 'Não foi possível validar a compra agora. Tente novamente.',
        isRetryable: true,
      );
    } on BillingRemoteException {
      rethrow;
    } catch (_) {
      throw const BillingRemoteException(
        code: 'BILLING_VERIFY_UNAVAILABLE',
        message: 'Não foi possível validar a compra agora. Tente novamente.',
        isRetryable: true,
      );
    }

    _requireCurrentUser(uid);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _backendException(response.statusCode, response.body);
    }
    return _parseResponse(response.body, response.statusCode);
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<String> _loadIdToken(String uid) async {
    _requireCurrentUser(uid);
    try {
      final token = await _idTokenProvider(uid).timeout(_timeout);
      _requireCurrentUser(uid);
      if (token == null || token.trim().isEmpty) {
        throw const BillingRemoteException(
          code: 'UNAUTHENTICATED',
          message: 'Sua sessão não é válida. Entre novamente e tente de novo.',
        );
      }
      return token.trim();
    } on BillingRemoteException {
      rethrow;
    } catch (_) {
      throw const BillingRemoteException(
        code: 'UNAUTHENTICATED',
        message: 'Sua sessão não é válida. Entre novamente e tente de novo.',
      );
    }
  }

  Future<String> _loadAppCheckToken() async {
    try {
      final token = await _appCheckTokenProvider().timeout(_timeout);
      if (token == null || token.trim().isEmpty) {
        throw const BillingRemoteException(
          code: 'APP_CHECK_REQUIRED',
          message: _appCheckMessage,
        );
      }
      return token.trim();
    } on BillingRemoteException {
      rethrow;
    } catch (_) {
      throw const BillingRemoteException(
        code: 'APP_CHECK_INVALID',
        message: _appCheckMessage,
      );
    }
  }

  void _requireCurrentUser(String expectedUid) {
    if (_currentUserIdProvider() != expectedUid) {
      throw const BillingRemoteException(
        code: 'UNAUTHENTICATED',
        message: 'Sua sessão não é válida. Entre novamente e tente de novo.',
      );
    }
  }

  static BillingVerificationResponse _parseResponse(String body, int status) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic> ||
          decoded.length != 4 ||
          decoded['isPremium'] is! bool ||
          decoded['tier'] is! String ||
          decoded['subscriptionState'] is! String ||
          !decoded.containsKey('expiresAt')) {
        throw const FormatException('Invalid billing response.');
      }
      final isPremium = decoded['isPremium'] as bool;
      final tier = switch (decoded['tier']) {
        'free' => PremiumTier.free,
        'monthly' => PremiumTier.monthly,
        'annual' => PremiumTier.annual,
        _ => throw const FormatException('Invalid tier.'),
      };
      final subscriptionState = (decoded['subscriptionState'] as String).trim();
      final expiresValue = decoded['expiresAt'];
      final expiresAt = expiresValue is String
          ? DateTime.tryParse(expiresValue)?.toUtc()
          : null;
      if (!_knownSubscriptionStates.contains(subscriptionState) ||
          (expiresValue != null && expiresAt == null) ||
          (isPremium &&
              (!_premiumSubscriptionStates.contains(subscriptionState) ||
                  tier == PremiumTier.free ||
                  expiresAt == null ||
                  !expiresAt.isAfter(DateTime.now().toUtc()))) ||
          (!isPremium && (tier != PremiumTier.free || expiresValue != null))) {
        throw const FormatException('Inconsistent billing response.');
      }
      return BillingVerificationResponse(
        isPremium: isPremium,
        tier: tier,
        subscriptionState: subscriptionState,
        expiresAt: expiresAt,
      );
    } catch (_) {
      throw BillingRemoteException(
        code: 'BILLING_VERIFY_INVALID_RESPONSE',
        message: 'Não foi possível confirmar a validação da compra.',
        statusCode: status,
      );
    }
  }

  static BillingRemoteException _backendException(int statusCode, String body) {
    if (statusCode == 401) {
      return BillingRemoteException(
        code: 'UNAUTHENTICATED',
        message: 'Sua sessão não é válida. Entre novamente e tente de novo.',
        statusCode: statusCode,
      );
    }
    if (statusCode == 403) {
      return BillingRemoteException(
        code: 'BILLING_ACCOUNT_MISMATCH',
        message: 'Esta compra não pertence à sessão atual.',
        statusCode: statusCode,
      );
    }
    if (statusCode == 429) {
      return BillingRemoteException(
        code: 'RATE_LIMITED',
        message: 'Muitas tentativas. Aguarde e tente novamente.',
        statusCode: statusCode,
        isRetryable: true,
      );
    }
    if (statusCode >= 500 && _isAcknowledgementFailure(body)) {
      return BillingRemoteException(
        code: 'BILLING_ACKNOWLEDGEMENT_FAILED',
        message:
            'A assinatura foi validada, mas o reconhecimento ainda precisa ser confirmado. Tente novamente.',
        statusCode: statusCode,
        isRetryable: true,
      );
    }
    return BillingRemoteException(
      code: 'BILLING_VERIFY_FAILED',
      message: 'Não foi possível validar a compra agora. Tente novamente.',
      statusCode: statusCode,
      isRetryable: statusCode >= 500,
    );
  }

  static bool _isAcknowledgementFailure(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> &&
          decoded['code'] == 'BILLING_ACKNOWLEDGEMENT_FAILED';
    } on FormatException {
      return false;
    }
  }

  static const _appCheckMessage =
      'Não foi possível validar a segurança do aplicativo. Tente novamente.';
}

Future<String?> _firebaseIdTokenProvider(String expectedUid) =>
    loadBillingIdTokenForExpectedUser(FirebaseAuth.instance, expectedUid);
Future<String?> _firebaseAppCheckTokenProvider() =>
    FirebaseAppCheck.instance.getToken();

Future<String?> loadBillingIdTokenForExpectedUser(
  FirebaseAuth auth,
  String expectedUid,
) async {
  final uid = expectedUid.trim();
  final user = auth.currentUser;
  if (uid.isEmpty || user == null || user.uid != uid) {
    throw const BillingRemoteException(
      code: 'UNAUTHENTICATED',
      message: 'Sua sessão não é válida. Entre novamente e tente de novo.',
    );
  }
  final token = await user.getIdToken(true);
  if (auth.currentUser?.uid != uid) {
    throw const BillingRemoteException(
      code: 'UNAUTHENTICATED',
      message: 'Sua sessão não é válida. Entre novamente e tente de novo.',
    );
  }
  return token;
}
