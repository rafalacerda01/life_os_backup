import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'main.dart';

void main() {
  for (final target in [
    'http://life-os-backend-gray.vercel.app/api/sync',
    'https://life-os-backend-gray.vercel.app/api/sync?host=10.0.2.2',
    'https://life-os-backend-gray.vercel.app/api/sync#fragment',
    'https://life-os-backend-gray.vercel.app:444/api/sync',
    'https://example.test/api/sync',
    'http://10.0.2.2:8789/api/sync',
    'https://life-os-backend-gray.vercel.app/api/account/delete',
  ]) {
    test('reject unrecognized request before opening a socket: $target', () async {
      final client = LocalOnlyClient();
      addTearDown(client.close);
      await expectLater(client.send(http.Request('POST', Uri.parse(target))), throwsStateError);
    });
  }
  test('reject GET even on the expected URI', () async {
    final client = LocalOnlyClient();
    addTearDown(client.close);
    await expectLater(client.send(http.Request('GET',
      Uri.parse('https://life-os-backend-gray.vercel.app/api/sync'))), throwsStateError);
  });
  test('account deletion transport is unavailable', () async {
    final client = NoAccountDeletionClient();
    addTearDown(client.close);
    await expectLater(client.send(http.Request('POST', Uri.parse('https://example.test'))), throwsStateError);
  });
}
