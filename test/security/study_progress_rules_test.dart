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

  test(
    'review_queue preserves owner reads and denies all Client mutations',
    () {
      final block = RegExp(
        r'match /review_queue/\{reviewId\} \{([\s\S]*?)\n\}',
      ).firstMatch(rules)!.group(1)!;
      expect(block, contains('allow read: if isOwner(userId);'));
      for (final operation in ['create', 'update', 'delete']) {
        expect(block, contains('allow $operation: if false;'));
      }
      expect(block, isNot(contains('validReviewQueueCreate()')));
      expect(RegExp(r'\ballow\b').allMatches(block), hasLength(4));
    },
  );

  test(
    'study_info reads preserved but former reviewQueue create/update server-only',
    () {
      final block = RegExp(
        r'match /study_info/\{studyInfoId\} \{([\s\S]*?)\n      \}',
      ).firstMatch(rules)!.group(1)!;
      expect(block, contains('allow read: if isOwner(userId);'));
      for (final operation in ['create', 'update', 'delete']) {
        expect(block, contains('allow $operation: if false;'));
      }
      expect(block, isNot(contains('validStudyInfoCreate()')));
      expect(block, isNot(contains('validStudyInfoUpdate()')));
      expect(RegExp(r'\ballow\b').allMatches(block), hasLength(4));
      // Retained legacy validator definitions do not grant a write.
      expect(rules, contains('function validStudyInfoCreate()'));
      expect(rules, contains('function validStudyInfoUpdate()'));
      expect(
        rules,
        contains("request.resource.data.keys().hasOnly(['reviewQueue'])"),
      );
    },
  );

  test(
    'Subject cardsToReview immutable while original progress/streak validators stay',
    () {
      final block = RegExp(
        r'match /subjects/\{subjectId\} \{([\s\S]*?)\n      \}',
      ).firstMatch(rules)!.group(1)!;
      final compact = block.replaceAll(RegExp(r'\s+'), '');
      expect(
        compact,
        contains(
          "&&!request.resource.data.diff(resource.data).affectedKeys().hasAny(['cardsToReview'])&&isUpdatingOnly([",
        ),
      );
      expect(block, contains('canWriteUserData(userId)'));
      expect(block, contains('request.resource.data.progress is number'));
      expect(block, contains('request.resource.data.progress >= 0'));
      expect(block, contains('request.resource.data.progress <= 1'));
      expect(block, contains('request.resource.data.streakDays is int'));
      expect(block, contains('request.resource.data.streakDays >= 0'));
      expect(block, contains('allow read: if isOwner(userId);'));
      expect(block, contains('allow create, delete: if false;'));
    },
  );

  test('creation receipts and descendants have no specific Client grant', () {
    expect(rules, isNot(contains('match /study_card_create_receipts')));
    expect(
      RegExp(
        r'match /\{document=\*\*\} \{\s*allow read, write: if false;\s*\}',
      ).hasMatch(rules),
      isTrue,
    );
  });

  test('R5 remains presence-only for all three controls', () {
    expect(
      rules,
      contains(
        r'exists(/databases/$(database)/documents/retired_auth_identities/$(userId))',
      ),
    );
    expect(
      rules,
      contains(
        r'exists(/databases/$(database)/documents/account_deletion_guards/$(userId))',
      ),
    );
    expect(
      rules,
      contains(
        r'exists(/databases/$(database)/documents/account_deletion_guards/$(userId)/control/operation)',
      ),
    );
  });
}
