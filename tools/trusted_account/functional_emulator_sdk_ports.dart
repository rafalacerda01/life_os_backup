// Test-only protocol adapters. Every supported Auth/Firestore operation uses
// the real Emulator protocol; unexpected SDK methods throw through Fake.
// These ports are not a native mobile Firebase SDK or a provenance generator.
// ignore_for_file: subtype_of_sealed_class, must_be_immutable
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class LocalClient extends http.BaseClient {
  LocalClient(this.hosts);
  final Set<String> hosts;
  final http.Client inner = http.Client();
  bool online = true;
  @override Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (!online) throw const SocketException('ISOLATED_OFFLINE');
    if(request.url.scheme!='http'||!hosts.contains(request.url.authority)) {
      throw StateError('NON_EMULATOR_HTTP_REFUSED');
    }
    request.followRedirects=false;
    return inner.send(request);
  }
  @override void close()=>inner.close();
}
class DemoApp extends Fake implements FirebaseApp {
  @override String get name=>'functional-integration';
  @override FirebaseOptions get options=>const FirebaseOptions(apiKey:'demo-key',appId:'demo-app',messagingSenderId:'demo',projectId:'demo-life-os');
}
class Decoded extends Fake implements IdTokenResult {
  Decoded(this.jwt);
  final String jwt;
  @override Map<String,dynamic> get claims=>jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(jwt.split('.')[1])))) as Map<String,dynamic>;
}
class AuthReply extends Fake implements UserCredential {
  AuthReply(this.person);
  final Person person;
  @override User get user=>person;
}
class Person extends Fake implements User {
  Person(this.owner,this.value);
  final ProtocolAuth owner;
  Map<String,dynamic> value;
  @override String get uid=>value['localId'] as String;
  @override String? get email=>value['email'] as String?;
  @override String? get displayName=>value['displayName'] as String?;
  @override String? get photoURL=>null;
  @override Future<String> getIdToken([bool forceRefresh=false]) async=>value['idToken'] as String;
  @override Future<IdTokenResult> getIdTokenResult([bool forceRefresh=false]) async=>Decoded(await getIdToken(forceRefresh));
  @override Future<void> updateDisplayName(String? name)async{
    final updated=await owner.request('update',{'idToken':await getIdToken(),'displayName':name,'returnSecureToken':true});
    value={...value,...updated,'displayName':name};
  }
}
class ProtocolAuth extends Fake implements FirebaseAuth {
  ProtocolAuth(this.client,this.host);
  final LocalClient client;
  final String host;
  Person? person;
  final events=StreamController<User?>.broadcast(sync:true);
  @override FirebaseApp get app=>DemoApp();
  @override String? get tenantId=>null;
  @override User? get currentUser=>person;
  @override Future<void> useAuthEmulator(String host,int port,{bool automaticHostMapping=true})async{
    if('$host:$port'!=this.host||automaticHostMapping)throw StateError('AUTH_HOST_DIVERGENCE');
  }
  Future<Map<String,dynamic>> request(String method,Map<String,dynamic> body)async{
    final reply=await client.post(Uri.parse('http://$host/identitytoolkit.googleapis.com/v1/accounts:$method?key=demo-key'),headers:{'Content-Type':'application/json'},body:jsonEncode(body));
    final data=jsonDecode(reply.body) as Map<String,dynamic>;
    if(reply.statusCode!=200)throw FirebaseAuthException(code:'EMULATOR_AUTH_REFUSED',message:'${reply.statusCode}');
    return data;
  }
  Future<UserCredential> authenticate(String method,String email,String password)async{
    final value=await request(method,{'email':email,'password':password,'returnSecureToken':true});
    person=Person(this,{...value,'email':email});events.add(person);return AuthReply(person!);
  }
  @override Future<UserCredential> createUserWithEmailAndPassword({required String email,required String password})=>authenticate('signUp',email,password);
  @override Future<UserCredential> signInWithEmailAndPassword({required String email,required String password})=>authenticate('signInWithPassword',email,password);
  @override Future<void> signOut()async{person=null;events.add(null);}
  @override Stream<User?> authStateChanges()=>Stream<User?>.multi((c){c.add(person);final s=events.stream.listen(c.add,onError:c.addError);c.onCancel=s.cancel;});
}
Object? decodeValue(Map<String,dynamic> value){
  if(value.containsKey('stringValue'))return value['stringValue'];
  if(value.containsKey('integerValue'))return int.parse(value['integerValue'].toString());
  if(value.containsKey('doubleValue'))return value['doubleValue'];
  if(value.containsKey('booleanValue'))return value['booleanValue'];
  if(value.containsKey('timestampValue'))return Timestamp.fromDate(DateTime.parse(value['timestampValue'] as String));
  if(value.containsKey('nullValue'))return null;
  if(value.containsKey('mapValue'))return decodeFields((value['mapValue'] as Map)['fields'] as Map<String,dynamic>? ?? {});
  if(value.containsKey('arrayValue'))return ((value['arrayValue'] as Map)['values'] as List? ?? []).map((v)=>decodeValue(Map<String,dynamic>.from(v as Map))).toList();
  throw StateError('UNSUPPORTED_FIRESTORE_VALUE');
}
Map<String,dynamic> decodeFields(Map<String,dynamic> fields)=>fields.map((k,v)=>MapEntry(k,decodeValue(Map<String,dynamic>.from(v as Map))));
Map<String,dynamic> encodeValue(Object? v){
  if(v==null)return {'nullValue':null};if(v is String)return {'stringValue':v};if(v is bool)return {'booleanValue':v};if(v is int)return {'integerValue':v.toString()};if(v is num)return {'doubleValue':v};throw StateError('UNSUPPORTED_CLIENT_WRITE');
}
class ServerMetadata extends Fake implements SnapshotMetadata {
  @override bool get isFromCache=>false;
  @override bool get hasPendingWrites=>false;
}
class ProtocolStore extends Fake implements FirebaseFirestore {
  ProtocolStore(this.auth,this.host);
  final ProtocolAuth auth;
  final String host;
  @override FirebaseApp get app=>auth.app;
  @override String get databaseId=>'(default)';
  @override void useFirestoreEmulator(String host,int port,{bool automaticHostMapping=true,bool sslEnabled=false}){if('$host:$port'!=this.host||automaticHostMapping||sslEnabled)throw StateError('FIRESTORE_HOST_DIVERGENCE');}
  @override CollectionReference<Map<String,dynamic>> collection(String path)=>ProtocolCollection(this,path);
  Future<http.Response> fetch(String path,{Map<String,Object?>? update})async{
    final uri=Uri.parse('http://$host/v1/projects/demo-life-os/databases/(default)/documents/$path');
    final headers={'Authorization':'Bearer ${await auth.currentUser!.getIdToken()}','Content-Type':'application/json'};
    final response=update==null?await auth.client.get(uri,headers:headers):await auth.client.patch(uri.replace(queryParameters:{'updateMask.fieldPaths':update.keys.toList()}),headers:headers,body:jsonEncode({'fields':update.map((k,v)=>MapEntry(k,encodeValue(v)))}));
    if(![200,404].contains(response.statusCode))throw FirebaseException(plugin:'cloud_firestore',code:response.statusCode==403?'permission-denied':'unavailable');
    return response;
  }
}
class ProtocolDocument extends Fake implements DocumentReference<Map<String,dynamic>> {
  ProtocolDocument(this.store,this.path);
  final ProtocolStore store;
  @override final String path;
  @override String get id=>path.split('/').last;
  @override CollectionReference<Map<String,dynamic>> collection(String name)=>ProtocolCollection(store,'$path/$name');
  @override Future<DocumentSnapshot<Map<String,dynamic>>> get([GetOptions? options])async{
    if(options?.source!=Source.server)throw StateError('SERVER_ONLY_READ_REQUIRED');
    final response=await store.fetch(path);return ProtocolSnapshot(this,response.statusCode==404?null:jsonDecode(response.body) as Map<String,dynamic>);
  }
  @override Future<void> update(Map<Object,Object?> data)async{await store.fetch(path,update:data.map((k,v)=>MapEntry(k.toString(),v)));}
}
class ProtocolSnapshot extends Fake implements DocumentSnapshot<Map<String,dynamic>> {
  ProtocolSnapshot(this.ref,this.value);
  final ProtocolDocument ref;
  @override DocumentReference<Map<String,dynamic>> get reference=>ref;
  final Map<String,dynamic>? value;
  @override String get id=>ref.id;
  @override bool get exists=>value!=null;
  @override SnapshotMetadata get metadata=>ServerMetadata();
  @override Map<String,dynamic>? data()=>value==null?null:decodeFields(value!['fields'] as Map<String,dynamic>? ?? {});
}
class ProtocolQueryDocument extends ProtocolSnapshot implements QueryDocumentSnapshot<Map<String,dynamic>> {
  ProtocolQueryDocument(super.ref,super.value);
  @override Map<String,dynamic> data()=>super.data()!;
}
class ProtocolQuery extends Fake implements QuerySnapshot<Map<String,dynamic>> {
  ProtocolQuery(this.docs);
  @override final List<QueryDocumentSnapshot<Map<String,dynamic>>> docs;
  @override SnapshotMetadata get metadata=>ServerMetadata();
  @override int get size=>docs.length;
}
class ProtocolCollection extends Fake implements CollectionReference<Map<String,dynamic>> {
  ProtocolCollection(this.store,this.path);
  final ProtocolStore store;
  @override final String path;
  @override DocumentReference<Map<String,dynamic>> doc([String? id])=>ProtocolDocument(store,'$path/$id');
  @override Future<QuerySnapshot<Map<String,dynamic>>> get([GetOptions? options])async{
    if(options?.source!=Source.server)throw StateError('SERVER_ONLY_QUERY_REQUIRED');
    final response=await store.fetch(path),value=jsonDecode(response.body) as Map<String,dynamic>;
    return ProtocolQuery((value['documents'] as List? ?? []).map((d){final row=Map<String,dynamic>.from(d as Map),full=row['name'] as String;return ProtocolQueryDocument(ProtocolDocument(store,full.split('/documents/')[1]),row);}).toList());
  }
}
