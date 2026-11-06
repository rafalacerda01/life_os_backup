// ignore_for_file: prefer_initializing_formals
import 'dart:convert';
import 'dart:math';
import '../database/local_database_identity.dart';
import 'generational_local_store.dart';

class GenerationalCleanupReceipt {
  GenerationalCleanupReceipt._(
    this.identity,
    this.revision,
    this.phase,
    this.completedSteps,
    this.plan,
  );
  final LocalDatabaseIdentity identity;
  final String revision, phase;
  final List<String> completedSteps, plan;
  bool get isComplete => phase == 'COMPLETE';
}

/// Local receipt only. Confirmation must come from the original successful
/// remote deletion response. Auth absence/timeouts never promote REQUESTED.
class GenerationalCleanupJournal {
  GenerationalCleanupJournal({
    required LocalStringRead read,
    required LocalStringWrite write,
  }) : _read = read,
       _write = write;
  final LocalStringRead _read;
  final LocalStringWrite _write;
  static final Map<String, Future<void>> _tails = {};
  String keyFor(LocalDatabaseIdentity identity) {
    if (!identity.isBound)
      throw ArgumentError('LOCAL_GENERATION_BINDING_REQUIRED');
    return 'life_os_generation_cleanup_v1:${identity.namespace}';
  }

  Future<T> _serial<T>(
    LocalDatabaseIdentity identity,
    Future<T> Function() work,
  ) {
    final key = keyFor(identity),
        run = (_tails[key] ?? Future<void>.value()).then((_) => work());
    final tail = run.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _tails[key] = tail;
    tail.whenComplete(() {
      if (identical(_tails[key], tail)) _tails.remove(key);
    });
    return run;
  }

