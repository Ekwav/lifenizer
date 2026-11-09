import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:app/models.dart';
import 'package:app/services/conversation_catalog.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:app/services/disk_search_index_io.dart';
import 'package:app/services/search_criteria.dart';
import 'package:app/services/search_scorer.dart';
import 'package:app/services/search_source_groups.dart';
import 'package:app/services/source_categories.dart';

import 'search_relevance_fixtures.dart';

/// Run from app/: dart run tool/million_search_benchmark.dart [count] [directory] [--resume] [--shuffle-new-dates] [--build-only|--query-only|--relevance-only]
/// Retains the encrypted database and result JSON; --resume reuses committed data.
/// Defaults to build/benchmarks/; use a real filesystem, never /tmp on tmpfs.
/// Build AOT with SQLite: dart build cli --target=tool/million_search_benchmark.dart
/// Run its bundle/bin/million_search_benchmark in a transient systemd user service
/// with MemoryMax=2000000000, MemorySwapMax=0 and WorkingDirectory set to app/.
Future<void> main(List<String> arguments) async {
  final shuffleNewDates = arguments.contains('--shuffle-new-dates');
  final relevanceOnly = arguments.contains('--relevance-only');
  final queryOnly = arguments.contains('--query-only') || relevanceOnly;
  final buildOnly = arguments.contains('--build-only');
  _require(
    arguments
            .where(
              (value) => const [
                '--build-only',
                '--query-only',
                '--relevance-only',
              ].contains(value),
            )
            .length <=
        1,
    'Choose only one phase.',
  );
  final count = arguments.isEmpty ? 1000000 : int.parse(arguments[0]);
  if (count < 1 || count > 2000000) {
    throw ArgumentError('Use a count from 1 through 2000000.');
  }
  final cgroup = File(
    '/proc/self/cgroup',
  ).readAsLinesSync().firstWhere((line) => line.startsWith('0::')).substring(3);
  final memory = '/sys/fs/cgroup$cgroup';
  if (count >= 1000000) {
    final limit = int.tryParse(
      File('$memory/memory.max').readAsStringSync().trim(),
    );
    _require(
      limit != null &&
          limit > 0 &&
          limit <= 2000000000 &&
          File('$memory/memory.swap.max').readAsStringSync().trim() == '0',
      'Run the million-item benchmark in a cgroup with a 2 GB limit and no swap.',
    );
  }
  final directory = await Directory(
    arguments.length < 2
        ? 'build/benchmarks/million-search-${DateTime.now().microsecondsSinceEpoch}'
        : arguments[1],
  ).create(recursive: true);
  _require(
    Process.runSync('chmod', ['700', directory.path]).exitCode == 0,
    'Could not make the benchmark directory private.',
  );
  final fileSystemType = _fileSystemType(directory);
  _require(
    count < 1000000 || !['tmpfs', 'ramfs'].contains(fileSystemType),
    'Use a disk filesystem; RAM-backed databases count against the memory limit.',
  );
  final path = '${directory.path}/search.sqlite';
  if (await File(path).exists() &&
      !arguments.contains('--resume') &&
      !queryOnly) {
    throw StateError('Database already exists; use --resume to reuse it.');
  }
  final filler = _vocabulary();
  final key = List<int>.generate(32, (i) => i);
  final catalog = ConversationCatalog();
  final reportName = relevanceOnly
      ? 'relevance-result'
      : queryOnly
      ? 'query-result'
      : buildOnly
      ? 'build-result'
      : 'result';
  final metrics = <String, Object>{
    'schemaVersion': 2,
    'phase': relevanceOnly
        ? 'relevance-only'
        : queryOnly
        ? 'query-only'
        : buildOnly
        ? 'build-only'
        : 'full',
    'targetConversations': 2000000,
    'targetLatencyMs': 500,
    'requestedConversations': count,
    'wordsPerConversation': 200,
    'segmentsPerConversation': 10,
    'previewCharacters': 180,
    'fillerVocabulary': filler.length,
    'database': path,
    'actualFileSystemType': fileSystemType,
    'invocationId': Platform.environment['INVOCATION_ID'] ?? '',
  };
  final queries = <String, Object>{};
  metrics['queries'] = queries;
  Future<void> checkpoint(String phase) async {
    metrics['lastCompletedPhase'] = phase;
    await _writeReport('${directory.path}/$reportName.partial.json', metrics);
    stdout.writeln(
      jsonEncode({
        'event': 'phase-complete',
        'phase': phase,
        'report': '$reportName.partial.json',
      }),
    );
  }

  await checkpoint('starting');
  var index = await DiskSearchIndex.open(path: path, vaultKey: key);
  var plaintextBytes = 0;
  final build = Stopwatch()..start();
  Future<void> recordBuildMemory(int newlyCommitted) async {
    final observed = await index.count;
    final sample = <String, Object>{
      'invocationId': metrics['invocationId']!,
      'conversations': observed,
      'newlyCommittedConversations': newlyCommitted,
      'currentRssBytes': ProcessInfo.currentRss,
      'maxRssBytes': ProcessInfo.maxRss,
      'cgroupMemoryCurrentBytes': int.parse(
        File('$memory/memory.current').readAsStringSync(),
      ),
      'elapsedMs': build.elapsedMilliseconds,
    };
    final log = File('${directory.path}/build-memory.jsonl');
    await log.writeAsString(
      '${jsonEncode(sample)}\n',
      mode: newlyCommitted == 0 ? FileMode.write : FileMode.append,
      flush: true,
    );
    if (newlyCommitted == 0) {
      _require(
        Process.runSync('chmod', ['600', log.path]).exitCode == 0,
        'Could not make build memory telemetry private.',
      );
    }
    metrics['conversations'] = observed;
    metrics['buildProgress'] = sample;
    await _writeReport('${directory.path}/$reportName.partial.json', metrics);
  }

  try {
    metrics['recoveredRelevanceDocuments'] = await _restoreRelevanceBackup(
      index,
    );
    final existing = await index.count;
    metrics['conversations'] = existing;
    _require(
      existing <= count,
      'Existing database exceeds the requested count.',
    );
    _require(
      !queryOnly || existing == count,
      'Query-only requires the complete requested corpus.',
    );
    const datesKey = 'benchmark-date-layout';
    var dates = await index.readMetadata(datesKey);
    if (dates == null && shuffleNewDates) {
      _require(
        !queryOnly,
        'Query-only cannot introduce a missing date layout.',
      );
      _require(
        existing < count,
        'Shuffling new dates requires new conversations.',
      );
      dates = {
        'layout': 'new-date-permutation-v1',
        'start': existing,
        'span': count,
      };
      await index.writeMetadata(datesKey, dates);
    }
    _datePermutation = null;
    if (dates != null) {
      _require(
        dates is Map &&
            dates['layout'] == 'new-date-permutation-v1' &&
            dates['start'] is int &&
            dates['span'] is int &&
            dates['start'] >= 0 &&
            dates['start'] <= existing &&
            dates['start'] < count &&
            dates['span'] == count,
        'Stored date layout does not match the requested corpus or resume boundary.',
      );
      final layout = dates as Map;
      _datePermutation = (
        start: layout['start'] as int,
        span: layout['span'] as int,
      );
      metrics['fixtureDateLayout'] = layout;
      metrics['fixtureDateLayoutScope'] = layout['start'] == 0
          ? 'all $count conversations permuted across $count minutes'
          : 'original ${layout['start']} chronological + new ${count - (layout['start'] as int)} permuted across $count minutes';
    } else {
      metrics['fixtureDateLayout'] = const {'layout': 'chronological-v1'};
      metrics['fixtureDateLayoutScope'] =
          'all $count conversations chronological';
    }
    const fixtureKey = 'benchmark-source-partitions-start';
    final marker = await index.readMetadata(fixtureKey);
    _sourceStart = marker as int? ?? existing;
    _require(!queryOnly || marker != null, 'Missing fixture metadata.');
    if (marker == null) await index.writeMetadata(fixtureKey, _sourceStart);
    metrics['fixtureSourceStart'] = _sourceStart;
    const layoutKey = 'benchmark-source-partitions-layout';
    const layout = 'source-runs-128-v1';
    final storedLayout = await index.readMetadata(layoutKey);
    _require(
      storedLayout == layout ||
          (storedLayout == null && existing <= _sourceStart),
      'Existing mixed fixture has a different or unknown source layout.',
    );
    _require(!queryOnly || storedLayout != null, 'Missing fixture layout.');
    if (storedLayout == null) await index.writeMetadata(layoutKey, layout);
    metrics['fixtureSourceLayout'] = layout;
    const namesKey = 'benchmark-real-names-layout-v1-start';
    final namesMarker = await index.readMetadata(namesKey);
    _nameStart = namesMarker as int? ?? existing;
    if (namesMarker == null && !queryOnly) {
      await index.writeMetadata(namesKey, _nameStart);
    }
    metrics['fixtureNamesStart'] = _nameStart;
    metrics['fixtureNamesLayout'] = '20-firstnames-10-surnames-v1';
    metrics['fixtureNamePlacement'] =
        'Final two body words; Alice/Bob participant labels retained.';
    String? cursorId;
    for (var offset = 0; offset < existing; offset += 1000) {
      final page = await index.summaries(afterId: cursorId, limit: 1000);
      _require(
        page.length == math.min(1000, existing - offset),
        'Missing summary page.',
      );
      catalog.addAll(page);
      cursorId = page.last.id;
    }
    catalog.sort((a, b) => a.id.compareTo(b.id));
    for (var i = 0; i < existing; i++) {
      final number = _number(catalog[i].id);
      _require(
        number >= 0 &&
            number < count &&
            catalog[i].id == _id(number) &&
            (i == 0 || catalog[i - 1].id != catalog[i].id),
        'Invalid existing corpus IDs.',
      );
    }
    metrics['resumedConversations'] = existing;
    await checkpoint('catalog-loaded');
    if (!queryOnly) {
      final prepare = Stopwatch()..start();
      await index.prepare();
      metrics['searchPreparationBeforeAppendMs'] = prepare.elapsedMilliseconds;
      await checkpoint('existing-index-prepared');
      await recordBuildMemory(0);
    }
    var cursor = 0;
    var newlyCommitted = 0;
    var lastMemorySample = 0;
    for (
      var offset = 0;
      offset < count;
      offset += DiskSearchIndex.writeBatchSize
    ) {
      final batch = <Conversation>[];
      for (
        var i = offset;
        i < math.min(offset + DiskSearchIndex.writeBatchSize, count);
        i++
      ) {
        if (cursor < existing && catalog[cursor].id == _id(i)) {
          cursor++;
          continue;
        }
        final conversation = _conversation(i, filler);
        plaintextBytes += utf8.encode(jsonEncode(conversation)).length;
        batch.add(conversation);
        // Decode independently, as an actual persisted summary catalog does.
        catalog.add(_summary(conversation));
      }
      if (batch.isEmpty) continue;
      await index.upsert(
        batch,
        participantById: _people,
        relationTextByConversation: const {},
      );
      newlyCommitted += batch.length;
      if (newlyCommitted - lastMemorySample >= 16384) {
        await recordBuildMemory(newlyCommitted);
        lastMemorySample = newlyCommitted;
      }
    }
    if (newlyCommitted != lastMemorySample) {
      await recordBuildMemory(newlyCommitted);
    }
    _require(cursor == existing, 'Existing corpus contains unexpected IDs.');
    catalog.sort((a, b) => a.id.compareTo(b.id));
    metrics['buildMs'] = build.elapsedMilliseconds;
    metrics[existing == 0
            ? 'plaintextConversationBytes'
            : 'newPlaintextConversationBytes'] =
        plaintextBytes;
    final builtCount = await index.count;
    metrics['conversations'] = builtCount;
    _require(builtCount == count, 'Incorrect built document count.');
    metrics['builtCatalogChecksum'] = _catalogChecksum(catalog);
    metrics['builtRssBytes'] = ProcessInfo.currentRss;
    final partitionCounts = {
      for (final group in SearchSourceGroup.values) group.name: 0,
    };
    for (final conversation in catalog) {
      partitionCounts.update(
        groupForSource(conversation.source).name,
        (n) => n + 1,
      );
    }
    metrics['sourcePartitionCounts'] = partitionCounts;
    stderr.writeln(
      'Build complete: $count conversations; ${ProcessInfo.currentRss} bytes RSS.',
    );
    await checkpoint('build-verified');
    await index.close();

    final reopen = Stopwatch()..start();
    index = await DiskSearchIndex.open(path: path, vaultKey: key);
    _require(await index.count == count, 'Incorrect reopened document count.');
    cursorId = null;
    for (var offset = 0; offset < count; offset += 1000) {
      final page = await index.summaries(afterId: cursorId, limit: 1000);
      _require(
        page.length == math.min(1000, count - offset),
        'Missing summary page.',
      );
      catalog.setRange(offset, offset + page.length, page);
      cursorId = page.last.id;
    }
    catalog.sort((a, b) => a.id.compareTo(b.id));
    metrics['reopenAndCatalogMs'] = reopen.elapsedMilliseconds;
    _require(
      _catalogChecksum(catalog) == metrics['builtCatalogChecksum'],
      'Persisted summary fields changed.',
    );
    metrics['reopenedRssBytes'] = ProcessInfo.currentRss;
    stderr.writeln(
      'Reopen and catalog hydration complete: ${reopen.elapsedMilliseconds} ms.',
    );
    await checkpoint('reopen-verified');
    final loaded = await index.loadConversation(_id(count - 1));
    _require(
      jsonEncode(loaded.toJson()) ==
          jsonEncode(
            _conversation(
              count - 1,
              filler,
              updated: loaded.title.endsWith(' updateproof'),
            ).toJson(),
          ),
      'Full conversation did not survive reopen.',
    );

    if (!queryOnly) {
      final update = Stopwatch()..start();
      final changes = <Conversation>[
        for (var i = 0; i < math.min(100, count); i++)
          _conversation(i, filler, updated: true),
      ];
      await index.upsert(
        changes,
        participantById: _people,
        relationTextByConversation: const {},
      );
      for (var i = 0; i < changes.length; i++) {
        catalog[i] = _summary(changes[i]);
      }
      _require(await index.count == count, 'Updates changed document count.');
      await _checkQuery(
        index,
        'updateproof',
        changes.length,
        (i) => i < changes.length,
      );
      metrics['update100Ms'] = update.elapsedMilliseconds;
      final removed = math.min(3, count);
      await index.remove([for (var i = 0; i < removed; i++) _id(i)]);
      _require(
        await index.count == count - removed,
        'Removal count is incorrect.',
      );
      await _checkQuery(
        index,
        'updateproof',
        changes.length - removed,
        (i) => i >= removed && i < changes.length,
      );
      await index.upsert(
        changes.take(removed).toList(),
        participantById: _people,
        relationTextByConversation: const {},
      );
      _require(await index.count == count, 'Restore count is incorrect.');
      await index.close();
      index = await DiskSearchIndex.open(path: path, vaultKey: key);
      await _checkQuery(
        index,
        'updateproof',
        changes.length,
        (i) => i < changes.length,
      );
      _require(
        jsonEncode((await index.loadConversation(_id(0))).toJson()) ==
            jsonEncode(changes.first.toJson()),
        'Updated full conversation did not survive reopen.',
      );
      await checkpoint('update-delete-verified');
    }
    final prepare = Stopwatch()..start();
    await index.prepare();
    metrics['searchPreparationMs'] = prepare.elapsedMilliseconds;
    await checkpoint('search-prepared');
    await index.close();
    if (!buildOnly) {
      if (!relevanceOnly) {
        await _queries(path, key, catalog, filler, queries, checkpoint);
      }
      await _semanticRelevance(path, key, catalog, metrics, checkpoint);
      metrics['correctnessPassed'] = true;
    }
    // Observe every field after all queries, keeping the entire real catalog live.
    metrics['finalCatalogChecksum'] = _catalogChecksum(catalog);
    metrics['catalogLength'] = catalog.length;
    metrics['databaseBytes'] = await File(path).length();
    metrics['peakRssBytes'] = math.max(
      ProcessInfo.maxRss,
      ProcessInfo.currentRss,
    );
    _require(
      (metrics['peakRssBytes'] as int) <= 2000000000,
      'Process exceeded 2 GB RSS.',
    );
    metrics['cgroupMemoryMax'] = File(
      '$memory/memory.max',
    ).readAsStringSync().trim();
    metrics['cgroupMemoryPeakBytes'] = int.parse(
      File('$memory/memory.peak').readAsStringSync(),
    );
    metrics['cgroupMemoryEvents'] = File(
      '$memory/memory.events',
    ).readAsStringSync().trim();
    final latencyPassed =
        !buildOnly &&
        !relevanceOnly &&
        ['ordinary', 'name', 'prefix', 'fuzzy', 'broad'].every((family) {
          final values = queries[family] as Map<String, Object>?;
          return values != null &&
              (values['sampleCount'] as int) >= 20 &&
              (values['firstQueryP95Ms'] as double) <= 500 &&
              (values['warmP95Ms'] as double) <= 500;
        });
    metrics['latencyTargetPassed'] = latencyPassed;
    metrics['targetMet'] =
        count == 2000000 &&
        _nameStart < count &&
        !buildOnly &&
        latencyPassed &&
        (metrics['semanticRelevance'] as Map)['passed'] == true;
    metrics['passed'] =
        buildOnly ||
        relevanceOnly ||
        count < 2000000 ||
        metrics['targetMet'] == true;
    await checkpoint('complete');
    await _writeReport('${directory.path}/$reportName.json', metrics);
    stdout.writeln(
      jsonEncode({
        'event': 'complete',
        'passed': metrics['passed'],
        'targetMet': metrics['targetMet'],
        'report': '$reportName.json',
      }),
    );
    if (metrics['passed'] != true) exitCode = 1;
  } catch (error) {
    metrics['passed'] = false;
    metrics['error'] = error.toString();
    await _writeReport('${directory.path}/$reportName.partial.json', metrics);
    stdout.writeln(jsonEncode({'event': 'failed', 'error': error.toString()}));
    rethrow;
  } finally {
    await index.close();
    key.fillRange(0, key.length, 0);
  }
}

