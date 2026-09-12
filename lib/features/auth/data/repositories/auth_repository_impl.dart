import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:multiple_result/multiple_result.dart';
import '../../../../core/errors/failure.dart';
import '../../domain/entities/user_entity.dart';
import '../../domain/repositories/auth_repository.dart';
import '../models/user_model.dart';
import '../remote/account_remote_data_source.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../../../../core/security/input_sanitizer.dart';

class AuthRepositoryImpl implements AuthRepository {
  final fb.FirebaseAuth _firebaseAuth;
  final FirebaseFirestore _firestore;
  final AccountRemoteDataSource _accountRemoteDataSource;

  AuthRepositoryImpl(
    this._firebaseAuth,
    this._firestore,
    this._accountRemoteDataSource,
  );

  @override
  Future<Result<void, Failure>> deleteAccount({
    required String expectedUid,
  }) async {
    final normalizedExpectedUid = expectedUid.trim();
    final user = _firebaseAuth.currentUser;
    if (normalizedExpectedUid.isEmpty ||
        user == null ||
        user.uid != normalizedExpectedUid) {
      return const Error(
        AuthFailure('Usuário não está autenticado.', code: 'UNAUTHENTICATED'),
      );
    }

    try {
      await _accountRemoteDataSource.deleteAccount(
        expectedUid: normalizedExpectedUid,
      );
      await _signOutBestEffort(normalizedExpectedUid);
      return const Success(null);
    } on AccountRemoteException catch (error) {
      if (error.isAmbiguous && await _isAuthUserDeleted(user)) {
        await _signOutBestEffort(normalizedExpectedUid);
        return const Success(null);
      }
      return Error(AuthFailure(error.message, code: error.code));
    } catch (_) {
      return const Error(
        ServerFailure(
          'Não foi possível excluir a conta. Tente novamente.',
          code: 'ACCOUNT_DELETE_FAILED',
        ),
      );
    }
  }

  Future<bool> _isAuthUserDeleted(fb.User user) async {
    try {
      await user.reload();
      return false;
    } on fb.FirebaseAuthException catch (error) {
      return error.code == 'user-not-found';
    } catch (_) {
      return false;
    }
  }

  Future<void> _signOutBestEffort(String expectedUid) async {
    if (_firebaseAuth.currentUser?.uid != expectedUid) return;

    try {
      await _firebaseAuth.signOut();
    } catch (_) {
      // A exclusão confirmada no servidor não pode ser revertida localmente.
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

      return _getOrProvisionUser(credential.user!);
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

      return _getOrProvisionUser(
        credential.user!,
        fallbackEmail: InputSanitizer.sanitize(email),
        fallbackDisplayName: InputSanitizer.sanitize(name),
      );
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

      final googleUser = await googleSignIn.authenticate();

      final googleAuth = googleUser.authentication;

      final credential = fb.GoogleAuthProvider.credential(
        idToken: googleAuth.idToken,
      );

      final userCredential = await _firebaseAuth.signInWithCredential(
        credential,
      );

      final fbUser = userCredential.user;

      if (fbUser == null) {
        return const Error(
          AuthFailure('Falha ao autenticar com Google no Firebase.'),
        );
      }

      return _getOrProvisionUser(fbUser);
    } on fb.FirebaseAuthException catch (e) {
      return Error(
        AuthFailure(
          e.message ?? 'Erro na autenticação com Google',
          code: e.code,
        ),
      );
    } catch (e) {
      final errorStr = e.toString();

      if (errorStr.contains('No credentials available') ||
          errorStr.contains('sign_in_failed')) {
        return const Error(
          AuthFailure(
            'Nenhuma conta Google foi encontrada neste aparelho. '
            'Adicione uma conta nas configurações do seu celular '
            'para continuar.',
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

      if (user == null) {
        return const Error(AuthFailure('Usuário não logado'));
      }

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

      return _getOrProvisionUser(currentUser);
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

  Future<Result<UserEntity, Failure>> _getOrProvisionUser(
    fb.User firebaseUser, {
    String? fallbackDisplayName,
    String? fallbackEmail,
  }) async {
    try {
      final userRef = _firestore.collection('users').doc(firebaseUser.uid);
      final doc = await userRef.get();

      if (doc.exists) {
        return Success(UserModel.fromFirestore(doc.data()!, doc.id));
      }

      final newUser = UserModel(
        uid: firebaseUser.uid,
        email: InputSanitizer.sanitize(
          fallbackEmail ?? firebaseUser.email ?? '',
        ),
        displayName: InputSanitizer.sanitize(
          fallbackDisplayName ?? firebaseUser.displayName ?? 'Novo Usuário',
        ),
        photoUrl: firebaseUser.photoURL,
        isPremium: false,
        xp: 0,
        level: 1,
        streak: 0,
      );

      try {
        await userRef.set({
          ...newUser.toFirestore(),
          'habitsCount': 0,
          'tasksCount': 0,
          'goalsCount': 0,
          'subjectsCount': 0,
          'medicationsCount': 0,
          'transactionsCount': 0,
        });
      } catch (_) {
        try {
          final reconciledDoc = await userRef.get();
          if (reconciledDoc.exists) {
            return Success(
              UserModel.fromFirestore(reconciledDoc.data()!, reconciledDoc.id),
            );
          }
        } catch (_) {
          return _profileProvisionFailure();
        }
        return _profileProvisionFailure();
      }

      return Success(newUser);
    } catch (_) {
      return _profileProvisionFailure();
    }
  }

  Result<UserEntity, Failure> _profileProvisionFailure() => const Error(
    ServerFailure(
      'Não foi possível preparar seu perfil. Tente novamente.',
      code: 'USER_PROFILE_PROVISION_FAILED',
    ),
  );
}
