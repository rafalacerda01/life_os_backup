import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String rules;

  setUpAll(() {
    rules = File('firestore.rules').readAsStringSync();
  });

  test('study progress state é somente leitura do owner em main', () {
    expect(rules, contains("match /study_progress_state/{stateId}"));
    expect(
      rules,
      contains("allow read: if isOwner(userId) && stateId == 'main';"),
    );
    expect(rules, contains('allow create, update, delete: if false;'));
  });

  test('study progress events são integralmente server-owned', () {
    expect(rules, contains('match /study_progress_events/{eventId}'));
    expect(rules, contains('allow read, create, update, delete: if false;'));
    expect(rules, isNot(contains("request.resource.data.kind == 'review'")));
  });

  test('study streak ranges são integralmente server-owned', () {
    expect(
      RegExp(
        r'match /study_streak_ranges/\{rangeId\} \{\s*'
        r'allow read, create, update, delete: if false;\s*\}',
      ).hasMatch(rules),
      isTrue,
    );
  });

  test('review update é server-owned e create permanece validado', () {
    expect(rules, contains('validReviewQueueCreate()'));
    expect(rules, contains('allow update: if false;'));
  });

  test('study_info expõe somente reviewQueue para mutação client-side', () {
    expect(rules, contains("'updatedAt'"));
    expect(rules, contains('function validStudyInfoCreate()'));
    expect(
      rules,
      contains("request.resource.data.keys().hasOnly(['reviewQueue'])"),
    );
    expect(rules, contains('function validStudyInfoUpdate()'));
    expect(rules, contains(".hasOnly(['reviewQueue'])"));
  });
}
