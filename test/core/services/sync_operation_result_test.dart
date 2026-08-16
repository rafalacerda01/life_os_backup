import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/sync_operation_result.dart';

void main() {
  group('SyncOperationResult', () {
    test('success deve marcar operação como sucesso', () {
      const result = SyncOperationResult.success();

      expect(result.status, SyncOperationStatus.success);
      expect(result.isSuccess, isTrue);
      expect(result.shouldRetry, isFalse);
      expect(result.isPermanentFailure, isFalse);
    });

    test('retryable deve permitir nova tentativa', () {
      const result = SyncOperationResult.retryable(code: 'UNAVAILABLE');

      expect(result.status, SyncOperationStatus.retryableError);
      expect(result.isSuccess, isFalse);
      expect(result.shouldRetry, isTrue);
      expect(result.isPermanentFailure, isFalse);
      expect(result.code, 'UNAVAILABLE');
    });

    test('quotaExceeded deve ser falha permanente', () {
      const result = SyncOperationResult.quotaExceeded();

      expect(result.status, SyncOperationStatus.quotaExceeded);
      expect(result.isSuccess, isFalse);
      expect(result.shouldRetry, isFalse);
      expect(result.isPermanentFailure, isTrue);
      expect(result.code, 'QUOTA_EXCEEDED');
    });

    test('permissionDenied deve ser falha permanente', () {
      const result = SyncOperationResult.permissionDenied();

      expect(result.status, SyncOperationStatus.permissionDenied);
      expect(result.shouldRetry, isFalse);
      expect(result.isPermanentFailure, isTrue);
      expect(result.code, 'PERMISSION_DENIED');
    });

    test('invalidPayload deve ser falha permanente', () {
      const result = SyncOperationResult.invalidPayload(
        message: 'Payload inválido',
      );

      expect(result.status, SyncOperationStatus.invalidPayload);
      expect(result.shouldRetry, isFalse);
      expect(result.isPermanentFailure, isTrue);
      expect(result.message, 'Payload inválido');
      expect(result.code, 'INVALID_PAYLOAD');
    });

    test('unsupportedOperation deve ser falha permanente', () {
      const result = SyncOperationResult.unsupportedOperation(
        message: 'Operação inválida',
      );

      expect(result.status, SyncOperationStatus.unsupportedOperation);
      expect(result.shouldRetry, isFalse);
      expect(result.isPermanentFailure, isTrue);
      expect(result.message, 'Operação inválida');
      expect(result.code, 'UNSUPPORTED_OPERATION');
    });
  });
}
