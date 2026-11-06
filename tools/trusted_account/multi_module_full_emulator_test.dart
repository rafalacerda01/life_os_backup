// ignore_for_file: subtype_of_sealed_class, must_be_immutable, invalid_use_of_visible_for_testing_member
import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:drift/drift.dart' show Variable;
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:drift/native.dart';
import 'package:life_os/main.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/health/services/medication_reminder_providers.dart';
import 'package:life_os/features/checkin/presentation/providers/check_in_provider.dart';
import 'package:life_os/features/checkin/presentation/providers/checkin_controller.dart';
import 'package:life_os/features/focus/presentation/providers/providers/focus_provider.dart';
import 'package:life_os/features/circles/presentation/circle_focus_contribution_provider.dart';
import 'package:life_os/features/notifications/data/repositories/notifications_repository.dart';
import 'package:life_os/features/habits/presentation/providers/habits_provider.dart';
import 'package:life_os/features/finance/presentation/providers/finance_provider.dart';
import 'package:life_os/features/goals/presentation/goals_provider.dart';
import 'package:life_os/features/auth/presentation/screens/register_screen.dart';
import 'package:life_os/features/onboarding/presentation/onboarding_provider.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';
import 'package:sqlite3/sqlite3.dart' hide Row;
import 'package:life_os/core/router/router.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/database/user_database_factory.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_account_session.dart';
import 'package:life_os/core/services/emulator_account_runtime.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/core/services/water_v2_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/features/auth/data/remote/account_remote_data_source.dart';
import 'package:life_os/features/home/presentation/providers/home_provider.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';
import 'package:life_os/features/notifications/domain/providers/notification_engine.dart';
import 'package:life_os/features/health/services/cycle_reminder_action_bootstrap.dart';
import 'functional_emulator_sdk_ports.dart';

class NoDeletion extends Fake implements AccountRemoteDataSource {}
class NetworkBinding extends AutomatedTestWidgetsFlutterBinding {
  @override bool get overrideHttpClient=>false;
}
class FileFactory extends UserDatabaseFactory {
  FileFactory(this.directory);
  final Directory directory;
  @override Future<AppDatabase> open(LocalDatabaseIdentity identity)async=>AppDatabase.forUser(identity:identity,executor:NativeDatabase(identity.fileIn(directory)));
}
class IntroStore implements OnboardingCompletionStore {
  IntroStore(this.file);final File file;
  @override Future<bool> hasCompleted()async=>file.existsSync();
  @override Future<void> markCompleted()async{file.writeAsStringSync('completed');}
}
class FaultClient extends LocalClient {
  FaultClient(super.hosts);bool forgeAck=false;int faultsApplied=0;
  final operations=<Map<String,dynamic>>[];
  @override Future<http.StreamedResponse> send(http.BaseRequest request)async{
    Map<String,dynamic>? body,context;
    if(request.url.path=='/api/sync' && request is http.Request){body=jsonDecode(request.body) as Map<String,dynamic>;final header=request.headers['X-LifeOS-Operation']??request.headers['x-lifeos-operation'];if(header!=null)context=jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(header)))) as Map<String,dynamic>;}
    final response=await super.send(request);
    if(context!=null)operations.add({'operation':body!['operation'],'operationId':context['operationId'],'bodyHash':context['bodyHash'],'status':response.statusCode});
    if(forgeAck && body?['operation'].toString().startsWith('update_habit')==true && response.statusCode==200){
      final header=response.headers['x-lifeos-operation-ack'];if(header==null)throw StateError('REAL_SERVER_ACK_REQUIRED');
      final value=jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(header)))) as Map<String,dynamic>;value['operationId']='0'*64;
      final bytes=await response.stream.toBytes();faultsApplied++;
      return http.StreamedResponse(Stream<List<int>>.value(bytes),response.statusCode,headers:{...response.headers,'x-lifeos-operation-ack':base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=','')});
    }
    return response;
  }
}
class GatedStore extends ProtocolStore {
  GatedStore(super.auth,super.host);String? delayedPath;
  final readStarted=Completer<void>(),releaseRead=Completer<void>();
  @override Future<http.Response> fetch(String path,{Map<String,Object?>? update})async{
    final hold=path==delayedPath&&update==null;if(hold)delayedPath=null;
    final response=await super.fetch(path,update:update);
    if(hold){readStarted.complete();await releaseRead.future;}
    return response;
  }
}

