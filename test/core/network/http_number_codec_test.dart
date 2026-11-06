import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/network/generational_http_store.dart';

void main() {
  test(
    'decimal request and response bytes/hash agree with server without precision loss',
    () {
      final vectors =
          jsonDecode(
                File(
                  'tools/trusted_account/http-number-vectors.json',
                ).readAsStringSync(),
              )
              as List;
      for (final v in vectors) {
        expect(httpCanonical(v['value']), v['canonical'], reason: v.toString());
        expect(httpDigest(v['value']), v['hash'], reason: v.toString());
        expect(jsonDecode(httpCanonical(v['value'])), v['value']);
      }
      expect(
        httpCanonical({'progress': 0.05, 'amount': 12.34}),
        '{"amount":12.34,"progress":0.05}',
      );
    },
  );
  test(
    'unsafe integers and nonfinite numbers stay CLOSED; strings retain their type',
    () {
      for (final n in [
        9007199254740992,
        18014398509481984,
        9007199254740992.0,
        double.infinity,
        double.negativeInfinity,
        double.nan,
      ]) {
        expect(() => httpCanonical(n), throwsStateError);
      }
      expect(httpCanonical('12.34'), '"12.34"');
      expect(httpCanonical('9007199254740992'), '"9007199254740992"');
    },
  );
}
