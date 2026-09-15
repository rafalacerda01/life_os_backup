import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

enum PlayPurchaseState { pending, purchased, restored, canceled, error }

class PlayStoreOffer {
  const PlayStoreOffer({
    required this.productId,
    required this.basePlanId,
    required this.offerId,
    required this.offerToken,
    required this.formattedPrice,
    required this.rawPrice,
    required this.currencyCode,
    required this.nativeProduct,
  });

  final String productId;
  final String basePlanId;
  final String? offerId;
  final String offerToken;
  final String formattedPrice;
  final double rawPrice;
  final String currencyCode;
  final Object nativeProduct;
}

class PlayStorePurchase {
  const PlayStorePurchase({
    required this.state,
    required this.productId,
    required this.purchaseToken,
    required this.obfuscatedAccountId,
    required this.pendingCompletePurchase,
    required this.isGooglePlay,
    required this.nativePurchase,
  });

  final PlayPurchaseState state;
  final String productId;
  final String purchaseToken;
  final String? obfuscatedAccountId;
  final bool pendingCompletePurchase;
  final bool isGooglePlay;
  final Object nativePurchase;
}

abstract class GooglePlayBillingClient {
  Stream<List<PlayStorePurchase>> get purchaseStream;
  Future<bool> isAvailable();
  Future<List<PlayStoreOffer>> queryOffers(Set<String> productIds);
  Future<bool> buy(PlayStoreOffer offer, String applicationUserName);
  Future<List<PlayStorePurchase>> queryPastPurchases(
    String applicationUserName,
  );
  Future<void> completePurchase(PlayStorePurchase purchase);
}

class InAppPurchaseGooglePlayBillingClient implements GooglePlayBillingClient {
  InAppPurchaseGooglePlayBillingClient({InAppPurchase? store})
    : _store = store ?? InAppPurchase.instance;

  final InAppPurchase _store;

  @override
  Stream<List<PlayStorePurchase>> get purchaseStream =>
      _store.purchaseStream.map(_mapPurchases);

  @override
  Future<bool> isAvailable() => _store.isAvailable();

  @override
  Future<List<PlayStoreOffer>> queryOffers(Set<String> productIds) async {
    final response = await _store.queryProductDetails(productIds);
    if (response.error != null) throw StateError('PLAY_CATALOG_UNAVAILABLE');
    final offers = <PlayStoreOffer>[];
    for (final product in response.productDetails) {
      if (product is! GooglePlayProductDetails) continue;
      final index = product.subscriptionIndex;
      final details = product.productDetails.subscriptionOfferDetails;
      if (index == null || details == null || index >= details.length) continue;
      final offer = details[index];
      offers.add(
        PlayStoreOffer(
          productId: product.id,
          basePlanId: offer.basePlanId,
          offerId: offer.offerId,
          offerToken: offer.offerIdToken,
          formattedPrice: product.price,
          rawPrice: product.rawPrice,
          currencyCode: product.currencyCode,
          nativeProduct: product,
        ),
      );
    }
    return offers;
  }

  @override
  Future<bool> buy(PlayStoreOffer offer, String applicationUserName) {
    final product = offer.nativeProduct;
    if (product is! GooglePlayProductDetails)
      throw StateError('PLAY_PRODUCT_INVALID');
    return _store.buyNonConsumable(
      purchaseParam: GooglePlayPurchaseParam(
        productDetails: product,
        applicationUserName: applicationUserName,
        offerToken: offer.offerToken,
      ),
    );
  }

  @override
  Future<List<PlayStorePurchase>> queryPastPurchases(
    String applicationUserName,
  ) async {
    final addition = _store
        .getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
    final response = await addition.queryPastPurchases(
      applicationUserName: applicationUserName,
    );
    if (response.error != null) throw StateError('PLAY_RESTORE_UNAVAILABLE');
    return _mapPurchases(response.pastPurchases);
  }

  @override
  Future<void> completePurchase(PlayStorePurchase purchase) async {
    final native = purchase.nativePurchase;
    if (native is! PurchaseDetails) throw StateError('PLAY_PURCHASE_INVALID');
    await _store.completePurchase(native);
  }

  static List<PlayStorePurchase> _mapPurchases(
    List<PurchaseDetails> purchases,
  ) {
    return purchases
        .map((purchase) {
          final googlePurchase = purchase is GooglePlayPurchaseDetails;
          return PlayStorePurchase(
            state: switch (purchase.status) {
              PurchaseStatus.pending => PlayPurchaseState.pending,
              PurchaseStatus.purchased => PlayPurchaseState.purchased,
              PurchaseStatus.restored => PlayPurchaseState.restored,
              PurchaseStatus.canceled => PlayPurchaseState.canceled,
              PurchaseStatus.error => PlayPurchaseState.error,
            },
            productId: purchase.productID,
            purchaseToken: purchase.verificationData.serverVerificationData,
            obfuscatedAccountId: googlePurchase
                ? purchase.billingClientPurchase.obfuscatedAccountId
                : null,
            pendingCompletePurchase: purchase.pendingCompletePurchase,
            isGooglePlay:
                googlePurchase ||
                purchase.verificationData.source == 'google_play',
            nativePurchase: purchase,
          );
        })
        .toList(growable: false);
  }
}