final _now = DateTime.utc(2026, 10, 28);
int _sourceStart = 0;
int _nameStart = 0;
({int start, int span})? _datePermutation;
const _firstNames = [
  'Amelia',
  'Oliver',
  'Sophia',
  'Isabella',
  'Charlotte',
  'Elijah',
  'Camila',
  'Harper',
  'Evelyn',
  'Abigail',
  'Elizabeth',
  'Julian',
  'Scarlett',
  'Victoria',
  'Madison',
  'Penelope',
  'Gabriel',
  'Sebastian',
  'Benjamin',
  'Theodore',
];
const _surnames = [
  'Thompson',
  'Anderson',
  'Martinez',
  'Robinson',
  'Rodriguez',
  'Washington',
  'Jefferson',
  'Hamilton',
  'Campbell',
  'Richardson',
];
const _alice = 'fa3e6982-cc80-4d96-bd62-000000000001';
const _bob = 'fa3e6982-cc80-4d96-bd62-000000000002';
const _people = {_alice: 'Alice Müller', _bob: 'Bob'};

String _id(int i) =>
    '7a6d31e2-9f84-4b67-82a1-${i.toRadixString(16).padLeft(12, '0')}';
int _number(String id) => int.parse(id.substring(24), radix: 16);
String _sourceForIndex(int i) => i < _sourceStart
    ? 'manual'
    : const [
        'youtube-watch-history',
        'scanned-pdf',
        'imap',
        'discord',
        'manual',
      ][((i - _sourceStart) ~/ 128) % 5];

