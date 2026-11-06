// ignore_for_file: subtype_of_sealed_class, must_be_immutable, invalid_use_of_visible_for_testing_member
import 'dart:convert';
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
    final client=LocalClient({authHost,storeHost,base.authority});
    // One strict client for every protocol request; never minted claims/origins.
    final liveAuth=ProtocolAuth(client,authHost);
    final liveStore=ProtocolStore(liveAuth,storeHost);
    final runtime=await tester.runAsync(()=>EmulatorAccountRuntime.configure(enabledModules:const {'tasks','habits','finance','goals'},auth:liveAuth,store:liveStore,authPort:int.parse(authHost.split(':')[1]),firestorePort:int.parse(storeHost.split(':')[1]),baseUri:base,client:client,appCheckToken:()async=>'synthetic-app-check-port'));
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
      await until(()=>switch(module){'habits'=>container.read(habitsStreamProvider).hasValue,'finance'=>container.read(financeStreamProvider).hasValue,'goals'=>container.read(goalsStreamProvider).hasValue,'tasks'=>container.read(tasksStreamProvider).hasValue,_=>true},'module stream $module');
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
    Future<void> initialModules()async{
      await habit('UI hábito A');await toggleNamedHabit('UI hábito A');await until(()=>find.text('Feito hoje').evaluate().isNotEmpty,'Habit updated');await drain();await screenshot('habits');
      await finance('UI finanças A');await drain();await screenshot('finance');
      await goal('UI meta A');await tapVisible(find.byIcon(Icons.add_rounded).first);await until(()=>find.text('1 / 3').evaluate().isNotEmpty,'Goal updated');await drain();await screenshot('goals');
      trace.add('Habits-Finance-Goals-real-UI-create-update-and-original-ACK');
    }
    Future<void> restoreAndOfflineModules()async{
      for(final entry in {'habits':'UI hábito A','finance':'UI finanças A','goals':'UI meta A'}.entries){
        await openModule(entry.key);await until(()=>find.text(entry.value).evaluate().isNotEmpty,'restored ${entry.key}');
      }
      await openModule('goals');expect(find.text('1 / 3'),findsOneWidget);
      client.online=false;
      await habit('Offline hábito');await finance('Offline finanças');
      await openModule('goals');await tapVisible(find.byIcon(Icons.add_rounded).first);await until(()=>find.text('2 / 3').evaluate().isNotEmpty,'Goal offline');
      final pending=await drive(()=>container.read(databaseProvider).getPendingSyncItems(liveAuth.currentUser!.uid));
      expect(pending.map((r)=>r.collection).toSet(),containsAll(['habits','transactions','goals']));
      final ids=pending.map((r)=>r.id).toSet();client.online=true;await drain();
      final db=container.read(databaseProvider),rows=await drive(()=>db.select(db.syncQueueTable).get());
      for(final row in rows.where((r)=>ids.contains(r.id))){expect(row.isSynced,true);expect(row.status,'succeeded');}
      expect(rows.where((r)=>ids.contains(r.id)).length,ids.length);
      trace.add('three-families-restart-offline-and-original-row-replay');
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
      trace.add('B-isolation-three-families-DB-UI-and-Rules');
    }
    Future<void> returnAToReplayAndDelete()async{
      await logout();await tester.pump(const Duration(milliseconds:700));final fields=find.byType(TextFormField);
      await tester.enterText(fields.at(0),'ui-a@example.invalid');await tester.enterText(fields.at(1),'Synthetic-only-19!');await tapVisible(find.text('Acessar Sistema'));await home();
      await drain();final db=container.read(databaseProvider);expect(db.identity!.uid,uidA);
      final rows=await drive(()=>db.select(db.syncQueueTable).get());
      for(final original in retainedRows){final matches=rows.where((r)=>r.id==original.id).toList();expect(matches.length,1);expect(matches.single.payloadJson,original.payloadJson);expect(matches.single.isSynced,true);expect(matches.single.status,'succeeded');}
      trace.add('A-relogin-replays-the-identical-preserved-rows');
      for(final entry in {'habits':'Excluir hábito','finance':'Excluir transação','goals':'Excluir meta'}.entries){
        await openModule(entry.key);
        for(var i=0;i<4 && find.byTooltip(entry.value).evaluate().isNotEmpty;i++){
          await tapVisible(find.byTooltip(entry.value).first);await until(()=>find.byType(AlertDialog).evaluate().isNotEmpty,'delete dialog');
          await tapVisible(find.descendant(of:find.byType(AlertDialog),matching:find.text('Excluir')));
          await until(()=>find.byType(AlertDialog).evaluate().isEmpty,'delete persisted');await drain();await tester.pump(const Duration(milliseconds:700));
        }
      }
      expect(await drive(()=>db.select(db.habits).get()),isEmpty);expect(await drive(()=>db.select(db.transactions).get()),isEmpty);expect(await drive(()=>db.select(db.goals).get()),isEmpty);
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
      for(final route in ['/health','/study','/focus','/notifications','/settings','/circles','/ai-companion']){
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