void main(){
  NetworkBinding();
  testWidgets('actual Auth UI registers/logs in, enters Home, creates/syncs Task and restores without adopting A into B',(tester)async{
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() { WidgetController.hitTestWarningShouldBeFatal = false; });
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() async {
      final loader = FontLoader('Roboto')..addFont(Future.value(ByteData.sublistView(File('C:/src/flutter/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf').readAsBytesSync())));
      await loader.load();
      final icons=FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(File('C:/src/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf').readAsBytesSync())));await icons.load();
    });
    tester.view.physicalSize=const Size(1100,1000);tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
    final fixture=jsonDecode(File(Platform.environment['P1_FUNCTIONAL_FIXTURE']!).readAsStringSync()) as Map<String,dynamic>,phase=Platform.environment['P1_FUNCTIONAL_PHASE']!;
    final authHost=fixture['authHost'] as String,storeHost=fixture['firestoreHost'] as String,base=Uri.parse(fixture['baseUrl'] as String);
    final client=FaultClient({authHost,storeHost,base.authority});
    // One strict client for every protocol request; never minted claims/origins.
    final liveAuth=ProtocolAuth(client,authHost);
    final liveStore=GatedStore(liveAuth,storeHost);
    final runtime=await tester.runAsync(()=>EmulatorAccountRuntime.configure(enabledModules:const {'tasks','habits','finance','goals','study','health','focus','checkin','notifications'},auth:liveAuth,store:liveStore,authPort:int.parse(authHost.split(':')[1]),firestorePort:int.parse(storeHost.split(':')[1]),baseUri:base,client:client,appCheckToken:()async=>'synthetic-app-check-port'));
    String uidA='';
    List<SyncQueueTableData> retainedRows=[];
    final stateFile=File(fixture['sessionFile'] as String),trace=<String>[];
    if(phase=='restart'){
      final state=jsonDecode(stateFile.readAsStringSync()) as Map<String,dynamic>;
      final response=await tester.runAsync(()=>client.post(Uri.parse('http://$authHost/securetoken.googleapis.com/v1/token?key=demo-key'),headers:{'Content-Type':'application/json'},body:jsonEncode({'grant_type':'refresh_token','refresh_token':state['refreshToken']})));
      expect(response!.statusCode,200);final data=jsonDecode(response.body) as Map<String,dynamic>;
      uidA=state['uid'] as String;
      liveAuth.person=Person(liveAuth,{'localId':data['user_id'],'idToken':data['id_token'],'refreshToken':data['refresh_token'],'email':'ui-a@example.invalid'});
    }
    final poison=<String>[];
    Never closed(String family){poison.add(family);throw StateError('UNREVIEWED_CONSUMER_STARTED:$family');}
    final container=ProviderContainer(overrides:[
      emulatorAccountRuntimeProvider.overrideWithValue(runtime),
      onboardingCompletionStoreProvider.overrideWithValue(IntroStore(File('${fixture['databaseDir']}/intro.completed'))),
      activeCircleIdForFocusProvider.overrideWith((ref)=>closed('circle-focus')),
      notificationServiceProvider.overrideWith((ref)=>closed('native-notification-provider')),
      notificationEngineProvider.overrideWith(()=>closed('notification-engine')),
      analyticsServiceProvider.overrideWith((ref)=>closed('analytics')),
      firebaseAuthProvider.overrideWithValue(liveAuth),firestoreProvider.overrideWithValue(liveStore),
      accountRemoteDataSourceProvider.overrideWithValue(NoDeletion()),
      userDatabaseFactoryProvider.overrideWithValue(FileFactory(Directory(fixture['databaseDir'] as String))),
      homeStateProvider.overrideWith((ref)=>closed('dashboard')),
      premiumProvider.overrideWith(()=>closed('premium')),
      cycleReminderActionBootstrapProvider.overrideWith((ref)=>closed('cycle')),
      notificationBootstrapCoordinatorProvider.overrideWith((ref)=>closed('notifications')),
      waterV2ProcessorProvider.overrideWith((ref)=>closed('water')),
    ]);
    final extraState=phase=='restart'?jsonDecode(stateFile.readAsStringSync()) as Map<String,dynamic>:<String,dynamic>{};
    Future<void>? lateRead;LocalAccountLease? lateReadLease;
    final nativeCalls=<String>[];
    for(final channel in ['dexterous.com/flutter/local_notifications','flutter_timezone']) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(MethodChannel(channel),(call)async{nativeCalls.add('$channel:${call.method}');throw StateError('NATIVE_OPERATION_CLOSED');});
      addTearDown(()=>tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(MethodChannel(channel),null));
    }
    final router=container.read(routerProvider);
    if(phase=='initial')router.go('/onboarding');
    const boundaryKey=ValueKey('ui-evidence');
    await tester.pumpWidget(UncontrolledProviderScope(container:container,child:const RepaintBoundary(key:boundaryKey,child:LifeOSApp())));
    Future<void> until(bool Function() ready,String label)async{
      debugPrint('UI_PHASE:$phase:$label');
      for(var i=0;i<650;i++){
        await tester.pump(const Duration(milliseconds:40));
        if(ready())return;
        await tester.runAsync(()=>Future<void>.delayed(const Duration(milliseconds:35)));
        final error=tester.takeException();if(error!=null)throw StateError('UI_ERROR:$label:$error');
      }
      throw StateError('UI_TIMEOUT:$label:${container.read(authNotifierProvider).runtimeType}');
    }
    Future<T> drive<T>(Future<T> Function() action) async {
      var done = false; T? value; Object? failure;
      action().then((v) { value=v; done=true; }, onError:(Object e) {failure=e;done=true;});
      await until(()=>done,'async operation completed');
      if(failure!=null)throw failure!;return value as T;
    }
    Future<void> screenshot(String name)async{
      await tester.pump(const Duration(milliseconds:700));
      await tester.runAsync(() async {
      final boundary=tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey)),image=await boundary.toImage(pixelRatio:1),bytes=await image.toByteData(format:ui.ImageByteFormat.png);
      File('${fixture['resultDir']}/$phase-$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());image.dispose();
      });
    }
    Future<void> home()async{await until(()=>find.text('Abrir tarefas').hitTestable().evaluate().isNotEmpty,'Home');expect(container.read(authNotifierProvider),isA<AuthAuthenticated>());await tester.pump(const Duration(milliseconds:700));}
    Future<void> register(String email,String name)async{
      await until(()=>find.text('Inicializar Conta').evaluate().isNotEmpty,'register');
      await tester.pump(const Duration(milliseconds:700));final fields=find.descendant(of:find.byType(RegisterScreen),matching:find.byType(TextFormField));await tester.enterText(fields.at(0),name);await tester.enterText(fields.at(1),email);await tester.enterText(fields.at(2),'Synthetic-only-19!');
      await tester.ensureVisible(find.text('Inicializar Conta'));await tester.tap(find.text('Inicializar Conta').hitTestable());await tester.pump();expect(find.text('O e-mail é obrigatório'),findsNothing);expect(find.text('Mínimo de 6 dígitos'),findsNothing);await home();
    }
    Future<void> logout()async{await tester.tap(find.text('Sair').hitTestable());await until(()=>find.text('Acessar Sistema').evaluate().isNotEmpty,'logout/login');}
    Future<void> tasks()async{await tester.tap(find.text('Abrir tarefas'));await until(()=>find.byIcon(Icons.add_rounded).hitTestable().evaluate().isNotEmpty,'Tasks');await until(()=>container.read(tasksStreamProvider).hasValue,'Tasks stream ready');}
    Future<void> createTask(String title)async{
      await tester.tap(find.byIcon(Icons.add_rounded));await until(()=>find.text('Nova Tarefa Focada').evaluate().isNotEmpty,'new Task');
      await tester.pump(const Duration(milliseconds:700));await tester.enterText(find.byType(TextField).last,title);await tester.pump(const Duration(milliseconds:300));await tester.ensureVisible(find.text('Adicionar à Rotina'));await until(()=>find.text('Adicionar à Rotina').hitTestable().evaluate().isNotEmpty,'Task submit visible');await tester.tap(find.text('Adicionar à Rotina').hitTestable());
      await until(()=>find.text(title).evaluate().isNotEmpty && find.text('Adicionar à Rotina').evaluate().isEmpty,'persisted Task');
    }
    Future<void> tapVisible(Finder target) async {
      await until(()=>target.evaluate().isNotEmpty,'action rendered');
      await tester.ensureVisible(target);await tester.pump(const Duration(milliseconds:700));
      await until(()=>target.hitTestable().evaluate().isNotEmpty,'action hit-testable');await tester.tap(target.hitTestable());
    }
    Future<void> openModule(String module)async{
      await tapVisible(find.widgetWithText(TextButton,'Home'));
      await home();await tapVisible(find.byKey(ValueKey('open-$module')));
      await tester.pump(const Duration(milliseconds:700));
      await until(()=>switch(module){'habits'=>container.read(habitsStreamProvider).hasValue,'finance'=>container.read(financeStreamProvider).hasValue,'goals'=>container.read(goalsStreamProvider).hasValue,'tasks'=>container.read(tasksStreamProvider).hasValue,'study'=>container.read(studyStreamProvider).hasValue&&container.read(subjectsStreamProvider).hasValue,'health'=>container.read(medicationsStreamProvider).hasValue,_=>true},'module stream $module');
      await tester.pump(const Duration(milliseconds:700));
    }
    Future<void> drain()async{
      for(var i=0;i<50;i++){
        await drive(()=>container.read(syncManagerProvider).processPendingItems());
        final rows=await drive(()=>container.read(databaseProvider).getPendingSyncItems(liveAuth.currentUser!.uid));
        if(rows.isEmpty)return;
        await tester.runAsync(()=>Future<void>.delayed(const Duration(milliseconds:60)));await tester.pump();
      }
      final rows=await drive(()=>container.read(databaseProvider).getPendingSyncItems(liveAuth.currentUser!.uid));
      fail('Pending original rows: ${rows.map((r)=>[r.collection,r.operationType,r.lastErrorCode]).toList()}');
    }
    Future<void> habit(String title)async{
      await openModule('habits');await until(()=>container.read(habitsStreamProvider).hasValue,'Habits stream');
      await tapVisible(find.byType(FloatingActionButton));await tester.pump(const Duration(milliseconds:700));
      await tester.enterText(find.byType(TextField).last,title);await tapVisible(find.text('Criar hábito'));
      await until(()=>find.text(title).evaluate().isNotEmpty&&find.text('Criar hábito').evaluate().isEmpty,'Habit persisted');
    }
    Future<void> finance(String title)async{
      await openModule('finance');await until(()=>container.read(financeStreamProvider).hasValue,'Finance stream');
      await tapVisible(find.byType(FloatingActionButton));await tester.pump(const Duration(milliseconds:700));
      final fields=find.descendant(of:find.byType(BottomSheet),matching:find.byType(TextField));
      await tester.enterText(fields.at(0),title);await tester.enterText(fields.at(1),'12,34');
      await tapVisible(find.byKey(const ValueKey('create-category-Alimentação')));await tapVisible(find.text('Confirmar lançamento'));
      await until(()=>find.text(title).evaluate().isNotEmpty&&find.text('Nova transação').evaluate().isEmpty,'Finance persisted');
    }
    Future<void> goal(String title)async{
      await openModule('goals');await until(()=>container.read(goalsStreamProvider).hasValue,'Goals stream');
      await tapVisible(find.byType(FloatingActionButton));await tester.pump(const Duration(milliseconds:700));
      final fields=find.descendant(of:find.byType(BottomSheet),matching:find.byType(TextField));
      await tester.enterText(fields.at(0),title);await tester.enterText(fields.at(1),'3');await tapVisible(find.text('Criar meta'));
      await until(()=>find.text(title).evaluate().isNotEmpty&&find.text('Criar meta').evaluate().isEmpty,'Goal persisted');
    }
    Future<void> toggleNamedHabit(String title)async{
      final row=find.ancestor(of:find.text(title),matching:find.byType(Row)).first;
      await tapVisible(find.descendant(of:row,matching:find.byType(InkWell)).first);
    }
    Future<void> addCard(String question,String answer)async{
      await openModule('study');await tapVisible(find.text('Adicionar novo flashcard'));await until(()=>find.text('Novo Flashcard').evaluate().isNotEmpty,'flashcard form');await tester.pump(const Duration(milliseconds:700));
      await tapVisible(find.byType(DropdownButton<String>));await tester.pump(const Duration(milliseconds:700));await tapVisible(find.text('UI disciplina A').last);
      final fields=find.descendant(of:find.byType(BottomSheet),matching:find.byType(TextField));await tester.enterText(fields.at(0),question);await tester.enterText(fields.at(1),answer);
      await tapVisible(find.text('Criar Flashcard'));await until(()=>find.text('Novo Flashcard').evaluate().isEmpty,'flashcard persisted');
    }
    Future<void> addMedication(String name)async{
      await openModule('health');await tapVisible(find.widgetWithText(FilledButton,'Adicionar medicamento'));await until(()=>find.byKey(const ValueKey('medication-name')).evaluate().isNotEmpty,'medication form');
      await tester.enterText(find.byKey(const ValueKey('medication-name')),name);await tester.enterText(find.byKey(const ValueKey('medication-duration')),'7');await tapVisible(find.widgetWithText(FilledButton,'Salvar medicamento'));
      await until(()=>find.byType(AlertDialog).evaluate().isEmpty&&find.text(name).evaluate().isNotEmpty,'medication persisted');
    }
    Future<void> saveCheckin()async{
      await openModule('checkin');await until(()=>find.byType(Slider).evaluate().length==3,'Check-in form');await tester.drag(find.byType(Slider).first,const Offset(77,0));await tester.pump();
      final values=find.byType(Slider).evaluate().map((e)=>(e.widget as Slider).value).toList();
      await tapVisible(find.text('Registrar Métricas'));await until(()=>find.text('Check-in salvo.').evaluate().isNotEmpty,'Check-in saved locally');
      final rows=await drive(()=>container.read(databaseProvider).select(container.read(databaseProvider).checkInTable).get());expect(rows.length,1);expect([rows.single.energy,rows.single.focus,rows.single.motivation],values);extraState['checkin']=values;
    }
    Future<void> initialEssentials()async{
      await openModule('study');await tapVisible(find.byTooltip('Adicionar disciplina'));await until(()=>find.text('Nova disciplina').evaluate().isNotEmpty,'subject form');await tester.pump(const Duration(milliseconds:700));
      await tester.enterText(find.descendant(of:find.byType(BottomSheet),matching:find.byType(TextField)).first,'UI disciplina A');await tapVisible(find.text('Adicionar Disciplina'));await until(()=>find.text('Nova disciplina').evaluate().isEmpty&&find.text('UI disciplina A').evaluate().isNotEmpty,'subject persisted');await drain();
      await addCard('Pergunta UI','Resposta UI');await drain();final db=container.read(databaseProvider);final stats=(await drive(()=>db.select(db.studyStats).get())).single;expect(stats.reviewQueue,1);expect((await drive(()=>db.select(db.subjects).get())).single.cardsToReview,1);await screenshot('study');
      await addMedication('UI medicamento A');await drain();await screenshot('health');
      await saveCheckin();await drain();expect((await drive(()=>db.select(db.checkInTable).get())).single.isSynced,true);await screenshot('checkin');
      final saved=jsonDecode(stateFile.readAsStringSync()) as Map<String,dynamic>;stateFile.writeAsStringSync(jsonEncode({...saved,...extraState}));
      trace.add('Study-subject-card-F01-medication-and-Checkin-real-UI-and-ACK');
    }
    Future<void> restoreEssentials()async{
      await openModule('study');expect(find.text('UI disciplina A'),findsOneWidget);final db=container.read(databaseProvider);expect((await drive(()=>db.select(db.flashcards).get())).single.question,'Pergunta UI');
      await openModule('health');expect(find.text('UI medicamento A'),findsOneWidget);
      await openModule('checkin');await until(()=>container.read(checkInHistoryProvider).hasValue,'restored Check-in');final entry=(await drive(()=>db.select(db.checkInTable).get())).single;expect([entry.energy,entry.focus,entry.motivation],extraState['checkin']);expect(find.byKey(const ValueKey('checkin-history')),findsOneWidget);
      trace.add('Study-Health-Checkin-restored-in-new-Flutter-process');
    }
    Future<void> offlineEssentials()async{
      await addCard('Pergunta offline','Resposta offline');await addMedication('Offline medicamento');await saveCheckin();
    }
    Future<void> forgedAckMustStayPending()async{
      await openModule('habits');client.forgeAck=true;await toggleNamedHabit('Offline hábito');
      expect(await drive(()=>container.read(syncManagerProvider).processPendingItems()),false);
      final db=container.read(databaseProvider),pending=await drive(()=>db.getPendingSyncItems(liveAuth.currentUser!.uid));expect(pending.length,1);final original=pending.single as SyncQueueTableData;expect(original.collection,'habits');expect(original.isSynced,false);expect(original.status,'pending');expect(client.faultsApplied,greaterThan(0));
      final intents=await drive(()=>db.customSelect('SELECT operation_id,phase FROM generational_http_intents_v1 WHERE sync_id = ?',variables:[Variable<int>(original.id)]).get());expect(intents.single.read<String>('phase'),'PENDING');final operationId=intents.single.read<String>('operation_id');
      client.forgeAck=false;await drain();final row=(await drive(()=>(db.select(db.syncQueueTable)..where((q)=>q.id.equals(original.id))).get())).single;expect(row.payloadJson,original.payloadJson);expect(row.isSynced,true);
      final attempts=client.operations.where((o)=>o['operationId']==operationId).toList();expect(attempts.length,greaterThanOrEqualTo(2));expect(attempts.map((o)=>o['bodyHash']).toSet().length,1);
      trace.add('forged-ACK-after-real-commit-rejected-original-intent-replayed');
      lateReadLease=container.read(localAccountSessionProvider.notifier).capture();liveStore.delayedPath='users/${liveAuth.currentUser!.uid}/habits';lateRead=container.read(habitsRepositoryProvider).syncHabitsFromFirebaseToLocal();await drive(()=>liveStore.readStarted.future);
    }
    Future<void> assertExtraBIsolation()async{
      final db=container.read(databaseProvider);
      await openModule('study');expect(find.text('UI disciplina A'),findsNothing);expect(await drive(()=>db.select(db.subjects).get()),isEmpty);expect(await drive(()=>db.select(db.flashcards).get()),isEmpty);
      await openModule('health');expect(find.text('UI medicamento A'),findsNothing);expect(find.text('Offline medicamento'),findsNothing);expect(await drive(()=>db.select(db.medications).get()),isEmpty);
      await openModule('checkin');await until(()=>container.read(checkInHistoryProvider).hasValue,'B Check-in history');expect(await drive(()=>db.select(db.checkInTable).get()),isEmpty);
      await openModule('notifications');await until(()=>container.read(localNotificationInboxProvider).hasValue,'B inbox');expect(find.text('Aviso derivado A'),findsNothing);
      await openModule('focus');expect(container.read(focusProvider).activeTargetId,isNull);expect(container.read(focusProvider).isRunning,false);
      for(final family in ['subjects','review_queue','medications','checkins','notifications'])await drive(()async{await expectLater(liveStore.fetch('users/$uidA/$family'),throwsA(predicate((e)=>e.toString().contains('[cloud_firestore/permission-denied]'))));});
      trace.add('B-isolation-all-essential-families-and-old-Focus-timer');
    }
    Future<void> finishEssentialsAfterAReturn()async{
      expect(liveAuth.currentUser!.uid,uidA);expect(()=>lateReadLease!.requireCurrent(),throwsStateError);liveStore.releaseRead.complete();await drive(()=>lateRead!);
      trace.add('late-A-server-snapshot-after-A-B-A-never-admitted');
      await openModule('study');await tapVisible(find.text('Revisar agora'));await until(()=>find.text('Ver resposta').evaluate().isNotEmpty,'review page');await tapVisible(find.text('Ver resposta'));await tapVisible(find.text('Marcar como revisado'));await until(()=>find.text('1 revisão restante').evaluate().isNotEmpty,'review local');await drain();
      final db=container.read(databaseProvider),stats=(await drive(()=>db.select(db.studyStats).get())).single;expect(stats.reviewQueue,1);expect(stats.progress,closeTo(0.05,1e-12));expect((await drive(()=>db.select(db.subjects).get())).single.cardsToReview,1);await tapVisible(find.widgetWithText(TextButton,'Home'));await home();
      await openModule('focus');await tapVisible(find.text('NENHUM ALVO SELECIONADO'));await until(()=>find.text('UI tarefa A').evaluate().isNotEmpty,'Focus target');await tapVisible(find.text('UI tarefa A'));await until(()=>find.byIcon(Icons.play_arrow_rounded).evaluate().isNotEmpty,'Focus timer');await tapVisible(find.byIcon(Icons.play_arrow_rounded));await until(()=>container.read(focusProvider).isRunning&&container.read(focusProvider).isVerified,'real verified Focus start');await screenshot('focus');await tapVisible(find.text('Redefinir sessão'));
      var cancelled=false;for(var i=0;i<50;i++){final rows=await drive(()=>db.customSelect("SELECT phase FROM generational_http_intents_v1 WHERE route='focus/cancel'").get());if(rows.any((r)=>r.read<String>('phase')=='CONFIRMED')){cancelled=true;break;}await tester.runAsync(()=>Future<void>.delayed(const Duration(milliseconds:35)));}expect(cancelled,true);expect(container.read(focusProvider).isRunning,false);expect(container.read(focusProvider).isVerified,false);
      await openModule('notifications');await until(()=>find.text('Aviso derivado A').evaluate().isNotEmpty,'admitted inbox read');await screenshot('notifications');await tapVisible(find.text('Dispensar'));await until(()=>find.text('Aviso derivado A').evaluate().isEmpty,'notification locally dismissed');await drain();
      await openModule('health');for(var i=0;i<2;i++){await tapVisible(find.byTooltip('Excluir medicamento').first);await drain();await tester.pump(const Duration(milliseconds:700));}expect(await drive(()=>db.select(db.medications).get()),isEmpty);
      trace.add('F01-review-Focus-start-cancel-inbox-dismiss-and-medication-delete');
    }

    Future<void> initialModules()async{
      await habit('UI hábito A');await toggleNamedHabit('UI hábito A');await until(()=>find.text('Feito hoje').evaluate().isNotEmpty,'Habit updated');await drain();await screenshot('habits');
      await finance('UI finanças A');await drain();await screenshot('finance');
      await goal('UI meta A');await tapVisible(find.byIcon(Icons.add_rounded).first);await until(()=>find.text('1 / 3').evaluate().isNotEmpty,'Goal updated');await drain();await screenshot('goals');
      trace.add('Habits-Finance-Goals-real-UI-create-update-and-original-ACK');await initialEssentials();
    }
    Future<void> restoreAndOfflineModules()async{
      for(final entry in {'habits':'UI hábito A','finance':'UI finanças A','goals':'UI meta A'}.entries){
        await openModule(entry.key);await until(()=>find.text(entry.value).evaluate().isNotEmpty,'restored ${entry.key}');
      }
      await openModule('goals');expect(find.text('1 / 3'),findsOneWidget);
      await restoreEssentials();client.online=false;
      await habit('Offline hábito');await finance('Offline finanças');
      await openModule('goals');await tapVisible(find.byIcon(Icons.add_rounded).first);await until(()=>find.text('2 / 3').evaluate().isNotEmpty,'Goal offline');await offlineEssentials();
      final pending=await drive(()=>container.read(databaseProvider).getPendingSyncItems(liveAuth.currentUser!.uid));
      expect(pending.map((r)=>r.collection).toSet(),containsAll(['habits','transactions','goals','review_queue','medications','checkins']));
      final ids=pending.map((r)=>r.id).toSet();client.online=true;await drain();
      final db=container.read(databaseProvider),rows=await drive(()=>db.select(db.syncQueueTable).get());
      for(final row in rows.where((r)=>ids.contains(r.id))){expect(row.isSynced,true);expect(row.status,'succeeded');}
      expect(rows.where((r)=>ids.contains(r.id)).length,ids.length);
      trace.add('six-families-restart-offline-and-original-row-replay');await forgedAckMustStayPending();
      client.online=false;
      await openModule('habits');await toggleNamedHabit('UI hábito A');
      await finance('Pendência A');await openModule('goals');await tapVisible(find.byIcon(Icons.add_rounded).first);
      await until(()=>find.text('3 / 3').evaluate().isNotEmpty,'pending Goal before logout');
    }
    Future<void> assertBModulesIsolated()async{
      for(final entry in {'habits':'UI hábito A','finance':'UI finanças A','goals':'UI meta A'}.entries){await openModule(entry.key);await tester.pump(const Duration(milliseconds:500));expect(find.text(entry.value),findsNothing);}
      final db=container.read(databaseProvider);
      expect(await drive(()=>db.select(db.habits).get()),isEmpty);expect(await drive(()=>db.select(db.transactions).get()),isEmpty);expect(await drive(()=>db.select(db.goals).get()),isEmpty);
      for(final family in ['habits','transactions','goals'])await drive(()async{await expectLater(liveStore.fetch('users/$uidA/$family'),throwsA(predicate((e)=>e.toString().contains('[cloud_firestore/permission-denied]'))));});
      trace.add('B-isolation-three-families-DB-UI-and-Rules');await assertExtraBIsolation();
    }
    Future<void> returnAToReplayAndDelete()async{
      await logout();await tester.pump(const Duration(milliseconds:700));final fields=find.byType(TextFormField);
      await tester.enterText(fields.at(0),'ui-a@example.invalid');await tester.enterText(fields.at(1),'Synthetic-only-19!');await tapVisible(find.text('Acessar Sistema'));await home();
      await drain();final db=container.read(databaseProvider);expect(db.identity!.uid,uidA);
      final rows=await drive(()=>db.select(db.syncQueueTable).get());
      for(final original in retainedRows){final matches=rows.where((r)=>r.id==original.id).toList();expect(matches.length,1);expect(matches.single.payloadJson,original.payloadJson);expect(matches.single.isSynced,true);expect(matches.single.status,'succeeded');}
      trace.add('A-relogin-replays-the-identical-preserved-rows');await finishEssentialsAfterAReturn();
      for(final entry in {'habits':'Excluir hábito','finance':'Excluir transação','goals':'Excluir meta'}.entries){
        await openModule(entry.key);
        for(var i=0;i<1 && find.byTooltip(entry.value).evaluate().isNotEmpty;i++){
          await tapVisible(find.byTooltip(entry.value).first);await until(()=>find.byType(AlertDialog).evaluate().isNotEmpty,'delete dialog');
          await tapVisible(find.descendant(of:find.byType(AlertDialog),matching:find.text('Excluir')));
          await until(()=>find.byType(AlertDialog).evaluate().isEmpty,'delete persisted');await drain();await tester.pump(const Duration(milliseconds:700));
        }
      }
      expect((await drive(()=>db.select(db.habits).get())).length,1);expect((await drive(()=>db.select(db.transactions).get())).length,2);expect(await drive(()=>db.select(db.goals).get()),isEmpty);
      trace.add('Habits-Finance-Goals-UI-delete-and-real-ACK');
      await logout();
    }

    if(phase=='initial'){
      await until(()=>find.text('Continuar').hitTestable().evaluate().isNotEmpty,'Onboarding');await tester.tap(find.text('Continuar').hitTestable());
      await until(()=>find.text('Crie uma agora').hitTestable().evaluate().isNotEmpty,'Login entry');await tester.tap(find.text('Crie uma agora').hitTestable());
      trace.add('Onboarding-continues-with-analytics-CLOSED');
      await until(()=>find.text('Inicializar Conta').evaluate().isNotEmpty,'registration screen');await screenshot('register');
      await register('ui-a@example.invalid','UI A');trace.add('RegisterScreen-real-register-to-Home');
      await logout();final fields=find.byType(TextFormField);await tester.enterText(fields.at(0),'ui-a@example.invalid');await tester.enterText(fields.at(1),'Synthetic-only-19!');
      await tester.tap(find.text('Acessar Sistema'));await home();trace.add('LoginScreen-real-login-to-Home');
      await screenshot('home');await tasks();await createTask('UI tarefa A');
      for(var i=0;i<200;i++){
        final pending=await drive(()=>container.read(databaseProvider).getPendingSyncItems(liveAuth.currentUser!.uid));if(pending.isEmpty)break;
        await tester.runAsync(()=>Future<void>.delayed(const Duration(milliseconds:40)));await tester.pump();
      }
      expect(await drive(()=>container.read(databaseProvider).getPendingSyncItems(liveAuth.currentUser!.uid)),isEmpty);
      final task=(await drive(()=>container.read(databaseProvider).select(container.read(databaseProvider).taskTable).get())).single;
      stateFile.writeAsStringSync(jsonEncode({'uid':liveAuth.person!.uid,'taskId':task.id,'refreshToken':liveAuth.person!.value['refreshToken']}));
      await screenshot('task');trace.add('TasksScreen-create-to-genuine-HTTP-ACK');await initialModules();
    }else{
      await home();await tasks();await until(()=>find.text('UI tarefa A').evaluate().isNotEmpty,'task restored');trace.add('new-Flutter-process-restores-Home-and-Task');
      await screenshot('restored-task');
      for(final route in ['/health/cycle','/settings','/circles','/ai-companion','/analytics']){
        router.go(route);await until(()=>find.text('Este módulo aguarda homologação.').evaluate().isNotEmpty,'family closed');
      }
      trace.add('unreviewed-routes-CLOSED-before-consumers');
      await restoreAndOfflineModules();router.go('/home');await home();await tasks();client.online=false;await createTask('Pendente de A');
      final aFile=container.read(databaseProvider).identity!.fileIn(Directory(fixture['databaseDir'] as String));
      final uid=liveAuth.currentUser!.uid,oldLease=container.read(localAccountSessionProvider.notifier).capture();
      expect((await drive(()=>container.read(databaseProvider).getPendingSyncItems(uid))).isNotEmpty,true);
      retainedRows=await drive(()=>container.read(databaseProvider).getPendingSyncItems(uid).then((rows)=>rows.cast<SyncQueueTableData>()));
      await logout();expect(()=>oldLease.requireCurrent(),throwsStateError);client.online=true;
      await tester.tap(find.text('Crie uma agora'));await register('ui-b@example.invalid','UI B');await tasks();
      await assertBModulesIsolated();await openModule('tasks');
      expect(find.text('UI tarefa A'),findsNothing);expect(find.text('Pendente de A'),findsNothing);
      expect(await drive(()=>container.read(databaseProvider).select(container.read(databaseProvider).taskTable).get()),isEmpty);
      await drive(()async {await expectLater(liveStore.fetch('users/$uid/tasks'),throwsA(predicate((e)=>e.toString().contains('[cloud_firestore/permission-denied]'))));});
      File('${fixture['resultDir']}/identities.json').writeAsStringSync(jsonEncode({'A':uid,'B':liveAuth.currentUser!.uid,'taskId':(jsonDecode(stateFile.readAsStringSync()) as Map)['taskId']}));
      final check=sqlite3.open(aFile.path,mode:OpenMode.readOnly);
      try { expect(check.select('SELECT COUNT(*) AS n FROM sync_queue_table WHERE owner_uid = ? AND is_synced = 0',[uid]).single['n'],4); } finally {check.dispose();}
      trace.add('UI-logout-preserves-intent-B-login-does-not-adopt-A');await screenshot('B-isolated');await returnAToReplayAndDelete();
    }
    expect(nativeCalls,isEmpty);
    File('${fixture['resultDir']}/$phase-protocol.json').writeAsStringSync(jsonEncode({'nativeCalls':nativeCalls,'forgedAcksRejected':client.faultsApplied,'operations':client.operations}));
    expect(poison,isEmpty);expect(tester.takeException(),isNull);
    File('${fixture['resultDir']}/$phase-trace.json').writeAsStringSync(jsonEncode({'phase':phase,'steps':trace,'forbiddenConsumersStarted':poison,'nativeSdk':false,'productionActivated':false}));
    final coordinator=container.read(sessionDatabaseCoordinatorProvider);
    final stopUid=liveAuth.currentUser?.uid;
    if(stopUid!=null && coordinator.attachedDatabase!=null) {
      expect(await drive(()=>container.read(syncManagerProvider).prepareForSessionDetach(stopUid)),true);
      container.read(localAccountSessionProvider.notifier).clear();
    }
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose(); // Cancel provider streams before closing their database.
    await drive(()=>coordinator.dispose());
    await drive(()=>liveAuth.events.close());client.close();
  },timeout:const Timeout(Duration(seconds:180)));
}