int _minuteOffset(int i) {
  final layout = _datePermutation;
  return layout == null || i < layout.start
      ? i
      : (i - layout.start) * 2147483647 % layout.span;
}

Conversation _conversation(int i, List<String> filler, {bool updated = false}) {
  var seed = i + 1;
  final date = _now.subtract(Duration(minutes: _minuteOffset(i)));
  final words = <String>[
    ...i % 10000 == 0 ? ['insurance', 'renewal'] : ['grocery', 'shopping'],
    for (var n = 2; n < 200; n++)
      filler[(seed = (seed * 1664525 + 1013904223) & 0xffffffff) %
          filler.length],
  ];
  if (i >= _nameStart) {
    final named = i - _nameStart;
    words[198] = _firstNames[named % _firstNames.length];
    words[199] = _surnames[(named ~/ _firstNames.length) % _surnames.length];
  }
  return Conversation(
    id: _id(i),
    title:
        'Archive ${i.toString().padLeft(12, '0')}${updated ? ' updateproof' : ''}',
    source: _sourceForIndex(i),
    participantIds: [i % 10000 == 0 ? _alice : _bob],
    startedAt: date,
    endedAt: date,
    segments: [
      for (var n = 0; n < 200; n += 20)
        ConversationSegment(
          id: 'segment-$i-$n',
          text: words.skip(n).take(20).join(' '),
          createdAt: date,
        ),
    ],
  );
}

