import 'package:equatable/equatable.dart';

class AiConfigEntity extends Equatable {
  final bool isFeatureLocked;
  final String version;
  final String engineName;

  const AiConfigEntity({
    required this.isFeatureLocked,
    required this.version,
    required this.engineName,
  });

  @override
  List<Object?> get props => [isFeatureLocked, version, engineName];
}