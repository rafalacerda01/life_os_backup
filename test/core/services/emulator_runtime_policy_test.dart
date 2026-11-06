// Environment refusal tests only. No synthetic origin or positive Auth grant.
// ignore_for_file: subtype_of_sealed_class, must_be_immutable
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:life_os/core/services/emulator_account_runtime.dart';
class App extends Fake implements FirebaseApp {
  App(this.project,[this.label='local']);final String project,label;
  @override String get name=>label;
  @override FirebaseOptions get options=>FirebaseOptions(apiKey:'demo-key',appId:'demo',messagingSenderId:'demo',projectId:project);
}
class Auth extends Fake implements FirebaseAuth {
  Auth(this.application,{this.tenant});final FirebaseApp application;final String? tenant;int calls=0;
  @override FirebaseApp get app=>application;
  @override String? get tenantId=>tenant;
  @override Future<void> useAuthEmulator(String host,int port,{bool automaticHostMapping=true})async{calls++;throw StateError('UNEXPECTED_CONFIG_IO');}
}
class Store extends Fake implements FirebaseFirestore {
  Store(this.application,{this.database='(default)'});final FirebaseApp application;final String database;
  @override FirebaseApp get app=>application;
  @override String get databaseId=>database;
}
void main(){
  for(final url in ['https://127.0.0.1:4000','http://example.invalid:4000','http://localhost:4000','http://user@127.0.0.1:4000','http://127.0.0.1:4000/path','http://127.0.0.1:4000?q=x','http://127.0.0.1:4000#fragment'])test('runtime refuses destination before SDK/credential IO: $url',()async{
    final auth=Auth(App('demo-life-os')),store=Store(App('demo-life-os')),client=http.Client();addTearDown(client.close);
    await expectLater(EmulatorAccountRuntime.configure(auth:auth,store:store,authPort:4001,firestorePort:4002,baseUri:Uri.parse(url),client:client,appCheckToken:()async=>throw StateError('TOKEN_IO_REFUSED')),throwsStateError);expect(auth.calls,0);
  });
  for(final wrong in ['project','app','database','tenant','auth port'])test('runtime refuses $wrong before SDK/credential IO',()async{
    final auth=Auth(App(wrong=='project'?'production-project':'demo-life-os'),tenant:wrong=='tenant'?'other':null),store=Store(App('demo-life-os',wrong=='app'?'other':'local'),database:wrong=='database'?'other':'(default)'),client=http.Client();addTearDown(client.close);
    await expectLater(EmulatorAccountRuntime.configure(auth:auth,store:store,authPort:wrong=='auth port'?0:4001,firestorePort:4002,baseUri:Uri.parse('http://127.0.0.1:4000'),client:client,appCheckToken:()async=>throw StateError('TOKEN_IO_REFUSED')),throwsStateError);expect(auth.calls,0);
  });
}
