import 'dart:io';

import 'package:app/services/local_vault_store.dart';
import 'package:app/services/vault_database_worker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

void main() {
  late Directory directory;
  late String path;
  late String legacy;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sqlite-vault-');
    path = '${directory.path}/lifenizer-vaults.sqlite';
    legacy = '${directory.path}/lifenizer-vaults.db';
  });
  tearDown(() => directory.delete(recursive: true));
  Future<VaultDatabaseRequest> open() =>
      openVaultDatabaseWorker(path, useSqlite: true, legacyPath: legacy);
  Future<void> seedLegacy() async {
    final previous = await databaseFactoryIo.openDatabase(legacy);
    final records = stringMapStoreFactory.store('vaults');
    await records.record('vault').put(previous, {
      'cipherText': 'encrypted core',
    });
    await records.record('outbox').put(previous, {
      'cipherText': 'encrypted outbox',
    });
    await records.record('settings').put(previous, {
      'server': 'https://example.test',
    });
    await previous.close();
  }

  test('metadata reads SQLite directly and retains encrypted rows', () async {
    final store = LocalVaultStore.remote(await open());
    await store.writeMany({
      'vault': {'cipherText': 'encrypted core', 'nonce': 'nonce'},
      'outbox': {'cipherText': 'encrypted outbox'},
      'settings': {'server': 'https://example.test'},
    });
    await store.close();
    final header = await File(
      path,
    ).openRead(0, 16).fold<List<int>>([], (all, bytes) => all..addAll(bytes));
    expect(header, 'SQLite format 3\u0000'.codeUnits);
    final direct = sql.sqlite3.open(path);
    expect(
      direct.select('SELECT key FROM vaults').map((row) => row['key']).toSet(),
      {'vault', 'outbox', 'settings'},
    );
    direct.close();
    final reopened = LocalVaultStore.remote(await open());
    expect(await reopened.read('outbox'), {'cipherText': 'encrypted outbox'});
    expect(await reopened.read('missing'), isNull);
    await reopened.deleteMany(['vault', 'missing']);
    expect(await reopened.read('vault'), isNull);
    await reopened.close();
  });

  test(
    'migration preserves legacy bytes and never replays them after success',
    () async {
      await seedLegacy();
      final original = await File(legacy).readAsBytes();
      final worker = await open();
      expect(await worker('read', 'vault', null), {
        'cipherText': 'encrypted core',
      });
      expect(await worker('read', 'outbox', null), {
        'cipherText': 'encrypted outbox',
      });
      expect(await worker('read', 'settings', null), {
        'server': 'https://example.test',
      });
      await worker('write', 'vault', {'cipherText': 'new encrypted core'});
      await worker('deleteMany', null, {
        'keys': ['outbox'],
      });
      await worker('close', null, null);
      expect(await File(legacy).readAsBytes(), original);
      await File(legacy).writeAsString('invalid legacy file');
      final reopened = await open();
      expect(await reopened('read', 'vault', null), {
        'cipherText': 'new encrypted core',
      });
      expect(await reopened('read', 'outbox', null), isNull);
      await reopened('close', null, null);
    },
  );

  test('failed migration rolls back rows and marker and can retry', () async {
    await seedLegacy();
    final original = await File(legacy).readAsBytes();
    final direct = sql.sqlite3.open(path);
    direct.execute(
      'CREATE TABLE vaults (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    direct.execute(
      "CREATE TRIGGER reject_migration BEFORE INSERT ON vaults WHEN NEW.key = 'outbox' BEGIN SELECT RAISE(FAIL, 'injected failure'); END",
    );
    direct.close();
    await expectLater(
      open().timeout(const Duration(seconds: 5)),
      throwsStateError,
    );
    final failed = sql.sqlite3.open(path);
    expect(failed.select('SELECT key FROM vaults'), isEmpty);
    expect(failed.select('PRAGMA user_version').single.values.single, 0);
    failed.execute('DROP TRIGGER reject_migration');
    failed.close();
    expect(await File(legacy).readAsBytes(), original);
    final restored = await open();
    expect(await restored('read', 'outbox', null), {
      'cipherText': 'encrypted outbox',
    });
    await restored('close', null, null);
    final migrated = sql.sqlite3.open(path);
    expect(migrated.select('PRAGMA user_version').single.values.single, 1);
    migrated.close();
  });

  test('failed batches roll back writes and deletes and allow retry', () async {
    final worker = await open();
    await worker('writeMany', null, {
      'stable': {'cipherText': 'previous'},
      'reject-delete': {'cipherText': 'keep'},
    });
    final direct = sql.sqlite3.open(path);
    direct.execute(
      "CREATE TRIGGER reject_write BEFORE INSERT ON vaults WHEN NEW.key = 'reject' BEGIN SELECT RAISE(FAIL, 'injected failure'); END",
    );
    direct.execute(
      "CREATE TRIGGER reject_delete BEFORE DELETE ON vaults WHEN OLD.key = 'reject-delete' BEGIN SELECT RAISE(FAIL, 'injected failure'); END",
    );
    direct.close();
    await expectLater(
      worker('writeMany', null, {
        'stable': {'cipherText': 'replacement'},
        'reject': {'cipherText': 'failure'},
      }),
      throwsStateError,
    );
    expect(await worker('read', 'stable', null), {'cipherText': 'previous'});
    expect(await worker('read', 'reject', null), isNull);
    await expectLater(
      worker('deleteMany', null, {
        'keys': ['stable', 'reject-delete'],
      }),
      throwsStateError,
    );
    expect(await worker('read', 'stable', null), {'cipherText': 'previous'});
    await worker('write', 'retry', {'cipherText': 'saved after error'});
    expect(await worker('read', 'retry', null), {
      'cipherText': 'saved after error',
    });
    await worker('close', null, null);
  });

  test(
    'SQLite open errors and closed requests fail instead of hanging',
    () async {
      await expectLater(
        openVaultDatabaseWorker(
          directory.path,
          useSqlite: true,
        ).timeout(const Duration(seconds: 5)),
        throwsStateError,
      );
      final worker = await open();
      final write = worker('write', 'vault', {'cipherText': 'last write'});
      await Future.wait([
        worker('close', null, null),
        worker('close', null, null),
      ]);
      await write;
      await expectLater(worker('read', 'vault', null), throwsStateError);
      final reopened = await open();
      expect(await reopened('read', 'vault', null), {
        'cipherText': 'last write',
      });
      await reopened('close', null, null);
    },
  );
}
