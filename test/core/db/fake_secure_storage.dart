import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class FakeSecureStorage extends FlutterSecureStorage {
  final values = <String, String>{};
  final reads = <String, int>{};
  final writes = <String, int>{};
  final deletes = <String, int>{};
  Future<void> Function(String key)? beforeRead;
  bool failRead = false;
  bool discardWrites = false;
  bool discardDeletes = false;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads[key] = (reads[key] ?? 0) + 1;
    await beforeRead?.call(key);
    if (failRead) throw StateError('technical-storage-marker');
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writes[key] = (writes[key] ?? 0) + 1;
    if (!discardWrites && value != null) values[key] = value;
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    deletes[key] = (deletes[key] ?? 0) + 1;
    if (!discardDeletes) values.remove(key);
  }
}
