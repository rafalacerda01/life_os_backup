import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../../../../core/database/local_database_identity.dart';
import '../local/account_deletion_cleanup_barrier.dart';
import '../local/auth_cleanup_barrier.dart';

enum DeletionRecoveryState {
  pending,
  confirmed,
  unknown,
  invalidReceipt,
  otherGeneration,
  unauthorized,
  unavailable,
}

enum DeletionPreparation { absent, unsent, fenced, inconsistent }

final class RecoveredDeletionProof {
  const RecoveredDeletionProof._(
    this.identity,
    this.operationId,
    this.markerRevision,
  );

  final LocalDatabaseIdentity identity;
  final String operationId;
  final String markerRevision;
}

final class DeletionRecoveryResult {
  const DeletionRecoveryResult(
    this.state, {
    this.operationId,
    this.manifestRef,
    this.proof,
  });

  final DeletionRecoveryState state;
  final String? operationId;
  final String? manifestRef;
  final RecoveredDeletionProof? proof;
}

/// Local homologation client. This component never dispatches or finalizes deletion.
final class AccountDeletionRecovery {
  AccountDeletionRecovery({
    required this.identity,
    required Uri baseUri,
    required this._storage,
    required this._client,
    required this._appCheckToken,
    required this._isOriginalSession,
    required this._isSignedOut,
    this._authChanges,
  }) : _url = baseUri.resolve('/api/account/deletion-result') {
    if (!identity.isBound ||
        identity.tenantId != null ||
        baseUri.scheme != 'http' ||
        baseUri.host != '127.0.0.1' ||
        !baseUri.hasPort ||
        baseUri.userInfo.isNotEmpty ||
        baseUri.hasQuery ||
        baseUri.hasFragment) {
      throw ArgumentError('DELETION_RECOVERY_BINDING_INVALID');
    }
  }

  final LocalDatabaseIdentity identity;
  final FlutterSecureStorage _storage;
  final http.Client _client;
  final Future<String?> Function() _appCheckToken;
  final Future<bool> Function() _isOriginalSession;
  final bool Function() _isSignedOut;
  final Stream<Object?> Function()? _authChanges;
  final Uri _url;
  static final _tails = <String, Future<void>>{};
  static final _keyFormat = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final _revisionFormat = RegExp(r'^[A-Za-z0-9_-]{22}$');
  static final _uuid = RegExp(
    r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
  );
  static const _timeout = Duration(seconds: 15);

  String get _storageKey =>
      'life_os_deletion_recovery_v1:${identity.namespace}';

