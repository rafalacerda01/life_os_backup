import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:multiple_result/multiple_result.dart';
import '../../../../core/errors/failure.dart';
import '../../domain/entities/user_entity.dart';
import '../../domain/repositories/auth_repository.dart';
import '../models/user_model.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../../../../core/security/input_sanitizer.dart';

class AuthRepositoryImpl implements AuthRepository {
  final fb.FirebaseAuth _firebaseAuth;
  final FirebaseFirestore _firestore;

  AuthRepositoryImpl(this._firebaseAuth, this._firestore);

  // ===========================================================================
  // EXCLUSÃO RECURSIVA DE UMA COLEÇÃO
  // ===========================================================================
  //
  // O Firestore NÃO exclui subcoleções quando um documento pai é excluído.
  //
  // Esta função:
  // 1. Busca todos os documentos da coleção.
  // 2. Exclui documentos em batches de no máximo 450 operações.
  // 3. Permite também excluir subcoleções conhecidas dentro dos documentos.
  //
  Future<void> _deleteCollection(
    CollectionReference<Map<String, dynamic>> collection, {
    List<String> nestedCollections = const [],
  }) async {
    while (true) {
      final snapshot = await collection.limit(450).get();

      if (snapshot.docs.isEmpty) {
        break;
      }

      final batch = _firestore.batch();

      for (final doc in snapshot.docs) {
        // Exclui subcoleções conhecidas antes do documento pai.
        for (final nestedName in nestedCollections) {
          await _deleteCollection(doc.reference.collection(nestedName));
        }

        batch.delete(doc.reference);
      }

      await batch.commit();

      // Se vieram menos de 450, não há mais documentos.
      if (snapshot.docs.length < 450) {
        break;
      }
    }
  }

  // ===========================================================================
  // EXCLUSÃO DE TODAS AS SUBCOLEÇÕES DO USUÁRIO
  // ===========================================================================
  Future<void> _deleteUserFirestoreData(String uid) async {
    final userDocRef = _firestore.collection('users').doc(uid);

    // -------------------------------------------------------------------------
    // Todas as subcoleções atualmente utilizadas pelo Life OS.
    //
    // IMPORTANTE:
    // O Firestore não exclui automaticamente essas coleções quando
    // users/{uid} é apagado.
    // -------------------------------------------------------------------------
    const userSubcollections = <String>[
      // Produtividade
      'tasks',
      'habits',
      'goals',

      // Estudos
      'study_info',
      'subjects',
      'review_queue',

      // Focus
      'focus_logs',

      // Financeiro
      'finance',
      'transactions',

      // Saúde
      'health_info',
      'medications',

      // Check-in
      'checkins',

      // Notificações
      'notifications',
      // Privacy
      'privacy',
    ];

    for (final collectionName in userSubcollections) {
      await _deleteCollection(
        userDocRef.collection(collectionName),
        // Algumas estruturas podem possuir documentos com dados
        // agrupados em subcoleções. Mantemos os nomes conhecidos para
        // evitar documentos órfãos.
        nestedCollections: const ['items', 'entries', 'logs', 'history'],
      );
    }

    // -------------------------------------------------------------------------
    // CIRCLES
    // -------------------------------------------------------------------------
    //
    // Se o usuário for o único membro e também o administrador,
    // o Circle pertence exclusivamente à conta e deve ser removido
    // juntamente com suas subcoleções.
    //
    // Se houver outros membros, NÃO apagamos o Circle.
    // Removemos somente os dados privados/ranking do usuário.
    //

    final userSnapshot = await userDocRef.get();
    final userData = userSnapshot.data();

    final activeCircleId = userData?['activeCircleId'] as String?;

    if (activeCircleId != null && activeCircleId.trim().isNotEmpty) {
      final circleId = activeCircleId.trim();

      final circleRef = _firestore.collection('circles').doc(circleId);
      final circleSnapshot = await circleRef.get();

      if (circleSnapshot.exists) {
        final circleData = circleSnapshot.data();

        final adminId = circleData?['adminId'] as String?;
        final memberCount = circleData?['memberCount'];

        final isAdmin = adminId == uid;
        final isLastMember = memberCount is num && memberCount <= 1;

        // ================================================================
        // CIRCLE EXCLUSIVO DO USUÁRIO
        // ================================================================
        //
        // No seu caso do print:
        // memberCount = 1
        // adminId = uid
        //
        // Portanto podemos apagar o Circle inteiro.
        //
        if (isAdmin && isLastMember) {
          // Remove desafios e quaisquer documentos dentro deles.
          await _deleteCollection(
            circleRef.collection('challenges'),
            nestedCollections: const ['items', 'entries', 'logs', 'history'],
          );

          // Remove ranking.
          await _deleteCollection(circleRef.collection('ranking'));

          // Remove outras estruturas conhecidas do Circle,
          // caso existam.
          await _deleteCollection(circleRef.collection('members'));

          await _deleteCollection(circleRef.collection('activities'));

          // Finalmente remove o documento principal do Circle.
          await circleRef.delete();
        } else {
          // ================================================================
          // CIRCLE COMPARTILHADO
          // ================================================================
          //
          // Nunca apagamos dados dos outros membros.
          //
          final rankingRef = circleRef.collection('ranking').doc(uid);

          try {
            await rankingRef.delete();
          } on FirebaseException {
            // Ranking é secundário.
            // Não interrompe a exclusão da conta.
          }
        }
      }
    }
    await userDocRef.delete();
  }

  @override
  Future<Result<void, Failure>> deleteAccount() async {
    try {
      final user = _firebaseAuth.currentUser;

      if (user == null) {
        return const Error(AuthFailure('Usuário não está autenticado'));
      }

      final uid = user.uid;

      // =======================================================================
      // FASE 1
      // Dados do Firestore
      // =======================================================================
      //
      // IMPORTANTE:
      // Não excluímos o Firebase Auth antes desta etapa.
      //
      // Se ocorrer erro de permissão ou comunicação com o Firestore,
      // o usuário do Auth continuará existindo e poderá tentar novamente.
      //
      await _deleteUserFirestoreData(uid);

      // =======================================================================
      // FASE 2
      // Firebase Authentication
      // =======================================================================
      //
      // A reautenticação já é realizada pelo AuthNotifier antes deste método.
      //
      await user.delete();

      return const Success(null);
    } on fb.FirebaseAuthException catch (e) {
      return Error(
        AuthFailure(e.message ?? 'Erro ao deletar conta', code: e.code),
      );
    } on FirebaseException catch (e) {
      return Error(
        AuthFailure(
          e.message ?? 'Erro ao excluir dados da conta',
          code: e.code,
        ),
      );
    } catch (e) {
      return Error(ServerFailure('Erro inesperado ao excluir conta: $e'));
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

      await _firestore.collection('users').doc(newUser.uid).set({
        ...newUser.toFirestore(),
        'habitsCount': 0,
        'tasksCount': 0,
        'goalsCount': 0,
        'subjectsCount': 0,
      });

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

        await _firestore.collection('users').doc(newUser.uid).set({
          ...newUser.toFirestore(),
          'habitsCount': 0,
          'tasksCount': 0,
          'goalsCount': 0,
          'subjectsCount': 0,
        });

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
