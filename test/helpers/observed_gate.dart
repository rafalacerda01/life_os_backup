/// Observes the operation before awaiting a pause. Completion is not evidence
/// that the pause was reached; callers still await the original operation.
Future<T> observedGate<T>(Future<T> gate, Future<dynamic> operation) =>
    Future.any<T>([
      gate,
      operation.then<T>(
        (_) => throw StateError('TEST_GATE_NOT_REACHED'),
        onError: (Object error, StackTrace stack) =>
            Error.throwWithStackTrace(error, stack),
      ),
    ]);
