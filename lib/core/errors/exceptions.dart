class ServerException implements Exception {
  final String message;
  final String? code;
  const ServerException(this.message, {this.code});
}

class CacheException implements Exception {
  final String message;
  const CacheException(this.message);
}

class SecurityException implements Exception {
  final String message;
  const SecurityException(this.message);
}