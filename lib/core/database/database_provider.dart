import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_database.dart';

/// Provider global do banco de dados local.
///
/// O AppDatabase mantém a persistência local do Life OS através do Drift.
///
/// O provider permanece vivo durante todo o ciclo de vida do container
/// Riverpod para evitar que o banco seja fechado enquanto streams,
/// repositories ou operações assíncronas ainda estiverem utilizando-o.
final databaseProvider = Provider<AppDatabase>((ref) {
  ref.keepAlive();

  final database = AppDatabase();

  ref.onDispose(() {
    database.close();
  });

  return database;
});
