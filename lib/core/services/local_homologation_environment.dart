import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';

/// Fixed local profiles. Selecting one is never admission or Cloud permission.
final class LocalHomologationEnvironment {
  const LocalHomologationEnvironment._(this.id, this.projectId, this.appId);
  static const demo = LocalHomologationEnvironment._('demo-loopback', 'demo-life-os', null);
  // Populate only by a reviewed local patch after nominal external approval.
  // No client argument, dart-define or environment variable grants readiness.
  static const String? _nominalAppId = null;
  static const _nominalExternallyApproved = false;
  static const nominal = LocalHomologationEnvironment._('p1-life-os-27b92-android-local', 'life-os-27b92', _nominalAppId);
  final String id, projectId;
  final String? appId;
  static LocalHomologationEnvironment select(String id) => switch(id) {
    'demo-loopback' => demo,
    'p1-life-os-27b92-android-local' => nominal,
    _ => throw StateError('LOCAL_ENVIRONMENT_MISMATCH'),
  };
  void requireReady() {
    if (!kDebugMode) throw StateError('LOCAL_ENVIRONMENT_DEBUG_ONLY');
    // No registered diagnostic App ID or debug-secret/egress authorization yet.
    // There is deliberately no dart-define, caller bool or production fallback.
    if (identical(this, nominal) && (!_nominalExternallyApproved ||
        appId == null || !RegExp(r'^1:278760083864:android:[a-f0-9]{16,40}$').hasMatch(appId!) ||
        appId == '1:278760083864:android:3e698113400113022d1bed')) {
      throw StateError('LOCAL_ENVIRONMENT_PENDING_AUTHORIZATION');
    }
  }
  void requireApp(FirebaseApp app) {
    requireReady();
    if (app.options.projectId != projectId ||
        identical(this, nominal) && app.name != '[DEFAULT]' ||
        appId != null && app.options.appId != appId) {
      throw StateError('LOCAL_ENVIRONMENT_MISMATCH');
    }
  }
}
