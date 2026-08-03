import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:multiple_result/multiple_result.dart';
import '../../../../core/errors/failure.dart';
import '../../domain/entities/user_entity.dart';
import '../../domain/repositories/auth_repository.dart';
import '../models/user_model.dart';

// Importação de Segurança
import '../../../../core/security/input_sanitizer.dart';

class AuthRepositoryImpl implements AuthRepository {
  final fb.FirebaseAuth _firebaseAuth;
  final FirebaseFirestore _firestore;

  AuthRepositoryImpl(this._firebaseAuth, this._firestore);

  @override
  Future<Result<void, Failure>> deleteAccount() async {
    try {
      final user = _firebaseAuth.currentUser;
      if (user == null) {
        return const Error(AuthFailure("Usuário não está autenticado"));
      }

      final uid = user.uid;
      final userDocRef = _firestore.collection('users').doc(uid);

      // 🚀 CÓDIGO INSERIDO: Lê o documento do usuário antes de deletar
      // para verificar se ele está participando de algum Círculo.
      final userDocSnap = await userDocRef.get();
      final activeCircleId = userDocSnap.data()?['activeCircleId'] as String?;

      final batch = _firestore.batch();

      // 1. 🚀 CÓDIGO ALTERADO: Identificamos todas as subcoleções (Adicionado 'checkins')
      final subcollections = ['finance', 'health_info', 'checkins'];

      // 2. Adicionamos todos os documentos dessas subcoleções ao batch de deleção
      for (final sub in subcollections) {
        final snapshot = await userDocRef.collection(sub).get();
        for (final doc in snapshot.docs) {
          batch.delete(doc.reference);
        }
      }

      // 3. 🚀 CÓDIGO INSERIDO: Se o usuário estiver num círculo, removemos ele do ranking
      if (activeCircleId != null && activeCircleId.isNotEmpty) {
        final circleRef = _firestore.collection('circles').doc(activeCircleId);
        final rankingRef = circleRef.collection('ranking').doc(uid);

        batch.delete(rankingRef);

        // Remove 1 membro do contador do círculo para liberar vaga
        batch.update(circleRef, {
          'memberCount': FieldValue.increment(-1),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

      // 4. Adicionamos o documento principal do usuário ao batch
      batch.delete(userDocRef);

      // 5. Executamos todas as deleções de uma vez no Firestore de forma atômica
      await batch.commit();

      // 6. Por fim, deletamos o usuário da Autenticação do Firebase
      await user.delete();

      return const Success(null);
    } on fb.FirebaseAuthException catch (e) {
      return Error(
        AuthFailure(e.message ?? "Erro ao deletar conta", code: e.code),
      );
    } catch (e) {
      return Error(ServerFailure("Erro inesperado: $e"));
    }
  }

  @override
  Future<Result<void, Failure>> sendPasswordResetEmail(String email) async {
    try {
      await _firebaseAuth.sendPasswordResetEmail(
        email: InputSanitizer.sanitize(email),
      );
      return const Success(null);
    } on fb.FirebaseAuthException catch (e) {
      return Error(
        AuthFailure(e.message ?? 'Erro ao enviar e-mail', code: e.code),
      );
    } catch (e) {
      return Error(ServerFailure(e.toString()));
    }
  }

  @override
  Future<Result<UserEntity, Failure>> signInWithEmailAndPassword(
    String email,
    String password,
  ) async {
    try {
      final credential = await _firebaseAuth.signInWithEmailAndPassword(
        email: InputSanitizer.sanitize(email),
        password: password,
      );
      if (credential.user == null) {
        return const Error(
          AuthFailure('Usuário nulo retornado pelo Firebase.'),
        );
      }
      return _getUserFromFirestore(credential.user!.uid);
    } on fb.FirebaseAuthException catch (e) {
      return Error(
        AuthFailure(e.message ?? 'Erro de Autenticação', code: e.code),
      );
    } catch (e) {
      return Error(ServerFailure(e.toString()));
    }
  }

  @override
  Future<Result<UserEntity, Failure>> signUpWithEmailAndPassword(
    String email,
    String password,
    String name,
  ) async {
    try {
      final credential = await _firebaseAuth.createUserWithEmailAndPassword(
        email: InputSanitizer.sanitize(email),
        password: password,
      );
      if (credential.user == null) {
        return const Error(
          AuthFailure('Falha ao instanciar usuário de destino.'),
        );
      }

      final newUser = UserModel(
        uid: credential.user!.uid,
        email: InputSanitizer.sanitize(email),
        displayName: InputSanitizer.sanitize(name),
        isPremium: false,
        xp: 0,
        level: 1,
        streak: 0,
      );

      await _firestore
          .collection('users')
          .doc(newUser.uid)
          .set(newUser.toFirestore());
      return Success(newUser);
    } on fb.FirebaseAuthException catch (e) {
      return Error(
        AuthFailure(e.message ?? 'Erro ao criar conta', code: e.code),
      );
    } catch (e) {
      return Error(ServerFailure(e.toString()));
    }
  }

  @override
  Future<Result<UserEntity, Failure>> signInWithGoogle() async {
    try {
      final googleProvider = fb.GoogleAuthProvider();
      final userCredential = await _firebaseAuth.signInWithPopup(
        googleProvider,
      );
      final fbUser = userCredential.user;

      if (fbUser == null) {
        return const Error(AuthFailure('Falha ao autenticar com Google.'));
      }

      final doc = await _firestore.collection('users').doc(fbUser.uid).get();
      if (!doc.exists) {
        final newUser = UserModel(
          uid: fbUser.uid,
          email: InputSanitizer.sanitize(fbUser.email ?? ''),
          displayName: InputSanitizer.sanitize(
            fbUser.displayName ?? 'Novo Usuário',
          ),
          photoUrl: fbUser.photoURL,
          isPremium: false,
          xp: 0,
          level: 1,
          streak: 0,
        );
        await _firestore
            .collection('users')
            .doc(fbUser.uid)
            .set(newUser.toFirestore());
        return Success(newUser);
      }
      return _getUserFromFirestore(fbUser.uid);
    } catch (e) {
      return Error(ServerFailure(e.toString()));
    }
  }

  @override
  Future<Result<UserEntity, Failure>> updateProfile(
    String newName, {
    String? newPhotoUrl,
  }) async {
    try {
      final user = _firebaseAuth.currentUser;
      if (user == null) return const Error(AuthFailure('Usuário não logado'));

      final cleanName = InputSanitizer.sanitize(newName);
      await user.updateDisplayName(cleanName);

      // Prepara o payload de atualização para o Firestore
      final Map<String, dynamic> updateData = {'displayName': cleanName};

      if (newPhotoUrl != null) {
        // Se for um link http ou chave local, sanitizamos se necessário ou armazenamos direto
        updateData['photoUrl'] = newPhotoUrl;
      }

      await _firestore.collection('users').doc(user.uid).update(updateData);

      return _getUserFromFirestore(user.uid);
    } catch (e) {
      return Error(ServerFailure(e.toString()));
    }
  }

  @override
  Future<Result<void, Failure>> signOut() async {
    try {
      await _firebaseAuth.signOut();
      return const Success(null);
    } catch (e) {
      return Error(ServerFailure(e.toString()));
    }
  }

  @override
  Future<Result<UserEntity, Failure>> getCurrentUser() async {
    try {
      final currentUser = _firebaseAuth.currentUser;
      if (currentUser == null) {
        return const Error(AuthFailure('Nenhum usuário logado.'));
      }
      return _getUserFromFirestore(currentUser.uid);
    } catch (e) {
      return Error(ServerFailure(e.toString()));
    }
  }

  Future<Result<UserEntity, Failure>> _getUserFromFirestore(String uid) async {
    final doc = await _firestore.collection('users').doc(uid).get();
    if (!doc.exists) {
      return const Error(
        SecurityFailure(
          'Registro do usuário violado ou não encontrado no banco de dados.',
        ),
      );
    }
    return Success(UserModel.fromFirestore(doc.data()!, doc.id));
  }
}
