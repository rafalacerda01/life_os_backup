import 'package:life_os/core/services/water_v2_contract.dart';

final class WaterV2Bootstrap {
  const WaterV2Bootstrap(
    this.state, {
    this.healthDay,
    this.epoch,
    this.revision,
    this.waterIntakeMl,
    this.initialHealthDay,
    this.goalMl,
    this.goalRevision,
  });
  final String state;
  final String? healthDay, epoch, initialHealthDay;
  final int? revision, waterIntakeMl, goalMl, goalRevision;
  factory WaterV2Bootstrap.parse(String body) {
    final m = WaterV2Validation.object(body);
    final ready = m['state'] == 'READY';
    WaterV2Validation.require(
      WaterV2Validation.exact(
            m,
            ready
                ? const {
                    'success',
                    'operation',
                    'version',
                    'state',
                    'healthDay',
                    'epoch',
                    'revision',
                    'waterIntakeMl',
                    'initialHealthDay',
                    'goalMl',
                    'goalRevision',
                  }
                : const {'success', 'operation', 'version', 'state'},
          ) &&
          m['success'] == true &&
          m['operation'] == 'bootstrap_water' &&
          m['version'] == 2 &&
          const {'READY', 'LEGACY', 'NOT_ELIGIBLE'}.contains(m['state']),
    );
    if (!ready) return WaterV2Bootstrap(m['state'] as String);
    WaterV2Validation.require(
      m['initialHealthDay'] is String &&
          WaterV2Validation.day(m['initialHealthDay']) &&
          m['healthDay'] is String &&
          m['initialHealthDay'].compareTo(m['healthDay']) <= 0 &&
          WaterV2Validation.integer(m['goalMl'], 250, 10000) &&
          m['goalMl'] % 250 == 0 &&
          WaterV2Validation.integer(
            m['goalRevision'],
            0,
            WaterV2Validation.maxRevision,
          ) &&
          (m['goalRevision'] != 0 || m['goalMl'] == 3000) &&
          m['healthDay'] is String &&
          WaterV2Validation.day(m['healthDay']) &&
          m['epoch'] is String &&
          WaterV2Validation.uuid.hasMatch(m['epoch']) &&
          WaterV2Validation.integer(
            m['revision'],
            0,
            WaterV2Validation.maxRevision,
          ) &&
          WaterV2Validation.integer(m['waterIntakeMl'], 0, 1000000) &&
          (m['revision'] != 0 || m['waterIntakeMl'] == 0),
    );
    return WaterV2Bootstrap(
      'READY',
      healthDay: m['healthDay'],
      epoch: m['epoch'],
      revision: m['revision'],
      waterIntakeMl: m['waterIntakeMl'],
      initialHealthDay: m['initialHealthDay'],
      goalMl: m['goalMl'],
      goalRevision: m['goalRevision'],
    );
  }
}
