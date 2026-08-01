// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'checkin_controller.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(CheckInController)
final checkInControllerProvider = CheckInControllerProvider._();

final class CheckInControllerProvider
    extends $NotifierProvider<CheckInController, CheckInState> {
  CheckInControllerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'checkInControllerProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$checkInControllerHash();

  @$internal
  @override
  CheckInController create() => CheckInController();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(CheckInState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<CheckInState>(value),
    );
  }
}

String _$checkInControllerHash() => r'c903cd8b5a605bc7e0db9ae4161ba73bd19c6de7';

abstract class _$CheckInController extends $Notifier<CheckInState> {
  CheckInState build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<CheckInState, CheckInState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<CheckInState, CheckInState>,
              CheckInState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
