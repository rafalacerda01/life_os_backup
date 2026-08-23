import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Estes testes são estruturais: verificam invariantes esperadas no texto de
// firestore.rules. Eles NÃO executam as regras no Firestore Emulator e não
// substituem testes de autorização contra o motor real de Firestore Rules.

void main() {
  late String rules;

  setUpAll(() async {
    rules = await File('firestore.rules').readAsString();
  });

  test('privacy rules contêm proteção de owner e bloqueio de delete', () {
    expect(rules, contains('allow create: if isOwner(userId)'));
    expect(rules, contains('allow update: if isOwner(userId)'));
    expect(rules, contains("privacyId == 'ai_consent'"));
    expect(rules, contains('allow delete: if false;'));
  });

  test('privacy schema declara allowlist completa de campos', () {
    expect(rules, contains('function validPrivacySchema(data, userId)'));
    expect(rules, contains('data.keys().hasOnly(['));

    for (final field in [
      'accepted',
      'userId',
      'consentVersion',
      'acceptedAt',
      'revokedAt',
      'updatedAt',
      'source',
    ]) {
      expect(rules, contains("'$field'"));
    }
  });

  test('privacy update preserva campos de identidade', () {
    expect(
      rules,
      contains('request.resource.data.userId == resource.data.userId'),
    );

    expect(
      rules,
      contains(
        'request.resource.data.consentVersion == '
        'resource.data.consentVersion',
      ),
    );

    expect(
      rules,
      contains('request.resource.data.source == resource.data.source'),
    );
  });

  test('privacy rules usam request.time nos timestamps sensíveis', () {
    expect(rules, contains('request.resource.data.acceptedAt == request.time'));

    expect(rules, contains('request.resource.data.revokedAt == request.time'));

    expect(rules, contains('request.resource.data.updatedAt == request.time'));
  });

  test('privacy rules declaram somente revoke e reaccept como transições', () {
    expect(
      rules,
      contains(
        'resource.data.accepted == true\n'
        '            && request.resource.data.accepted == false',
      ),
    );

    expect(
      rules,
      contains(
        'resource.data.accepted == false\n'
        '            && resource.data.revokedAt is timestamp\n'
        '            && request.resource.data.accepted == true',
      ),
    );

    expect(
      rules,
      contains('request.resource.data.acceptedAt == resource.data.acceptedAt'),
    );
  });
}
