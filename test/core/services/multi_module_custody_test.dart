// Negative local fixtures confer no R1, token, server origin or receipt.
// ignore_for_file: subtype_of_sealed_class
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:drift/native.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_account_session.dart';
import 'package:life_os/core/services/generational_read_policy.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_queue_store.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';
import 'package:life_os/core/services/sync_operation_result.dart';
import 'package:life_os/features/habits/data/repositories/habits_repository.dart';
import 'package:life_os/features/finance/data/repositories/finance_repository.dart';
import 'package:life_os/features/goals/data/models/local/repositories/goal_repository.dart';
import 'package:life_os/features/study/data/study_repository.dart';
import 'package:life_os/features/health/data/repositories/health_repository.dart';
import 'package:life_os/features/checkin/data/repositories/checkin_repository.dart';
import 'package:life_os/features/focus/data/repositories/focus_repository.dart';
import 'package:life_os/features/notifications/data/repositories/notifications_repository.dart';

class RefusalUser extends Fake implements User {@override String get uid=>'A';}
class RefusalAuth extends Fake implements FirebaseAuth {@override User get currentUser=>RefusalUser();}
class RefusalStore extends Fake implements FirebaseFirestore {
  var calls=0;
  @override CollectionReference<Map<String,dynamic>> collection(String path){calls++;throw StateError('SDK_MUST_NOT_START');}
}
class NoRemote implements SyncRemoteDataSource {
  @override Future<SyncOperationResult> process(String uid,SyncQueueTableData item)=>throw StateError('NO_REMOTE_AUTHORITY');
}
const generation='00000000-0000-4000-8000-000000000001';
LocalDatabaseIdentity identity(String uid)=>LocalDatabaseIdentity.bound(projectId:'demo-life-os',databaseId:'(default)',uid:uid,generation:generation);
void main(){
  late AppDatabase db;late RefusalAuth auth;late RefusalStore store;late SyncManager manager;
  setUp((){auth=RefusalAuth();store=RefusalStore();db=AppDatabase.forUser(identity:identity('A'),executor:NativeDatabase.memory());db.localMutations.bindSessionReader(()=>'A');db.localMutations.openPreparedSession(admission:db.localMutations.capture(expectedUid:'A'));manager=SyncManager(queueStore:AppDatabaseSyncQueueStore(db),remoteDataSource:NoRemote(),currentUserId:()=>'A');});
  tearDown(()async{manager.dispose();await db.close();});
  for(final family in ['habits','finance','goals','study','health','checkin','focus','notifications'])test('$family bound pull without admitted lease performs no SDK read or mutation',()async{
    final Future<void> Function() read=switch(family){
      'habits'=>HabitsRepository(db,store,auth).syncHabitsFromFirebaseToLocal,
      'finance'=>FinanceRepository(db,store,auth,manager).syncTransactionsFromFirestore,
      'goals'=>GoalRepository(db,store,auth).syncGoalsFromFirebaseToLocal,
      'study'=>StudyRepository(db,store,auth,manager).syncStudyFromFirebaseToLocal,
      'health'=>()=>HealthRepository(NotificationService.instance,store,auth,db,manager,medicationsOnly:true,nativeRemindersEnabled:false).syncHealthFromFirebase(),
      'checkin'=>CheckInRepository(db,store,auth).syncCheckinsFromFirebaseToLocal,
      'focus'=>FocusRepository(db,store,auth,manager).syncFocusFromFirebaseToLocal,
      _=>NotificationsRepository(firestore:store,auth:auth,localDao:db.notificationDao,readAndDismissOnly:true).syncNotificationsFromFirebaseToLocal,
    };
    try{await read();}on StateError{/* Fail-closed repositories may expose or sanitize the refusal. */}
    expect(store.calls,0);expect(await db.getPendingSyncItems('A'),isEmpty);
    expect(await db.select(db.habits).get(),isEmpty);expect(await db.select(db.transactions).get(),isEmpty);expect(await db.select(db.goals).get(),isEmpty);expect(await db.select(db.checkInTable).get(),isEmpty);
  });
  for(final transition in ['A-B','A-B-A'])test('read lease rejects $transition even with an unchanged local generation',(){
    final container=ProviderContainer();addTearDown(container.dispose);final session=container.read(localAccountSessionProvider.notifier);session.bind(identity('A'));final old=session.capture();session.clear();session.bind(identity('B'));if(transition=='A-B-A'){session.clear();session.bind(identity('A'));}
    expect(()=>GenerationalReadPolicy.requireCurrent(identity:identity('A'),lease:old,auth:auth,expectedUid:'A'),throwsStateError);expect(store.calls,0);
  });
  for(final value in [double.nan,double.infinity,-0.1,10.1])test('Check-in rejects invalid local metric $value before domain/outbox writes',()async{
    final repository=CheckInRepository(db,store,auth);await expectLater(repository.saveDailyMetrics(energy:value,focus:5,motivation:5),throwsArgumentError);expect(await db.select(db.checkInTable).get(),isEmpty);expect(await db.getPendingSyncItems('A'),isEmpty);expect(store.calls,0);
  });
  test('notification local slice refuses SDK listener and metadata writers',()async{
    final repository=NotificationsRepository(firestore:store,auth:auth,localDao:db.notificationDao,readAndDismissOnly:true);
    expect(repository.getNotificationsStream,throwsStateError);expect(()=>repository.markAsReadLocal('habit_x'),throwsStateError);expect(()=>repository.markAsCompletedLocal('habit_x'),throwsStateError);expect(()=>repository.deleteDerivedNotification('habit_x'),throwsStateError);expect(store.calls,0);expect(await db.getPendingSyncItems('A'),isEmpty);
  });
  test('module capability alone never grants goal HTTP admission or SDK fallback',()async{
    final source=FirestoreSyncRemoteDataSource(store,auth,allowedCollections:const {'goals'},clientFactory:()=>throw StateError('NO_HTTP'));
    final row=SyncQueueTableData(id:1,ownerUid:'A',collection:'goals',docId:'g',operationType:'update',payloadJson:'{"currentValue":1}',createdAt:1,isSynced:false,status:'pending',attemptCount:2,lastErrorCode:'UNKNOWN');
    final result=await source.process('A',row);expect(result.isSuccess,false);expect(result.code,'TRUSTED_LOCAL_SESSION_CLOSED');expect(store.calls,0);expect(row.payloadJson,'{"currentValue":1}');expect(row.attemptCount,2);expect(row.lastErrorCode,'UNKNOWN');
  });
}
