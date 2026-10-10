import 'dart:async';
import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:life_os/core/database/remote_send_permit.dart';

import 'sync_operation_result.dart';
import 'sync_remote_data_source.dart';
import 'water_v2_contract.dart';

final class WaterV2TransportResult<T> {
  const WaterV2TransportResult.value(T this.value) : error = null;
  const WaterV2TransportResult.failure(SyncOperationResult this.error)
    : value = null;
  final T? value;
  final SyncOperationResult? error;
}

/// No application provider constructs an enabled instance. The named constructor
/// is explicit local test injection, with no remote flag or request override.
final class WaterV2RemoteDataSource {
  WaterV2RemoteDataSource(
    FirebaseAuth auth, {
    RemoteSendPermit Function(String)? captureRemoteSend,
  }) : this._(
         auth,
         false,
         captureRemoteSend,
         http.Client.new,
         null,
         () => FirebaseAppCheck.instance.getToken(),
         const Duration(seconds: 15),
       );

  WaterV2RemoteDataSource.enabledForLocalTests(
    FirebaseAuth auth, {
    required RemoteSendPermit Function(String) captureRemoteSend,
    required http.Client Function() clientFactory,
    required Future<String?> Function(User, bool) idTokenProvider,
    required SyncAppCheckTokenProvider appCheckTokenProvider,
    Duration requestTimeout = const Duration(seconds: 15),
  }) : this._(
         auth,
         true,
         captureRemoteSend,
         clientFactory,
         idTokenProvider,
         appCheckTokenProvider,
         requestTimeout,
       );

  WaterV2RemoteDataSource._(
    this._auth,
    this.isEnabled,
    this._captureRemoteSend,
    this._clientFactory,
    this._idTokenProvider,
    this._appCheckTokenProvider,
    this._timeout,
  );
  final FirebaseAuth _auth;
  final bool isEnabled;
  final RemoteSendPermit Function(String)? _captureRemoteSend;
  final http.Client Function() _clientFactory;
  final Future<String?> Function(User, bool)? _idTokenProvider;
  final SyncAppCheckTokenProvider _appCheckTokenProvider;
  final Duration _timeout;

  RemoteSendPermit capturePermit(String uid, bool Function() canSend) =>
      (_captureRemoteSend?.call(uid) ?? RemoteSendPermit(() => false)).and(
        () => isEnabled && canSend() && _auth.currentUser?.uid == uid,
      );

  Future<WaterV2TransportResult<WaterV2IncrementSuccess>> increment(
    WaterV2IncrementRequest request,
    RemoteSendPermit permit,
  ) => _send(
    request.ownerUid,
    request.toJson(),
    permit,
    (body, boundPermit) =>
        WaterV2IncrementSuccess.parse(body, request, permit: boundPermit),
  );

  Future<WaterV2TransportResult<WaterV2ReconcileSuccess>> reconcile(
    WaterV2ReconcileRequest request,
    RemoteSendPermit permit,
  ) => _send(
    request.ownerUid,
    request.toJson(),
    permit,
    (body, _) => WaterV2ReconcileSuccess.parse(body, request),
  );

  Future<String?> _token(String uid, bool forceRefresh) {
    final user = _auth.currentUser;
    if (user == null || user.uid != uid) return Future.value(null);
    return _idTokenProvider?.call(user, forceRefresh) ??
        user.getIdToken(forceRefresh);
  }

