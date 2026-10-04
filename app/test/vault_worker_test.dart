import 'dart:async';
import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/crypto_service.dart';
import 'package:app/models.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  Future<VaultCrypto> unlocked(String phrase) async {
    final crypto = VaultCrypto();
    await crypto.unlock(
      email: 'worker@example.test',
      passphrase: phrase,
      vaultSalt: 'salt',
    );
    addTearDown(crypto.lock);
    return crypto;
  }

  test(
    'worker snapshots preserve model JSON and authenticated envelope compatibility',
    () async {
      final crypto = await unlocked('private worker vault phrase');
      final conversation = Conversation(
        id: 'thread',
        title: 'Private conversation',
        source: 'discord',
        participantIds: ['person'],
        sourceThreadId: 'discord:thread',
        segments: [ConversationSegment(id: 'message', text: 'Secret words')],
      );
      final payload = await crypto.encryptJson({
        'conversations': [conversation],
      }, background: true);
      expect(payload.cipherText, isNot(contains('Secret words')));
      final expected = {
        'conversations': [conversation.toJson()],
      };
      expect(
        await crypto.decryptJson(
          cipherText: payload.cipherText,
          nonce: payload.nonce,
        ),
        expected,
      );
      expect(
        await crypto.decryptJson(
          cipherText: payload.cipherText,
          nonce: payload.nonce,
          background: true,
        ),
        expected,
      );
      final wrong = await unlocked('different private worker phrase');
      await expectLater(
        wrong.decryptJson(
          cipherText: payload.cipherText,
          nonce: payload.nonce,
          background: true,
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      crypto.lock();
      await expectLater(
        crypto.encryptJson({}, background: true),
        throwsStateError,
      );
    },
  );

  test(
    'large native snapshot work lets input events run before completion',
    () async {
      final crypto = await unlocked('private worker vault phrase');
      final snapshot = {
        'messages': List.generate(
          15000,
          (i) => {
            'id': '$i',
            'text':
                'An exported discussion about deployment and planning. ' * 6,
          },
        ),
      };
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => ticks++,
      );
      addTearDown(timer.cancel);
      final payload = await crypto.encryptJson(snapshot, background: true);
      expect(
        ticks,
        greaterThan(1),
        reason: 'Input must run during serialization and encryption.',
      );
      ticks = 0;
      final restored = await crypto.decryptJson(
        cipherText: payload.cipherText,
        nonce: payload.nonce,
        background: true,
      );
      expect(
        ticks,
        greaterThan(1),
        reason: 'Input must run during decryption and JSON parsing.',
      );
      expect(restored['messages'], hasLength(15000));
    },
  );

  test(
    'busy import keeps prior search results then swaps the completed index',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final api = LifenizerApiClient(
        baseUrl: 'https://vault.test',
        client: MockClient((request) async {
          if (request.url.path == '/api/imports/discord') {
            entered.complete();
            await release.future;
            return http.Response(
              jsonEncode(
                NormalizedImportResult(
                  source: 'discord',
                  plaintextCompute: true,
                  message: 'Imported',
                  participants: [],
                  conversations: [
                    NormalizedConversation(
                      title: 'New thread',
                      source: 'discord',
                      participantNames: [],
                      segments: [NormalizedSegment(text: 'pineapple')],
                    ),
                  ],
                ).toJson(),
              ),
              200,
            );
          }
          if (request.url.path == '/api/sync/push') {
            return http.Response('{"cursor":0}', 200);
          }
          if (request.url.path == '/api/sync/pull') {
            return http.Response('{"cursor":0,"envelopes":[]}', 200);
          }
          return http.Response('not found', 404);
        }),
      );
      final state = LifenizerAppState();
      addTearDown(state.dispose);
      await state.debugAuthenticateForTesting(api);
      state.conversations.add(
        Conversation(
          id: 'old',
          title: 'Existing thread',
          source: 'discord',
          participantIds: [],
          segments: [
            ConversationSegment(id: 'old-message', text: 'Insurance renewal'),
          ],
        ),
      );
      expect(state.search('insurance').single.id, 'old');
      final importing = state.importSource(source: 'discord', text: 'payload');
      await entered.future;
      try {
        expect(state.busy, isTrue);
        expect(state.search('insurance').single.id, 'old');
        expect(state.search('pineapple'), isEmpty);
      } finally {
        release.complete();
        await importing;
      }
      expect(state.error, isNull);
      expect(state.busy, isFalse);
      expect(state.search('pineapple').single.title, 'New thread');
      await state.lock();
      expect(state.search('insurance'), isEmpty);
      expect(state.search('pineapple'), isEmpty);
    },
  );
}
