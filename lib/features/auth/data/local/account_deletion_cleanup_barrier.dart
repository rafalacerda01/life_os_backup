import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/errors/failure.dart';
import 'dart:convert';
import 'dart:math';

import 'auth_cleanup_barrier.dart';

enum AccountDeletionPhase { requested, remoteConfirmed }

class PendingAccountDeletion {
  const PendingAccountDeletion({
    required this.userId,
    required this.phase,
    required this.revision,
    this.hasAuthoritativeConfirmation = false,
    this.identity,
  });

  final LocalDatabaseIdentity? identity;
  final String userId;
  final AccountDeletionPhase phase;
  final String revision;
  final bool hasAuthoritativeConfirmation;

  @override
  bool operator ==(Object other) =>
      other is PendingAccountDeletion &&
      other.identity == identity &&
      other.userId == userId &&
      other.phase == phase &&
      other.revision == revision &&
      other.hasAuthoritativeConfirmation == hasAuthoritativeConfirmation;
  @override
  int get hashCode => Object.hash(
    identity,
    userId,
    phase,
    revision,
    hasAuthoritativeConfirmation,
  );
}

/// Independent from the non-destructive logout/isolation marker.
class AccountDeletionCleanupBarrier {
  AccountDeletionCleanupBarrier(
    AuthCleanupBarrierStorage storage, {
    LocalDatabaseIdentity? identity,
    Future<Set<String>> Function()? listKeys,
  }) : _identity = identity,
       _storage = identity == null
           ? storage
           : IdentityAuthCleanupStorage(
               storage,
               identity,
               domain: 'account_cleanup',
               listKeys: listKeys,
             );

  static const storageKey = 'life_os_account_deletion_cleanup_v1';
  static const storageVersion = 3;
  static Future<void> _tail = Future<void>.value();
  final LocalDatabaseIdentity? _identity;
  final AuthCleanupBarrierStorage _storage;

  Future<PendingAccountDeletion?> readForUser(String uid) =>
      _serialize(() async {
        final normalized = _normalizeUid(uid);
        if (_identity != null && _identity.uid != normalized)
          throw StateError("LOCAL_OWNER_MISMATCH");
        return _forUser(await _read(), normalized);
      });

  Future<List<PendingAccountDeletion>> readAll() => _serialize(_read);

  Future<PendingAccountDeletion> request(
    String uid, {
    bool reusePending = true,
    String? reservedRevision,
  }) => _serialize(() async {
    final normalized = _normalizeUid(uid);
    if (reservedRevision != null &&
        (_identity?.isBound != true ||
            _identity?.uid != normalized ||
            reusePending ||
            !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(reservedRevision))) {
      throw ArgumentError('ACCOUNT_DELETION_RESERVATION_INVALID');
    }
    final markers = await _read();
    final current = _forUser(markers, normalized);
    if (current != null) {
      if (current.phase == AccountDeletionPhase.requested) {
        if (reusePending) return current;
        throw const AccountDeletionUnconfirmedFailure();
      }
      throw StateError('ACCOUNT_DELETION_ALREADY_PENDING');
    }
    final marker = _newMarker(
      normalized,
      AccountDeletionPhase.requested,
      revision: reservedRevision,
    );
    await _write([...markers, marker]);
    return marker;
  });

  Future<PendingAccountDeletion> confirmIfCurrent(
    PendingAccountDeletion expected,
  ) => _serialize(() async {
    final markers = await _read();
    if (expected.phase != AccountDeletionPhase.requested ||
        _forUser(markers, expected.userId) != expected) {
      throw StateError('ACCOUNT_DELETION_MARKER_CHANGED');
    }
    final confirmed = _newMarker(
      expected.userId,
      AccountDeletionPhase.remoteConfirmed,
    );
    await _write([
      for (final marker in markers)
        if (marker == expected) confirmed else marker,
    ]);
    return confirmed;
  });

  Future<bool> clearIfCurrent(PendingAccountDeletion expected) => _serialize(
    () async {
      final markers = await _read();
      if (_forUser(markers, expected.userId) != expected) return false;
      final remaining = markers.where((marker) => marker != expected).toList();
      if (remaining.isEmpty) {
        await _storage.delete(storageKey);
        if (await _storage.read(storageKey) != null)
          throw StateError('ACCOUNT_DELETION_MARKER_NOT_CLEARED');
      } else {
        await _write(remaining);
      }
      return true;
    },
  );

