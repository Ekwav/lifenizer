import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:app/services/conversation_catalog.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:app/services/disk_search_index_io.dart';
import 'package:app/services/search_criteria.dart';
import 'package:app/services/search_scorer.dart';

/// Profiles an existing synthetic benchmark copy; never use a real vault key.
/// Build with `dart build cli --target=tool/search_latency_probe.dart`.
Future<void> main(List<String> args) async {
  if (args.length != 1) throw ArgumentError('Pass a synthetic SQLite path.');
  final key = List<int>.generate(32, (i) => i);
  final catalog = ConversationCatalog();
  var index = await DiskSearchIndex.open(path: args.single, vaultKey: key);
  final count = await index.count;
  final watch = Stopwatch()..start();
  String? catalogAfterId;
  for (var offset = 0; offset < count; offset += 1000) {
    final page = await index.summaries(afterId: catalogAfterId);
    if (page.length != math.min(1000, count - offset)) {
      throw StateError('Incomplete native search catalog.');
    }
    catalog.addAll(page);
    catalogAfterId = page.last.id;
  }
  int checksum() => catalog.fold<int>(
    0,
    (total, doc) => total + jsonEncode(doc.toSummaryJson()).length,
  );
  final expected = checksum();
  stdout.writeln(
    jsonEncode({
      'event': 'catalog-ready',
      'count': count,
      'ms': watch.elapsedMilliseconds,
      'rss': ProcessInfo.currentRss,
      'checksum': expected,
    }),
  );
  final results = <Map<String, Object?>>[];
  Future<void> query(String query, String stage) async {
    final tokens = ConversationSearchIndex.tokenize(query);
    final timer = Stopwatch()..start();
    final found = await index.search(
      SearchCriteria(query: query),
      SearchScorer(
        temporalIntent: null,
        normalizedQuery: query.toLowerCase(),
        now: DateTime.utc(2026, 10, 28),
      ),
      tokens,
      tokens.join(' '),
    );
    final sample = <String, Object?>{
      'event': 'query-complete',
      'stage': stage,
      'query': query,
      'ms': timer.elapsedMicroseconds / 1000,
      'returned': found.length,
      'profile': await index.searchProfile,
    };
    results.add(sample);
    stdout.writeln(jsonEncode(sample));
  }

  try {
    await query('zzqxnonexistent', 'migration');
    for (final stage in ['built', 'reopened']) {
      for (final queryText in [
        'insurance renewal',
        'insuranc alice',
        'ali muell',
        'MÜLLER',
        'insurance zxqvbnm',
        'grocery shopping',
        'archive',
        '',
      ]) {
        await query(queryText, stage);
      }
      if (stage == 'built') {
        await index.close();
        index = await DiskSearchIndex.open(path: args.single, vaultKey: key);
      }
    }
    if (catalog.length != count || checksum() != expected) {
      throw StateError('The retained catalog changed.');
    }
    final report = {
      'count': count,
      'peakRss': math.max(ProcessInfo.maxRss, ProcessInfo.currentRss),
      'samples': results,
    };
    await File(
      '${args.single}.probe.json',
    ).writeAsString('${const JsonEncoder.withIndent('  ').convert(report)}\n');
    stdout.writeln(jsonEncode({'event': 'probe-complete', ...report}));
  } finally {
    await index.close();
    key.fillRange(0, key.length, 0);
  }
}