Conversation _summary(Conversation value) => Conversation.fromSummaryJson(
  jsonDecode(jsonEncode(value.toSummaryJson(previewLength: 180)))
      as Map<String, dynamic>,
);

int _catalogChecksum(List<Conversation> catalog) {
  var checksum = 0;
  for (var i = 0; i < catalog.length; i++) {
    final item = catalog[i];
    final expectedTime =
        _now.microsecondsSinceEpoch -
        _minuteOffset(i) * Duration.microsecondsPerMinute;
    _require(
      !item.isLoaded &&
          item.segments.isEmpty &&
          item.id == _id(i) &&
          item.source == _sourceForIndex(i) &&
          item.startedAt.microsecondsSinceEpoch == expectedTime &&
          item.endedAt.microsecondsSinceEpoch == expectedTime,
      'Catalog contains full bodies or incorrect IDs/sources/dates.',
    );
    checksum += jsonEncode(item.toSummaryJson()).hashCode;
  }
  return checksum;
}

List<String> _vocabulary() {
  final words = <String>{};
  for (final name in ['ARCHITECTURE', 'IMPORTERS', 'AUTH', 'DATABASE']) {
    words.addAll(
      ConversationSearchIndex.tokenize(
        File('../docs/$name.md').readAsStringSync(),
      ).where((word) => word.length >= 4 && !word.contains(RegExp(r'[0-9]'))),
    );
  }
  final probe = ConversationSearchIndex.build(
    conversations: [
      Conversation(
        id: 'probe',
        title: '',
        source: 'manual',
        participantIds: [],
        segments: [ConversationSegment(id: 'probe', text: words.join(' '))],
      ),
    ],
    participantById: const {},
    relationTextByConversation: const {},
  );
  words.removeAll(
    probe
        .expandTokens([
          'insurance',
          'renewal',
          'insuranc',
          'alice',
          'muell',
          'mueller',
          'zxqvbnm',
          'updateproof',
        ])
        .values
        .expand((matches) => matches.keys),
  );
  return words.toList()..sort();
}

