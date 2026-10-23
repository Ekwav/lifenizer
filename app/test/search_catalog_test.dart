import 'dart:convert';

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
      }
      catalog.loadDetails({
        for (final entry in original.documents.entries)
          entry.key: {
            'haystack': entry.value.haystack,
            'termFrequency': entry.value.termFrequency,
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

  for (final useNative in [true, false]) {
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
        expect(
          catalog.lookupCandidates(['invoice']),
          original.lookupCandidates(['invoice']),
        );
        for (var bucket = 0; bucket < 4; bucket++) {
          final details = useNative
              ? await web.decodeSearchDetails(parts.details[bucket])
              : await native.decodeSearchDetails(parts.details[bucket]);
          expect(details.keys.toSet(), {
            for (final id in original.documents.keys)
              if (vaultChunkFor(id, 4) == bucket) id,
          });
          catalog.loadDetails(details);
        }
        for (final entry in original.documents.entries) {
          final document = catalog.documents[entry.key]!;
          expect(document.detailsLoaded, isTrue);
          expect(document.haystack, entry.value.haystack);
          expect(document.termFrequency, entry.value.termFrequency);
          expect(
            catalog.lexicalScore(document, 'invoice', ['invoice']),
            original.lexicalScore(entry.value, 'invoice', ['invoice']),
          );
        }
      },
    );
  }
}
