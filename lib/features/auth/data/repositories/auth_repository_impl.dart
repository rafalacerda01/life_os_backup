import 'package:life_os/core/services/emulator_account_runtime.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'dart:async';
import 'auth_entry_failure.dart';
import 'package:life_os/core/services/trusted_account_access.dart';

import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:life_os/core/services/water_v2_configuration.dart';
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

  final EmulatorAccountRuntime? emulatorRuntime;
  final fb.FirebaseAuth _firebaseAuth;
  final FirebaseFirestore _firestore;
  final AccountRemoteDataSource _accountRemoteDataSource;
  final Future<void> Function(fb.User)? _waterProfileProvisioner;
  final Future<void> Function(LocalDatabaseIdentity)? _checkPendingDeletion;

  AuthRepositoryImpl(
    this._firebaseAuth,
    this._firestore,
    this._accountRemoteDataSource, {
    // Public test seam keeps the production flag immutable.
    // ignore: prefer_initializing_formals
    Future<void> Function(fb.User)? waterProfileProvisioner,
    this.emulatorRuntime,
    this._checkPendingDeletion,
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
    if (TrustedAccountAccess.localSessionClosed) {
      return const Error(AuthFailure(
        'Esta coorte aguarda a habilitação segura dos dados locais.',
        code: 'TRUSTED_LOCAL_SESSION_CLOSED',
      ));
    }

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
    if (TrustedAccountAccess.localSessionClosed && emulatorRuntime == null) {
      return const Error(AuthFailure(
        'Esta coorte aguarda a habilitação segura dos dados locais.',
        code: 'TRUSTED_LOCAL_SESSION_CLOSED',
      ));
    }

    try {
      emulatorRuntime?.requireClients(_firebaseAuth, _firestore);
      final credential = await _firebaseAuth.signInWithEmailAndPassword(
        email: InputSanitizer.sanitize(email),
        password: password,
      ).timeout(const Duration(seconds:20));

      if (credential.user == null) {
        return Error(_emailSignInFailure('unknown'));
      }

      return _getOrProvisionUser(credential.user!);
    } on fb.FirebaseAuthException catch (e) {
      return Error(_emailSignInFailure(e.code));
    } catch (error) {
      return Error(authEntryFailure(error));
    }
  }

  @override
  Future<Result<UserEntity, Failure>> signUpWithEmailAndPassword(
    String email,
    String password,
    String name,
  ) async {
    if (TrustedAccountAccess.localSessionClosed && emulatorRuntime == null) {
      return const Error(AuthFailure(
        'Esta coorte aguarda a habilitação segura dos dados locais.',
        code: 'TRUSTED_LOCAL_SESSION_CLOSED',
      ));
    }

    try {
      emulatorRuntime?.requireClients(_firebaseAuth, _firestore);
      final credential = await _firebaseAuth.createUserWithEmailAndPassword(
        email: InputSanitizer.sanitize(email),
        password: password,
      ).timeout(const Duration(seconds:20));

      if (credential.user == null) {
        return Error(_emailSignUpFailure('unknown'));
      }

      final provisioned = await _getOrProvisionUser(
        credential.user!,
        fallbackEmail: InputSanitizer.sanitize(email),
        fallbackDisplayName: InputSanitizer.sanitize(name),
      );
      if (provisioned.isSuccess()) {
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
    } catch (error) {
      return Error(authEntryFailure(error));
    }
  }

  @override
  Future<Result<UserEntity, Failure>> signInWithGoogle() async {
    if (TrustedAccountAccess.localSessionClosed) {
      return const Error(AuthFailure(
        'Esta coorte aguarda a habilitação segura dos dados locais.',
        code: 'TRUSTED_LOCAL_SESSION_CLOSED',
      ));
    }

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
    if (TrustedAccountAccess.localSessionClosed && emulatorRuntime == null) {
      return const Error(AuthFailure(
        'Esta coorte aguarda a habilitação segura dos dados locais.',
        code: 'TRUSTED_LOCAL_SESSION_CLOSED',
      ));
    }

    try {
      emulatorRuntime?.requireClients(_firebaseAuth, _firestore);
      final currentUser = _firebaseAuth.currentUser;

      if (currentUser == null) {
        return const Error(AuthFailure('Nenhum usuário logado.'));
      }

      return _getOrProvisionUser(currentUser);
    } catch (error) {
      return Error(authEntryFailure(error));
    }
  }

  Future<Result<UserEntity, Failure>> _getUserFromFirestore(String uid) async {
    final doc = await _firestore.collection('users').doc(uid).get(const GetOptions(source: Source.server));

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
      if (!sameSession()) throw StateError('AUTH_SESSION_UNCONFIRMED');
    }

    try {
authSubscription = _firebaseAuth.authStateChanges().listen((current) {
          // The first event reports the current session. Any later sign-in
          // or sign-out invalidates this work, including reuse of the UID.
          if (!initialAuthEvent || current?.uid != uid) sessionCurrent = false;
          initialAuthEvent = false;
        }, onError: (Object _) => sessionCurrent = false);
      checkSession();
      final userRef = _firestore.collection('users').doc(uid);
      final runtime = emulatorRuntime;
      runtime?.requireClients(_firebaseAuth, _firestore);
      final generation = runtime == null
          ? await TrustedAccountAccess.ensureReady(_firebaseAuth, _firestore, uid)
          : (await runtime.admit(uid, beforeBootstrap: _checkPendingDeletion))
                .generation!;
      checkSession();
      if (serverProfile) {
        checkSession();

        // An existing cached profile restores Auth offline; it grants no Water admission.
        final existing = await userRef.get(const GetOptions(source: Source.server)).timeout(
          const Duration(seconds: 5),
        );
        checkSession();
        if (existing.exists && !existing.metadata.isFromCache && !existing.metadata.hasPendingWrites &&
            existing.data()?['_lifeosGeneration'] == generation)
          return Success(
            UserModel.fromFirestore(existing.data()!, existing.id),
          );
        // No alternate domain can authorize or restore a missing profile.
        return _profileProvisionPending();
      }
      final doc = await userRef.get(const GetOptions(source: Source.server)).timeout(const Duration(seconds:15));
      checkSession();

      if (doc.exists && !doc.metadata.isFromCache && !doc.metadata.hasPendingWrites && doc.data()?['_lifeosGeneration'] == generation) {
        return Success(UserModel.fromFirestore(doc.data()!, doc.id));
      }

      return _profileProvisionPending();
    } catch (error) {
      if (error is AccountDeletionUnconfirmedFailure ||
          error is TrustedAccountPending ||
          error is StateError ||
          error is TimeoutException && !serverProfile) {
        return Error(authEntryFailure(error));
      }
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

  Result<UserEntity, Failure> _profileProvisionPending() => const Error(
    AuthFailure(
      'A conta foi autenticada. Seu perfil ainda está sendo preparado. '
      'Tente entrar novamente em instantes.',
      code: 'TRUSTED_ACCOUNT_PROVISIONING_PENDING',
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
