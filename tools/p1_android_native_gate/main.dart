// Native prerequisite probe only. No REST replacements, synthetic App Check,
// positive local-session override, profile adoption or production bootstrap.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:life_os/core/services/emulator_account_runtime.dart';
import 'package:life_os/core/services/trusted_account_access.dart';

const channel=MethodChannel('life_os/native_gate');
const password='Native-emulator-only-19!';
String code(Object error)=>error is FirebaseException?error.code:error is TimeoutException?'TIMEOUT':error is StateError&&RegExp(r'^[A-Z_]+$').hasMatch(error.message.toString())?error.message.toString():error.runtimeType.toString();
Future<void> main()async{
  if(!kDebugMode||!Platform.isAndroid)throw StateError('NATIVE_GATE_DEBUG_ANDROID_ONLY');
  WidgetsFlutterBinding.ensureInitialized();
  final log=<String,dynamic>{'nativePlugins':true,'productionSessionClosed':TrustedAccountAccess.localSessionClosed,'applicationSessionPublished':false,'accountDatabaseOpened':false,'sdkReplacement':false};
  final events=<String?>[];
  String phase='unknown';
  try{
    final config=await channel.invokeMapMethod<String,dynamic>('configuration');
    if(config?['ready']!=true||config?['project']!='demo-life-os'||config?['package']!='com.rafalacerda.lifeos.p1nativegate'||config?['host']!='127.0.0.1'||config?['authPort']!=45099||config?['firestorePort']!=45089)throw StateError('NATIVE_CONFIG_REFUSED');
    phase=config!['phase'] as String;
    if(!{'initial','restart','offline','second','appcheck'}.contains(phase))throw StateError('PHASE_REFUSED');
    log['phase']=phase;log['nativeConfiguration']=config;
    final app=await Firebase.initializeApp();
    if(app.name!='[DEFAULT]'||app.options.projectId!='demo-life-os'||app.options.appId!='1:123456789012:android:00000000000000000000000000000000')throw StateError('FIREBASE_APP_REFUSED');
    final auth=FirebaseAuth.instanceFor(app:app),store=FirebaseFirestore.instanceFor(app:app);
    store.settings=const Settings(persistenceEnabled:false);
    final check=FirebaseAppCheck.instanceFor(app:app);
    if(phase=='appcheck') {
      await check.activate(androidProvider:AndroidProvider.debug);
      await check.setTokenAutoRefreshEnabled(false);
      log['officialDebugActivated']=true;
      log['nativeDiagnostic']=await channel.invokeMapMethod<String,dynamic>('diagnoseAppCheck').timeout(const Duration(seconds:40));
      try {
        final token=await check.getToken(true).timeout(const Duration(seconds:15));
        log['dartTokenReturned']=token?.isNotEmpty==true;
      } catch(error) {
        log['dartTokenReturned']=false;
        log['dartErrorClass']=error.runtimeType.toString();log['dartErrorCode']=code(error);
        final message=error is FirebaseException?error.message:error.toString();
        log['dartErrorMessage']=await channel.invokeMethod<String>('sanitizeDiagnostic',{'text':message});
      }
      log['status']='APP_CHECK_DIAGNOSTIC_ONLY';
      final directory=await getApplicationDocumentsDirectory();
      await File('${directory.path}/p1-native-appcheck.json').writeAsString(jsonEncode(log),flush:true);
      runApp(MaterialApp(home:Scaffold(body:SafeArea(child:SingleChildScrollView(child:Text(const JsonEncoder.withIndent('  ').convert(log)))))));
      return;
    }
    final client=http.Client();
    final runtime=await EmulatorAccountRuntime.configure(auth:auth,store:store,authPort:45099,firestorePort:45089,baseUri:Uri.parse('http://127.0.0.1:45789'),client:client,appCheckToken:()async{
      final token=await check.getToken(true).timeout(const Duration(seconds:8));
      if(token==null||token.isEmpty)throw StateError('APP_CHECK_TOKEN_UNAVAILABLE');return token;
    });
    final subscription=auth.authStateChanges().listen((user)=>events.add(user?.uid));
    await auth.authStateChanges().first.timeout(const Duration(seconds:5));
    log['restoredUid']=auth.currentUser?.uid;
    const secure=FlutterSecureStorage(aOptions:AndroidOptions(encryptedSharedPreferences:true));
    if(phase=='initial'){
      if(auth.currentUser!=null)throw StateError('FRESH_INSTALL_REQUIRED');
      final email='native-a-${DateTime.now().microsecondsSinceEpoch}@example.invalid';
      final credential=await auth.createUserWithEmailAndPassword(email:email,password:password).timeout(const Duration(seconds:30));
      final uid=credential.user!.uid;log['signupUid']=uid;
      await auth.signOut();await auth.signInWithEmailAndPassword(email:email,password:password).timeout(const Duration(seconds:20));
      if(auth.currentUser?.uid!=uid)throw StateError('NATIVE_LOGIN_MISMATCH');log['nativeLoginSameUid']=true;
      await secure.write(key:'p1_native_probe_marker',value:'noncredential-$uid');
    }else if(auth.currentUser==null){throw StateError('NATIVE_AUTH_NOT_RESTORED');}
    final marker=await secure.read(key:'p1_native_probe_marker');
    if(marker==null)throw StateError('NATIVE_SECURE_STORAGE_NOT_RESTORED');log['secureMarkerSha256']=sha256.convert(utf8.encode(marker)).toString();
    if(phase=='second'){
      final a=auth.currentUser!.uid;await auth.signOut();
      if(auth.currentUser!=null)throw StateError('NATIVE_LOGOUT_FAILED');log['nativeLogoutCleared']=true;
      await auth.createUserWithEmailAndPassword(email:'native-b-${DateTime.now().microsecondsSinceEpoch}@example.invalid',password:password).timeout(const Duration(seconds:30));
      if(auth.currentUser!.uid==a)throw StateError('NATIVE_IDENTITY_NOT_CHANGED');log['previousUid']=a;
    }
    final user=auth.currentUser!;log['uid']=user.uid;
    final result=await user.getIdTokenResult(phase!='offline').timeout(const Duration(seconds:15));
    final claims=result.claims;log['tokenPresent']=result.token?.isNotEmpty==true;log['generation']=claims?['lifeos_generation'];
    log['tokenBindingValid']=claims?['sub']==user.uid&&claims?['aud']=='demo-life-os'&&claims?['iss']=='https://securetoken.google.com/demo-life-os'&&claims?['lifeos_generation'] is String;
    if(log['tokenBindingValid']!=true)throw StateError('NATIVE_R1_TOKEN_BINDING_MISSING');
    if(phase!='offline'){
      final observation=await client.post(Uri.parse('http://127.0.0.1:45789/native-observation'),headers:{'Authorization':'Bearer ${result.token!}','Content-Type':'application/json'},body:jsonEncode({'phase':phase})).timeout(const Duration(seconds:10));
      if(observation.statusCode!=200)throw StateError('SERVER_R1_OBSERVATION_FAILED');log['serverR1']=jsonDecode(observation.body);
      try{await store.collection('users').doc(user.uid).get(const GetOptions(source:Source.server)).timeout(const Duration(seconds:10));log['reservedProfileRead']='UNEXPECTED_SUCCESS';}catch(e){log['reservedProfileRead']=code(e);}
    }
    await check.activate(androidProvider:AndroidProvider.debug);
    await check.setTokenAutoRefreshEnabled(false);
    log['officialAppCheckDebugActivated']=true;
    try{
      final token=await check.getToken(true).timeout(const Duration(seconds:8));
      log['appCheckTokenAvailable']=token?.isNotEmpty==true;
      if(token?.isNotEmpty==true)throw StateError('UNEXPECTED_DEMO_APP_CHECK_TOKEN');
    }catch(e){log['appCheckTokenAvailable']=false;log['appCheckError']=code(e);}
    try{await runtime.admit(user.uid).timeout(const Duration(seconds:12));log['runtimeAdmission']='UNEXPECTED_SUCCESS';}catch(e){log['runtimeAdmission']='BLOCKED';log['admissionError']=code(e);}
    if(log['runtimeAdmission']!='BLOCKED')throw StateError('UNEXPECTED_APPLICATION_ADMISSION');
    if(phase!='offline'){
      final denied=await client.post(Uri.parse('http://127.0.0.1:45789/api/account/bootstrap'),headers:{'Authorization':'Bearer ${result.token!}','Content-Type':'application/json'},body:'{}').timeout(const Duration(seconds:10));
      log['bootstrapWithoutAppCheck']=denied.statusCode;
      if(denied.statusCode==200)throw StateError('MISSING_APP_CHECK_ACCEPTED');
    }
    log['authEvents']=events;log['status']='BLOCKED_APP_CHECK';
    await subscription.cancel();client.close();
  }catch(e){log['status']='FAIL_OR_BLOCKED';log['error']=code(e);}
  final directory=await getApplicationDocumentsDirectory();
  await File('${directory.path}/p1-native-$phase.json').writeAsString(jsonEncode(log),flush:true);
  runApp(MaterialApp(home:Scaffold(appBar:AppBar(title:const Text('Life OS — native gate local')),body:SingleChildScrollView(padding:const EdgeInsets.all(20),child:Text('NÃO DISTRIBUÍVEL\n\n${const JsonEncoder.withIndent('  ').convert(log)}')))));
}