  Future<GenerationalCleanupReceipt?> read(
    LocalDatabaseIdentity identity,
  ) async {
    final raw = await _read(keyFor(identity));
    if (raw == null) return null;
    final d = jsonDecode(raw);
    if (d is! Map ||
        d.length != 6 ||
        d['v'] is! int ||
        d['v'] != 1 ||
        LocalDatabaseIdentity.fromBinding(d['binding']) != identity ||
        d['revision'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(d['revision'] as String) ||
        !['REQUESTED', 'REMOTE_CONFIRMED', 'COMPLETE'].contains(d['phase']) ||
        d['plan'] is! List ||
        (d['plan'] as List).isEmpty ||
        (d['plan'] as List).length > 32 ||
        (d['plan'] as List).any(
          (s) => s is! String || !RegExp(r'^[a-z_]{1,40}$').hasMatch(s),
        ) ||
        (d['plan'] as List).toSet().length != (d['plan'] as List).length ||
        d['steps'] is! List ||
        (d['steps'] as List).any(
          (s) => s is! String || !RegExp(r'^[a-z_]{1,40}$').hasMatch(s),
        ) ||
        (d['steps'] as List).length > 32 ||
        (d['steps'] as List).toSet().length != (d['steps'] as List).length ||
        (d['steps'] as List).any((s) => !(d['plan'] as List).contains(s)) ||
        (d['phase'] == 'COMPLETE' &&
            (d['plan'] as List).length != (d['steps'] as List).length) ||
        (d['phase'] == 'REQUESTED' && (d['steps'] as List).isNotEmpty)) {
      throw const FormatException('LOCAL_CLEANUP_RECEIPT_INVALID');
    }
    return GenerationalCleanupReceipt._(
      identity,
      d['revision'] as String,
      d['phase'] as String,
      List<String>.unmodifiable(d['steps'] as List),
      List<String>.unmodifiable(d['plan'] as List),
    );
  }

  Future<GenerationalCleanupReceipt> _persist(
    GenerationalCleanupReceipt receipt,
  ) async {
    final value = jsonEncode({
      'v': 1,
      'binding': receipt.identity.toBinding(),
      'revision': receipt.revision,
      'phase': receipt.phase,
      'steps': receipt.completedSteps,
      'plan': receipt.plan,
    });
    await _write(keyFor(receipt.identity), value);
    if (await _read(keyFor(receipt.identity)) != value)
      throw StateError('LOCAL_CLEANUP_RESULT_UNKNOWN');
    return receipt;
  }

  Future<GenerationalCleanupReceipt> request(
    LocalDatabaseIdentity identity, {
    List<String> plan = const ['preferences', 'notifications', 'database'],
  }) => _serial(identity, () async {
    if (plan.isEmpty ||
        plan.length > 32 ||
        plan.toSet().length != plan.length ||
        plan.any((s) => !RegExp(r'^[a-z_]{1,40}$').hasMatch(s)))
      throw ArgumentError('LOCAL_CLEANUP_PLAN_INVALID');
    final current = await read(identity);
    if (current != null) {
      if (jsonEncode(current.plan) != jsonEncode(plan))
        throw StateError('LOCAL_CLEANUP_PLAN_CHANGED');
      return current;
    }
    final revision = base64Url
        .encode(List<int>.generate(16, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');
    return _persist(
      GenerationalCleanupReceipt._(
        identity,
        revision,
        'REQUESTED',
        const [],
        List.unmodifiable(plan),
      ),
    );
  });
  bool _same(GenerationalCleanupReceipt? a, GenerationalCleanupReceipt b) =>
      a != null &&
      a.identity == b.identity &&
      a.revision == b.revision &&
      a.phase == b.phase &&
      jsonEncode(a.completedSteps) == jsonEncode(b.completedSteps) &&
      jsonEncode(a.plan) == jsonEncode(b.plan);
  Future<GenerationalCleanupReceipt> confirmOriginalResponse(
    GenerationalCleanupReceipt expected,
  ) => _serial(expected.identity, () async {
    final current = await read(expected.identity);
    if (current != null &&
        current.identity == expected.identity &&
        current.revision == expected.revision &&
        jsonEncode(current.plan) == jsonEncode(expected.plan) &&
        current.phase != 'REQUESTED')
      return current;
    if (!_same(current, expected) || expected.phase != 'REQUESTED')
      throw StateError('LOCAL_CLEANUP_RECEIPT_CHANGED');
    return _persist(
      GenerationalCleanupReceipt._(
        expected.identity,
        expected.revision,
        'REMOTE_CONFIRMED',
        const [],
        expected.plan,
      ),
    );
  });
  Future<GenerationalCleanupReceipt> resume(
    GenerationalCleanupReceipt expected,
    Map<String, Future<void> Function(LocalDatabaseIdentity)> effects,
  ) => _serial(expected.identity, () async {
    if (effects.isEmpty ||
        effects.length > 32 ||
        effects.keys.any((s) => !RegExp(r'^[a-z_]{1,40}$').hasMatch(s)))
      throw ArgumentError('LOCAL_CLEANUP_PLAN_INVALID');
    var current = await read(expected.identity);
    if (!_same(current, expected) || current!.phase == 'REQUESTED')
      throw StateError('LOCAL_CLEANUP_NOT_CONFIRMED');
    if (jsonEncode(current.plan) != jsonEncode(effects.keys.toList()))
      throw StateError('LOCAL_CLEANUP_PLAN_CHANGED');
    if (current.completedSteps.any((s) => !effects.containsKey(s)))
      throw StateError('LOCAL_CLEANUP_PLAN_CHANGED');
    if (current.isComplete) {
      if (current.completedSteps.length != effects.length)
        throw StateError('LOCAL_CLEANUP_PLAN_CHANGED');
      return current;
    }
    for (final entry in effects.entries) {
      if (current!.completedSteps.contains(entry.key)) continue;
      if (!_same(await read(expected.identity), current))
        throw StateError('LOCAL_CLEANUP_RECEIPT_CHANGED');
      await entry.value(expected.identity);
      if (!_same(await read(expected.identity), current))
        throw StateError('LOCAL_CLEANUP_RECEIPT_CHANGED');
      current = await _persist(
        GenerationalCleanupReceipt._(
          expected.identity,
          expected.revision,
          'REMOTE_CONFIRMED',
          List.unmodifiable([...current.completedSteps, entry.key]),
          expected.plan,
        ),
      );
    }
    return _persist(
      GenerationalCleanupReceipt._(
        expected.identity,
        expected.revision,
        'COMPLETE',
        current!.completedSteps,
        expected.plan,
      ),
    );
  });
}
