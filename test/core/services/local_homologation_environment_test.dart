// Policy/refusal tests. No SDK token, provenance or admission is fabricated.
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/local_homologation_environment.dart';
import 'package:life_os/core/services/trusted_account_access.dart';
import 'package:life_os/features/auth/data/repositories/auth_entry_failure.dart';
import 'package:firebase_core/firebase_core.dart';
import 'dart:async';

void main(){
 test('nominal environment is explicitly selectable but remains closed',(){
  final p=LocalHomologationEnvironment.select('p1-life-os-27b92-android-local');
  expect(p.projectId,'life-os-27b92');expect(p.appId,isNull);expect(p.requireReady,throwsStateError);
  expect(TrustedAccountAccess.localSessionClosed,isTrue);
 });
 for(final id in ['','production','life-os-27b92','demo-life-os','https://life-os-backend-gray.vercel.app']){
  test('unrecognized environment refuses $id',()=>expect(()=>LocalHomologationEnvironment.select(id),throwsStateError));
 }
 test('demo profile remains explicitly isolated',(){expect(LocalHomologationEnvironment.select('demo-loopback'),same(LocalHomologationEnvironment.demo));});
 for(final code in ['APP_CHECK_REQUIRED','APP_CHECK_INVALID','APP_CHECK_TOKEN_UNAVAILABLE','APP_CHECK_TIMEOUT']){
  test('App Check message is distinct and redacted $code',(){final f=authEntryFailure(TrustedAccountPending(code));expect(f.code,'APP_CHECK_UNCONFIRMED');expect(f.message,contains('segurança do aplicativo'));});
 }
 test('network is distinct from credentials/App Check',(){expect(authEntryFailure(FirebaseException(plugin:'firebase_auth',code:'network-request-failed',message:'private-detail')).code,'NETWORK_ERROR');expect(authEntryFailure(TimeoutException('private-detail')).code,'NETWORK_ERROR');});
 for(final code in ['LOCAL_ENVIRONMENT_PENDING_AUTHORIZATION','TRUSTED_LOCAL_SESSION_CLOSED','LOCAL_ENVIRONMENT_MISMATCH']){
  test('environment remains closed $code',()=>expect(authEntryFailure(StateError(code)).code,'AUTH_ENVIRONMENT_CLOSED'));
 }
 test('origin/profile pending is distinct',()=>expect(authEntryFailure(const TrustedAccountPending('TRUSTED_ACCOUNT_SERVER_PROOF_REQUIRED')).code,'AUTH_ORIGIN_OR_PROFILE_PENDING'));
 test('database failure is distinct',()=>expect(authEntryFailure(StateError('LOCAL_DATABASE_UNAVAILABLE')).code,'AUTH_LOCAL_DATABASE_UNAVAILABLE'));
 test('unknown errors expose no details',(){final f=authEntryFailure(StateError('private-token-or-uid'));expect(f.code,'AUTH_SESSION_UNCONFIRMED');expect(f.message,isNot(contains('private-token-or-uid')));});
}
