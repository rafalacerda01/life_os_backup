// ignore_for_file: subtype_of_sealed_class, must_be_immutable
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/native.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/local_account_session.dart';
import 'package:life_os/core/database/session_database_coordinator.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/services/emulator_account_runtime.dart';
import 'package:life_os/core/services/trusted_account_access.dart';
import 'package:life_os/core/network/generational_http_transport.dart';
import 'package:life_os/core/network/generational_http_store.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';
import 'package:life_os/core/services/sync_queue_store.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:life_os/features/auth/data/remote/account_remote_data_source.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';
import 'functional_emulator_sdk_ports.dart';

class NoDeletion extends Fake implements AccountRemoteDataSource {}
class NetworkBinding extends AutomatedTestWidgetsFlutterBinding {
  @override bool get overrideHttpClient=>false;
}
void main(){
  NetworkBinding();
  test('genuine R1 email signup, durable restart, Tasks ACK/offline/logout and independent B',()async{
    final fixture=jsonDecode(await File(Platform.environment['P1_FUNCTIONAL_FIXTURE']!).readAsString()) as Map<String,dynamic>;
    final phase=Platform.environment['P1_FUNCTIONAL_PHASE']!,base=fixture['baseUrl'] as String,authHost=fixture['authHost'] as String,firestoreHost=fixture['firestoreHost'] as String;
    final client=LocalClient({Uri.parse(base).authority,authHost,firestoreHost});addTearDown(client.close);
    final auth=ProtocolAuth(client,authHost);
    // The runtime requires the exact clients; store uses the same Auth session.
    final firestore=ProtocolStore(auth,firestoreHost);
    final runtime=await EmulatorAccountRuntime.configure(auth:auth,store:firestore,authPort:int.parse(authHost.split(':')[1]),firestorePort:int.parse(firestoreHost.split(':')[1]),baseUri:Uri.parse(base),client:client,appCheckToken:()async=>'synthetic-app-check-port');
    final repo=AuthRepositoryImpl(auth,firestore,NoDeletion(),emulatorRuntime:runtime);
    final container=ProviderContainer();addTearDown(container.dispose);
    final session=container.read(localAccountSessionProvider.notifier);
    final coordinator=SessionDatabaseCoordinator(currentUserId:()=>auth.currentUser?.uid,openDatabase:(identity)async=>AppDatabase.forUser(identity:identity,executor:NativeDatabase(identity.fileIn(Directory(fixture['databaseDir'] as String)))));
    addTearDown(coordinator.dispose);addTearDown(auth.events.close);
    final trace=<String>[];
    void event(String value){trace.add(value);}
    // Every explicit sign-out is immediately observable by local mutation gates.
    final subscription=auth.events.stream.listen((user){session.clear();coordinator.observeSession(null);coordinator.observeSession(user?.uid);});addTearDown(subscription.cancel);
    late AppDatabase database;
    late TasksRepository tasks;
    late GenerationalHttpTransport transport;
    late SyncManager manager;
    Future<void> prepare()async{
      final identity=await TrustedAccountAccess.admittedIdentity(auth,firestore,auth.currentUser!.uid);
      database=await coordinator.prepare(identity.uid,accountIdentity:identity);
      session.bind(identity);
      tasks=TasksRepository(database,firestore,auth,sessionLease:session.capture());
      transport=GenerationalHttpTransport(store:GenerationalHttpStore(database),lease:session.capture(),auth:auth,client:client,appCheckToken:()async=>'synthetic-app-check-port',baseUri:Uri.parse(base));
      manager=SyncManager(queueStore:AppDatabaseSyncQueueStore(database),remoteDataSource:FirestoreSyncRemoteDataSource(firestore,auth,trustedTransport:transport,captureRemoteSend:(uid)=>database.localMutations.captureRemoteSend(expectedUid:uid)),currentUserId:()=>auth.currentUser?.uid);
      await Future<void>.delayed(Duration.zero);
    }
    Future<void> stop({bool logout=false})async{
      if(logout)expect(await manager.prepareForSessionDetach(auth.currentUser!.uid),true);
      manager.dispose();await transport.close();session.clear();await coordinator.detach(expectedUid:database.identity!.uid);
      if(logout)expect((await repo.signOut()).isSuccess(),true);
    }
    const email='functional-a@example.invalid',password='Synthetic-only-19!';
    final state=File(fixture['sessionFile'] as String);
    if(phase=='initial'){
      final signup=await repo.signUpWithEmailAndPassword(email,password,'Functional A');
      signup.when((u){expect(u.displayName,'Functional A');},(e)=>fail('Signup failed: ${e.code}'));
      event('signup-origin-R1-and-bootstrap-confirmed');
      await prepare();expect((await database.select(database.taskTable).get()).isEmpty,true);
      await tasks.addTask('Persisted Task','low');
      final local=(await database.select(database.taskTable).get()).single;
      expect((await database.getPendingSyncItems(auth.currentUser!.uid)).length,1);
      expect(await manager.processPendingItems(),true);
      expect((await database.getPendingSyncItems(auth.currentUser!.uid)),isEmpty);
      expect((await GenerationalHttpStore(database).pending()),isEmpty);
      event('task-created-and-correct-ACK-committed');
      final person=auth.person!;
      // Ephemeral emulator refresh token, not copied into report/evidence.
      await state.writeAsString(jsonEncode({'refreshToken':person.value['refreshToken'],'uid':person.uid,'taskId':local.id,'binding':database.identity!.toBinding()}));
      await stop();event('database-and-runtime-closed-before-process-exit');
    }else{
      final previous=jsonDecode(await state.readAsString()) as Map<String,dynamic>;
      final response=await client.post(Uri.parse('http://$authHost/securetoken.googleapis.com/v1/token?key=demo-key'),headers:{'Content-Type':'application/json'},body:jsonEncode({'grant_type':'refresh_token','refresh_token':previous['refreshToken']}));
      expect(response.statusCode,200);
      final restored=jsonDecode(response.body) as Map<String,dynamic>;
      auth.person=Person(auth,{'localId':restored['user_id'],'idToken':restored['id_token'],'refreshToken':restored['refresh_token'],'email':email});
      expect((await repo.getCurrentUser()).isSuccess(),true);
      event('new-process-refresh-and-server-profile-restored');
      await prepare();expect(database.identity,LocalDatabaseIdentity.fromBinding(previous['binding']));
      expect((await database.select(database.taskTable).get()).single.id,previous['taskId']);
      await tasks.syncTasksFromFirebaseToLocal();expect((await database.select(database.taskTable).get()).length,1);
      event('generation-bound-Drift-reopened-and-server-hydrated');
      final id=previous['taskId'] as String,uid=auth.currentUser!.uid;
      client.online=false;
      expect((await tasks.getTasksStream().first).single.title,'Persisted Task');
      await tasks.toggleTaskStatus(id,false);expect(await manager.processPendingItems(),false);
      expect((await database.getPendingSyncItems(uid)).length,1);
      event('offline-local-read-and-durable-intent-no-false-ACK');
      client.online=true;expect(await manager.processPendingItems(),true);
      expect((await database.getPendingSyncItems(uid)),isEmpty);
      event('reconnect-same-intent-ACK');
      client.online=false;await tasks.toggleTaskStatus(id,true);
      final pending=(await database.getPendingSyncItems(uid)).single as SyncQueueTableData,lease=session.capture();
      await stop(logout:true);expect(()=>lease.requireCurrent(),throwsStateError);
      client.online=true;
      event('logout-preserved-pending-and-invalidated-old-lease');
      final b=await repo.signUpWithEmailAndPassword('functional-b@example.invalid',password,'Functional B');expect(b.isSuccess(),true);
      await prepare();expect(database.identity!.uid,isNot(uid));expect(await database.select(database.taskTable).get(),isEmpty);
      await tasks.syncTasksFromFirebaseToLocal();expect(await database.select(database.taskTable).get(),isEmpty);
      await expectLater(firestore.fetch('users/$uid/tasks'),throwsA(anything));
      event('B-isolated-in-new-namespace-and-A-remote-read-denied');
      final uidB=auth.currentUser!.uid;
      await stop(logout:true);
      expect((await repo.signInWithEmailAndPassword(email,password)).isSuccess(),true);
      await prepare();expect(database.identity!.uid,uid);
      expect((await database.getPendingSyncItems(uid)).single.id,pending.id);
      expect(await manager.processPendingItems(),true);
      expect(await database.getPendingSyncItems(uid),isEmpty);
      event('A-relogin-preserves-original-queue-row-and-confirms-pending');
      expect(TrustedAccountAccess.localSessionClosed,true);
      (await repo.deleteAccount(expectedUid:uid)).when((_)=>fail('Deletion must stay closed'),(e)=>expect(e.code,'TRUSTED_LOCAL_SESSION_CLOSED'));
      (await repo.signInWithGoogle()).when((_)=>fail('Google must stay closed'),(e)=>expect(e.code,'TRUSTED_LOCAL_SESSION_CLOSED'));
      expect(()=>runtime.requireClients(ProtocolAuth(client,authHost),firestore),throwsStateError);
      await File('${fixture['resultDir']}/identities.json').writeAsString(jsonEncode({'A':uid,'B':uidB,'taskId':id}));
      await stop();event('global-private-Auth-Google-and-deletion-still-CLOSED');
    }
    await File('${fixture['resultDir']}/$phase-trace.json').writeAsString(jsonEncode({'phase':phase,'steps':trace,'nativeSdk':false,'cloudIam':false,'productionNotifierOpened':false,'realEmulatorProtocols':true}));
  },timeout:const Timeout(Duration(seconds:75)));
}