  Future<WaterV2TransportResult<T>> _send<T>(
    String uid,
    Map<String, dynamic> payload,
    RemoteSendPermit permit,
    T Function(String, RemoteSendPermit) decode,
  ) async {
    if (!isEnabled)
      return const WaterV2TransportResult.failure(
        SyncOperationResult.retryable(code: 'WATER_V2_DISABLED'),
      );
    final boundPermit = permit.and(() => _auth.currentUser?.uid == uid);
    http.Client? client;
    try {
      boundPermit.requireCurrent();
      final url = FirestoreSyncRemoteDataSource.backendSyncUri;
      if (url.scheme != 'https' ||
          url.host != 'life-os-backend-gray.vercel.app' ||
          url.path != '/api/sync' ||
          url.hasQuery ||
          url.hasFragment ||
          url.userInfo.isNotEmpty ||
          url.hasPort) {
        return const WaterV2TransportResult.failure(
          SyncOperationResult.retryable(code: 'WATER_ENDPOINT_INVALID'),
        );
      }
      final token = await _token(uid, false);
      boundPermit.requireCurrent();
      if (token == null || token.trim().isEmpty)
        return const WaterV2TransportResult.failure(
          SyncOperationResult.retryable(code: 'AUTHENTICATION_REQUIRED'),
        );
      String? appCheck;
      try {
        appCheck = await _appCheckTokenProvider();
      } catch (_) {
        boundPermit.requireCurrent();
        return const WaterV2TransportResult.failure(
          SyncOperationResult.retryable(code: 'APP_CHECK_REQUIRED'),
        );
      }
      boundPermit.requireCurrent();
      if (appCheck == null || appCheck.trim().isEmpty)
        return const WaterV2TransportResult.failure(
          SyncOperationResult.retryable(code: 'APP_CHECK_REQUIRED'),
        );
      final body = jsonEncode(payload);
      final requestClient = _clientFactory();
      client = requestClient;
      Future<http.Response> send(String idToken) {
        final request = http.Request('POST', url)
          ..followRedirects = false
          ..headers.addAll({
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $idToken',
            'X-Firebase-AppCheck': appCheck!.trim(),
          })
          ..body = body;
        boundPermit.requireCurrent();
        return requestClient
            .send(request)
            .then(http.Response.fromStream)
            .timeout(_timeout);
      }

      var response = await send(token);
      boundPermit.requireCurrent();
      if (response.statusCode == 401 && !_isAppCheck(response.body)) {
        final fresh = await _token(uid, true);
        boundPermit.requireCurrent();
        if (fresh == null || fresh.trim().isEmpty)
          return const WaterV2TransportResult.failure(
            SyncOperationResult.retryable(code: 'AUTHENTICATION_REQUIRED'),
          );
        response = await send(fresh);
        boundPermit.requireCurrent();
      }
      if (response.statusCode == 200) {
        final result = decode(response.body, boundPermit);
        boundPermit.requireCurrent();
        return WaterV2TransportResult.value(result);
      }
      return WaterV2TransportResult.failure(_mapError(response));
    } on RemoteSessionStopped {
      return const WaterV2TransportResult.failure(
        SyncOperationResult.retryable(code: 'SESSION_STOPPED'),
      );
    } on FormatException {
      return const WaterV2TransportResult.failure(
        SyncOperationResult.retryable(code: 'WATER_INVALID_RESPONSE'),
      );
    } on TimeoutException {
      return const WaterV2TransportResult.failure(
        SyncOperationResult.retryable(code: 'SYNC_TIMEOUT'),
      );
    } on http.ClientException {
      return const WaterV2TransportResult.failure(
        SyncOperationResult.retryable(code: 'NETWORK_ERROR'),
      );
    } catch (_) {
      return const WaterV2TransportResult.failure(
        SyncOperationResult.retryable(code: 'WATER_REMOTE_FAILED'),
      );
    } finally {
      client?.close();
    }
  }

  bool _isAppCheck(String body) {
    try {
      return const {
        'APP_CHECK_REQUIRED',
        'APP_CHECK_INVALID',
      }.contains(WaterV2Validation.object(body)['code']);
    } catch (_) {
      return false;
    }
  }

  SyncOperationResult _mapError(http.Response response) {
    if (response.statusCode == 401)
      return SyncOperationResult.retryable(
        code: _isAppCheck(response.body)
            ? 'APP_CHECK_REQUIRED'
            : 'AUTHENTICATION_REQUIRED',
      );
    // Only known code/status/retryability combinations can become terminal.
    const known = <String, (int, bool)>{
      'WATER_INVALID_PAYLOAD': (400, false),
      'WATER_MUTATION_CONFLICT': (409, false),
      'WATER_USER_NOT_FOUND': (404, false),
      'WATER_ACCOUNT_DELETING': (403, false),
      'WATER_V2_DISABLED': (503, true),
      'WATER_MIGRATION_NOT_READY': (503, true),
      'WATER_INVALID_REMOTE_STATE': (409, true),
      'WATER_SNAPSHOT_MISMATCH': (409, true),
      'WATER_FIRESTORE_UNAVAILABLE': (503, true),
    };
    try {
      final m = WaterV2Validation.object(response.body);
      final spec = known[m['code']];
      if (WaterV2Validation.exact(m, const {'error', 'code', 'retryable'}) &&
          m['error'] is String &&
          spec != null &&
          response.statusCode == spec.$1 &&
          m['retryable'] == spec.$2) {
        final code = m['code'] as String;
        if (spec.$2) return SyncOperationResult.retryable(code: code);
        if (spec.$1 == 403)
          return SyncOperationResult.permissionDenied(code: code);
        return SyncOperationResult.invalidPayload(code: code);
      }
    } catch (_) {
      /* Raw server errors may contain secrets: never return them. */
    }
    return SyncOperationResult.retryable(
      code: 'WATER_HTTP_${response.statusCode}',
    );
  }
}
