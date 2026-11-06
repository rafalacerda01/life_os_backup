// A migration of four historical goal contracts to real Emulator R1/HTTP.
// No origin, claim, entitlement or successful receipt is minted by this helper.
// ignore_for_file: subtype_of_sealed_class
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:uuid/uuid.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/local_account_session.dart';
import 'package:life_os/core/database/session_database_coordinator.dart';
import 'package:life_os/core/network/generational_http_store.dart';
import 'package:life_os/core/network/generational_http_transport.dart';
import 'package:life_os/core/services/emulator_account_runtime.dart';
import 'package:life_os/core/services/trusted_account_access.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_queue_store.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';
import 'package:life_os/core/services/sync_operation_result.dart';
import 'package:life_os/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:life_os/features/auth/data/remote/account_remote_data_source.dart';
import 'package:life_os/features/goals/data/models/local/repositories/goal_repository.dart';
import '../../tools/trusted_account/functional_emulator_sdk_ports.dart';

class _NoDeletion extends Fake implements AccountRemoteDataSource {}
class _Client extends LocalClient {
  _Client(super.hosts);int syncRequests=0;
  @override Future<http.StreamedResponse> send(http.BaseRequest request){if(request.url.path=='/api/sync')syncRequests++;return super.send(request);}
}
class _ReadOnlyStore extends ProtocolStore {
  _ReadOnlyStore(super.auth,super.host);int sdkWrites=0;
  @override Future<http.Response> fetch(String path,{Map<String,Object?>? update}){
    // The already reviewed Auth name update still traverses real Rules. Goal
    // domain writes may only use HTTP; an unexpected SDK path must fail.
    if(update!=null && !(path=='users/${auth.currentUser?.uid}' && update.keys.every((k)=>const {'displayName','photoUrl'}.contains(k)))){sdkWrites++;throw StateError('UNREVIEWED_SDK_WRITE');}return super.fetch(path,update:update);
  }
}
class GenuineGoalScenario {
  late _Client _client;late ProtocolAuth auth;late _ReadOnlyStore _firestore;
  final container=ProviderContainer();
  late SessionDatabaseCoordinator coordinator;late AppDatabase db;
  late GenerationalHttpTransport transport;late FirestoreSyncRemoteDataSource source;late SyncManager manager;
  late String goalId;int get syncRequests=>_client.syncRequests;int get sdkWrites=>_firestore.sdkWrites;int? updateRowId;
  late String evidenceDirectory;
  static Future<GenuineGoalScenario> create()async{
    final fixturePath=Platform.environment['P1_FUNCTIONAL_FIXTURE'];
    if(fixturePath==null)throw StateError('GENUINE_R1_EMULATORS_REQUIRED: run the recorded multi-module server selection');
    final f=jsonDecode(File(fixturePath).readAsStringSync()) as Map<String,dynamic>,s=GenuineGoalScenario(),base=Uri.parse(f['baseUrl'] as String),authHost=f['authHost'] as String,storeHost=f['firestoreHost'] as String;
    s.evidenceDirectory=f['resultDir'] as String;s._client=_Client({authHost,storeHost,base.authority});s.auth=ProtocolAuth(s._client,authHost);s._firestore=_ReadOnlyStore(s.auth,storeHost);
    final runtime=await EmulatorAccountRuntime.configure(enabledModules:const {'goals'},auth:s.auth,store:s._firestore,authPort:int.parse(authHost.split(':')[1]),firestorePort:int.parse(storeHost.split(':')[1]),baseUri:base,client:s._client,appCheckToken:()async=>'synthetic-app-check-port');
    final repo=AuthRepositoryImpl(s.auth,s._firestore,_NoDeletion(),emulatorRuntime:runtime),created=await repo.signUpWithEmailAndPassword('history-${const Uuid().v4()}@example.invalid','Synthetic-only-19!','Historical goal');
    created.when((_) {},(failure)=>throw StateError('REAL_R1_SIGNUP_FAILED:${failure.code}'));
    final uid=s.auth.currentUser!.uid,identity=await TrustedAccountAccess.admittedIdentity(s.auth,s._firestore,uid,allowBootstrap:false);
    s.coordinator=SessionDatabaseCoordinator(currentUserId:()=>s.auth.currentUser?.uid,openDatabase:(id)async=>AppDatabase.forUser(identity:id,executor:NativeDatabase.memory()));
    s.db=await s.coordinator.prepare(uid,accountIdentity:identity);final session=s.container.read(localAccountSessionProvider.notifier);session.bind(identity);
    s.transport=GenerationalHttpTransport(store:GenerationalHttpStore(s.db),lease:session.capture(),auth:s.auth,client:s._client,appCheckToken:()async=>'synthetic-app-check-port',baseUri:base);
    s.source=FirestoreSyncRemoteDataSource(s._firestore,s.auth,trustedTransport:s.transport,captureRemoteSend:(uid)=>s.db.localMutations.captureRemoteSend(expectedUid:uid));
    s.manager=SyncManager(queueStore:AppDatabaseSyncQueueStore(s.db),remoteDataSource:s.source,currentUserId:()=>s.auth.currentUser?.uid);
    await Future<void>.delayed(Duration.zero);
    final goals=GoalRepository(s.db,s._firestore,s.auth,sessionLease:session.capture());await goals.createGoal('Historical goal','DIÁRIA',3);expect(await s.manager.processPendingItems(),true);
    s.goalId=(await s.db.select(s.db.goals).get()).single.id;return s;
  }
  Future<SyncOperationResult> update(Map<String,dynamic> payload)async{
    await db.insertSyncItem(ownerUid:auth.currentUser!.uid,collection:'goals',docId:goalId,operationType:'update',payloadJson:jsonEncode(payload));
    final row=(await db.getPendingSyncItems(auth.currentUser!.uid)).single;updateRowId=row.id;return source.process(auth.currentUser!.uid,row);
  }
  Future<Map<String,dynamic>> readGoal()async=>(await _firestore.collection('users').doc(auth.currentUser!.uid).collection('goals').doc(goalId).get(const GetOptions(source:Source.server))).data()!;
  Future<int> confirmedLocalIntentCount()async=>(await db.customSelect("SELECT COUNT(*) AS n FROM generational_http_intents_v1 WHERE phase='CONFIRMED'").get()).single.read<int>('n');
  void requireServerReceipts(int expected){File('$evidenceDirectory/historical-goal-${auth.currentUser!.uid}.json').writeAsStringSync(jsonEncode({'uid':auth.currentUser!.uid,'goalId':goalId,'expectedReceipts':expected}));}
  Future<void> requireOriginalAck()async{
    final row=(await (db.select(db.syncQueueTable)..where((t)=>t.id.equals(updateRowId!))).get()).single;expect(row.isSynced,true);expect(row.status,'succeeded');
    final intent=(await db.customSelect('SELECT sync_id,phase,ack_json FROM generational_http_intents_v1 WHERE sync_id = ?',variables:[Variable<int>(updateRowId!)]).get()).single;
    expect(intent.read<int>('sync_id'),updateRowId);expect(intent.read<String>('phase'),'CONFIRMED');expect(intent.read<String>('ack_json'),isNotEmpty);
  }
  Future<void> close()async{await transport.close();manager.dispose();container.dispose();await coordinator.dispose();await auth.events.close();_client.close();}
}
