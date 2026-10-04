import 'dart:io';

import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/local_database_identity.dart';

void main() {
  test('identity trims UID and has stable value equality', () {
    final a = LocalDatabaseIdentity(' user-a ');
    expect(a.uid, 'user-a');
    expect(a, LocalDatabaseIdentity('user-a'));
    expect(a.hashCode, LocalDatabaseIdentity('user-a').hashCode);
    expect(a, isNot(LocalDatabaseIdentity('user-b')));
  });

  test('empty and whitespace UIDs are rejected', () {
    for (final uid in ['', '   ', '\n\t']) {
      expect(() => LocalDatabaseIdentity(uid), throwsArgumentError);
    }
  });

  test('namespace uses the full deterministic SHA256 digest', () {
    final identity = LocalDatabaseIdentity('user-a');
    expect(identity.namespace, 'u_${sha256.convert(utf8.encode('user-a'))}');
    expect(identity.namespace.length, 66);
  });

  test('namespaces are filename safe and distinct for adversarial UIDs', () {
    final identities = [
      'user-a',
      'user-b',
      '../user-a',
      'user/a',
      'user\\a',
      'USER-A',
      'usu\u00e1rio',
      'a' * 128,
      '${'a' * 127}b',
    ].map(LocalDatabaseIdentity.new).toList();
    expect(
      identities.map((identity) => identity.namespace).toSet().length,
      identities.length,
    );
    for (final identity in identities) {
      expect(identity.namespace, matches(RegExp(r'^u_[a-f0-9]{64}$')));
      expect(identity.fileName, isNot('life_os.sqlite'));
      expect(identity.toString(), isNot(contains(identity.uid)));
    }
  });

  test('explicit paths and secure storage aliases are scoped', () {
    final directory = Directory.systemTemp;
    final a = LocalDatabaseIdentity('user-a');
    final b = LocalDatabaseIdentity('user-b');
    expect(a.fileIn(directory).parent.path, directory.path);
    expect(a.fileIn(directory).path, isNot(b.fileIn(directory).path));
    expect(a.keyAlias, 'db_encryption_key_v2_${a.namespace}');
    expect(a.keyAlias, isNot(b.keyAlias));
    expect(a.keyAlias, isNot('db_encryption_key'));
  });
}
