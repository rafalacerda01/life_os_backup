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
  });

  final String userId;
  final AccountDeletionPhase phase;
  final String revision;
  final bool hasAuthoritativeConfirmation;

  @override
  bool operator ==(Object other) =>
      other is PendingAccountDeletion &&
      other.userId == userId &&
      other.phase == phase &&
      other.revision == revision &&
      other.hasAuthoritativeConfirmation == hasAuthoritativeConfirmation;
  @override
  int get hashCode =>
      Object.hash(userId, phase, revision, hasAuthoritativeConfirmation);
}

/// Independent from the non-destructive logout/isolation marker.
class AccountDeletionCleanupBarrier {
  AccountDeletionCleanupBarrier(this._storage);

  static const storageKey = 'life_os_account_deletion_cleanup_v1';
  static const storageVersion = 3;
  static Future<void> _tail = Future<void>.value();
  final AuthCleanupBarrierStorage _storage;

  Future<PendingAccountDeletion?> readForUser(String uid) =>
      _serialize(() async {
        final normalized = _normalizeUid(uid);
        return _forUser(await _read(), normalized);
      });

  Future<List<PendingAccountDeletion>> readAll() => _serialize(_read);

  Future<PendingAccountDeletion> request(String uid) => _serialize(() async {
    final normalized = _normalizeUid(uid);
    final markers = await _read();
    final current = _forUser(markers, normalized);
    if (current != null) {
      if (current.phase == AccountDeletionPhase.requested) return current;
      throw StateError('ACCOUNT_DELETION_ALREADY_PENDING');
    }
    final marker = _newMarker(normalized, AccountDeletionPhase.requested);
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

  PendingAccountDeletion _newMarker(String uid, AccountDeletionPhase phase) {
    final random = Random.secure();
    final revision = base64UrlEncode(
      List<int>.generate(16, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    return PendingAccountDeletion(
      userId: uid,
      phase: phase,
      revision: revision,
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
    return PendingAccountDeletion(
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
