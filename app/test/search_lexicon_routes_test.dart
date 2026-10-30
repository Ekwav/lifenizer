import 'dart:io';

import 'package:app/models.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:app/services/disk_search_index_io.dart';
import 'package:app/services/search_criteria.dart';
import 'package:app/services/search_lexicon_routes.dart';
import 'package:app/services/search_scorer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

void main() {
  test('routes retain substring and edit matches, including Unicode', () {
    Iterable<String> edits(String value) sync* {
      final runes = value.runes.toList();
      for (var i = 0; i <= runes.length; i++) {
        yield String.fromCharCodes([...runes.take(i), 120, ...runes.skip(i)]);
        if (i < runes.length) {
          yield String.fromCharCodes([...runes.take(i), ...runes.skip(i + 1)]);
          yield String.fromCharCodes([
            ...runes.take(i),
            120,
            ...runes.skip(i + 1),
          ]);
        }
      }
    }

    for (final query in [
      'a',
      'ab',
      'aaaa',
      'ababab',
      'insurance',
      'a123',
      '𐐀𐐁',
      '𐐀𐐁𐐂',
    ]) {
      final routes = searchLexiconQueryGrams(query);
      final variants = <String>{query, 'prefix${query}suffix'};
      if (query.length >= 4) variants.addAll(edits(query));
      if (query.length >= 6) {
        for (final value in edits(query)) {
          variants.addAll(edits(value));
        }
      }
      for (final word in variants) {
        expect(
          searchLexiconGrams(word).any(routes.contains),
          isTrue,
          reason: '$query -> $word',
        );
      }
    }
  });

  test(
    'indexed dictionary survives updates, reopen and checkpointed migration',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lexicon-routes-',
      );
      final path = '${directory.path}/index.sqlite';
      final key = List<int>.generate(32, (i) => i);
      var disk = await DiskSearchIndex.open(path: path, vaultKey: key);
      final now = DateTime.utc(2026, 10, 28);
      Conversation conversation(String id, String text) => Conversation(
        id: id,
        title: text,
        source: 'manual',
        participantIds: const [],
        startedAt: now,
        endedAt: now,
        segments: const [],
      );
      Future<List<String>> search(String query) async {
        final criteria = SearchCriteria(query: query);
        final tokens = ConversationSearchIndex.tokenize(query);
        return (await disk.search(
          criteria,
          SearchScorer(temporalIntent: null, normalizedQuery: query, now: now),
          tokens,
          tokens.join(' '),
        )).map((value) => value.id).toList();
      }

      try {
        await disk.upsert(
          [
            conversation('words', 'insurance abcdefghijk 0123 𐐨𐐩𐐪'),
            conversation(
              'numbers',
              List.generate(3000, (i) => '${100000 + i}').join(' '),
            ),
          ],
          participantById: const {},
          relationTextByConversation: const {},
        );
        for (final query in [
          'insuranc',
          'surance',
          'abxdefghijx',
          'a123',
          '𐐨𐐩',
        ]) {
          expect(await search(query), ['words'], reason: query);
        }
        expect(await search('100123'), ['numbers']);
        await disk.close();
        var database = sql.sqlite3.open(path);
        expect(
          database
              .select('SELECT COUNT(DISTINCT page) AS n FROM lexicon_routes')
              .single['n'],
          greaterThan(8),
        );
        final untouchedVocabulary = database
            .select('SELECT payload FROM vocabulary WHERE id = 8')
            .single['payload'];
        database.execute("UPDATE vocabulary SET payload = X'00' WHERE id = 8");
        database.close();
        disk = await DiskSearchIndex.open(path: path, vaultKey: key);
        // A selective text lookup must not decrypt the unrelated numeric page.
        expect(await search('insurance'), ['words']);
        await disk.close();
        database = sql.sqlite3.open(path);
        database.execute('UPDATE vocabulary SET payload = ? WHERE id = 8', [
          untouchedVocabulary,
        ]);
        database.execute('DELETE FROM lexicon_routes');
        database.execute(
          "DELETE FROM metadata WHERE key IN ('_lexiconRoutes', '_lexiconRoutesCursor')",
        );
        database.execute(
          "CREATE TRIGGER interrupt_routes BEFORE INSERT ON lexicon_routes WHEN NEW.page >= 8 BEGIN SELECT RAISE(ABORT, 'migration interrupted'); END",
        );
        database.close();
        disk = await DiskSearchIndex.open(path: path, vaultKey: key);
        await expectLater(search('insurance'), throwsStateError);
        expect(await disk.readMetadata('_lexiconRoutesCursor'), 8);
        expect(await disk.readMetadata('_lexiconRoutes'), isNull);
        await disk.close();
        database = sql.sqlite3.open(path);
        database.execute('DROP TRIGGER interrupt_routes');
        database.close();
        disk = await DiskSearchIndex.open(path: path, vaultKey: key);
        expect(await search('insurance'), ['words']);
        expect(await disk.readMetadata('_lexiconRoutes'), 1);
        expect(await disk.readMetadata('_lexiconRoutesCursor'), isNull);
        await disk.upsert(
          [conversation('words', 'newlexicalword')],
          participantById: const {},
          relationTextByConversation: const {},
        );
        expect(await search('newlexicalword'), ['words']);
        expect(await search('insurance'), isEmpty);
        await disk.remove(['words', 'numbers']);
        await disk.upsert(
          [conversation('restored', 'insurance')],
          participantById: const {},
          relationTextByConversation: const {},
        );
        expect(await search('insurance'), ['restored']);
        await disk.clear();
        await disk.upsert(
          [conversation('fresh', 'freshword')],
          participantById: const {},
          relationTextByConversation: const {},
        );
        expect(await search('freshword'), ['fresh']);
      } finally {
        await disk.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
