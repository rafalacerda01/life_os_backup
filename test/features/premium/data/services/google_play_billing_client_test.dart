import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:life_os/features/premium/data/services/google_play_billing_client.dart';

void main() {
  for (final status in [PurchaseStatus.canceled, PurchaseStatus.error]) {
    for (final source in ['google_play', 'other_store']) {
      test(
        'generic ${status.name} recognizes source $source without inventing account',
        () async {
          final native = PurchaseDetails(
            productID: '',
            verificationData: PurchaseVerificationData(
              localVerificationData: '',
              serverVerificationData: '',
              source: source,
            ),
            transactionDate: null,
            status: status,
          );
          final adapter = InAppPurchaseGooglePlayBillingClient(
            store: _Store(Stream.value([native])),
          );
          final purchase = (await adapter.purchaseStream.first).single;
          expect(purchase.isGooglePlay, source == 'google_play');
          expect(
            purchase.state,
            status == PurchaseStatus.canceled
                ? PlayPurchaseState.canceled
                : PlayPurchaseState.error,
          );
          expect(purchase.productId, isEmpty);
          expect(purchase.purchaseToken, isEmpty);
          expect(purchase.obfuscatedAccountId, isNull);
          expect(purchase.nativePurchase, same(native));
        },
      );
    }
  }
}

class _Store extends Fake implements InAppPurchase {
  _Store(this.purchaseStream);

  @override
  final Stream<List<PurchaseDetails>> purchaseStream;
}