  Future<T> _serial<T>(Future<T> Function() action) {
    final key = _storageKey;
    final result = (_tails[key] ?? Future<void>.value()).then((_) => action());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _tails[key] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_tails[key], tail)) _tails.remove(key);
      }),
    );
    return result;
  }

  Future<
    ({String key, String? operationId, String? markerRevision, bool? fenced})?
  >
  _read() async {
    final raw = await _storage.read(key: _storageKey);
    if (raw == null) return null;
    final data = jsonDecode(raw);
    if (data is! Map ||
        data.length !=
            3 +
                (data.containsKey('markerRevision') ? 1 : 0) +
                (data.containsKey('fenced') ? 1 : 0) ||
        !data.containsKey('operationId') ||
        LocalDatabaseIdentity.fromBinding(data['identity']) != identity ||
        data['key'] is! String ||
        !_keyFormat.hasMatch(data['key'] as String) ||
        (data['operationId'] != null &&
            (data['operationId'] is! String ||
                !_uuid.hasMatch(data['operationId'] as String))) ||
        (data.containsKey('markerRevision') &&
            (data['markerRevision'] is! String ||
                !_revisionFormat.hasMatch(data['markerRevision'] as String))) ||
        (data.containsKey('fenced') &&
            (data['fenced'] is! bool ||
                data['markerRevision'] == null ||
                (data['fenced'] == false && data['operationId'] != null)))) {
      throw const FormatException('DELETION_RECOVERY_RECORD_INVALID');
    }
    return (
      key: data['key'] as String,
      operationId: data['operationId'] as String?,
      markerRevision: data['markerRevision'] as String?,
      fenced: data['fenced'] as bool?,
    );
  }

  Future<void> _write(
    String key,
    String? operationId,
    String? markerRevision, {
    bool? fenced,
  }) async {
    final value = jsonEncode({
      'identity': identity.toBinding(),
      'key': key,
      'operationId': operationId,
      'markerRevision': ?markerRevision,
      'fenced': ?fenced,
    });
    await _storage.write(key: _storageKey, value: value);
    if (await _storage.read(key: _storageKey) != value) {
      throw StateError('DELETION_RECOVERY_STORAGE_UNCONFIRMED');
    }
  }

  String _randomToken(int length) {
    final random = Random.secure();
    return base64Url
        .encode(List.generate(length, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  /// Reserves the marker revision and capability in one write, without exposing the key.
  Future<String> reserveDispatch() => _serial(() async {
    if (!await _isOriginalSession() || await _read() != null) {
      throw StateError('DELETION_RECOVERY_ALREADY_PREPARED');
    }
    final revision = _randomToken(16);
    await _write(_randomToken(32), null, revision, fenced: false);
    return revision;
  });

  bool _matches(PendingAccountDeletion marker, String? revision) =>
      marker.identity == identity &&
      marker.userId == identity.uid &&
      marker.phase == AccountDeletionPhase.requested &&
      marker.revision == revision;

  /// Commit the one-way boundary immediately before transport. Never issues the key twice.
  Future<Map<String, String>> fenceDispatch(PendingAccountDeletion marker) =>
      _serial(() async {
        final intent = await _read();
        if (intent == null ||
            intent.fenced != false ||
            !_matches(marker, intent.markerRevision)) {
          throw StateError('DELETION_RECOVERY_DISPATCH_FENCED');
        }
        await _write(intent.key, null, intent.markerRevision, fenced: true);
        return {'receiptKey': intent.key};
      });

  Future<DeletionPreparation> preparation(PendingAccountDeletion? marker) =>
      _serial(() async {
        final intent = await _read();
        if (intent == null)
          return marker == null
              ? DeletionPreparation.absent
              : DeletionPreparation.inconsistent;
        if (marker != null && !_matches(marker, intent.markerRevision))
          return DeletionPreparation.inconsistent;
        if (intent.fenced == false) return DeletionPreparation.unsent;
        return marker == null
            ? DeletionPreparation.inconsistent
            : DeletionPreparation.fenced;
      });

  Future<bool> resetUnsent() => _serial(
    () => _withRecoverySession((allowed) async {
      final intent = await _read();
      if (intent == null || intent.fenced != false || !await allowed())
        return false;
      final barrier = AccountDeletionCleanupBarrier(
        SecureAuthCleanupBarrierStorage(_storage),
        identity: identity,
      );
      final marker = await barrier.readForUser(identity.uid);
      if (marker != null &&
          (!_matches(marker, intent.markerRevision) ||
              !await allowed() ||
              !await barrier.clearIfCurrent(marker)))
        return false;
      // Keep the reservation until after the marker is gone so a crash is retryable.
      if (!await allowed()) return false;
      await _storage.delete(key: _storageKey);
      if (await _storage.read(key: _storageKey) != null)
        throw StateError('DELETION_RECOVERY_RESET_UNCONFIRMED');
      return true;
    }),
  );

  /// Persist before the original authenticated request. An existing intent must
  /// go through [recover], even if the request never received a response.
  Future<Map<String, String>> preparePayload({
    PendingAccountDeletion? marker,
  }) => _serial(() async {
    if (!await _isOriginalSession())
      throw StateError('DELETION_RECOVERY_SESSION_CHANGED');
    if (await _read() != null)
      throw StateError('DELETION_RECOVERY_ALREADY_PREPARED');
    if (marker != null &&
        (marker.identity != identity ||
            marker.userId != identity.uid ||
            marker.phase != AccountDeletionPhase.requested ||
            !_revisionFormat.hasMatch(marker.revision))) {
      throw StateError('DELETION_RECOVERY_MARKER_MISMATCH');
    }
    final key = _randomToken(32);
    await _write(key, null, marker?.revision);
    if (!await _isOriginalSession())
      throw StateError('DELETION_RECOVERY_SESSION_CHANGED');
    return {'receiptKey': key};
  });

  Future<T> _withRecoverySession<T>(
    Future<T> Function(Future<bool> Function()) action,
  ) async {
    final events = _authChanges;
    if (events == null) return action(() async => _isSignedOut());
    final first = Completer<void>();
    var changed = false;
    void invalidate() {
      changed = true;
      if (!first.isCompleted) first.complete();
    }

    final subscription = events().listen(
      (_) {
        if (first.isCompleted)
          invalidate();
        else
          first.complete();
      },
      onError: (Object _) => invalidate(),
      onDone: invalidate,
    );
    try {
      await first.future.timeout(_timeout);
      return await action(
        () async =>
            !changed &&
            (_isSignedOut() || await _isOriginalSession()) &&
            !changed,
      );
    } finally {
      await subscription.cancel();
    }
  }

  Future<DeletionRecoveryResult> recover() => _serial(() async {
    try {
      return await _withRecoverySession(_recover);
    } on FormatException {
      return const DeletionRecoveryResult(DeletionRecoveryState.invalidReceipt);
    } catch (_) {
      return const DeletionRecoveryResult(DeletionRecoveryState.unavailable);
    }
  });

  Future<DeletionRecoveryResult> _recover(
    Future<bool> Function() allowed,
  ) async {
    if (!await allowed())
      return const DeletionRecoveryResult(DeletionRecoveryState.unauthorized);
    final intent = await _read();
    if (intent == null || intent.fenced == false)
      return const DeletionRecoveryResult(DeletionRecoveryState.unauthorized);
    final token = await _appCheckToken().timeout(_timeout);
    if (token == null || token.isEmpty || !await allowed()) {
      return const DeletionRecoveryResult(DeletionRecoveryState.unauthorized);
    }
    final request = http.Request('POST', _url)
      ..followRedirects = false
      ..headers.addAll({
        'Content-Type': 'application/json',
        'X-Firebase-AppCheck': token,
      })
      ..body = jsonEncode({
        'uid': identity.uid,
        'generation': identity.generation,
        'receiptKey': intent.key,
      });
    final response = await _client.send(request).timeout(_timeout);
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(_timeout)) {
      if (bytes.length + chunk.length > 4096) {
        return const DeletionRecoveryResult(
          DeletionRecoveryState.invalidReceipt,
        );
      }
      bytes.addAll(chunk);
    }
    if (response.statusCode == 401)
      return const DeletionRecoveryResult(DeletionRecoveryState.unauthorized);
    if (response.statusCode != 200)
      return const DeletionRecoveryResult(DeletionRecoveryState.unavailable);
    if (!await allowed())
      return const DeletionRecoveryResult(DeletionRecoveryState.unauthorized);
    final result = _parse(
      jsonDecode(utf8.decode(bytes)),
      intent.operationId,
      intent.markerRevision,
    );
    if (result.operationId != null && intent.operationId == null)
      await _write(
        intent.key,
        result.operationId,
        intent.markerRevision,
        fenced: intent.fenced,
      );
    if (!await allowed())
      return const DeletionRecoveryResult(DeletionRecoveryState.unauthorized);
    return result;
  }

  DeletionRecoveryResult _parse(
    Object? value,
    String? originalId,
    String? markerRevision,
  ) {
    const invalid = DeletionRecoveryResult(
      DeletionRecoveryState.invalidReceipt,
    );
    if (value is! Map ||
        value.length != 9 ||
        value['version'] != 1 ||
        !value.containsKey('evidence'))
      return invalid;
    if (value['projectId'] != identity.projectId ||
        value['databaseId'] != identity.databaseId ||
        value['uid'] != identity.uid ||
        value['generation'] != identity.generation) {
      return const DeletionRecoveryResult(
        DeletionRecoveryState.otherGeneration,
      );
    }
    final operation = value['operationId'];
    final hash = sha256.convert(utf8.encode('users/${identity.uid}'));
    final manifest =
        'account_deletion_guards/${identity.uid}/cleanup_manifests/$hash';
    if (operation is! String ||
        !_uuid.hasMatch(operation) ||
        (originalId != null && originalId != operation) ||
        value['manifestRef'] != manifest)
      return invalid;
    final proof = value['evidence'];
    final state = switch (value['state']) {
      'CONFIRMED'
          when proof is Map &&
              proof.length == 3 &&
              proof['operationState'] == 'COMPLETE' &&
              proof['manifestState'] == 'COMPLETE' &&
              proof['authOutcome'] == 'CONFIRMED' =>
        DeletionRecoveryState.confirmed,
      'PENDING' when proof == null => DeletionRecoveryState.pending,
      'UNKNOWN' when proof == null => DeletionRecoveryState.unknown,
      _ => DeletionRecoveryState.invalidReceipt,
    };
    if (state == DeletionRecoveryState.invalidReceipt) return invalid;
    return DeletionRecoveryResult(
      state,
      operationId: operation,
      manifestRef: manifest,
      proof: state == DeletionRecoveryState.confirmed && markerRevision != null
          ? RecoveredDeletionProof._(identity, operation, markerRevision)
          : null,
    );
  }
}
