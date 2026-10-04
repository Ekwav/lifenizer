import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/crypto_service.dart';
import 'package:app/models.dart';
import 'package:app/pages/participants_page.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sembast/sembast_memory.dart';

class _Server {
  final envelopes = <Map<String, dynamic>>[];
  bool offline = false;
  Future<http.Response> handle(http.Request request) async {
    if (offline) throw http.ClientException('Offline');
    Object result;
    if (request.url.path.startsWith('/api/auth/')) {
      result = {
        'authToken': 'token',
        'userId': 'user',
        'vaultId': 'vault',
        'vaultSalt': 'salt',
      };
    } else if (request.url.path == '/api/imports/capabilities') {
      result = [];
    } else if (request.url.path == '/api/sync/push') {
      for (final raw in jsonDecode(request.body)['envelopes'] as List) {
        if (!envelopes.any((e) => e['id'] == raw['id'])) {
          envelopes.add({
            ...Map<String, dynamic>.from(raw),
            'serverSequence': envelopes.length + 1,
          });
        }
      }
      result = {'cursor': envelopes.length};
    } else if (request.url.path == '/api/sync/pull') {
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
}

void main() {
  var nextStore = 0;
  Future<LocalVaultStore> store() async {
    final database = await databaseFactoryMemory.openDatabase(
      'people-${nextStore++}',
    );
    addTearDown(database.close);
    return LocalVaultStore(database);
  }

  LifenizerAppState device(_Server server, LocalVaultStore disk) {
    final state = LifenizerAppState(
      localStore: disk,
      apiFactory: (url) =>
          LifenizerApiClient(baseUrl: url, client: MockClient(server.handle)),
    );
    addTearDown(state.dispose);
    return state;
  }

  Future<void> login(LifenizerAppState state, {bool offline = false}) =>
      state.login(
        baseUrl: 'https://vault.test',
        email: 'owner@example.test',
        password: 'account password',
        passphrase: 'private person vault phrase',
        offline: offline,
      );

  test(
    'canonical identity matching is exact; equal names with different known IDs stay separate',
    () async {
      final state = LifenizerAppState();
      addTearDown(state.dispose);
      final sam1 = await state.ensureParticipantIdentity(
        'Sam',
        identifiers: [' Discord:000123456789012345 '],
        persist: false,
      );
      final sam2 = await state.ensureParticipantIdentity(
        'Sam',
        identifiers: ['discord:123456789012346'],
        persist: false,
      );
      final renamed = await state.ensureParticipantIdentity(
        'Samuel',
        identifiers: ['discord:123456789012345'],
        aliases: ['Sam#1001'],
        persist: false,
      );
      expect(renamed.id, sam1.id);
      expect(renamed.aliases, containsAll(['Samuel', 'Sam#1001']));
      expect(sam2.id, isNot(sam1.id));
      final email = await state.ensureParticipantIdentity(
        'SAM@Example.Test',
        persist: false,
      );
      expect(email.identifiers, ['email:sam@example.test']);
      expect(state.activeParticipants, hasLength(3));
      final anotherDevice = LifenizerAppState();
      addTearDown(anotherDevice.dispose);
      final sameDiscord = await anotherDevice.ensureExternalParticipant(
        provider: 'discord',
        externalId: '123456789012345',
        displayName: 'Different nickname',
        persist: false,
      );
      expect(sameDiscord.id, sam1.id);
      final unknown = await state.ensureParticipantIdentity(
        'Sam',
        persist: false,
      );
      final unknownAgain = await state.ensureParticipantIdentity(
        'Sam',
        persist: false,
      );
      expect(unknown.id, unknownAgain.id);
    },
  );

  test(
    'merges survive encrypted restart, second-device sync, stale events and future re-import',
    () async {
      final server = _Server();
      final disk = await store();
      final state = device(server, disk);
      await login(state);
      final discord = await state.ensureExternalParticipant(
        provider: 'discord',
        externalId: '123456789012345',
        displayName: 'Nova',
        aliases: ['Nova#1001'],
      );
      final email = await state.ensureParticipantIdentity(
        'Mara',
        identifiers: [' EMAIL:Mara@Example.TEST '],
      );
      final oldParticipant = server.envelopes.firstWhere(
        (e) => e['entityId'] == discord.id,
      );
      await state.addManualText(
        title: 'Launch plan',
        participantNames: 'Nova',
        text: 'Prepare deployment',
      );
      final original = state.conversations.single;
      state.conversations[0] = Conversation.fromJson({
        ...original.toJson(),
        'sourceThreadId': 'discord:thread',
        'segments': [
          {
            ...original.segments.single.toJson(),
            'participantId': discord.id,
            'sourceMessageId': 'discord:message',
            'attachmentUrls': ['https://example.test/file'],
          },
        ],
      });
      await state.mergeParticipants(discord.id, email.id);
      expect(state.error, isNull);
      expect(state.activeParticipants.map((p) => p.id), [email.id]);
      expect(state.participantById(discord.id)!.id, email.id);
      expect(state.conversations.single.participantIds, [email.id]);
      expect(
        state.conversations.single.segments.single.participantId,
        email.id,
      );
      for (final query in [
        'Nova#1001',
        'mara@example.test',
        'discord:123456789012345',
      ]) {
        expect(state.search(query).map((c) => c.id), [
          original.id,
        ], reason: query);
      }
      expect(state.search('', participantId: discord.id).map((c) => c.id), [
        original.id,
      ]);
      await state.lock();
      server.offline = true;
      final restarted = device(server, disk);
      await login(restarted, offline: true);
      expect(restarted.participantById(discord.id)!.id, email.id);
      expect(restarted.conversations.single.segments.single.attachmentUrls, [
        'https://example.test/file',
      ]);
      final importedAgain = await restarted.ensureExternalParticipant(
        provider: 'discord',
        externalId: '123456789012345',
        displayName: 'New Nova',
      );
      expect(importedAgain.id, email.id);
      expect(restarted.activeParticipants, hasLength(1));
      server.offline = false;
      await restarted.pullSync();
      server.envelopes.add({
        ...oldParticipant,
        'id': 'stale-old-participant',
        'serverSequence': server.envelopes.length + 1,
      });
      await restarted.pullSync();
      expect(restarted.activeParticipants, hasLength(1));
      expect(restarted.participantById(discord.id)!.id, email.id);
      final second = device(server, await store());
      await login(second);
      expect(second.participantById(discord.id)!.id, email.id);
      expect(second.activeParticipants, hasLength(1));
      expect(second.search('New Nova').map((c) => c.id), [original.id]);
      expect(
        (await second.ensureParticipantIdentity(
          'Mara',
          identifiers: ['email:mara@example.test'],
        )).id,
        email.id,
      );
    },
  );

  test(
    'offline Discord-plus-email and email-only imports coalesce immediately after sync',
    () async {
      final server = _Server();
      final first = device(server, await store());
      final second = device(server, await store());
      await login(first);
      await login(second);
      server.offline = true;
      final discord = await first.ensureParticipantIdentity(
        'Nova',
        identifiers: ['discord:123456789012345', 'email:mara@example.test'],
      );
      final email = await second.ensureParticipantIdentity(
        'Mara',
        identifiers: ['email:mara@example.test'],
      );
      expect(discord.id, isNot(email.id));
      server.offline = false;
      await first.pullSync();
      await second.pullSync();
      await first.pullSync();
      await second.pullSync();
      expect(first.activeParticipants, hasLength(1));
      expect(second.activeParticipants, hasLength(1));
      expect(
        first.resolveParticipantId(discord.id),
        second.resolveParticipantId(email.id),
      );
      expect(
        first.activeParticipants.single.identifiers,
        containsAll(['discord:123456789012345', 'email:mara@example.test']),
      );
      expect(
        second.activeParticipants.single.identifiers,
        containsAll(['discord:123456789012345', 'email:mara@example.test']),
      );
    },
  );

  test(
    'later pull pages retain identity updates while earlier coalescing is pending',
    () async {
      final server = _Server();
      final crypto = VaultCrypto();
      await crypto.unlock(
        email: 'owner@example.test',
        passphrase: 'private person vault phrase',
        vaultSalt: 'salt',
      );
      addTearDown(crypto.lock);
      Future<Map<String, dynamic>> encrypted(Participant person) async {
        final payload = await crypto.encryptJson(person.toJson());
        return SyncEnvelope(
          id: 'template',
          deviceId: 'other-device',
          entityType: 'participant',
          entityId: person.id,
          operation: 'upsert',
          revision: 1,
          cipherText: payload.cipherText,
          nonce: payload.nonce,
          keyId: payload.keyId,
          clientCreatedAt: DateTime.utc(2026),
        ).toJson();
      }

      final discord = await encrypted(
        Participant(
          id: 'b',
          displayName: 'Nova',
          identifiers: ['discord:123456789012345', 'email:mara@example.test'],
        ),
      );
      final email = await encrypted(
        Participant(
          id: 'a',
          displayName: 'Mara',
          identifiers: ['email:mara@example.test'],
        ),
      );
      final updated = await encrypted(
        Participant(
          id: 'a',
          displayName: 'Mara',
          identifiers: ['email:mara@example.test', 'email:work@example.test'],
          aliases: ['Work alias'],
        ),
      );
      for (var i = 0; i < 501; i++) {
        server.envelopes.add({
          ...(i == 1
              ? email
              : i == 500
              ? updated
              : discord),
          'id': 'event-$i',
          'serverSequence': i + 1,
        });
      }
      final first = device(server, await store());
      await login(first);
      expect(first.activeParticipants, hasLength(1));
      expect(first.activeParticipants.single.aliases, contains('Work alias'));
      expect(
        first.activeParticipants.single.identifiers,
        containsAll(['discord:123456789012345', 'email:work@example.test']),
      );
      await first.pullSync();
      expect(first.pendingSyncCount, 0);
      final second = device(server, await store());
      await login(second);
      expect(second.activeParticipants, hasLength(1));
      expect(second.activeParticipants.single.aliases, contains('Work alias'));
      expect(
        second.activeParticipants.single.identifiers,
        first.activeParticipants.single.identifiers,
      );
      await second.pullSync();
      await first.pullSync();
      final count = server.envelopes.length;
      await first.pullSync();
      await second.pullSync();
      expect(server.envelopes, hasLength(count));
    },
  );

  test('redirect cycles converge to one stable person without hanging', () {
    final state = LifenizerAppState();
    addTearDown(state.dispose);
    state.participants.addAll([
      Participant(id: 'b', displayName: 'B', mergedInto: 'a'),
      Participant(id: 'a', displayName: 'A', mergedInto: 'b'),
    ]);
    expect(state.resolveParticipantId('a'), 'a');
    expect(state.resolveParticipantId('b'), 'a');
    expect(state.activeParticipants.map((p) => p.id), ['a']);
  });

  testWidgets(
    'People search paginates a large address book and finds identities',
    (tester) async {
      final state = LifenizerAppState();
      addTearDown(state.dispose);
      state.participants.addAll(
        List.generate(
          1500,
          (i) => Participant(
            id: '$i',
            displayName: 'Person $i',
            identifiers: ['email:person$i@example.test'],
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ParticipantsPage(state: state)),
        ),
      );
      expect(find.text('1500 people'), findsOneWidget);
      expect(find.byType(PopupMenuButton<String>), findsNWidgets(50));
      await tester.enterText(find.byType(TextField), 'person1499@example.test');
      await tester.pump();
      expect(find.text('1 person'), findsOneWidget);
      expect(find.text('Person 1499'), findsOneWidget);
      expect(find.byType(PopupMenuButton<String>), findsOneWidget);
    },
  );
}
