// Strict negative SDK ports only. No positive origin, receipt or native token.
// ignore_for_file: subtype_of_sealed_class, must_be_immutable
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_os/core/services/emulator_account_runtime.dart';
import 'package:life_os/core/services/local_homologation_environment.dart';
import 'package:life_os/core/services/trusted_account_access.dart';

class App extends Fake implements FirebaseApp {
 @override String get name=>'negative-local';
 @override FirebaseOptions get options=>const FirebaseOptions(apiKey:'demo',appId:'demo',messagingSenderId:'demo',projectId:'demo-life-os');
}
class Token extends Fake implements IdTokenResult {
 @override Map<String,dynamic> get claims=>{'sub':'A','aud':'demo-life-os','iss':'https://securetoken.google.com/demo-life-os','lifeos_generation':'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'};
}
class Person extends Fake implements User {
 @override String get uid=>'A';
 @override Future<String?> getIdToken([bool forceRefresh=false])async=>'untrusted-id-input';
 @override Future<IdTokenResult> getIdTokenResult([bool forceRefresh=false])async=>Token();
}
class Auth extends Fake implements FirebaseAuth {
 int configurations=0;
 @override FirebaseApp get app=>App();
 @override String? get tenantId=>null;
 @override User get currentUser=>Person();
 @override Stream<User?> authStateChanges()=>Stream.value(currentUser);
 @override Future<void> useAuthEmulator(String host,int port,{bool automaticHostMapping=true})async{configurations++;expect(host,'127.0.0.1');expect(automaticHostMapping,isFalse);}
}
class Store extends Fake implements FirebaseFirestore {
 @override FirebaseApp get app=>App();
 @override String get databaseId=>'(default)';
 @override void useFirestoreEmulator(String host,int port,{bool automaticHostMapping=true,bool sslEnabled=false}){expect(host,'127.0.0.1');expect(automaticHostMapping,isFalse);}
}
Future<EmulatorAccountRuntime> runtime(Auth auth,http.Client client,Future<String?> Function() check)=>EmulatorAccountRuntime.configure(auth:auth,store:Store(),authPort:45099,firestorePort:45089,baseUri:Uri.parse('http://127.0.0.1:45789'),client:client,appCheckToken:check);
void main(){
 test('nominal refusal happens before configuring even demo SDK ports',()async{
  final auth=Auth(),client=MockClient((_)async=>throw StateError('NO_HTTP'));addTearDown(client.close);
  await expectLater(EmulatorAccountRuntime.configure(environment:LocalHomologationEnvironment.nominal,auth:auth,store:Store(),authPort:45099,firestorePort:45089,baseUri:Uri.parse('http://127.0.0.1:45789'),client:client,appCheckToken:()async=>throw StateError('NO_TOKEN_IO')),throwsStateError);expect(auth.configurations,0);
 });
 for(final kind in ['missing','sdk error','timeout'])test('App Check $kind cannot reach bootstrap',()async{
  var httpCalls=0;final client=MockClient((_)async{httpCalls++;throw StateError('NO_HTTP');});addTearDown(client.close);
  final r=await runtime(Auth(),client,()async{if(kind=='sdk error')throw FirebaseException(plugin:'firebase_app_check',code:'unknown',message:'private SDK detail');if(kind=='timeout')throw TimeoutException('private detail');return null;});
  await expectLater(r.admit('A'),throwsA(isA<TrustedAccountPending>().having((e)=>e.code,'safe code',kind=='missing'?'APP_CHECK_REQUIRED':kind=='timeout'?'APP_CHECK_TIMEOUT':'APP_CHECK_INVALID')));expect(httpCalls,0);
 });
 // No positive token is accepted: these requests are deliberately rejected by
 // the HTTP port. They test response classification and redirect containment.
 for(final code in ['APP_CHECK_REQUIRED','APP_CHECK_INVALID','UNAUTHENTICATED'])test('401 $code is classified without claiming admission',()async{
  final client=MockClient((_)async=>http.Response('{"code":"$code"}',401));addTearDown(client.close);final r=await runtime(Auth(),client,()async=>'untrusted-negative-header');
  await expectLater(r.admit('A'),throwsA(isA<TrustedAccountPending>().having((e)=>e.code,'code',code)));
 });
 test('307 cannot forward Auth/App Check outside loopback',()async{
  var calls=0;final client=MockClient((request)async{calls++;expect(request.url.host,'127.0.0.1');expect(request.followRedirects,isFalse);return http.Response('{}',307,headers:{'location':'https://example.invalid/api/account/bootstrap'});});addTearDown(client.close);
  final r=await runtime(Auth(),client,()async=>'untrusted-negative-header');await expectLater(r.admit('A'),throwsStateError);expect(calls,1);
  await expectLater(r.client.get(Uri.parse('https://example.invalid/api/sync')),throwsStateError);expect(calls,1);
 });
 test('bootstrap network failure is distinct from App Check and origin pending',()async{
  final client=MockClient((_)async=>throw http.ClientException('private socket detail'));addTearDown(client.close);
  final r=await runtime(Auth(),client,()async=>'untrusted-negative-header');
  await expectLater(r.admit('A'),throwsA(isA<TrustedAccountPending>().having((e)=>e.code,'code','EMULATOR_ACCOUNT_NETWORK_UNAVAILABLE')));
 });
}
