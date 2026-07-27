class ServerException implements Exception {
  final String message;
  final String? code;
  final StackTrace? stackTrace;

  const ServerException(this.message, {this.code, this.stackTrace});

  @override
  String toString() => 'ServerException: $message (Code: $code)';
}

class CacheException implements Exception {
  final String message;
  final StackTrace? stackTrace;

  const CacheException(this.message, {this.stackTrace});

  @override
  String toString() => 'CacheException: $message';
}

class SecurityException implements Exception {
  final String message;
  final StackTrace? stackTrace;

  const SecurityException(this.message, {this.stackTrace});

  @override
  String toString() => 'SecurityException: $message';
}

class ValidationException implements Exception {
  final String message;
  final StackTrace? stackTrace;

  const ValidationException(this.message, {this.stackTrace});

  @override
  String toString() => 'ValidationException: $message';
}
