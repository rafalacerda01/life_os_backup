import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:multiple_result/multiple_result.dart';
import '../../../../core/errors/failure.dart';
import '../../domain/entities/user_entity.dart';
import '../../domain/repositories/auth_repository.dart';
import '../models/user_model.dart';
import 'package:google_sign_in/google_sign_in.dart';
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

      final userDocSnap = await userDocRef.get();
      final activeCircleId = userDocSnap.data()?['activeCircleId'] as String?;

      final batch = _firestore.batch();

      final subcollections = ['finance', 'health_info', 'checkins'];

      for (final sub in subcollections) {
        final snapshot = await userDocRef.collection(sub).get();
        for (final doc in snapshot.docs) {
          batch.delete(doc.reference);
        }
      }

      if (activeCircleId != null && activeCircleId.isNotEmpty) {
        final circleRef = _firestore.collection('circles').doc(activeCircleId);
        final rankingRef = circleRef.collection('ranking').doc(uid);

        batch.delete(rankingRef);

        batch.update(circleRef, {
          'memberCount': FieldValue.increment(-1),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

      batch.delete(userDocRef);

      await batch.commit();

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
      final googleSignIn = GoogleSignIn.instance;

      await googleSignIn.initialize(
        serverClientId:
            '278760083864-nfp6h9r9gjaq4tvtcerif8h2d08c6afi.apps.googleusercontent.com',
      );

      // Executa a autenticação usando o fluxo moderno do Credential Manager
      final googleUser = await googleSignIn.authenticate();

      // Extração direta dos tokens
      final googleAuth = googleUser.authentication;

      // Credencial configurada com o idToken
      final credential = fb.GoogleAuthProvider.credential(
        idToken: googleAuth.idToken,
      );

      // Conexão ao Firebase Auth
      final userCredential = await _firebaseAuth.signInWithCredential(
        credential,
      );
      final fbUser = userCredential.user;

      if (fbUser == null) {
        return const Error(
          AuthFailure('Falha ao autenticar com Google no Firebase.'),
        );
      }

      // Validação ou criação de registro no Firestore
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
    } on fb.FirebaseAuthException catch (e) {
      return Error(
        AuthFailure(
          e.message ?? 'Erro na autenticação com Google',
          code: e.code,
        ),
      );
    } catch (e) {
      final errorStr = e.toString();

      // 🟢 Tratamento amigável para celular novo / sem conta Google logada
      if (errorStr.contains('No credentials available') ||
          errorStr.contains('sign_in_failed')) {
        return const Error(
          AuthFailure(
            'Nenhuma conta Google foi encontrada neste aparelho. Adicione uma conta nas configurações do seu celular para continuar.',
          ),
        );
      }

      return Error(ServerFailure('Erro inesperado ao entrar com o Google.'));
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

      final Map<String, dynamic> updateData = {'displayName': cleanName};

      if (newPhotoUrl != null) {
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
