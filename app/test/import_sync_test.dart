import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/crypto_service.dart';
import 'package:app/models.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sembast/sembast_memory.dart';

class _Server {
  final envelopes = <Map<String, dynamic>>[];
  final crypto = VaultCrypto();
  bool syncOffline = false;
  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    if (syncOffline && path.startsWith('/api/sync/')) {
      throw http.ClientException('Sync offline');
    }
    Object result;
    if (path.startsWith('/api/auth/')) {
      result = {
        'authToken': 'token',
        'userId': 'user',
        'vaultId': 'vault',
        'vaultSalt': 'salt',
      };
    } else if (path == '/api/imports/capabilities') {
      result = [];
    } else if (path == '/api/imports/discord') {
      final message = jsonDecode(request.body)['text'] as String;
      result = NormalizedImportResult(
        source: 'discord',
        plaintextCompute: true,
        message: 'Imported',
        participants: [],
        conversations: [
          NormalizedConversation(
            title: 'Thread',
            source: 'discord',
            sourceThreadId: 'discord:thread',
            participantNames: [],
            segments: [
              NormalizedSegment(
                text: message,
                sourceMessageId: message,
                createdAt: DateTime.utc(2026, 1, message == 'a' ? 1 : 2),
              ),
            ],
          ),
        ],
      ).toJson();
    } else if (path == '/api/sync/push') {
      for (final raw in jsonDecode(request.body)['envelopes'] as List) {
        if (!envelopes.any((e) => e['id'] == raw['id'])) {
          envelopes.add({
            ...Map<String, dynamic>.from(raw),
            'serverSequence': envelopes.length + 1,
          });
        }
      }
      result = {'cursor': envelopes.length};
    } else if (path == '/api/sync/pull') {
      final since = int.parse(request.url.queryParameters['since']!);
      final items = envelopes
          .where((e) => (e['serverSequence'] as int) > since)
          .take(500)
          .toList();
      result = {
        'cursor': items.isEmpty ? since : items.last['serverSequence'],
        'envelopes': items,
      };
    } else {
      return http.Response('not found', 404);
    }
    return http.Response(jsonEncode(result), 200);
  }

  Future<void> publish(Conversation conversation) async {
    final payload = await crypto.encryptJson(conversation.toJson());
    envelopes.add(
      SyncEnvelope(
        id: 'injected-${envelopes.length}',
        deviceId: 'other-device',
        entityType: 'conversation',
        entityId: conversation.id,
        operation: 'upsert',
        revision: 1,
        cipherText: payload.cipherText,
        nonce: payload.nonce,
        keyId: payload.keyId,
        clientCreatedAt: DateTime.utc(2026),
      ).toJson()..['serverSequence'] = envelopes.length + 1,
    );
  }
}

void main() {
  var nextDatabase = 0;
  Future<LifenizerAppState> device(_Server server) async {
    final db = await databaseFactoryMemory.openDatabase(
      'import-race-${nextDatabase++}',
    );
    final state = LifenizerAppState(
      localStore: LocalVaultStore(db),
      apiFactory: (url) =>
          LifenizerApiClient(baseUrl: url, client: MockClient(server.handle)),
    );
    addTearDown(() async {
      state.dispose();
      await db.close();
    });
    await state.login(
      baseUrl: 'https://vault.test',
      email: 'owner@example.test',
      password: 'account password',
      passphrase: 'private import vault phrase',
    );
    expect(state.error, isNull);
    return state;
  }

  Future<void> drain(LifenizerAppState first, LifenizerAppState second) async {
    for (var i = 0; i < 3; i++) {
      await first.pullSync();
      await second.pullSync();
    }
  }

  test(
    'different offline thread pages converge to a union without endless repairs',
    () async {
      final server = _Server();
      final first = await device(server);
      final second = await device(server);
      server.syncOffline = true;
      await first.importSource(source: 'discord', text: 'a');
      await second.importSource(source: 'discord', text: 'b');
      expect(first.conversations.single.id, second.conversations.single.id);
      server.syncOffline = false;
      await drain(first, second);
      for (final state in [first, second]) {
        expect(
          state.conversations.single.segments
              .map((s) => s.sourceMessageId)
              .toSet(),
          {'a', 'b'},
        );
        expect(state.pendingSyncCount, 0);
        expect(state.conversations.single.startedAt, DateTime.utc(2026, 1, 1));
        expect(state.conversations.single.endedAt, DateTime.utc(2026, 1, 2));
      }
      final count = server.envelopes.length;
      await drain(first, second);
      expect(server.envelopes, hasLength(count));
    },
  );

  test(
    'a complete latest snapshot can clear a favorite without repairs resurrecting it',
    () async {
      final server = _Server();
      await server.crypto.unlock(
        email: 'owner@example.test',
        passphrase: 'private import vault phrase',
        vaultSalt: 'salt',
      );
      addTearDown(server.crypto.lock);
      final first = await device(server);
      await first.importSource(source: 'discord', text: 'a');
      final second = await device(server);
      final conversation = first.conversations.single;
      await server.publish(
        Conversation.fromJson({...conversation.toJson(), 'isFavorite': true}),
      );
      await drain(first, second);
      expect(first.conversations.single.isFavorite, isTrue);
      expect(second.conversations.single.isFavorite, isTrue);
      await server.publish(
        Conversation.fromJson({...conversation.toJson(), 'isFavorite': false}),
      );
      await drain(first, second);
      expect(first.conversations.single.isFavorite, isFalse);
      expect(second.conversations.single.isFavorite, isFalse);
      final count = server.envelopes.length;
      await drain(first, second);
      expect(server.envelopes, hasLength(count));
    },
  );
}