  PendingAccountDeletion _newMarker(
    String uid,
    AccountDeletionPhase phase, {
    String? revision,
  }) {
    final random = Random.secure();
    final markerRevision =
        revision ??
        base64UrlEncode(
          List<int>.generate(16, (_) => random.nextInt(256)),
        ).replaceAll('=', '');
    return PendingAccountDeletion(
      identity: _identity,
      userId: uid,
      phase: phase,
      revision: markerRevision,
      hasAuthoritativeConfirmation:
          phase == AccountDeletionPhase.remoteConfirmed,
    );
  }

  Future<void> _write(List<PendingAccountDeletion> markers) async {
    final ordered = [...markers]..sort((a, b) => a.userId.compareTo(b.userId));
    await _storage.write(
      storageKey,
      jsonEncode({
        'v': storageVersion,
        'markers': [
          for (final marker in ordered)
            {
              'uid': marker.userId,
              'phase': marker.phase.name,
              'revision': marker.revision,
              'confirmedBy': marker.hasAuthoritativeConfirmation
                  ? 'accountDeleteResponse'
                  : null,
            },
        ],
      }),
    );
    final persisted = await _read();
    if (persisted.length != ordered.length)
      throw StateError('ACCOUNT_DELETION_MARKER_NOT_PERSISTED');
    for (var i = 0; i < ordered.length; i++) {
      if (persisted[i] != ordered[i])
        throw StateError('ACCOUNT_DELETION_MARKER_NOT_PERSISTED');
    }
  }

  Future<List<PendingAccountDeletion>> _read() async {
    final raw = await _storage.read(storageKey);
    if (raw == null) return const [];
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic> || value['v'] is! int) {
      throw const FormatException('ACCOUNT_DELETION_MARKER_INVALID');
    }
    // Keep the existing key so a valid single-marker v1 cannot be orphaned.
    if (value['v'] == 1 && value.length == 4) {
      return List.unmodifiable([
        _parseMarker({
          'uid': value['uid'],
          'phase': value['phase'],
          'revision': value['revision'],
        }),
      ]);
    }
    if (![2, storageVersion].contains(value['v']) ||
        value.length != 2 ||
        value['markers'] is! List) {
      throw const FormatException('ACCOUNT_DELETION_MARKER_INVALID');
    }
    final markers = <PendingAccountDeletion>[];
    final owners = <String>{};
    for (final entry in value['markers'] as List) {
      final marker = _parseMarker(
        entry,
        currentVersion: value['v'] == storageVersion,
      );
      if (!owners.add(marker.userId)) {
        throw const FormatException('ACCOUNT_DELETION_MARKER_INVALID');
      }
      markers.add(marker);
    }
    markers.sort((a, b) => a.userId.compareTo(b.userId));
    return List.unmodifiable(markers);
  }

  PendingAccountDeletion _parseMarker(
    Object? value, {
    bool currentVersion = false,
  }) {
    if (value is! Map<String, dynamic> ||
        value.length != (currentVersion ? 4 : 3) ||
        (currentVersion &&
            (!value.containsKey('confirmedBy') ||
                ![
                  null,
                  'accountDeleteResponse',
                ].contains(value['confirmedBy']) ||
                (value['phase'] == 'requested' &&
                    value['confirmedBy'] != null))) ||
        value['uid'] is! String ||
        (value['uid'] as String).trim().isEmpty ||
        value['uid'] != (value['uid'] as String).trim() ||
        value['revision'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(value['revision'] as String) ||
        !AccountDeletionPhase.values.any(
          (phase) => phase.name == value['phase'],
        )) {
      throw const FormatException('ACCOUNT_DELETION_MARKER_INVALID');
    }
    if (_identity != null && value['uid'] != _identity.uid)
      throw const FormatException('LOCAL_OWNER_MISMATCH');
    return PendingAccountDeletion(
      identity: _identity,
      userId: value['uid'] as String,
      phase: AccountDeletionPhase.values.firstWhere(
        (phase) => phase.name == value['phase'],
      ),
      revision: value['revision'] as String,
      // v1/v2 could have been confirmed by Auth absence; never upgrade trust.
      hasAuthoritativeConfirmation:
          currentVersion &&
          value['phase'] == 'remoteConfirmed' &&
          value['confirmedBy'] == 'accountDeleteResponse',
    );
  }

  String _normalizeUid(String uid) {
    final normalized = uid.trim();
    if (normalized.isEmpty)
      throw ArgumentError('ACCOUNT_DELETION_UID_REQUIRED');
    return normalized;
  }

  PendingAccountDeletion? _forUser(
    List<PendingAccountDeletion> markers,
    String uid,
  ) {
    for (final marker in markers) {
      if (marker.userId == uid) return marker;
    }
    return null;
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