const _relevanceBackupKey = 'benchmark-relevance-backup-v1';

Future<int> _restoreRelevanceBackup(DiskSearchIndex index) async {
  final backup = await index.readMetadata(_relevanceBackupKey) as Map?;
  if (backup == null) return 0;
  final originals = [
    for (final value in backup['conversations'] as List)
      Conversation.fromJson(Map<String, dynamic>.from(value as Map)),
  ];
  await index.upsert(
    originals,
    participantById: _people,
    relationTextByConversation: const {},
  );
  _require(
    await index.count == backup['count'],
    'Relevance restoration changed the corpus count.',
  );
  final restored = await index.loadConversations(
    originals.map((item) => item.id).toList(),
  );
  _require(
    jsonEncode(restored) == jsonEncode(originals),
    'Relevance overlay full-body restoration failed.',
  );
  await index.writeMetadata(_relevanceBackupKey, null);
  return originals.length;
}

Future<void> _semanticRelevance(
  String path,
  List<int> key,
  List<Conversation> catalog,
  Map<String, Object> metrics,
  Future<void> Function(String) checkpoint,
) async {
  final fixture = SearchRelevanceFixture(_now);
  final authored = [...fixture.conversations, ...fixture.heldOutConversations]
    ..sort((a, b) => a.id.compareTo(b.id));
  if (catalog.length < authored.length) {
    metrics['semanticRelevance'] = {
      'passed': false,
      'skipped': 'Corpus is smaller than the authored fixture.',
    };
    return;
  }
  final offset = catalog.length - authored.length;
  final summaries = catalog.sublist(offset);
  final mappedIds = {
    for (var n = 0; n < authored.length; n++) authored[n].id: summaries[n].id,
  };
  final overlay = [
    for (final item in authored)
      Conversation.fromJson({...item.toJson(), 'id': mappedIds[item.id]}),
  ];
  final cases = <Map<String, Object>>[];
  final evidence = <String, Object>{
    'passed': false,
    'corpusConversations': catalog.length,
    'backgroundConversations': offset,
    'authoredConversations': overlay.length,
    'judgments': cases,
  };
  metrics['semanticRelevance'] = evidence;
  final index = await DiskSearchIndex.open(path: path, vaultKey: key);
  try {
    final originals = await index.loadConversations(
      summaries.map((item) => item.id).toList(),
    );
    await index.writeMetadata(_relevanceBackupKey, {
      'count': catalog.length,
      'conversations': originals.map((item) => item.toJson()).toList(),
    });
    try {
      await index.upsert(
        overlay,
        participantById: {..._people, ...fixture.participantById},
        relationTextByConversation: const {},
      );
      catalog.setRange(offset, catalog.length, overlay.map(_summary));
      _require(
        await index.count == catalog.length,
        'Relevance overlay changed corpus count.',
      );
      await index.prepare();
      await checkpoint('semantic-overlay-prepared');
      for (final judgment in fixture.judgments) {
        final criteria = judgment.criteria;
        final tokens = ConversationSearchIndex.tokenize(criteria.normalized);
        final watch = Stopwatch()..start();
        final results = await index.search(
          criteria,
          SearchScorer(
            temporalIntent: null,
            normalizedQuery: criteria.normalized,
            now: _now,
          ),
          tokens,
          tokens.join(' '),
        );
        watch.stop();
        final elapsed = watch.elapsedMicroseconds / 1000;
        final actual = results.map((item) => item.id).toList();
        final expected = judgment.expectedTopIds
            .map((id) => mappedIds[id]!)
            .toList();
        final observed = judgment.requireExactResults
            ? actual.toList()
            : actual.take(expected.length).toList();
        final excluded = judgment.excludedIds.map((id) => mappedIds[id]!);
        if (judgment.unordered) {
          expected.sort();
          observed.sort();
        }
        final passed =
            jsonEncode(observed) == jsonEncode(expected) &&
            !actual.any(excluded.contains);
        cases.add({
          'label': judgment.label,
          'expectedTopIds': expected,
          'actualTopIds': actual.take(math.max(10, expected.length)).toList(),
          'requireExactResults': judgment.requireExactResults,
          'unordered': judgment.unordered,
          'elapsedMs': elapsed,
          'profile': await index.searchProfile,
          'passed': passed,
        });
        await checkpoint('semantic-judgment:${cases.length}');
        _require(
          passed,
          'Semantic relevance failed: ${judgment.label}; expected $expected, got $observed.',
        );
      }
      evidence['passed'] = true;
    } finally {
      evidence['restoredConversations'] = await _restoreRelevanceBackup(index);
      catalog.setRange(offset, catalog.length, summaries);
      await checkpoint('semantic-overlay-restored');
    }
  } finally {
    await index.close();
  }
}

