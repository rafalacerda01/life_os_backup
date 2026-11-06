import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import '../../helpers/observed_gate.dart';
void main() {
  test('early completion does not masquerade as a controlled pause', () async {
    await expectLater(observedGate(Completer<void>().future, Future.value(false)), throwsStateError);
  });
  test('early rejection preserves the exact original error', () async {
    final error = StateError('original');
    await expectLater(observedGate(Completer<void>().future, Future.error(error)), throwsA(same(error)));
  });
  test('a reached gate does not hide a later operation failure', () async {
    final operation = Completer<void>();
    await observedGate(Future<void>.value(), operation.future);
    final error = StateError('later');
    final observed = expectLater(operation.future, throwsA(same(error)));
    operation.completeError(error); await observed;
  });
}
