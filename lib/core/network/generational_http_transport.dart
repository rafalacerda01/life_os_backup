import 'dart:async';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import '../database/local_account_session.dart';
import 'generational_http_store.dart';
import '../services/emulator_account_runtime.dart';

class HttpCustodyException implements Exception {
  const HttpCustodyException(this.code, {this.acknowledged = false});
  final bool acknowledged;
  final String code;
  @override
  String toString() => code;
}

/// A captured User is retained through refresh; JWT checks are consistency only.
/// Server verification, origin and transactional controls remain authoritative.
class GenerationalHttpTransport {
  GenerationalHttpTransport({
    required this.store,
    required this.lease,
    required this.auth,
    required this.client,
    required this.appCheckToken,
    required this.baseUri,
    this.localRuntime,
    this.timeout = const Duration(seconds: 15),
    Future<String?> Function(User, bool)? idToken,
  }) : _idToken = idToken ?? ((user, refresh) => user.getIdToken(refresh)) {
    if (lease.identity.namespace != store.identity.namespace)
      throw const HttpCustodyException('HTTP_BINDING_MISMATCH');
    // The SDK getter creates a new wrapper every read. Object identity cannot
    // represent a session. Invalidate in-flight work on every Auth state event;
    // the immutable lease and full JWT binding are checked independently.
    _sessionEvents = auth.authStateChanges().listen(
      (_) {
        _authRevision++;
      },
      onError: (Object _) {
        _closed = true;
        _authRevision++;
      },
    );
  }
  final GenerationalHttpStore store;
  final LocalAccountLease lease;
  final FirebaseAuth auth;
  final http.Client client;
  final Future<String?> Function() appCheckToken;
  final Future<String?> Function(User, bool) _idToken;
  late final StreamSubscription<User?> _sessionEvents;
  int _authRevision = 0;
  bool _closed = false;
  Future<void> close() async {
    _closed = true;
    _authRevision++;
    await _sessionEvents.cancel();
  }

  final EmulatorAccountRuntime? localRuntime;
  final Uri baseUri;
  final Duration timeout;
  void _current(User original, int revision) {
    lease.requireCurrent();
    if (_closed ||
        revision != _authRevision ||
        auth.currentUser?.uid != original.uid ||
        original.uid != store.identity.uid ||
        auth.app.options.projectId != store.identity.projectId ||
        auth.tenantId != store.identity.tenantId) {
      throw const HttpCustodyException('HTTP_SESSION_CHANGED');
    }
  }

  void _claims(Map<String, dynamic>? d) {
    final i = store.identity;
    if (d == null ||
        d['sub'] != i.uid ||
        d['user_id'] != null && d['user_id'] != i.uid ||
        d['aud'] != i.projectId ||
        d['iss'] != 'https://securetoken.google.com/${i.projectId}' ||
        d['lifeos_generation'] != i.generation ||
        (d['firebase'] as Map?)?['tenant'] != i.tenantId)
      throw const HttpCustodyException('HTTP_TOKEN_BINDING_MISMATCH');
  }