Future<void> _queries(
  String path,
  List<int> key,
  List<Conversation> catalog,
  List<String> filler,
  Map<String, Object> metrics,
  Future<void> Function(String) checkpoint,
) async {
  final count = catalog.length;
  final filters = <String?>[
    null,
    for (final group in SearchSourceGroup.values) sourceGroupFilter(group),
  ];
  final vocabulary = ConversationSearchIndex.build(
    conversations: [
      Conversation(
        id: 'vocabulary',
        title: '',
        source: 'manual',
        participantIds: [],
        segments: [
          ConversationSegment(
            id: 'words',
            text: [
              ...filler,
              ..._firstNames,
              ..._surnames,
              'insurance renewal grocery shopping archive Alice Müller Bob updateproof youtube-watch-history scanned-pdf imap discord manual',
            ].join(' '),
          ),
        ],
      ),
    ],
    participantById: const {},
    relationTextByConversation: const {},
  );
  final words = <String>{
    ...[
      'search',
      'database',
      'conversation',
      'recording',
      'import',
      'export',
      'metadata',
      'participant',
      'storage',
      'token',
      'encrypted',
      'source',
      'history',
      'message',
      'content',
      'local',
      'server',
      'client',
      'create',
      'delete',
      'project',
      'calendar',
      'document',
      'account',
      'session',
      'request',
      'response',
      'index',
      'settings',
      'device',
    ].where(filler.contains),
    ...filler,
  }.take(24).toList();
  final families = <String, List<(String, String?, int?)>>{
    'ordinary': [
      for (var n = 0; n < words.length; n++)
        (words[n], filters[n % filters.length], null),
    ],
    'name': [],
    'prefix': [],
    'fuzzy': [],
    'broad': [
      for (final query in ['archive', 'grocery', 'shopping', 'bob'])
        (query, null, null),
      for (final word in words.take(20)) ('archive $word', null, null),
    ],
  };
  // Real names occupy two of the same 200 words only in the appended fixture.
  // Use distinct name combinations, not numeric IDs or source-filter variants.
  for (var n = 0; n < 24; n++) {
    final first = _firstNames[n % _firstNames.length].toLowerCase();
    final surname = _surnames[n ~/ _firstNames.length].toLowerCase();
    final variants = {
      'name': first,
      'prefix': first.substring(0, first.length - 1),
      'fuzzy': 'z${first.substring(1)}',
    };
    for (final variant in variants.entries) {
      final query = '${variant.value} $surname';
      families[variant.key]!.add((query, null, n));
    }
  }
  for (final family in families.entries) {
    _require(
      family.value.length >= 20,
      'Insufficient distinct ${family.key} queries.',
    );
    final firstSamples = <double>[];
    final warmSamples = <double>[];
    final cases = <Map<String, Object?>>[];
    for (final (query, source, nameResidue) in family.value) {
      final expansions = vocabulary.expandTokens(
        ConversationSearchIndex.tokenize(query),
      );
      bool member(int i) {
        if (i < 0 ||
            i >= count ||
            !matchesSourceFilter(source, _sourceForIndex(i))) {
          return false;
        }
        final conversation = _conversation(i, filler);
        final tokens = ConversationSearchIndex.tokenize(
          [
            catalog[i].title,
            conversation.source,
            for (final id in conversation.participantIds) _people[id]!,
            for (final segment in conversation.segments) segment.text,
          ].join(' '),
        ).toSet();
        return expansions.values.every(
          (matches) => matches.keys.any(tokens.contains),
        );
      }

      var expected = 0;
      final namedMatches = nameResidue == null
          ? 0
          : math.max(0, (count - _nameStart + 199 - nameResidue) ~/ 200);
      if (namedMatches >= 100) {
        // Every document in this residue has the same two authored name words;
        // 100 known matches prove the result limit even when expansion is broad.
        final residue = nameResidue!;
        _require(
          expansions.values.first.containsKey(
                _firstNames[residue % _firstNames.length].toLowerCase(),
              ) &&
              expansions.values.last.containsKey(
                _surnames[residue ~/ _firstNames.length].toLowerCase(),
              ),
          'Name query does not match its authored fixture: $query',
        );
        expected = 100;
      } else {
        // For small corpora, count all valid content matches, including matches
        // through ambiguous expansions, until the result limit is proven.
        for (var i = 0; i < count && expected < 100; i++) {
          if (member(i)) expected++;
        }
      }
      final preparation = Stopwatch()..start();
      final index = await DiskSearchIndex.open(path: path, vaultKey: key);
      try {
        await index.prepare();
        preparation.stop();
        List<String>? previous;
        final profiles = <Map<String, int>>[];
        for (var repetition = 0; repetition < 2; repetition++) {
          final ids = await _checkQuery(
            index,
            query,
            expected,
            member,
            source: source,
            samples: repetition == 0 ? firstSamples : warmSamples,
            profiles: profiles,
          );
          _require(
            previous == null || jsonEncode(previous) == jsonEncode(ids),
            'Unstable ranking for "$query" ($source).',
          );
          previous = ids;
        }
        cases.add({
          'query': query,
          'source': source,
          'expandedWords': {
            for (final entry in expansions.entries)
              entry.key: entry.value.keys.toList(),
          },
          'ambiguousExpansion': expansions.values.any(
            (matches) => matches.length > 1,
          ),
          'expectedReturned': expected,
          'returned': expected,
          'preparationMs': preparation.elapsedMicroseconds / 1000,
          'firstQueryMs': firstSamples.last,
          'warmMs': warmSamples.last,
          'firstQueryProfile': profiles.first,
          'warmProfile': profiles.last,
          'topIds': previous!,
        });
      } finally {
        await index.close();
      }
      // Persist each completed request so a failure never discards earlier
      // evidence or forces the multi-million-conversation build to repeat.
      metrics[family.key] = {
        'cacheCondition': 'fresh prepared worker; OS page cache uncontrolled',
        'queryLatencyExcludesInitialization': true,
        'preparationScope':
            'worker open and prepare, including numeric cache hydration',
        'preparationP95Ms': _p95([
          for (final item in cases) item['preparationMs'] as double,
        ]),
        'samples': cases,
        'firstQueryP95Ms': _p95(firstSamples),
        'warmP95Ms': _p95(warmSamples),
        'sampleCount': cases.length,
        'ambiguousExpansionCases': cases
            .where((item) => item['ambiguousExpansion'] == true)
            .length,
        'rssBytes': ProcessInfo.currentRss,
      };
      await checkpoint('query:${family.key}:${cases.length}');
    }
    _require(
      firstSamples.length >= 20 && warmSamples.length >= 20,
      'At least 20 samples are required for p95.',
    );
  }
  final index = await DiskSearchIndex.open(path: path, vaultKey: key);
  try {
    final recent = await _checkQuery(
      index,
      '',
      math.min(100, count),
      (i) => i >= 0 && i < count,
    );
    _require(
      jsonEncode(recent) == jsonEncode(_recent(catalog)),
      'Incorrect expected top IDs for recent conversations.',
    );
    final lookups = <Map<String, Object>>[];
    for (var n = 0; n < 20; n++) {
      final number = n * (count - 1) ~/ 19;
      final query = 'archive ${number.toString().padLeft(12, '0')}';
      final ids = await _checkQuery(index, query, 1, (i) => i == number);
      _require(
        ids.single == _id(number),
        'Wrong expected top ID for "$query".',
      );
      lookups.add({
        'query': query,
        'expectedTopIds': [_id(number)],
        'actualTopIds': ids,
      });
    }
    final participantQueries = <Map<String, Object>>[];
    for (final query in [
      'insurance renewal',
      'insuranc alice',
      'ali muell',
      'MÜLLER',
    ]) {
      final samples = <double>[];
      await _checkQuery(
        index,
        query,
        math.min(100, (count + 9999) ~/ 10000),
        (i) => i >= 0 && i < count && i % 10000 == 0,
        samples: samples,
      );
      participantQueries.add({
        'query': query,
        'elapsedMs': samples.single,
        'profile': await index.searchProfile,
      });
    }
    await _checkQuery(index, 'insurance zxqvbnm', 0, (_) => false);
    metrics['relevance'] = {
      'knownTitleQueries': lookups,
      'participantQueries': participantQueries,
      'recentExpectedTopIds': recent,
      'contentAndSourceMembershipPassed': true,
      'distinctNameQueries': _nameStart < count ? 24 : 0,
      'allQueryTokensRequiredPassed': true,
    };
  } finally {
    await index.close();
  }
  await checkpoint('relevance-verified');
}

