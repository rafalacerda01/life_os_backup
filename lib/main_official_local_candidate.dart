import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_device_session.dart';
import 'package:life_os/core/database/local_installation_storage_inspector.dart';
import 'package:life_os/features/tasks/data/services/local_task_reminder.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'main_local.dart'
    show LocalFirstDevelopmentApp, prepareLocalDeviceSession;

const _host = MethodChannel('lifeos.official_local_candidate');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _StartupMessage('Verificando armazenamento local…'));
  unawaited(_start());
}

Future<void> _start() async {
  LocalDeviceSession? session;
  try {
    if (!Platform.isAndroid || kReleaseMode) {
      throw StateError('OFFICIAL_LOCAL_ANDROID_CANDIDATE_REQUIRED');
    }
    final admission = await _host.invokeMapMethod<String, Object?>('admission');
    final epoch = admission?['epoch'];
    final uid = admission?['uid'];
    final namespace = admission?['namespace'];
    if (epoch is! int ||
        epoch < 1 ||
        (uid == null && namespace != null) ||
        (uid != null &&
            (uid is! String ||
                !LocalDatabaseIdentity.isValidLocalInstallationId(uid) ||
                LocalDatabaseIdentity(uid).namespace != namespace))) {
      throw StateError('OFFICIAL_LOCAL_ADMISSION_INVALID');
    }
    session = await prepareLocalDeviceSession(
      inspector: LocalInstallationStorageInspector(
        documentsDirectory: getApplicationDocumentsDirectory,
        supportDirectory: getApplicationSupportDirectory,
        allowOfficialStartupCoordinator: true,
      ),
      expectedInstallationId: uid as String?,
    );
    final identity = session.requirePrepared().identity!;
    if (!identical(
      await _host.invokeMethod<bool>('opened', {
        'uid': identity.uid,
        'namespace': identity.namespace,
      }),
      true,
    )) {
      throw StateError('OFFICIAL_LOCAL_ADMISSION_UNATTESTED');
    }
    runApp(
      LocalFirstDevelopmentApp(
        session: session,
        taskReminder: const _NativeTaskReminder(),
      ),
    );
  } catch (_) {
    try {
      await session?.dispose();
    } finally {
      debugPrint('LIFE_OS_DART_STARTUP_DENIED');
      runApp(const _StartupMessage('Abertura local bloqueada.'));
    }
  }
}

class _NativeTaskReminder implements TaskReminder {
  const _NativeTaskReminder();

  @override
  Future<TaskReminderStatus> status() async {
    final status = await _host.invokeMapMethod<String, Object?>(
      'reminderStatus',
    );
    return (
      minuteOfDay: status!['minute'] as int?,
      needsRecovery: status['needsRecovery'] as bool,
    );
  }

  @override
  Future<bool> create(int minuteOfDay) async {
    if (!(await Permission.notification.request()).isGranted) return false;
    return await _host.invokeMethod<bool>('createReminder', minuteOfDay) ==
        true;
  }

  @override
  Future<void> remove() => _host.invokeMethod<void>('cancelReminder');
}

class _StartupMessage extends StatelessWidget {
  const _StartupMessage(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(body: Center(child: Text(message))),
  );
}
