import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';

final syncServiceProviderProvider = Provider<SyncService>((ref) {
  return SyncService(ref);
});

class SyncService {
  final Ref _ref;
  final String _baseUrl = "https://life-os-backend-gray.vercel.app";

  SyncService(this._ref);

  Future<void> synchronizeData() async {
    final authState = _ref.read(authNotifierProvider);

    String? token;

    authState.maybeWhen(
      authenticated: (user) {
        token = user.token;
      },
      orElse: () {},
    );

    if (token == null || token!.isEmpty) {
      final firebaseUser = FirebaseAuth.instance.currentUser;
      token = await firebaseUser?.getIdToken();
    }

    if (token == null || token!.isEmpty) {
      throw Exception("Usuário não autenticado para sincronização.");
    }

    final Map<String, dynamic> localPayload = {
      "timestamp": DateTime.now().toIso8601String(),
      "tasks": [],
      "habits": [],
      "finances": [],
    };

    final response = await http.post(
      Uri.parse("$_baseUrl/api/sync"),
      headers: {
        "Content-Type": "application/json",
        "Authorization": "Bearer $token",
      },
      body: jsonEncode(localPayload),
    );

    if (response.statusCode == 200) {
      final responseData = jsonDecode(response.body);
      await _mergeServerDataLocally(responseData);
    } else {
      throw Exception("Falha na sincronização: ${response.body}");
    }
  }

  Future<void> _mergeServerDataLocally(Map<String, dynamic> serverData) async {
    // Ponto de integração com o banco local (Drift/SQLite) se necessário
  }
}
