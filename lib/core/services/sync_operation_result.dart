enum SyncOperationStatus {
  success,
  retryableError,
  quotaExceeded,
  permissionDenied,
  invalidPayload,
  unsupportedOperation,
}

class SyncOperationResult {
  final SyncOperationStatus status;
  final String? message;
  final String? code;

  const SyncOperationResult._({required this.status, this.message, this.code});

  const SyncOperationResult.success()
    : this._(status: SyncOperationStatus.success);

  const SyncOperationResult.retryable({String? message, String? code})
    : this._(
        status: SyncOperationStatus.retryableError,
        message: message,
        code: code,
      );

  const SyncOperationResult.quotaExceeded()
    : this._(status: SyncOperationStatus.quotaExceeded, code: 'QUOTA_EXCEEDED');

  const SyncOperationResult.permissionDenied({
    String code = 'PERMISSION_DENIED',
  }) : this._(status: SyncOperationStatus.permissionDenied, code: code);

  const SyncOperationResult.invalidPayload({
    String? message,
    String code = 'INVALID_PAYLOAD',
  }) : this._(
         status: SyncOperationStatus.invalidPayload,
         message: message,
         code: code,
       );

  const SyncOperationResult.unsupportedOperation({String? message})
    : this._(
        status: SyncOperationStatus.unsupportedOperation,
        message: message,
        code: 'UNSUPPORTED_OPERATION',
      );

  bool get isSuccess => status == SyncOperationStatus.success;

  bool get shouldRetry => status == SyncOperationStatus.retryableError;

  bool get isPermanentFailure =>
      status == SyncOperationStatus.quotaExceeded ||
      status == SyncOperationStatus.permissionDenied ||
      status == SyncOperationStatus.invalidPayload ||
      status == SyncOperationStatus.unsupportedOperation;
}
