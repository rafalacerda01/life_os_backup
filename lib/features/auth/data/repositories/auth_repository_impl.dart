import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:life_os/core/services/water_v2_configuration.dart';
import 'package:life_os/core/services/water_v2_remote_data_source.dart';
import 'package:life_os/core/database/remote_send_permit.dart';
import 'package:multiple_result/multiple_result.dart';
import '../../../../core/errors/failure.dart';
import '../../domain/entities/user_entity.dart';
import '../../domain/repositories/auth_repository.dart';
import '../models/user_model.dart';
import '../remote/account_remote_data_source.dart';
import '../services/google_sign_in_initializer.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../../../../core/security/input_sanitizer.dart';

@visibleForTesting
Failure googleSignInPluginFailure(GoogleSignInException exception) {
  switch (exception.code) {
    case GoogleSignInExceptionCode.canceled:
      return const AuthFailure(
        'Entrada com Google cancelada.',
        code: 'GOOGLE_SIGN_IN_CANCELED',
      );
    case GoogleSignInExceptionCode.uiUnavailable:
      return const AuthFailure(
        'Não foi possível abrir o acesso com o Google. Tente novamente.',
        code: 'GOOGLE_SIGN_IN_UI_UNAVAILABLE',
      );
    default:
      return const AuthFailure(
        'Não foi possível entrar com o Google. Tente novamente.',
        code: 'GOOGLE_SIGN_IN_FAILED',
      );
  }
}

class AuthRepositoryImpl implements AuthRepository {
  static const _predefinedAvatars = {
    'avatar_male',
    'avatar_female',
    'avatar_cyber',
    'avatar_neural',
  };

  final fb.FirebaseAuth _firebaseAuth;
  final FirebaseFirestore _firestore;
  final AccountRemoteDataSource _accountRemoteDataSource;
  final Future<void> Function(fb.User)? _waterProfileProvisioner;

  AuthRepositoryImpl(
    this._firebaseAuth,
    this._firestore,
    this._accountRemoteDataSource, {
    // Public test seam keeps the production flag immutable.
    // ignore: prefer_initializing_formals
    Future<void> Function(fb.User)? waterProfileProvisioner,
    // ignore: prefer_initializing_formals
  }) : _waterProfileProvisioner = waterProfileProvisioner;

