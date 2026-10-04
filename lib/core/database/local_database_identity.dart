import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Explicit storage identity, independent of authentication state.
final class LocalDatabaseIdentity {
  factory LocalDatabaseIdentity(String uid) {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty) {
      throw ArgumentError('LOCAL_DATABASE_UID_REQUIRED');
    }
    final digest = sha256.convert(utf8.encode(normalizedUid)).toString();
    return LocalDatabaseIdentity._(normalizedUid, 'u_$digest');
  }

  const LocalDatabaseIdentity._(this.uid, this.namespace);

  final String uid;
  final String namespace;

  String get fileName => 'life_os_$namespace.sqlite';
  String get keyAlias => 'db_encryption_key_v2_$namespace';

  File fileIn(Directory directory) => File(p.join(directory.path, fileName));

  @override
  bool operator ==(Object other) =>
      other is LocalDatabaseIdentity && other.uid == uid;

  @override
  int get hashCode => uid.hashCode;

  @override
  String toString() => 'LocalDatabaseIdentity';
}
