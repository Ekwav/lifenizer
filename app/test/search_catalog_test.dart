import 'dart:convert';

import 'package:app/crypto_service.dart';
import 'package:app/models.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:app/services/search_index_worker_io.dart' as native;
import 'package:app/services/search_index_worker_web.dart' as web;
import 'package:app/services/vault_chunks.dart';
import 'package:flutter_test/flutter_test.dart';

Conversation conversation(String id, String text) => Conversation(
  id: id,
  title: 'Archive $id',
  source: 'email',
  participantIds: const ['alice'],
  segments: [ConversationSegment(id: id, text: text)],
);
ConversationSearchIndex build(List<Conversation> conversations) =>
    ConversationSearchIndex.build(
      conversations: conversations,
      participantById: const {'alice': 'Alice'},
      relationTextByConversation: const {},
    );

void main() {
  test('compact previews stay short without truncating searchable content', () {
    final text = '${'A longer conversation. ' * 100} zebralantern';
    final original = build([conversation('one', text)]);
    final catalog = ConversationSearchIndex.fromJson(
      original.toJson(includeDetails: false),
    );
    expect(catalog.documents['one']!.conversation.previewText.length, 180);
    expect(catalog.lookupCandidates(['zebralantern']), {'one'});
    expect(original.documents['one']!.conversation.segments.single.text, text);
  });

  test(
    'catalog retains candidates and hydrates scoring without replacing live data',
    () {
      final original = build([
        conversation('one', 'invoice invoice amount 12345'),
        conversation('two', 'Berlin train ticket'),
      ]);
      final catalog = ConversationSearchIndex.fromJson(
        jsonDecode(jsonEncode(original.toJson(includeDetails: false)))
            as Map<String, dynamic>,
      );
      expect(catalog.invertedIndex, original.invertedIndex);
      expect(catalog.idf, original.idf);
      expect(catalog.averageLength, original.averageLength);
      for (final query in ['invoice', 'ticket', '12345']) {
        expect(
          catalog.lookupCandidates([query]),
          original.lookupCandidates([query]),
        );
      }
      final live = conversation('one', 'live body');
      catalog.rebind({'one': live});
      for (final document in catalog.documents.values) {
        expect(document.detailsLoaded, isFalse);
        expect(document.haystack, isEmpty);
        expect(document.termFrequency, isEmpty);
        expect(document.titleTokens, isEmpty);
        expect(document.personTokens, isEmpty);
      }
      catalog.loadDetails({
        for (final entry in original.documents.entries)
          entry.key: {
            'haystack': entry.value.haystack,
            'termFrequency': entry.value.termFrequency,
            'titleTokens': entry.value.titleTokens.toList(),
            'personTokens': entry.value.personTokens.toList(),
          },
      });
      expect(identical(catalog.documents['one']!.conversation, live), isTrue);
      for (final id in original.documents.keys) {
        final document = catalog.documents[id]!;
        expect(document.detailsLoaded, isTrue);
        expect(document.length, original.documents[id]!.length);
        expect(document.vectorNorm, original.documents[id]!.vectorNorm);
        expect(
          catalog.lexicalScore(document, 'invoice', ['invoice']),
          original.lexicalScore(original.documents[id]!, 'invoice', [
            'invoice',
          ]),
        );
        expect(
          catalog.vectorScore(document, ['invoice']),
          original.vectorScore(original.documents[id]!, ['invoice']),
        );
      }
    },
  );

  test(
    'legacy scoring buckets retain title and person tokens from their catalog',
    () {
      final original = build([conversation('one', 'invoice amount')]);
      final json = original.toJson(includeDetails: false);
      final row = (json['documents'] as List).single as List;
      final document = original.documents['one']!;
      row[2] = document.titleTokens.toList();
      row[3] = document.personTokens.toList();
      final legacy = ConversationSearchIndex.fromJson(json);
      legacy.loadDetails({
        'one': {
          'haystack': document.haystack,
          'termFrequency': document.termFrequency,
        },
      });
      final restored = legacy.documents['one']!;
      expect(restored.titleTokens, document.titleTokens);
      expect(restored.personTokens, document.personTokens);
      for (final query in ['alice', 'archive']) {
        expect(
          legacy.lexicalScore(restored, query, [query]),
          original.lexicalScore(document, query, [query]),
        );
      }
    },
  );

  test('partial updates detach postings and ignore stale detail loads', () {
    final original = build([
      conversation('one', 'invoice amount'),
      conversation('two', 'Berlin ticket'),
    ]);
    final catalog = ConversationSearchIndex.fromJson(
      original.toJson(includeDetails: false),
    );
    catalog.upsert(
      conversation('one', 'replacement statement'),
      participantById: const {},
      relationTextByConversation: const {},
    );
    catalog.remove('two');
    catalog.loadDetails({
      for (final entry in original.documents.entries)
        entry.key: {
          'haystack': entry.value.haystack,
          'termFrequency': entry.value.termFrequency,
        },
    });
    expect(catalog.documents['one']!.detailsLoaded, isTrue);
    expect(catalog.documents['one']!.termFrequency, contains('replacement'));
    expect(catalog.documents['one']!.termFrequency, isNot(contains('invoice')));
    expect(catalog.documents, isNot(contains('two')));
    expect(catalog.lookupCandidates(['invoice']), isEmpty);
    expect(catalog.lookupCandidates(['berlin']), isEmpty);
    expect(catalog.lookupCandidates(['replacement']), {'one'});
  });

  test(
    'compact catalog keeps vocabulary and IDF while posting buckets load on demand',
    () {
      final original = build([
        conversation('one', 'invoice invoice amount 12345'),
        conversation('two', 'Berlin train ticket'),
      ]);
      final json = original.toJson(
        includeDetails: false,
        includePostings: false,
      );
      expect(json.containsKey('postings'), false);
      final catalog = ConversationSearchIndex.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      );
      expect(catalog.postingsLoaded, false);
      expect(catalog.unloadedPostingTerms, original.invertedIndex.keys.toSet());
      expect(catalog.idf, original.idf);
      expect(catalog.averageLength, original.averageLength);
      expect(
        catalog.expandTokens(['invoice', 'berl', '12345']),
        original.expandTokens(['invoice', 'berl', '12345']),
      );
      expect(catalog.lookupCandidates([]), {'one', 'two'});
      expect(catalog.invertedIndex.values.every((ids) => ids.isEmpty), true);
      catalog.loadPostings({
        'invoice': ['one', 'missing'],
        'not-in-vocabulary': ['two'],
      });
      expect(catalog.lookupCandidates(['invoice']), {'one'});
      expect(catalog.unloadedPostingTerms, isNot(contains('invoice')));
      expect(catalog.postingsLoaded, false);
      expect(
        () => catalog.upsert(
          conversation('one', 'replacement'),
          participantById: {},
          relationTextByConversation: {},
        ),
        throwsStateError,
      );
      expect(() => catalog.remove('two'), throwsStateError);
      expect(catalog.refreshStatistics, throwsStateError);
      expect(catalog.toJson, throwsStateError);
      expect(catalog.documents.keys, unorderedEquals(['one', 'two']));
      catalog.loadPostings({
        for (final entry in original.invertedIndex.entries)
          entry.key: entry.value.toList(),
      });
      expect(catalog.postingsLoaded, true);
      expect(catalog.unloadedPostingTerms, isEmpty);
      expect(catalog.invertedIndex, original.invertedIndex);
      for (final query in ['invoice', 'ticket', '12345']) {
        expect(
          catalog.lookupCandidates([query]),
          original.lookupCandidates([query]),
        );
      }
      catalog.upsert(
        conversation('one', 'replacement statement'),
        participantById: {},
        relationTextByConversation: {},
      );
      catalog.remove('two');
      catalog.loadPostings({
        for (final entry in original.invertedIndex.entries)
          entry.key: entry.value.toList(),
      });
      expect(catalog.lookupCandidates(['invoice']), isEmpty);
      expect(catalog.lookupCandidates(['ticket']), isEmpty);
      expect(catalog.lookupCandidates(['replacement']), {'one'});
    },
  );

  test('empty and legacy full catalogs remain fully loaded', () {
    final empty = ConversationSearchIndex.fromJson(
      build([]).toJson(includeDetails: false, includePostings: false),
    );
    expect(empty.postingsLoaded, true);
    expect(empty.unloadedPostingTerms, isEmpty);
    expect(empty.lookupCandidates(['anything']), isEmpty);
    final original = build([conversation('one', 'invoice')]);
    final legacy = ConversationSearchIndex.fromJson(original.toJson());
    expect(legacy.postingsLoaded, true);
    expect(legacy.unloadedPostingTerms, isEmpty);
    expect(legacy.toJson(), original.toJson());
  });

  for (final useNative in [true, false]) {
    test(
      'encrypted catalog authenticates before decoding ${useNative ? 'native' : 'web'}',
      () async {
        final crypto = VaultCrypto()..unlockDeviceKey(List<int>.filled(32, 7));
        addTearDown(crypto.lock);
        final parts = await native.encodeSearchSnapshotParts(
          build([conversation('one', 'invoice')]),
          2,
        );
        final encrypted = await crypto.encryptJson({
          ...parts.catalog,
          'cacheVersion': 3,
          'detailNonces': ['detail-a', 'detail-b'],
          'postingNonces': ['posting-a', 'posting-b'],
        });
        final decode = useNative
            ? native.decryptSearchSnapshot
            : web.decryptSearchSnapshot;
        final decoded = await decode(
          crypto,
          cipherText: encrypted.cipherText,
          nonce: encrypted.nonce,
        );
        expect(decoded.index.documents.keys, ['one']);
        expect(decoded.index.documents['one']!.detailsLoaded, false);
        expect(decoded.index.postingsLoaded, false);
        expect(decoded.metadata, {
          'cacheVersion': 3,
          'detailNonces': ['detail-a', 'detail-b'],
          'postingNonces': ['posting-a', 'posting-b'],
        });
        final wrongKey = VaultCrypto()
          ..unlockDeviceKey(List<int>.filled(32, 8));
        addTearDown(wrongKey.lock);
        await expectLater(
          decode(
            wrongKey,
            cipherText: encrypted.cipherText,
            nonce: encrypted.nonce,
          ),
          throwsA(anything),
        );
        expect(crypto.isUnlocked, true);
      },
    );
    test(
      'parts codec handles empty corpora and refuses unloaded posting writes ${useNative ? 'native' : 'web'}',
      () async {
        final parts = useNative
            ? await native.encodeSearchSnapshotParts(build([]), 3)
            : await web.encodeSearchSnapshotParts(build([]), 3);
        final empty = useNative
            ? await web.decodeSearchSnapshot(parts.catalog)
            : await native.decodeSearchSnapshot(parts.catalog);
        expect(empty.postingsLoaded, true);
        expect(parts.postings, hasLength(3));
        for (final bucket in parts.postings) {
          expect(await native.decodeSearchDetails(bucket), isEmpty);
        }
        final partial = ConversationSearchIndex.fromJson(
          build([
            conversation('one', 'invoice'),
          ]).toJson(includeDetails: false, includePostings: false),
        );
        await expectLater(
          useNative
              ? native.encodeSearchSnapshotParts(partial, 3)
              : web.encodeSearchSnapshotParts(partial, 3),
          throwsStateError,
        );
      },
    );
    test(
      'parts partition details and cross-decode ${useNative ? 'native to web' : 'web to native'}',
      () async {
        final original = build([
          for (var i = 0; i < 20; i++)
            conversation('chat-$i', 'Invoice amount $i'),
        ]);
        final parts = useNative
            ? await native.encodeSearchSnapshotParts(original, 4)
            : await web.encodeSearchSnapshotParts(original, 4);
        final catalog = useNative
            ? await web.decodeSearchSnapshot(parts.catalog)
            : await native.decodeSearchSnapshot(parts.catalog);
        expect(
          catalog.documents.values.every((document) => !document.detailsLoaded),
          isTrue,
        );
        expect(catalog.postingsLoaded, false);
        expect(
          catalog.unloadedPostingTerms,
          original.invertedIndex.keys.toSet(),
        );
        expect(catalog.idf, original.idf);
        for (final document in catalog.documents.values) {
          expect(document.titleTokens, isEmpty);
          expect(document.personTokens, isEmpty);
        }
        for (var bucket = 0; bucket < 4; bucket++) {
          final postings = useNative
              ? await web.decodeSearchDetails(parts.postings[bucket])
              : await native.decodeSearchDetails(parts.postings[bucket]);
          expect(postings.keys.toSet(), {
            for (final term in original.invertedIndex.keys)
              if (vaultChunkFor(term, 4) == bucket) term,
          });
          catalog.loadPostings(postings);
          final details = useNative
              ? await web.decodeSearchDetails(parts.details[bucket])
              : await native.decodeSearchDetails(parts.details[bucket]);
          expect(details.keys.toSet(), {
            for (final id in original.documents.keys)
              if (vaultChunkFor(id, 4) == bucket) id,
          });
          catalog.loadDetails(details);
        }
        expect(catalog.postingsLoaded, true);
        expect(catalog.invertedIndex, original.invertedIndex);
        expect(
          catalog.lookupCandidates(['invoice']),
          original.lookupCandidates(['invoice']),
        );
        for (final entry in original.documents.entries) {
          final document = catalog.documents[entry.key]!;
          expect(document.detailsLoaded, isTrue);
          expect(document.haystack, entry.value.haystack);
          expect(document.termFrequency, entry.value.termFrequency);
          expect(document.titleTokens, entry.value.titleTokens);
          expect(document.personTokens, entry.value.personTokens);
          for (final query in ['alice', 'archive']) {
            expect(
              catalog.lookupCandidates([query]),
              original.lookupCandidates([query]),
            );
            expect(
              catalog.lexicalScore(document, query, [query]),
              original.lexicalScore(entry.value, query, [query]),
            );
          }
          expect(
            catalog.lexicalScore(document, 'invoice', ['invoice']),
            original.lexicalScore(entry.value, 'invoice', ['invoice']),
          );
        }
      },
    );
  }
}