double _p95(List<double> values) {
  final sorted = values.toList()..sort();
  return sorted[(sorted.length * .95).ceil() - 1];
}

Future<void> _writeReport(String path, Map<String, Object> metrics) async {
  final temporary = File('$path.tmp');
  await temporary.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(metrics)}\n',
    flush: true,
  );
  await temporary.rename(path);
}

Future<List<String>> _checkQuery(
  DiskSearchIndex index,
  String query,
  int expected,
  bool Function(int) member, {
  String? source,
  List<double>? samples,
  List<Map<String, int>>? profiles,
}) async {
  final watch = Stopwatch()..start();
  final tokens = ConversationSearchIndex.tokenize(query);
  final results = await index.search(
    SearchCriteria(query: query, source: source),
    SearchScorer(
      temporalIntent: null,
      normalizedQuery: query.toLowerCase(),
      now: _now,
    ),
    tokens,
    tokens.join(' '),
    maxResults: 100,
  );
  watch.stop();
  samples?.add(watch.elapsedMicroseconds / 1000);
  if (profiles != null) profiles.add(await index.searchProfile);
  final ids = results.map((item) => item.id).toList();
  _require(
    ids.length == expected &&
        ids.toSet().length == expected &&
        ids.every((id) => member(_number(id))) &&
        results.every(
          (item) => item.source == _sourceForIndex(_number(item.id)),
        ),
    'Incorrect results for "$query": ${ids.length} != $expected.',
  );
  return ids;
}

