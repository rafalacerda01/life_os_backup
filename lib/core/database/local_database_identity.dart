import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Storage address, never an autonomous proof of Auth ownership.
final class LocalDatabaseIdentity {
  factory LocalDatabaseIdentity(String uid, {String? generation}) {
    final normalized = _uid(uid);
    if (generation != null) _generation(generation);
    // Preserve legacy and R1 draft bytes; neither is silently promoted.
    return LocalDatabaseIdentity._(
      normalized,
      generation,
      null,
      null,
      null,
      _digest(
        generation == null ? normalized : jsonEncode([normalized, generation]),
      ),
    );
  }

  factory LocalDatabaseIdentity.bound({
    required String projectId,
    required String databaseId,
    String? tenantId,
    required String uid,
    required String generation,
  }) {
    _generation(generation);
    final normalized = _uid(uid);
    if (uid != normalized ||
        utf8.encode(uid).length > 128 ||
        uid.contains('/') ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(uid) ||
        uid == '.' ||
        uid == '..' ||
        RegExp(r'^__.*__$').hasMatch(uid)) {
      throw ArgumentError('LOCAL_DATABASE_BINDING_INVALID');
    }
    for (final value in [projectId, databaseId, tenantId].whereType<String>()) {
      if (value.isEmpty ||
          value.trim() != value ||
          value.length > 128 ||
          value.contains('/') ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
        throw ArgumentError('LOCAL_DATABASE_BINDING_INVALID');
      }
    }
    return LocalDatabaseIdentity._(
      normalized,
      generation,
      projectId,
      databaseId,
      tenantId,
      _digest(
        jsonEncode([
          2,
          projectId,
          databaseId,
          tenantId,
          normalized,
          generation,
        ]),
      ),
    );
  }
  const LocalDatabaseIdentity._(
    this.uid,
    this.generation,
    this.projectId,
    this.databaseId,
    this.tenantId,
    this.namespace,
  );
  final String uid;
  final String? generation, projectId, databaseId, tenantId;
  final String namespace;
  static bool isValidLocalInstallationId(String value) => RegExp(
    r'^local-v1-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  ).hasMatch(value);

  bool get isLocalInstallation =>
      generation == null &&
      projectId == null &&
      databaseId == null &&
      tenantId == null &&
      isValidLocalInstallationId(uid);

  bool get isBound =>
      generation != null && projectId != null && databaseId != null;
  bool get isLegacy => generation == null;
  String get fileName => 'life_os_$namespace.sqlite';
  String get keyAlias => 'db_encryption_key_v2_$namespace';
  File fileIn(Directory directory) => File(p.join(directory.path, fileName));

  Map<String, Object?> toBinding() {
    if (!isBound) throw StateError('LOCAL_GENERATION_BINDING_REQUIRED');
    return {
      'v': 2,
      'project': projectId,
      'database': databaseId,
      'tenant': tenantId,
      'uid': uid,
      'generation': generation,
    };
  }

  static LocalDatabaseIdentity fromBinding(Object? input) {
    if (input is! Map ||
        input.length != 6 ||
        !{
          'v',
          'project',
          'database',
          'tenant',
          'uid',
          'generation',
        }.every(input.containsKey) ||
        input['v'] is! int ||
        input['v'] != 2 ||
        input['project'] is! String ||
        input['database'] is! String ||
        !(input['tenant'] == null || input['tenant'] is String) ||
        input['uid'] is! String ||
        input['generation'] is! String) {
      throw const FormatException('LOCAL_GENERATION_BINDING_INVALID');
    }
    return LocalDatabaseIdentity.bound(
      projectId: input['project'] as String,
      databaseId: input['database'] as String,
      tenantId: input['tenant'] as String?,
      uid: input['uid'] as String,
      generation: input['generation'] as String,
    );
  }

  static String _uid(String uid) {
    final normalized = uid.trim();
    if (normalized.isEmpty) throw ArgumentError('LOCAL_DATABASE_UID_REQUIRED');
    return normalized;
  }

  static void _generation(String value) {
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    ).hasMatch(value)) {
      throw ArgumentError('LOCAL_DATABASE_GENERATION_INVALID');
    }
  }

  static String _digest(String value) =>
      'u_${sha256.convert(utf8.encode(value))}';
  @override
  bool operator ==(Object other) =>
      other is LocalDatabaseIdentity &&
      uid == other.uid &&
      generation == other.generation &&
      projectId == other.projectId &&
      databaseId == other.databaseId &&
      tenantId == other.tenantId;
  @override
  int get hashCode =>
      Object.hash(uid, generation, projectId, databaseId, tenantId);
  @override
  String toString() => 'LocalDatabaseIdentity';
}
