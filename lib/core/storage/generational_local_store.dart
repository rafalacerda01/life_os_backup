// ignore_for_file: prefer_initializing_formals
import 'dart:convert';
import '../database/local_database_identity.dart';

typedef LocalStringRead = Future<String?> Function(String key);
typedef LocalStringWrite = Future<void> Function(String key, String value);
typedef LocalStringDelete = Future<void> Function(String key);

/// Journal-first namespace. No legacy fallback, no global delete, no UID
/// lookup after await. A seal is durable and survives completion/restart.
class GenerationalLocalStore {
  GenerationalLocalStore({
    required this.identity,
    required this.domain,
    required LocalStringRead read,
    required LocalStringWrite write,
    required LocalStringDelete delete,
    Future<Set<String>> Function()? listKeys,
  }) : _listKeys = listKeys,
       _read = read,
       _write = write,
       _delete = delete {
    if (!identity.isBound || !RegExp(r'^[a-z_]{1,40}$').hasMatch(domain)) {
      throw ArgumentError('LOCAL_GENERATION_BINDING_REQUIRED');
    }
  }
  final LocalDatabaseIdentity identity;
  final String domain;
  final Future<Set<String>> Function()? _listKeys;
  final LocalStringRead _read;
  final LocalStringWrite _write;
  final LocalStringDelete _delete;
  static final Map<String, Future<void>> _tails = {};
  static const maxKeys = 128;
  String get root => 'life_os_scoped_v2:$domain:${identity.namespace}:';
  String get journalKey => '${root}journal';
  String keyFor(String key) {
    if (key.isEmpty || key.length > 512)
      throw ArgumentError('LOCAL_KEY_INVALID');
    return '${root}value:${base64Url.encode(utf8.encode(key))}';
  }

  Future<T> _serialized<T>(Future<T> Function() work) {
    final result = (_tails[root] ?? Future<void>.value()).then((_) => work());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _tails[root] = tail;
    tail.whenComplete(() {
      if (identical(_tails[root], tail)) _tails.remove(root);
    });
    return result;
  }

  Future<Map<String, dynamic>> _journal() async {
    final raw = await _read(journalKey);
    if (raw == null)
      return {
        'v': 1,
        'binding': identity.toBinding(),
        'state': 'OPEN',
        'keys': <String>[],
      };
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic> ||
        value.length != 4 ||
        value['v'] is! int ||
        value['v'] != 1 ||
        LocalDatabaseIdentity.fromBinding(value['binding']) != identity ||
        !['OPEN', 'SEALED', 'COMPLETE'].contains(value['state']) ||
        value['keys'] is! List ||
        (value['keys'] as List).length > maxKeys ||
        (value['keys'] as List).any(
          (k) => k is! String || k.isEmpty || k.length > 512,
        ) ||
        (value['keys'] as List).toSet().length !=
            (value['keys'] as List).length) {
      throw const FormatException('LOCAL_SCOPE_JOURNAL_INVALID');
    }
    return value;
  }

  Future<void> _persist(Map<String, dynamic> value) async {
    final text = jsonEncode(value);
    await _write(journalKey, text);
    if (await _read(journalKey) != text)
      throw StateError('LOCAL_SCOPE_WRITE_UNKNOWN');
  }

  Future<String?> read(String key) => _serialized(() async {
    final journal = await _journal();
    if (journal['state'] != 'OPEN') throw StateError('LOCAL_SCOPE_RETIRED');
    final value = await _read(keyFor(key));
    if (!(journal['keys'] as List).contains(key) && value != null) {
      throw StateError('LOCAL_SCOPE_UNMANIFESTED_VALUE');
    }
    return value;
  });
  Future<void> write(String key, String value) => _serialized(() async {
    final journal = await _journal();
    if (journal['state'] != 'OPEN') throw StateError('LOCAL_SCOPE_RETIRED');
    final keys = List<String>.from(journal['keys'] as List);
    if (!keys.contains(key)) {
      if (keys.length >= maxKeys || await _read(keyFor(key)) != null) {
        throw StateError('LOCAL_SCOPE_UNMANIFESTED_OR_LIMIT');
      }
      keys.add(key);
      keys.sort();
      journal['keys'] = keys;
      // Durable intent precedes the value; ambiguous writes remain enumerable.
      await _persist(journal);
    }
    await _write(keyFor(key), value);
    if (await _read(keyFor(key)) != value)
      throw StateError('LOCAL_SCOPE_WRITE_UNKNOWN');
  });
  Future<void> delete(String key) => _serialized(() async {
    final journal = await _journal();
    if (!(journal['keys'] as List).contains(key)) {
      if (await _read(keyFor(key)) != null)
        throw StateError('LOCAL_SCOPE_UNMANIFESTED_VALUE');
      return;
    }
    await _delete(keyFor(key));
    if (await _read(keyFor(key)) != null)
      throw StateError('LOCAL_SCOPE_DELETE_UNKNOWN');
    // Retain intent so an interrupted delete is repeatable.
  });
  Future<void> retire() => _serialized(() async {
    final journal = await _journal();
    if (journal['state'] == 'COMPLETE') return;
    journal['state'] = 'SEALED';
    await _persist(journal);
    final listKeys = _listKeys;
    if (listKeys == null) throw StateError('LOCAL_SCOPE_INVENTORY_REQUIRED');
    final expected = {
      journalKey,
      ...List<String>.from(journal['keys'] as List).map(keyFor),
    };
    if ((await listKeys()).any(
      (k) => k.startsWith(root) && !expected.contains(k),
    )) {
      throw StateError('LOCAL_SCOPE_UNMANIFESTED_VALUE');
    }
    for (final key in List<String>.from(journal['keys'] as List)) {
      await _delete(keyFor(key));
      if (await _read(keyFor(key)) != null)
        throw StateError('LOCAL_SCOPE_DELETE_UNKNOWN');
    }
    if ((await listKeys()).any((k) => k.startsWith(root) && k != journalKey)) {
      throw StateError('LOCAL_SCOPE_DELETE_UNKNOWN');
    }
    journal['state'] = 'COMPLETE';
    await _persist(journal);
  });
}
