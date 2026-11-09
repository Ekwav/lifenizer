import 'dart:io';

import 'package:app/models.dart';
import 'package:app/services/disk_search_index_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'summary seeks preserve source-page order through holes and reinsertion',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'summary-cursor-',
      );
      final path = '${directory.path}/search.sqlite';
      final key = List.generate(32, (n) => n);
      var disk = await DiskSearchIndex.open(path: path, vaultKey: key);
      final docs = List.generate(
        660,
        (n) => Conversation(
          id: 'doc-$n',
          title: 'archive $n',
          source: [
            'manual',
            'email',
            'discord',
            'scanned-pdf',
            'browser-history',
          ][n % 5],
          participantIds: const [],
          segments: const [],
        ),
      );
      Future<void> upsert(List<Conversation> values) => disk.upsert(
        values,
        participantById: const {},
        relationTextByConversation: const {},
      );
      Future<void> checkCatalog(int count) async {
        final complete = await disk.summaries(limit: 1000);
        final expected = complete.map((item) => item.id).toList();
        expect(expected.length, count);
        expect(expected.toSet().length, count);
        // Interleaved sources are stored in physical source pages, not input order.
        expect(expected.take(5), [
          'doc-0',
          'doc-5',
          'doc-10',
          'doc-15',
          'doc-20',
        ]);
        final actual = <String>[];
        String? cursor;
        while (true) {
          final page = await disk.summaries(afterId: cursor, limit: 37);
          if (page.isEmpty) break;
          actual.addAll(page.map((item) => item.id));
          cursor = page.last.id;
        }
        expect(actual, expected);
        for (final offset in [1, 36, 37, 127, 128, 255, count - 1, count]) {
          final random = await disk.summaries(offset: offset, limit: 17);
          final seek = await disk.summaries(
            afterId: expected[offset - 1],
            limit: 17,
          );
          expect(seek.map((item) => item.id), random.map((item) => item.id));
        }
        // A supplied cursor is authoritative; offset remains a separate fallback.
        final seek = await disk.summaries(
          afterId: expected[37],
          offset: 600,
          limit: 2,
        );
        expect(seek.map((item) => item.id), expected.skip(38).take(2));
        expect(await disk.summaries(afterId: expected.last), isEmpty);
      }

      try {
        await upsert(docs);
        await checkCatalog(660);
        await disk.remove(['doc-127', 'doc-128', 'doc-251', 'doc-659']);
        await expectLater(disk.summaries(afterId: 'doc-128'), throwsStateError);
        await expectLater(disk.summaries(afterId: 'missing'), throwsStateError);
        await checkCatalog(656);
        await upsert([docs[128], docs[251]]);
        await checkCatalog(658);
        await disk.close();
        disk = await DiskSearchIndex.open(path: path, vaultKey: key);
        await checkCatalog(658);
        final complete = await disk.summaries(limit: 1000);
        final index = complete.indexWhere((item) => item.id == 'doc-128');
        expect(
          (await disk.summaries(
            afterId: 'doc-128',
            limit: 3,
          )).map((item) => item.id),
          complete.skip(index + 1).take(3).map((item) => item.id),
        );
      } finally {
        await disk.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
