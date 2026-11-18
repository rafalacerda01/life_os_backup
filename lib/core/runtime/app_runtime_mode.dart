import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AppRuntimeMode { legacyRemote, localFirst }

/// Development entrypoints opt into local mode. Database admission is enforced
/// separately by the local-only connection; this is not an entitlement flag.
final appRuntimeModeProvider = Provider<AppRuntimeMode>(
  (ref) => AppRuntimeMode.legacyRemote,
);
