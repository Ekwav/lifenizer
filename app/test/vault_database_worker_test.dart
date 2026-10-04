import 'dart:async';
import 'dart:io';

import 'package:app/services/vault_database_worker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';

void main() {
  test(
    'worker reads existing snapshots and serializes durable writes',
    () async {
      final directory = await Directory.systemTemp.createTemp('vault-worker-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/vault.db';
      final records = stringMapStoreFactory.store('vaults');
      final previous = await databaseFactoryIo.openDatabase(path);
      final encrypted = {
        'cipherText': 'encrypted',
        'nonce': 'nonce',
        'vaultSalt': 'salt',
      };
      await records.record('vault').put(previous, encrypted);
      await previous.close();
      final worker = await openVaultDatabaseWorker(path);
      addTearDown(() => worker('close', null, null));
      expect(await worker('read', 'vault', null), encrypted);
      await Future.wait([
        for (var i = 0; i < 10; i++)
          worker('write', 'settings', {'revision': i}),
      ]);
      expect(await worker('read', 'settings', null), {'revision': 9});
      await worker('close', null, null);
      await expectLater(worker('read', 'vault', null), throwsStateError);
      final reopened = await databaseFactoryIo.openDatabase(path);
      expect(await records.record('vault').get(reopened), encrypted);
      expect(await records.record('settings').get(reopened), {'revision': 9});
      await reopened.close();
    },
  );

  test(
    'large encrypted writes leave the caller event loop available',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'vault-worker-large-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final worker = await openVaultDatabaseWorker(
        '${directory.path}/vault.db',
      );
      addTearDown(() => worker('close', null, null));
      final ciphertext = 'A' * (32 * 1024 * 1024);
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 10),
        (_) => ticks++,
      );
      try {
        await worker('write', 'vault', {'cipherText': ciphertext});
      } finally {
        timer.cancel();
      }
      expect(ticks, greaterThan(1));
      final saved = await worker('read', 'vault', null) as Map;
      expect(saved['cipherText'], ciphertext);
    },
  );

  test('database open failures reach the caller instead of hanging', () async {
    final directory = await Directory.systemTemp.createTemp(
      'vault-worker-error-',
    );
    addTearDown(() => directory.delete(recursive: true));
    await expectLater(
      openVaultDatabaseWorker(
        directory.path,
      ).timeout(const Duration(seconds: 5)),
      throwsStateError,
    );
  });

  test(
    'concurrent closes all await queued writes before the file can reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'vault-worker-close-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/vault.db';
      final worker = await openVaultDatabaseWorker(path);
      addTearDown(() => worker('close', null, null));
      final write = worker('write', 'vault', {
        'cipherText': 'A' * (4 * 1024 * 1024),
      });
      var written = false;
      final trackedWrite = write.then((_) => written = true);
      final firstClose = worker('close', null, null);
      await worker('close', null, null);
      expect(written, isTrue);
      await trackedWrite;
      await firstClose;
      final reopened = await databaseFactoryIo.openDatabase(path);
      final record = await stringMapStoreFactory
          .store('vaults')
          .record('vault')
          .get(reopened);
      expect((record!['cipherText'] as String).length, 4 * 1024 * 1024);
      await reopened.close();
    },
  );

  test(
    'real filesystem write failure is reported and retry preserves the existing format',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'vault-worker-write-error-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/vault.db';
      final backup = '$path.saved';
      final worker = await openVaultDatabaseWorker(path);
      addTearDown(() => worker('close', null, null));
      await worker('write', 'vault', {
        'cipherText': 'previous encrypted snapshot',
      });
      await File(path).rename(backup);
      await Directory(path).create();
      await expectLater(
        worker('write', 'vault', {'cipherText': 'new encrypted snapshot'}),
        throwsStateError,
      );
      final old = await databaseFactoryIo.openDatabase(backup);
      expect(
        await stringMapStoreFactory.store('vaults').record('vault').get(old),
        {'cipherText': 'previous encrypted snapshot'},
      );
      await old.close();
      await Directory(path).delete();
      await File(backup).rename(path);
      await worker('write', 'vault', {'cipherText': 'new encrypted snapshot'});
      await worker('close', null, null);
      final reopened = await databaseFactoryIo.openDatabase(path);
      expect(
        await stringMapStoreFactory
            .store('vaults')
            .record('vault')
            .get(reopened),
        {'cipherText': 'new encrypted snapshot'},
      );
      await reopened.close();
    },
  );
}
