import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:life_os/core/database/database_encryption.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_profile_bootstrap_journal.dart';
import 'package:life_os/features/market/presentation/market_screen.dart';
import 'package:life_os/main_local.dart' as app;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

const _secure = FlutterSecureStorage(
  aOptions: AndroidOptions(
    encryptedSharedPreferences: true,
    resetOnError: false,
    migrateOnAlgorithmChange: false,
  ),
);

String _fingerprint(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

// Read the encrypted database directly, before opening an application session
// and again after closing it. Hash all pre-existing application rows only.
({int version, String rows}) _readDatabase(
  File file,
  String key, {
  int? marketExpense,
}) {
  final raw = sql.sqlite3.open(file.path, mode: sql.OpenMode.readOnly);
  try {
    DatabaseEncryptionBootstrap.configureEncryptedConnection(raw, key);
    final tables = raw.select(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name NOT LIKE 'sqlite_%' AND name NOT IN ('market_items', 'market_purchases') ORDER BY name",
    );
    final snapshot = <String, List<String>>{};
    for (final entry in tables) {
      final name = entry['name'] as String;
      final table = '"${name.replaceAll('"', '""')}"';
      final rows = name == 'transactions' && marketExpense != null
          ? raw.select('SELECT * FROM $table WHERE id <> ?', [marketExpense])
          : raw.select('SELECT * FROM $table');
      snapshot[name] = rows.map(jsonEncode).toList()..sort();
    }
    return (version: raw.userVersion, rows: _fingerprint(snapshot));
  } finally {
    raw.dispose();
  }
}

Future<Map<String, dynamic>> _readJournal() async =>
    jsonDecode(
          (await _secure.read(key: LocalProfileBootstrapJournal.storageKey))!,
        )
        as Map<String, dynamic>;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  final report = <String, Object?>{'module': 'market'};
  final checks = <String, bool>{};

  void check(bool value, String label) {
    checks[label] = value;
    expect(value, isTrue, reason: label);
  }

  tearDownAll(() async {
    report['checks'] = checks;
    report['testResults'] = binding.results.map(
      (key, value) => MapEntry(key, value.toString()),
    );
    report['failureDetails'] = binding.failureMethodsDetails
        .map((e) => e.toString())
        .toList();
    await app.localLabChannel.invokeMethod('saveReport', jsonEncode(report));
  });

  testWidgets(
    'native schema upgrade and offline market checkout',
    (tester) async {
      Future<void> waitFor(
        FutureOr<bool> Function() condition,
        String label,
      ) async {
        final watch = Stopwatch()..start();
        while (!await condition()) {
          if (watch.elapsed > const Duration(seconds: 15))
            fail('State did not arrive: $label');
          await tester.pump(const Duration(milliseconds: 60));
        }
        await tester.pumpAndSettle();
      }

      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      Future<void> nativeText(String fieldKey, String value) async {
        final field = find.descendant(
          of: find.byKey(Key(fieldKey)),
          matching: find.byType(EditableText),
        );
        await tap(field);
        final controller = tester.widget<EditableText>(field).controller;
        controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: controller.text.length,
        );
        await tester.pump(const Duration(milliseconds: 80));
        await app.localLabChannel.invokeMethod<void>(
          'requestSyntheticInput',
          value,
        );
        await waitFor(
          () => controller.text == value,
          'native input for $fieldKey',
        );
        await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        await tester.pumpAndSettle();
      }

      Future<void> editItem(String name, String quantity) async {
        await nativeText('market-item-name', name);
        await nativeText('market-item-quantity', quantity);
        await tap(find.text('Salvar item'));
        await waitFor(
          () => find.text(name).evaluate().isNotEmpty,
          'item $name',
        );
      }

      final scenario = await app.localLabChannel.invokeMethod<String>(
        'scenario',
      );
      final audit = (await app.localLabChannel.invokeMapMethod<String, Object?>(
        'audit',
      ))!;
      report.addAll({'scenario': scenario, 'audit': audit});
      check(
        const {'migrate', 'seed', 'reopen'}.contains(scenario),
        'known-scenario',
      );
      check(
        audit['package'] == 'com.rafalacerda.lifeos.localdev',
        'isolated-package',
      );
      check(audit['internetPermission'] == false, 'android-denies-internet');
      check(
        audit['firebaseApps'] == 0 &&
            (audit['forbiddenPluginsRegistered'] as List).isEmpty,
        'no-native-firebase-or-billing',
      );

      final beforeJournal = await _readJournal();
      final version = scenario == 'migrate' ? 11 : 12;
      final identity = LocalDatabaseIdentity(
        beforeJournal['profile'] as String,
      );
      final directory = await getApplicationDocumentsDirectory();
      final file = identity.fileIn(directory);
      final key = await _secure.read(key: identity.keyAlias) ?? '';
      check(
        identity.isLocalInstallation && key.isNotEmpty,
        'key-and-profile-read-before-open',
      );
      report.addAll({
        'profileId': identity.uid,
        'keyFingerprint': sha256.convert(utf8.encode(key)).toString(),
        'sourceDatabaseHash': sha256
            .convert(await file.readAsBytes())
            .toString(),
      });
      check(
        beforeJournal['phase'] == 'READY' && beforeJournal['schema'] == version,
        'source-journal-version',
      );
      final source = _readDatabase(file, key);
      report['sourceVersion'] = source.version;
      report['sourceRowsFingerprint'] = source.rows;
      check(source.version == version, 'source-encrypted-schema-version');

      final session = await app.prepareLocalDevelopmentSession();
      final db = session.requirePrepared();
      int? expenseId;
      try {
        check(
          db.isLocalOnly &&
              db.identity == identity &&
              session.currentLocalId == identity.uid,
          'same-local-profile',
        );
        final schema = await db.customSelect('PRAGMA user_version').getSingle();
        check(schema.read<int>('user_version') == 12, 'schema-12-after-open');
        final journal = await _readJournal();
        check(
          journal['phase'] == 'READY' &&
              journal['schema'] == 12 &&
              journal['nonce'] == beforeJournal['nonce'] &&
              journal['alias'] == identity.keyAlias,
          'journal-ready-with-same-provenance',
        );
        check(
          await _secure.read(key: identity.keyAlias) == key,
          'same-native-key',
        );
        if (scenario != 'reopen') {
          check(
            (await db.select(db.marketItems).get()).isEmpty &&
                (await db.select(db.marketPurchases).get()).isEmpty,
            'fresh-empty-market',
          );
        }

        if (scenario != 'migrate') {
          await tester.pumpWidget(
            app.LocalFirstDevelopmentApp(session: session),
          );
          await tester.pumpAndSettle();
          await tap(find.text('Início'));
          await waitFor(
            () => find.text('Mercado').evaluate().isNotEmpty,
            'home ready',
          );
          await tap(find.text('Mercado'));
          await waitFor(
            () => find.text('Adicionar item').evaluate().isNotEmpty,
            'market list ready',
          );
          check(
            find.byType(MarketScreen).evaluate().length == 1,
            'home-opens-market',
          );

          if (scenario == 'seed') {
            await tap(find.text('Adicionar item'));
            await editItem('SYNTHETIC-RICE', '1');
            await tap(find.text('Adicionar item'));
            await editItem('SYNTHETIC-COFFEE', '2');
            await tap(find.text('Adicionar item'));
            await editItem('SYNTHETIC-REMOVE', '1');
            await tap(find.byTooltip('Opções de SYNTHETIC-REMOVE'));
            await tap(find.text('Remover da lista'));
            await waitFor(
              () => find.text('SYNTHETIC-REMOVE').evaluate().isEmpty,
              'removed draft',
            );
            await tap(find.byTooltip('Opções de SYNTHETIC-RICE'));
            await tap(find.text('Editar'));
            await editItem('SYNTHETIC-RICE-EDITED', '3');
            check(
              find.text('Quantidade 3').evaluate().length == 1,
              'market-crud-in-ui',
            );
            final checkbox = find.descendant(
              of: find.ancestor(
                of: find.text('SYNTHETIC-RICE-EDITED'),
                matching: find.byType(ListTile),
              ),
              matching: find.byType(Checkbox),
            );
            await tap(checkbox);
            await waitFor(
              () =>
                  tester
                      .widget<FilledButton>(
                        find.widgetWithText(FilledButton, 'Finalizar compra'),
                      )
                      .onPressed !=
                  null,
              'checked item enables checkout',
            );
            await tap(find.text('Finalizar compra'));
            await nativeText('market-total', '48,75');
            check(
              tester
                      .widget<CheckboxListTile>(
                        find.widgetWithText(
                          CheckboxListTile,
                          'Registrar despesa em Finanças',
                        ),
                      )
                      .value ==
                  true,
              'finance-option-visible',
            );
            await tap(find.text('Salvar compra'));
            await waitFor(
              () async =>
                  (await db.select(db.marketPurchases).get()).length == 1,
              'checkout persisted',
            );
          }

          await tap(find.text('Lista'));
          await waitFor(
            () => find.text('SYNTHETIC-COFFEE').evaluate().isNotEmpty,
            'remaining active item visible in Lista',
          );
          check(
            find.text('SYNTHETIC-COFFEE').evaluate().length == 1 &&
                find.text('SYNTHETIC-RICE-EDITED').evaluate().isEmpty,
            'remaining-items-visible',
          );
          await tap(find.text('Histórico'));
          await waitFor(
            () => find.byType(ExpansionTile).evaluate().length == 1,
            'receipt visible',
          );
          await tap(find.byType(ExpansionTile));
          check(
            find.text('SYNTHETIC-RICE-EDITED').evaluate().length == 1 &&
                find.text('×3').evaluate().length == 1 &&
                find.text('Despesa registrada em Finanças').evaluate().length ==
                    1,
            'receipt-with-purchased-items',
          );

          final purchase = (await db.select(db.marketPurchases).get()).single;
          final items = (await db.select(db.marketItems).get())
            ..sort((a, b) => a.id.compareTo(b.id));
          final finances = await db.select(db.transactions).get();
          final expense = finances.singleWhere(
            (row) => row.id == purchase.financeTransactionId,
          );
          expenseId = expense.id;
          check(
            purchase.totalCents == 4875 &&
                expense.amount == 48.75 &&
                expense.type == 'expense' &&
                expense.title == 'Compra de mercado' &&
                finances.length == 2,
            'exactly-one-linked-expense',
          );
          check(
            items.length == 2 &&
                items
                    .singleWhere((item) => item.purchaseId == purchase.id)
                    .checked &&
                items.singleWhere((item) => item.purchaseId == null).name ==
                    'SYNTHETIC-COFFEE',
            'checkout-archived-only-marked-item',
          );
          report['marketFingerprint'] = _fingerprint({
            'purchase': purchase.toJson(),
            'items': items.map((item) => item.toJson()).toList(),
            'expense': expense.toJson(),
          });
          await tap(find.byType(BackButton));
          await tap(
            find.descendant(
              of: find.byType(NavigationBar),
              matching: find.text('Finanças'),
            ),
          );
          await waitFor(
            () => find.text('Compra de mercado').evaluate().isNotEmpty,
            'finance entry visible',
          );
          check(
            find.text('Compra de mercado').evaluate().length == 1,
            'expense-appears-in-finance-ui',
          );
        }

        check(
          (await db.select(db.syncQueueTable).get()).isEmpty,
          'no-remote-queue',
        );
        check(
          (await db.customSelect('PRAGMA integrity_check').getSingle())
                  .data
                  .values
                  .single ==
              'ok',
          'sqlite-integrity',
        );
        check(
          (await db.customSelect('PRAGMA foreign_key_check').get()).isEmpty,
          'foreign-key-integrity',
        );
        check(
          !DatabaseEncryptionBootstrap.hasPlaintextHeader(file),
          'encrypted-after-opening',
        );
        check(tester.takeException() == null, 'no-unhandled-ui-error');
      } catch (error, stack) {
        report['bodyError'] = error.toString();
        report['bodyStack'] = stack.toString();
        report['uiTextOnFailure'] = tester.allWidgets
            .whereType<Text>()
            .map((widget) => widget.data ?? '')
            .take(80)
            .toList();
        rethrow;
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await session.dispose();
        report['databaseHash'] = sha256
            .convert(await file.readAsBytes())
            .toString();
      }

      final after = _readDatabase(file, key, marketExpense: expenseId);
      report['legacyRowsFingerprint'] = after.rows;
      check(after.version == 12, 'disk-schema-is-12');
      if (scenario != 'reopen')
        check(after.rows == source.rows, 'all-older-rows-preserved');
      final auditAfter = (await app.localLabChannel
          .invokeMapMethod<String, Object?>('audit'))!;
      check(
        auditAfter['firebaseApps'] == 0 &&
            (auditAfter['forbiddenPluginsRegistered'] as List).isEmpty,
        'no-late-native-firebase-or-billing',
      );
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
