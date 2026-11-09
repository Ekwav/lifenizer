import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:app/models.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:app/services/disk_search_index_io.dart';
import 'package:app/services/search_criteria.dart';
import 'package:app/services/search_scorer.dart';
import 'package:app/services/search_service.dart';

/// Independent synthetic probe; creates fresh databases and never opens a vault.
/// From app/: dart build cli --target=tool/search_order_probe.dart --output=/tmp/order-probe-cli
/// Run its bundle/bin/search_order_probe [count=20000] [new output directory]
/// [--mixed-fields] to put a ubiquitous body term in only 1% of titles.
/// [--prepare-queries] reports cold initialization separately from queries.
Future<void> main(List<String> args) async {
  final mixedFields = args.contains('--mixed-fields');
  final prepareQueries = args.contains('--prepare-queries');
  final positional = args
      .where((arg) => arg != '--mixed-fields' && arg != '--prepare-queries')
      .toList();
  final count = positional.isEmpty ? 20000 : int.parse(positional.first);
  if (count < 10000 || count > 30000 || count % 100 != 0) {
    throw ArgumentError('Use 10,000–30,000 documents in multiples of 100.');
  }
  final directory = positional.length > 1
      ? Directory(positional[1])
      : await Directory.systemTemp.createTemp('search-order-probe-');
  if (positional.length > 1) {
    if (await directory.exists()) throw StateError('Output directory exists.');
    await directory.create(recursive: true);
  }
  const people = {'alice': 'Alice Müller', 'bob': 'Bob Garcia'};
  final queries = [
    'archive',
    'alice mueller',
    'ali muell',
    'archive grocery',
    if (mixedFields) ...['project', 'project grocery'],
  ];
  final now = DateTime.utc(2026, 10, 29);
  final words = <String>{};
  for (final name in ['ARCHITECTURE', 'IMPORTERS', 'AUTH', 'DATABASE']) {
    words.addAll(
      ConversationSearchIndex.tokenize(
        File('../docs/$name.md').readAsStringSync(),
      ).where((word) => word.length >= 4 && !RegExp(r'[0-9]').hasMatch(word)),
    );
  }
  final vocabularyProbe = ConversationSearchIndex.build(
    conversations: [
      Conversation(
        id: 'vocabulary',
        title: words.join(' '),
        source: 'manual',
        participantIds: const [],
        segments: const [],
      ),
    ],
    participantById: const {},
    relationTextByConversation: const {},
  );
  words.removeAll(
    vocabularyProbe
        .expandTokens([
          'archive',
          'alice',
          'mueller',
          'ali',
          'muell',
          'grocery',
          if (mixedFields) 'project',
        ])
        .values
        .expand((matches) => matches.keys),
  );
  final filler = words.toList()..sort();
  final docs = List.generate(count, (n) {
    var seed = n + 1;
    final date = now.subtract(Duration(minutes: n));
    final text = [
      mixedFields ? 'project' : 'grocery',
      mixedFields ? 'grocery' : 'shopping',
      for (var i = 2; i < 200; i++)
        filler[(seed = (seed * 1664525 + 1013904223) & 0xffffffff) %
            filler.length],
    ];
    return Conversation(
      id: '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}',
      title:
          'Archive ${n.toString().padLeft(12, '0')}${mixedFields && n % 100 == 0 ? ' Project' : ''}',
      source: [
        'manual',
        'email',
        'discord',
        'scanned-pdf',
        'browser-history',
      ][(n ~/ 128) % 5],
      participantIds: [n % (count ~/ 100) == 0 ? 'alice' : 'bob'],
      startedAt: date,
      endedAt: date,
      segments: [
        for (var i = 0; i < 200; i += 20)
          ConversationSegment(
            id: 'segment-$n-$i',
            text: text.skip(i).take(20).join(' '),
            createdAt: date,
          ),
      ],
    );
  });
  final reference = SearchService(
    ConversationSearchIndex.build(
      conversations: docs,
      participantById: people,
      relationTextByConversation: const {},
    ),
  );
  SearchScorer scorer(String query) =>
      SearchScorer(temporalIntent: null, normalizedQuery: query, now: now);
  final golden = <String, List<String>>{};
  for (final query in queries) {
    final tokens = ConversationSearchIndex.tokenize(query);
    golden[query] = reference
        .rankConversations(
          SearchCriteria(query: query),
          scorer(query),
          tokens,
          tokens.join(' '),
          maxResults: 100,
        )
        .map((item) => item.id)
        .toList();
  }
  if (mixedFields) {
    final titled = {for (var n = 0; n < docs.length; n += 100) docs[n].id};
    for (final query in ['project', 'project grocery']) {
      if (golden[query]!.length != 100 ||
          !golden[query]!.every(titled.contains)) {
        throw StateError(
          'Mixed-field reference must select 100 titled matches.',
        );
      }
    }
  }
  final report = <String, Object?>{
    'count': count,
    'words': 200,
    'fillerVocabulary': filler.length,
    'mixedFields': mixedFields,
    'prepareQueries': prepareQueries,
    if (mixedFields) 'projectTitleMatches': count ~/ 100,
    'goldenTopIds': golden,
    'samples': <Object?>[],
  };
  stdout.writeln(
    jsonEncode({
      'event': 'fixture-ready',
      'count': count,
      'directory': directory.path,
    }),
  );
  for (final order in ['chronological', 'shuffled']) {
    final insertion = docs.toList();
    if (order == 'shuffled') insertion.shuffle(Random(42));
    final path = '${directory.path}/$order.sqlite';
    var disk = await DiskSearchIndex.open(
      path: path,
      vaultKey: List.generate(32, (n) => n),
    );
    try {
      final build = Stopwatch()..start();
      await disk.upsert(
        insertion,
        participantById: people,
        relationTextByConversation: const {},
      );
      await disk.prepare();
      stdout.writeln(
        jsonEncode({
          'event': 'index-ready',
          'order': order,
          'buildMs': build.elapsedMilliseconds,
        }),
      );
      for (var sample = 0; sample < 3; sample++) {
        for (final query in queries) {
          // Each sample includes a fresh worker/cache as well as a warm repeat.
          await disk.close();
          final initialize = Stopwatch()..start();
          disk = await DiskSearchIndex.open(
            path: path,
            vaultKey: List.generate(32, (n) => n),
          );
          final openMs = initialize.elapsedMicroseconds / 1000;
          initialize.reset();
          if (prepareQueries) await disk.prepare();
          final prepareMs = initialize.elapsedMicroseconds / 1000;
          final tokens = ConversationSearchIndex.tokenize(query);
          for (final stage in [
            prepareQueries ? 'prepared' : 'reopened',
            'warm',
          ]) {
            final watch = Stopwatch()..start();
            final actual = await disk.search(
              SearchCriteria(query: query),
              scorer(query),
              tokens,
              tokens.join(' '),
            );
            final elapsed = watch.elapsedMicroseconds / 1000;
            final ids = actual.map((item) => item.id).toList();
            if (jsonEncode(ids) != jsonEncode(golden[query])) {
              throw StateError(
                'Reference ranking mismatch: $order $query $stage',
              );
            }
            final result = {
              'order': order,
              'query': query,
              'sample': sample,
              'stage': stage,
              if (stage == 'prepared') 'openMs': openMs,
              if (stage == 'prepared') 'prepareMs': prepareMs,
              'ms': elapsed,
              'returned': ids.length,
              'profile': await disk.searchProfile,
            };
            (report['samples'] as List).add(result);
            stdout.writeln(jsonEncode({'event': 'query-complete', ...result}));
          }
        }
      }
    } finally {
      await disk.close();
    }
  }
  report['referenceOrderingPassed'] = true;
  report['peakRss'] = ProcessInfo.maxRss;
  final output = File('${directory.path}/result.json');
  await output.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  stdout.writeln(jsonEncode({'event': 'complete', 'report': output.path}));
}
