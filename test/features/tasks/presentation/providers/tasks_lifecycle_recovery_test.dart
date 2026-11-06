// Local lifecycle tests; no Auth provenance, server grant or remote mocks.
// ignore_for_file: subtype_of_sealed_class, must_be_immutable
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/native.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/tasks/data/models/task_model.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_notifier.dart';
class NoStore extends Fake implements FirebaseFirestore {}
class UserA extends Fake implements User {@override String get uid=>'A';}
class LocalAuth extends Fake implements FirebaseAuth {@override User get currentUser=>UserA();}
class NoDatabase extends Fake implements AppDatabase {}
class StreamTasks extends TasksRepository {
  StreamTasks():super(NoDatabase(),NoStore(),LocalAuth());
  final controller=StreamController<List<TaskModel>>.broadcast(sync:true);
  @override Stream<List<TaskModel>> getTasksStream()=>controller.stream;
}
TaskModel task(String id)=>TaskModel(id:id,title:id,priority:'low',isCompleted:false,date:DateTime(2026));
void main(){
  test('Tasks notifier disposal cancels its account listener',()async{
    final source=StreamTasks(),container=ProviderContainer(overrides:[tasksRepositoryProvider.overrideWithValue(StreamTasks())]);
    container.updateOverrides([tasksRepositoryProvider.overrideWithValue(source)]);
    final listener=container.listen(tasksProvider,(_,_){});
    expect(source.controller.hasListener,true);
    source.controller.add([task('A')]);expect(container.read(tasksProvider).single.id,'A');
    listener.close();container.dispose();await pumpEventQueue();
    expect(source.controller.hasListener,false);await source.controller.close();
  });
  test('Tasks notifier follows repository cutover and never publishes A after B',()async{
    final a=StreamTasks(),b=StreamTasks(),container=ProviderContainer(overrides:[tasksRepositoryProvider.overrideWithValue(a)]);
    final listener=container.listen(tasksProvider,(_,_){});
    a.controller.add([task('A')]);expect(container.read(tasksProvider).single.id,'A');
    container.updateOverrides([tasksRepositoryProvider.overrideWithValue(b)]);await pumpEventQueue();
    container.read(tasksProvider);
    expect(a.controller.hasListener,false);expect(b.controller.hasListener,true);
    a.controller.add([task('A-late')]);b.controller.add([task('B')]);expect(container.read(tasksProvider).single.id,'B');
    listener.close();container.dispose();await a.controller.close();await b.controller.close();
  });
  test('rapid concurrent Tasks create distinct durable local intents',()async{
    final database=AppDatabase(executor:NativeDatabase.memory()),auth=LocalAuth(),repository=TasksRepository(database,NoStore(),auth);
    addTearDown(database.closeDatabase);
    await Future.wait(List.generate(12,(i)=>repository.addTask('Task $i','low')));
    final tasks=await database.select(database.taskTable).get(),queue=await database.getPendingSyncItems('A');
    expect(tasks.length,12);expect(tasks.map((t)=>t.id).toSet().length,12);expect(queue.length,12);
    expect(queue.map((q)=>(q as SyncQueueTableData).docId).toSet(),tasks.map((t)=>t.id).toSet());
  });
}
