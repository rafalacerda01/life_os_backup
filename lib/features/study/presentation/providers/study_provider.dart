import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/core/database/database_provider.dart';
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
  );
});

// --- PROVIDERS DE LEITURA (STREAMS) ---
final studyStreamProvider = StreamProvider<StudyModel>((ref) {
  return ref.watch(studyRepositoryProvider).getStudyStatsStream();
});

final subjectsStreamProvider =
    StreamProvider.autoDispose<List<StudySubjectEntity>>((ref) {
      return ref.watch(studyRepositoryProvider).getSubjectsStream();
    });

final flashcardStreamProvider = StreamProvider<List<FlashcardModel>>((ref) {
  return ref.watch(studyRepositoryProvider).getFlashcardsStream();
});
