import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/checkin/data/repositories/checkin_repository.dart';

@GenerateNiceMocks([MockSpec<CheckinLocalDataSource>()])
import 'checkin_repository_impl_test.mocks.dart';

abstract class CheckinLocalDataSource {
  Future<void> insertCheckin(String note);
}

class CheckinRepositoryImpl {
  final CheckinLocalDataSource localDataSource;
  CheckinRepositoryImpl(this.localDataSource);

  Future<bool> saveCheckin(String note) async {
    try {
      await localDataSource.insertCheckin(note);
      return true;
    } catch (_) {
      return false;
    }
  }
}

void main() {
  late CheckinRepositoryImpl repository;
  late MockCheckinLocalDataSource mockDataSource;

  setUp(() {
    mockDataSource = MockCheckinLocalDataSource();
    repository = CheckinRepositoryImpl(mockDataSource);
  });

  group('CheckinRepositoryImpl', () {
    test(
      'deve retornar true quando o salvamento no data source for bem-sucedido',
      () async {
        when(mockDataSource.insertCheckin(any)).thenAnswer((_) async => {});

        final result = await repository.saveCheckin('Dia produtivo!');

        expect(result, isTrue);
        verify(mockDataSource.insertCheckin('Dia produtivo!')).called(1);
      },
    );

    test(
      'deve retornar false quando ocorrer uma exceção no data source',
      () async {
        when(
          mockDataSource.insertCheckin(any),
        ).thenThrow(Exception('Erro no banco de dados'));

        final result = await repository.saveCheckin('Dia ruim');

        expect(result, isFalse);
        verify(mockDataSource.insertCheckin('Dia ruim')).called(1);
      },
    );
  });
}
