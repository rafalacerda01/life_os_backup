import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Estes testes são estruturais: verificam invariantes no texto de
// firestore.rules. Eles NÃO executam as regras no Firestore Emulator e não
// substituem testes de autorização contra o motor real de Firestore Rules.

void main() {
  late String goalsRules;

  setUpAll(() async {
    final rules = (await File(
      'firestore.rules',
    ).readAsString()).replaceAll('\r\n', '\n');
    goalsRules = RegExp(
      r'match /goals/\{goalId\} \{([\s\S]*?)\n      \}',
    ).firstMatch(rules)!.group(1)!;
  });

  test('goals mantém leitura e update restritos ao owner', () {
    expect(goalsRules, contains('allow read: if isOwner(userId);'));
    expect(goalsRules, contains('allow update: if isOwner(userId)'));
  });

  test('goals mantém create e delete bloqueados', () {
    expect(goalsRules, contains('allow create, delete: if false;'));
  });

  test('goals update permite somente currentValue e lastReset', () {
    expect(
      goalsRules,
      contains(
        "isUpdatingOnly([\n"
        "            'currentValue',\n"
        "            'lastReset'\n"
        '          ])',
      ),
    );
  });

  test('goals exige lastReset canônico como timestamp', () {
    expect(
      goalsRules,
      contains('request.resource.data.lastReset is timestamp'),
    );
    expect(goalsRules, isNot(contains('lastReset is string')));
  });
}
