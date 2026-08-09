import 'package:drift/drift.dart';

@DataClassName('HealthEntry')
class HealthEntries extends Table {
  /// Identificador único do registro diário.
  ///
  /// Formato esperado:
  /// yyyy-MM-dd
  ///
  /// Exemplo:
  /// 2026-07-08
  ///
  /// O docId funciona como chave primária para garantir que exista
  /// apenas um registro de saúde por dia.
  TextColumn get docId => text()();

  /// Humor registrado pelo usuário no dia.
  ///
  /// Valor padrão utilizado quando nenhum humor foi informado.
  TextColumn get mood => text().withDefault(const Constant('—'))();

  /// Quantidade de água ingerida no dia, em mililitros.
  ///
  /// Valor inicial padrão: 0 ml.
  IntColumn get waterIntakeMl => integer().withDefault(const Constant(0))();

  /// Indica se o medicamento/pílula diária foi marcado como tomado.
  ///
  /// Valor inicial padrão: false.
  BoolColumn get hasTakenPillToday =>
      boolean().withDefault(const Constant(false))();

  /// Configurações/dados do ciclo menstrual serializados em JSON.
  ///
  /// O armazenamento como TEXT permite manter uma estrutura flexível
  /// sem criar várias colunas para os dados do ciclo.
  ///
  /// A conversão JSON <-> Map é responsabilidade do HealthRepository.
  TextColumn get menstrualCycleJson => text().nullable()();

  /// Data/hora associada ao registro.
  ///
  /// O valor é fornecido explicitamente pelo repository em todas as
  /// operações de escrita.
  DateTimeColumn get date => dateTime()();

  /// Garante um único registro de saúde por dia.
  @override
  Set<Column> get primaryKey => {docId};
}