List<String> _recent(List<Conversation> catalog) {
  final scorer = SearchScorer(
    temporalIntent: null,
    normalizedQuery: '',
    now: _now,
  );
  final top = <(Conversation, double)>[];
  int compare((Conversation, double) a, (Conversation, double) b) {
    final score = b.$2.compareTo(a.$2);
    if (score != 0) return score;
    final date = b.$1.startedAt.compareTo(a.$1.startedAt);
    return date != 0 ? date : a.$1.id.compareTo(b.$1.id);
  }

  for (final conversation in catalog) {
    final item = (
      conversation,
      scorer.score(
            documentTime: conversation.startedAt,
            conversationId: conversation.id,
            useVector: false,
          ) *
          weightForSource(conversation.source),
    );
    if (top.length == 100 && compare(item, top.last) >= 0) continue;
    var position = 0;
    while (position < top.length && compare(item, top[position]) >= 0) {
      position++;
    }
    top.insert(position, item);
    if (top.length > 100) top.removeLast();
  }
  return top.map((item) => item.$1.id).toList();
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

String _fileSystemType(Directory directory) {
  final path = directory.resolveSymbolicLinksSync();
  var longest = -1;
  var type = 'unknown';
  for (final line in File('/proc/self/mountinfo').readAsLinesSync()) {
    final fields = line.split(' ');
    final mount = fields[4].replaceAllMapped(
      RegExp(r'\\([0-7]{3})'),
      (match) => String.fromCharCode(int.parse(match[1]!, radix: 8)),
    );
    if (mount.length > longest &&
        (mount == '/' || path == mount || path.startsWith('$mount/'))) {
      longest = mount.length;
      type = fields[fields.indexOf('-') + 1];
    }
  }
  return type;
}
