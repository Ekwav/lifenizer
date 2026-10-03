import 'dart:async';
import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sembast/sembast_memory.dart';

class _FailingStore extends LocalVaultStore {
  _FailingStore(super.database);
  bool failWrites = false;
  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    if (failWrites) throw StateError('Disk full');
    await super.write(key, value);
  }
}

void main() {
  test(
    'lock waits for failing background sync and preserves encrypted outbox',
    () async {
      final db = await databaseFactoryMemory.openDatabase('lock-sync');
      final disk = LocalVaultStore(db);
      var offline = false;
      var delay = false;
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final client = MockClient((request) async {
        if (request.url.path == '/api/sync/push') {
          if (delay) {
            started.complete();
            return response.future;
          }
          if (offline) throw http.ClientException('Offline');
        }
        if (request.url.path == '/api/auth/dev-login') {
          return http.Response(
            jsonEncode({
              'authToken': 'token',
              'userId': 'user',
              'vaultId': 'vault',
              'vaultSalt': 'salt',
            }),
            200,
          );
        }
        if (request.url.path == '/api/imports/capabilities') {
          return http.Response('[]', 200);
        }
        return http.Response(jsonEncode({'cursor': 0, 'envelopes': []}), 200);
      });
      final state = LifenizerAppState(
        localStore: disk,
        apiFactory: (url) => LifenizerApiClient(baseUrl: url, client: client),
      );
      Future<void> unlock({bool offline = false}) => state.login(
        baseUrl: 'http://localhost',
        email: 'alice@example.test',
        passphrase: 'local vault passphrase',
        offline: offline,
      );
      await unlock();
      offline = true;
      await state.addManualText(
        title: 'Unsent note',
        participantNames: '',
        text: 'private saved topic',
      );
      expect(state.pendingSyncCount, 1);
      delay = true;
      final sync = state.syncQuietly();
      await started.future;
      final locking = state.lock();
      expect(state.busy, isTrue);
      response.completeError(http.ClientException('Offline during sync'));
      await Future.wait([sync, locking]);
      expect(state.busy, isFalse);
      expect(state.isAuthenticated, isFalse);
      expect(state.search('private'), isEmpty);
      await unlock(offline: true);
      expect(state.pendingSyncCount, 1);
      expect(state.search('private').single.title, 'Unsent note');
      await state.lock();
      await db.close();
      client.close();
    },
  );

  test(
    'failed recording persistence keeps draft available and explains failed lock',
    () async {
      final db = await databaseFactoryMemory.openDatabase('lock-storage');
      final disk = _FailingStore(db);
      final client = MockClient((request) async {
        if (request.url.path == '/api/auth/dev-login') {
          return http.Response(
            jsonEncode({
              'authToken': 'token',
              'userId': 'user',
              'vaultId': 'vault',
              'vaultSalt': 'salt',
            }),
            200,
          );
        }
        if (request.url.path == '/api/imports/capabilities') {
          return http.Response('[]', 200);
        }
        return http.Response(jsonEncode({'cursor': 0, 'envelopes': []}), 200);
      });
      final state = LifenizerAppState(
        localStore: disk,
        apiFactory: (url) => LifenizerApiClient(baseUrl: url, client: client),
      );
      await state.login(
        baseUrl: 'http://localhost',
        email: 'alice@example.test',
        passphrase: 'local vault passphrase',
      );
      disk.failWrites = true;
      state.stopRecording = () async {
        try {
          await state.saveAudioDraft([1, 2, 3], DateTime.utc(2026));
        } catch (error) {
          state.reportError('Recording save failed: $error');
        }
      };
      await state.lock();
      expect(state.isAuthenticated, isTrue);
      expect(state.busy, isFalse);
      expect(state.audioDraft, isNotNull);
      expect(state.error, contains('Disk full'));
      disk.failWrites = false;
      state.stopRecording = null;
      await state.lock();
      expect(state.isAuthenticated, isFalse);
      await db.close();
      client.close();
    },
  );
}
