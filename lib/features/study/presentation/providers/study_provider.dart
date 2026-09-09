import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/features/study/data/models/study_model.dart';
import 'package:life_os/features/study/data/models/flashcard_model.dart';
import 'package:life_os/features/study/domain/entities/study_subject_entity.dart';

import 'package:life_os/features/study/data/study_repository.dart';

// --- INJEÇÃO DO REPOSITÓRIO ---
final studyRepositoryProvider = Provider((ref) {
  return StudyRepository(
    ref.watch(databaseProvider),
    FirebaseFirestore.instance,
    FirebaseAuth.instance,
    ref.watch(syncManagerProvider),
  );
});

// --- PROVIDERS DE LEITURA (STREAMS) ---
final _studyDayProvider = Provider.autoDispose<DateTime>((ref) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final nextDay = DateTime(now.year, now.month, now.day + 1);
  final timer = Timer(
    nextDay.add(const Duration(milliseconds: 50)).difference(now),
    ref.invalidateSelf,
  );
  ref.onDispose(timer.cancel);
  return today;
});

final studyStreamProvider = StreamProvider<StudyModel>((ref) {
  ref.watch(_studyDayProvider);
  return ref.watch(studyRepositoryProvider).getStudyStatsStream();
});

final subjectsStreamProvider =
    StreamProvider.autoDispose<List<StudySubjectEntity>>((ref) {
      ref.watch(_studyDayProvider);
      return ref.watch(studyRepositoryProvider).getSubjectsStream();
    });

final flashcardStreamProvider = StreamProvider<List<FlashcardModel>>((ref) {
  ref.watch(_studyDayProvider);
  return ref.watch(studyRepositoryProvider).getFlashcardsStream();
});
