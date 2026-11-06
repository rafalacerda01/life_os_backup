// Refusal/persistence tests only: these fixtures grant no R1 authority.
// ignore_for_file: subtype_of_sealed_class
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';
import 'package:life_os/core/services/trusted_account_access.dart';
import 'package:life_os/core/router/router.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
class NoAuth extends Fake implements FirebaseAuth {}
class NoStore extends Fake implements FirebaseFirestore {}
SyncQueueTableData row(String collection)=>SyncQueueTableData(id:1,ownerUid:'A',collection:collection,docId:'saved',operationType:'update',payloadJson:'{"original":true}',createdAt:1,isSynced:false,status:'pending',attemptCount:2,lastErrorCode:'UNKNOWN');
void main(){
  for(final family in ['habits','goals','transactions','checkins','review_queue','notifications','health_info','study_activity'])test('local UI family $family remains CLOSED before any SDK/HTTP IO',()async{
    final original=row(family),source=FirestoreSyncRemoteDataSource(NoStore(),NoAuth(),allowedCollections:const {'tasks'},clientFactory:()=>throw StateError('HTTP_MUST_NOT_START'));
    final result=await source.process('A',original);
    expect(result.isSuccess,false);expect(result.shouldRetry,true);expect(result.code,'SYNC_FAMILY_CLOSED');expect(result.preserveQueueState,true);
    expect(original.payloadJson,'{"original":true}');expect(original.lastErrorCode,'UNKNOWN');expect(original.attemptCount,2);expect(original.isSynced,false);
  });
  test('family allowlist alone never grants Tasks admission',()async{
    expect(TrustedAccountAccess.localSessionClosed,true);
    final source=FirestoreSyncRemoteDataSource(NoStore(),NoAuth(),allowedCollections:const {'tasks'},clientFactory:()=>throw StateError('HTTP_MUST_NOT_START'));
    expect((await source.process('A',row('tasks'))).code,'TRUSTED_LOCAL_SESSION_CLOSED');
  });
  for(final hasUser in [false,true])test('CLOSED private deep link returns to public gate, Firebase user=$hasUser',(){
    final state=AuthState.error('closed',code:'TRUSTED_LOCAL_SESSION_CLOSED');
    for(final route in ['/home','/tasks','/health','/settings'])expect(authRedirectFor(authState:state,hasFirebaseUser:hasUser,location:route),'/splash');
    expect(authRedirectFor(authState:state,hasFirebaseUser:hasUser,location:'/register'),null);
    expect(authRedirectFor(authState:state,hasFirebaseUser:hasUser,location:'/privacy-policy'),null);
  });
}
