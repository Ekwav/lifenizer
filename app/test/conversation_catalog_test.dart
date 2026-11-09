import 'dart:convert';

import 'package:app/models.dart';
import 'package:app/services/conversation_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

Conversation summary(String id) => Conversation.fromSummaryJson(
  jsonDecode(
        jsonEncode({
          'id': id,
          'title': 'Title $id',
          'source': 'discord',
          'participantIds': ['alice', 'bob'],
          'artifactNames': ['notes.txt'],
          'tags': ['work'],
          'metadata': {'messageScope': 'own-sent-messages'},
          'sourceUrl': 'https://example.com/$id',
          'sourceThreadId': 'thread-$id',
          'importFingerprint': 'receipt-$id',
          'isFavorite': true,
          'segmentCount': 27,
          'previewText': 'Preview $id',
          'startedAt': '2026-10-28T12:00:00.000Z',
          'endedAt': '2026-10-28T12:00:00.000Z',
          'location': {'town': 'Berlin', 'venue': 'Office'},
        }),
      )
      as Map<String, dynamic>,
);

void main() {
  test('summary values survive sharing and replacement without bodies', () {
    final first = summary('one'), second = summary('two');
    final catalog = ConversationCatalog()..addAll([first, second]);
    expect(catalog[0].toSummaryJson(), first.toSummaryJson());
    expect(catalog[1].toSummaryJson(), second.toSummaryJson());
    expect(identical(catalog[0].source, catalog[1].source), isTrue);
    expect(
      identical(catalog[0].participantIds, catalog[1].participantIds),
      isTrue,
    );
    expect(identical(catalog[0].tags, catalog[1].tags), isTrue);
    expect(identical(catalog[0].startedAt, catalog[0].endedAt), isTrue);
    expect(catalog[0].isLoaded, isFalse);
    expect(catalog[0].segments, isEmpty);
    expect(() => catalog[0].toJson(), throwsStateError);
    catalog[0] = summary('updated');
    expect(catalog[0].id, 'updated');
    expect(catalog[1].toSummaryJson(), second.toSummaryJson());
  });

  test('live edits retain identity and list operations preserve summaries', () {
    final live = Conversation(
      id: 'live',
      title: 'Edited title',
      source: 'manual',
      participantIds: [],
      segments: [ConversationSegment(id: 'segment', text: 'Full body')],
    );
    final catalog = ConversationCatalog()..add(live);
    expect(identical(catalog.single, live), isTrue);
    catalog.insertAll(0, [summary('two'), summary('one')]);
    final one = catalog[1];
    catalog.sort((a, b) => a.id.compareTo(b.id));
    expect(identical(catalog[1], one), isTrue);
    catalog.removeWhere((item) => item.id == 'two');
    expect(catalog.map((item) => item.id), ['live', 'one']);
    catalog.clear();
    catalog.add(summary('after-clear'));
    expect(catalog.single.id, 'after-clear');
  });

  test(
    'bounded pools do not lose values when unique fields exceed capacity',
    () {
      final catalog = ConversationCatalog();
      for (var i = 0; i < 4200; i++) {
        catalog.add(
          Conversation.fromSummaryJson({
            ...summary('$i').toSummaryJson(),
            'source': 'source-$i',
            'participantIds': ['person-$i'],
          }),
        );
      }
      for (var i = 0; i < catalog.length; i++) {
        expect(catalog[i].source, 'source-$i');
        expect(catalog[i].participantIds, ['person-$i']);
      }
    },
  );

  Conversation withPreview(String id, String text) =>
      Conversation.fromSummaryJson({
        ...summary(id).toSummaryJson(),
        'previewText': text,
      });

  test(
    'all fields preserve mixed Unicode, whitespace and UTF16 code units',
    () {
      final catalog = ConversationCatalog();
      final samples = [
        'alpha  beta\t\ngamma\r\n delta\u00a0epsilon\u2003zeta',
        'hello🚀launch café naïve 日本語 Ελληνικά',
        'word\uD800part\uDFFF tail\u0000middle',
        '\uD800 \uDC00 \uDFFF \uD800\uDC00',
        '',
        'short',
      ];
      for (var n = 0; n < samples.length; n++) {
        final value = samples[n];
        final original = withPreview(
          'unicode-$n',
          List.filled(8, value).join(' '),
        );
        catalog.add(original);
        final retained = catalog.last;
        expect(retained.previewText.codeUnits, original.previewText.codeUnits);
        expect(retained.toSummaryJson(), original.toSummaryJson());
        expect(retained.previewText.codeUnits, original.previewText.codeUnits);
      }
    },
  );

  test('append-only word limit and clear preserve already-held summaries', () {
    final catalog = ConversationCatalog();
    final text = List.filled(20, 'persisted dictionary phrase').join(' ');
    final original = withPreview('held', text);
    catalog.add(original);
    final held = catalog.single;
    for (var n = 0; n < 4500; n++) {
      catalog.add(
        withPreview(
          'word-$n',
          List.filled(20, 'token${n.toString().padLeft(6, '0')}').join(' '),
        ),
      );
    }
    final beyond = List.filled(20, 'entirelynewword').join(' ');
    catalog.add(withPreview('beyond-limit', beyond));
    expect(identical(catalog.last.previewText, beyond), isTrue);
    expect(held.toSummaryJson(), original.toSummaryJson());
    catalog.clear();
    catalog.add(
      withPreview(
        'new-codec',
        List.filled(20, 'replacement distinct words').join(' '),
      ),
    );
    expect(held.previewText.codeUnits, text.codeUnits);
    expect(held.toSummaryJson(), original.toSummaryJson());
  });

  test('incompressible and overlong words keep their original strings', () {
    final catalog = ConversationCatalog();
    var state = 7;
    final entropy = String.fromCharCodes(
      List.generate(180, (_) {
        state = (state * 1664525 + 1013904223) & 0xffffffff;
        return 33 + state % 94;
      }),
    );
    final longWord = 'abcdefghij' * 20;
    for (final text in [entropy, longWord, '😀' * 80]) {
      final original = withPreview('fallback-${catalog.length}', text);
      catalog.add(original);
      expect(catalog.last.toSummaryJson(), original.toSummaryJson());
      expect(identical(catalog.last.previewText, text), isTrue);
    }
  });

  test('packed replacement and ListBase operations retain live identity', () {
    final text = List.filled(20, 'shared lexical preview words').join(' ');
    final catalog = ConversationCatalog()
      ..addAll([withPreview('b', text), withPreview('a', text)]);
    final held = catalog[0];
    catalog.sort((a, b) => a.id.compareTo(b.id));
    expect(identical(catalog[1], held), isTrue);
    catalog[0] = withPreview('replacement', text);
    final live = Conversation(
      id: 'live',
      title: 'Edited',
      source: 'manual',
      participantIds: [],
      segments: [ConversationSegment(id: 's', text: 'Full live body')],
    );
    catalog.insert(0, live);
    expect(identical(catalog[0], live), isTrue);
    catalog[1] = live;
    expect(identical(catalog[1], live), isTrue);
    catalog.removeWhere((v) => v.id == 'live');
    expect(catalog.single.toSummaryJson(), held.toSummaryJson());
  });
}