  void _token(String? token) {
    try {
      final parts = token!.split('.');
      if (parts.length != 3) throw const FormatException();
      _claims(
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))))
            as Map<String, dynamic>,
      );
    } catch (_) {
      throw const HttpCustodyException('HTTP_TOKEN_BINDING_MISMATCH');
    }
  }

  Future<void> _liveBinding(User original, int revision) async {
    _current(original, revision);
    // Observe the active SDK identity ONLY to refuse a mismatch. Its token is
    // never used for dispatch or refresh of this operation's captured User.
    final active = auth.currentUser;
    if (active == null)
      throw const HttpCustodyException('HTTP_SESSION_CHANGED');
    final result = await active.getIdTokenResult(false).timeout(timeout);
    _current(original, revision);
    _claims(result.claims);
  }

  Future<Map<String, dynamic>> send(
    GenerationalHttpIntent intent, {
    void Function(Map<String, dynamic>)? validateResponse,
    Future<void> Function()? acknowledgeDomain,
  }) async {
    // R1 production policy remains CLOSED. No arbitrary credential destination.
    final runtime = localRuntime;
    if (runtime != null) runtime.requireClients(auth, runtime.store);
    if ((store.identity.projectId != 'demo-life-os' &&
          (runtime == null || runtime.environment.projectId != store.identity.projectId || runtime.baseUri != baseUri)) ||
        store.identity.databaseId != '(default)' ||
        store.identity.tenantId != null ||
        baseUri.scheme != 'http' ||
        baseUri.host != '127.0.0.1' ||
        baseUri.userInfo.isNotEmpty ||
        baseUri.hasQuery ||
        baseUri.hasFragment) {
      throw const HttpCustodyException('HTTP_ENVIRONMENT_CLOSED');
    }
    final revision = _authRevision;
    final original = auth.currentUser;
    if (original == null)
      throw const HttpCustodyException('HTTP_AUTHENTICATION_REQUIRED');
    _current(original, revision);
    await store.verify(intent);
    _current(original, revision);
    var token = await _idToken(original, false).timeout(timeout);
    _current(original, revision);
    _token(token);
    Future<http.Response> dispatch() async {
      final appCheck = await appCheckToken().timeout(timeout);
      _current(original, revision);
      _token(token);
      await _liveBinding(original, revision);
      if (appCheck == null || appCheck.trim().isEmpty)
        throw const HttpCustodyException('HTTP_APP_CHECK_REQUIRED');
      return client
          .post(
            baseUri.resolve('/api/${intent.route}'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
              'X-Firebase-AppCheck': appCheck,
              'X-LifeOS-Operation': base64Url
                  .encode(utf8.encode(httpCanonical(intent.context)))
                  .replaceAll('=', ''),
            },
            body: intent.bodyJson,
          )
          .timeout(timeout);
    }

    try {
      var response = await dispatch();
      await _liveBinding(original, revision);
      if (response.statusCode == 401) {
        // The original object only. Never reacquire currentUser after an await.
        token = await _idToken(original, true).timeout(timeout);
        _current(original, revision);
        _token(token);
        response = await dispatch();
        await _liveBinding(original, revision);
      }
      if (response.statusCode < 200 || response.statusCode >= 300)
        throw HttpCustodyException('HTTP_REMOTE_${response.statusCode}');
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final encoded = response.headers['x-lifeos-operation-ack'];
      if (encoded == null || encoded.length > 8192)
        throw const FormatException();
      final ack =
          jsonDecode(
                utf8.decode(base64Url.decode(base64Url.normalize(encoded))),
              )
              as Map<String, dynamic>;
      final expected = {
        ...intent.context,
        'status': response.statusCode,
        'responseHash': httpDigest(body),
        'operationReplay': ack['operationReplay'],
      };
      if (ack['operationReplay'] is! bool ||
          httpCanonical(ack) != httpCanonical(expected))
        throw const FormatException();
      _current(original, revision);
      // Domain confirmation (e.g. F01 card receipt) precedes the atomic SQL ACK.
      validateResponse?.call(body);
      await store.acknowledge(
        intent,
        body,
        ack,
        lease,
        validateSession: () => _current(original, revision),
        acknowledgeDomain: acknowledgeDomain,
      );
      // The SQL commit is the ACK linearization point. No additional async
      // credential lookup may turn that committed row back into pending.
      try {
        _current(original, revision);
      } catch (_) {
        throw const HttpCustodyException(
          'HTTP_SESSION_CHANGED_AFTER_ACK',
          acknowledged: true,
        );
      }
      return body;
    } on TimeoutException {
      throw const HttpCustodyException('HTTP_UNKNOWN_TIMEOUT');
    } on FormatException {
      throw const HttpCustodyException('HTTP_UNKNOWN_ACK');
    } on http.ClientException {
      throw const HttpCustodyException('HTTP_UNKNOWN_NETWORK');
    }
  }
}