  String? _normalizePhotoReference(String value) {
    final normalized = value.trim();
    if (_predefinedAvatars.contains(normalized)) return normalized;

    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty) return null;
    final scheme = uri.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https' ? normalized : null;
  }

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
      if (error.isAmbiguous) {
        if (await _isAuthUserDeleted(user)) {
          // End only the captured session. Auth absence is not remote cleanup.
          await _signOutBestEffort(normalizedExpectedUid);
        }
        return const Error(AccountDeletionUnconfirmedFailure());
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
      await user.reload().timeout(const Duration(seconds: 20));
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
      await _firebaseAuth.signOut().timeout(const Duration(seconds: 20));
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
      if (e.code == 'user-not-found') return const Success(null);
      return Error(_passwordResetFailure(e.code));
    } catch (_) {
      return Error(ServerFailure.unexpected());
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
        return Error(_emailSignInFailure('unknown'));
      }

      return _getOrProvisionUser(credential.user!);
    } on fb.FirebaseAuthException catch (e) {
      return Error(_emailSignInFailure(e.code));
    } catch (_) {
      return Error(ServerFailure.unexpected());
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
        return Error(_emailSignUpFailure('unknown'));
      }

      final provisioned = await _getOrProvisionUser(
        credential.user!,
        fallbackEmail: InputSanitizer.sanitize(email),
        fallbackDisplayName: InputSanitizer.sanitize(name),
      );
      if ((WaterV2Configuration.enabled || _waterProfileProvisioner != null) &&
          provisioned.isSuccess()) {
        // The server creates the profile/admission. A normal profile update
        // preserves the entered name without changing the immutable birth proof.
        return updateProfile(
          InputSanitizer.sanitize(name),
          expectedUid: credential.user!.uid,
        );
      }
      return provisioned;
    } on fb.FirebaseAuthException catch (e) {
      return Error(_emailSignUpFailure(e.code));
    } catch (_) {
      return Error(ServerFailure.unexpected());
    }
  }

  @override
  Future<Result<UserEntity, Failure>> signInWithGoogle() async {
    try {
      final googleSignIn = GoogleSignIn.instance;

      await googleSignInInitialization;

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
        return Error(_googleSignInFailure('unknown'));
      }

      return _getOrProvisionUser(fbUser);
    } on GoogleSignInException catch (e) {
      return Error(googleSignInPluginFailure(e));
    } on fb.FirebaseAuthException catch (e) {
      return Error(_googleSignInFailure(e.code));
    } catch (_) {
      return Error(_googleSignInFailure('unknown'));
    }
  }

  @override
  Future<Result<UserEntity, Failure>> updateProfile(
    String newName, {
    required String expectedUid,
    String? newPhotoUrl,
  }) async {
    try {
      final normalizedExpectedUid = expectedUid.trim();
      final user = _firebaseAuth.currentUser;

      if (normalizedExpectedUid.isEmpty ||
          user == null ||
          user.uid != normalizedExpectedUid) {
        return const Error(
          AuthFailure(
            'Sua sessão não é válida. Entre novamente e tente de novo.',
            code: 'UNAUTHENTICATED',
          ),
        );
      }

      final cleanName = InputSanitizer.sanitize(newName);

      await user.updateDisplayName(cleanName);

      final Map<String, dynamic> updateData = {'displayName': cleanName};

      if (newPhotoUrl != null) {
        updateData['photoUrl'] = _normalizePhotoReference(newPhotoUrl);
      }

      await _firestore
          .collection('users')
          .doc(normalizedExpectedUid)
          .update(updateData);

      return _getUserFromFirestore(normalizedExpectedUid);
    } catch (_) {
      return Error(ServerFailure.unexpected());
    }
  }

  @override
  Future<Result<void, Failure>> signOut() async {
    try {
      await _firebaseAuth.signOut();

      return const Success(null);
    } catch (_) {
      return Error(ServerFailure.unexpected());
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
    } catch (_) {
      return Error(ServerFailure.unexpected());
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
    final serverProfile =
        WaterV2Configuration.enabled || _waterProfileProvisioner != null;
    final uid = firebaseUser.uid;
    StreamSubscription<fb.User?>? authSubscription;
    var sessionCurrent = true;
    var initialAuthEvent = true;
    bool sameSession() =>
        sessionCurrent && _firebaseAuth.currentUser?.uid == uid;
    void checkSession() {
      if (!sameSession()) throw StateError('Profile session changed');
    }

    try {
      final userRef = _firestore.collection('users').doc(uid);
      if (serverProfile) {
        checkSession();
        authSubscription = _firebaseAuth.authStateChanges().listen((current) {
          // The first event reports the current session. Any later sign-in
          // or sign-out invalidates this work, including reuse of the UID.
          if (!initialAuthEvent || current?.uid != uid) sessionCurrent = false;
          initialAuthEvent = false;
        }, onError: (Object _) => sessionCurrent = false);
        // An existing cached profile restores Auth offline; it grants no Water admission.
        final existing = await userRef.get().timeout(
          const Duration(seconds: 5),
        );
        checkSession();
        if (existing.exists)
          return Success(
            UserModel.fromFirestore(existing.data()!, existing.id),
          );
        if (_waterProfileProvisioner != null) {
          await _waterProfileProvisioner(firebaseUser);
        } else {
          final remote = WaterV2RemoteDataSource(
            _firebaseAuth,
            captureRemoteSend: (targetUid) =>
                RemoteSendPermit(() => targetUid == uid && sameSession()),
          );
          final result = await remote.bootstrap(
            firebaseUser.uid,
            DateTime.now().timeZoneOffset.inMinutes,
            RemoteSendPermit(sameSession),
          );
          checkSession();
          if (result.error?.code == 'ACCOUNT_DELETION_BLOCKED')
            return const Error(
              AuthFailure(
                'A conta está em exclusão.',
                code: 'ACCOUNT_DELETION_BLOCKED',
              ),
            );
          if (result.value?.state == 'NOT_ELIGIBLE')
            return const Error(
              AuthFailure(
                'A conta precisa de revisão antes de ser preparada.',
                code: 'WATER_NOT_ELIGIBLE',
              ),
            );
          if (result.value == null ||
              !{'READY', 'LEGACY'}.contains(result.value!.state)) {
            return _profileProvisionPending();
          }
        }
        checkSession();
        // READY does not make a separate Firestore read atomic with bootstrap.
        return await _readProvisionedProfile(userRef, checkSession);
      }
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
    } catch (error) {
      if (serverProfile && !sameSession()) {
        return const Error(
          AuthFailure(
            'A sessão mudou. Entre novamente para retomar o preparo do perfil.',
            code: 'UNAUTHENTICATED',
          ),
        );
      }
      if (serverProfile && error is TimeoutException) {
        return _profileProvisionPending();
      }
      if (error is FirebaseException &&
          error.plugin == 'cloud_firestore' &&
          (error.code == 'unavailable' || error.code == 'deadline-exceeded')) {
        if (serverProfile) return _profileProvisionPending();
        return Error(ServerFailure.connection());
      }
      return _profileProvisionFailure();
    } finally {
      sessionCurrent = false;
      authSubscription?.cancel().ignore();
    }
  }

  Future<Result<UserEntity, Failure>> _readProvisionedProfile(
    DocumentReference<Map<String, dynamic>> userRef,
    void Function() checkSession,
  ) async {
    const delays = [
      Duration.zero,
      Duration(milliseconds: 250),
      Duration(milliseconds: 750),
    ];
    for (final delay in delays) {
      checkSession();
      if (delay != Duration.zero) await Future<void>.delayed(delay);
      checkSession();
      try {
        final doc = await userRef
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 5));
        checkSession();
        if (doc.id != userRef.id) throw StateError('Profile identity mismatch');
        if (doc.exists)
          return Success(UserModel.fromFirestore(doc.data()!, doc.id));
      } on TimeoutException {
        checkSession();
      } on FirebaseException catch (error) {
        checkSession();
        if (error.plugin != 'cloud_firestore' ||
            !{'unavailable', 'deadline-exceeded'}.contains(error.code))
          rethrow;
      }
    }
    return _profileProvisionPending();
  }

  Result<UserEntity, Failure> _profileProvisionPending() => const Error(
    AuthFailure(
      'A conta foi autenticada. Seu perfil ainda está sendo preparado. '
      'Tente entrar novamente em instantes.',
      code: 'WATER_PROVISIONING_PENDING',
    ),
  );

  Result<UserEntity, Failure> _profileProvisionFailure() => const Error(
    ServerFailure(
      'Não foi possível preparar seu perfil. Tente novamente.',
      code: 'USER_PROFILE_PROVISION_FAILED',
    ),
  );

  Failure _emailSignInFailure(String code) {
    switch (code) {
      case 'invalid-credential':
      case 'wrong-password':
      case 'user-not-found':
        return AuthFailure.invalidCredentials();
      case 'invalid-email':
        return const AuthFailure(
          'Insira um e-mail válido.',
          code: 'INVALID_EMAIL',
        );
      case 'network-request-failed':
        return ServerFailure.connection();
      case 'too-many-requests':
        return const AuthFailure(
          'Muitas tentativas em pouco tempo. Aguarde e tente novamente.',
          code: 'TOO_MANY_REQUESTS',
        );
      default:
        return const AuthFailure(
          'Não foi possível entrar. Tente novamente.',
          code: 'AUTH_SIGN_IN_FAILED',
        );
    }
  }

  Failure _emailSignUpFailure(String code) {
    switch (code) {
      case 'email-already-in-use':
        return AuthFailure.emailAlreadyInUse();
      case 'weak-password':
        return const AuthFailure(
          'A senha informada é muito fraca.',
          code: 'WEAK_PASSWORD',
        );
      case 'invalid-email':
        return const AuthFailure(
          'Insira um e-mail válido.',
          code: 'INVALID_EMAIL',
        );
      case 'network-request-failed':
        return ServerFailure.connection();
      case 'too-many-requests':
        return const AuthFailure(
          'Muitas tentativas em pouco tempo. Aguarde e tente novamente.',
          code: 'TOO_MANY_REQUESTS',
        );
      default:
        return const AuthFailure(
          'Não foi possível criar a conta. Tente novamente.',
          code: 'AUTH_SIGN_UP_FAILED',
        );
    }
  }

  Failure _googleSignInFailure(String code) {
    switch (code) {
      case 'network-request-failed':
        return ServerFailure.connection();
      case 'too-many-requests':
        return const AuthFailure(
          'Muitas tentativas em pouco tempo. Aguarde e tente novamente.',
          code: 'TOO_MANY_REQUESTS',
        );
      case 'account-exists-with-different-credential':
        return const AuthFailure(
          'Já existe uma conta com este e-mail usando outro método de acesso.',
          code: 'ACCOUNT_EXISTS_WITH_DIFFERENT_CREDENTIAL',
        );
      default:
        return const AuthFailure(
          'Não foi possível entrar com o Google. Tente novamente.',
          code: 'GOOGLE_SIGN_IN_FAILED',
        );
    }
  }

  Failure _passwordResetFailure(String code) {
    switch (code) {
      case 'invalid-email':
        return const AuthFailure(
          'Insira um e-mail válido.',
          code: 'INVALID_EMAIL',
        );
      case 'network-request-failed':
        return ServerFailure.connection();
      case 'too-many-requests':
        return const AuthFailure(
          'Muitas tentativas em pouco tempo. Aguarde e tente novamente.',
          code: 'TOO_MANY_REQUESTS',
        );
      default:
        return const AuthFailure(
          'Não foi possível solicitar a recuperação de senha. Tente novamente.',
          code: 'PASSWORD_RESET_FAILED',
        );
    }
  }
}
