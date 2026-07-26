// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'finance_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(TransactionLimit)
final transactionLimitProvider = TransactionLimitProvider._();

final class TransactionLimitProvider
    extends $NotifierProvider<TransactionLimit, int> {
  TransactionLimitProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'transactionLimitProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$transactionLimitHash();

  @$internal
  @override
  TransactionLimit create() => TransactionLimit();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(int value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<int>(value),
    );
  }
}

String _$transactionLimitHash() => r'f00d4187c564e9590553beaf45dc7fea298852f4';

abstract class _$TransactionLimit extends $Notifier<int> {
  int build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<int, int>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<int, int>,
              int,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
