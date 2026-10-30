import 'dart:convert';
import 'dart:io';

import 'package:app/models.dart';
import 'package:app/crypto_service.dart';
import 'package:app/services/search_index_worker_io.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:app/services/search_criteria.dart';
import 'package:app/services/search_scorer.dart';
import 'package:app/services/search_service.dart';

/// Run: dart run tool/search_benchmark.dart [count] [words] [result-limit] [--search-only]
Future<void> main(List<String> arguments) async {
  final count = arguments.isEmpty ? 10000 : int.parse(arguments.first);
  final words = arguments.length < 2 ? 200 : int.parse(arguments[1]);
  final resultLimit = arguments.length < 3 ? 51 : int.parse(arguments[2]);
  if (count < 1 || words < 2 || resultLimit < 1) {
    throw ArgumentError('Use count >= 1, words >= 2, result-limit >= 1');
  }
  // Public repository documentation supplies varied words without private data.
  // Numeric titles add one distinct vocabulary term per conversation.
  final docs = Directory.fromUri(Platform.script.resolve('../../docs/'));
  final vocabulary = <String>{};
  for (final name in ['ARCHITECTURE', 'IMPORTERS', 'AUTH', 'DATABASE']) {
    final file = File('${docs.path}/$name.md');
    vocabulary.addAll(
      ConversationSearchIndex.tokenize(
        file.readAsStringSync(),
      ).where((word) => word.length >= 4 && !word.contains(RegExp(r'[0-9]'))),
    );
  }
  // Reserve every fuzzy neighbor too, keeping the expected result sets exact.
  final probe = ConversationSearchIndex.build(
    conversations: [
      Conversation(
        id: 'probe',
        title: '',
        source: 'manual',
        participantIds: [],
        segments: [
          ConversationSegment(id: 'probe', text: vocabulary.join(' ')),
        ],
      ),
    ],
    participantById: const {},
    relationTextByConversation: const {},
  );
  vocabulary.removeAll(
    probe
        .expandTokens(['insurance', 'renewal', 'insuranc', 'alice', 'muell'])
        .values
        .expand((matches) => matches.keys),
  );
  final filler = vocabulary.toList()..sort();
  final now = DateTime.utc(2026, 10, 3);
  final build = Stopwatch()..start();
  var plaintextBytes = 0;
  final corpus = List.generate(count, (i) {
    var seed = i + 1;
    final text = <String>[
      ...(i % 100 == 0 ? ['insurance', 'renewal'] : ['grocery', 'shopping']),
      for (var n = 2; n < words; n++)
        filler[(seed = (seed * 1664525 + 1013904223) & 0xffffffff) %
            filler.length],
    ];
    final conversation = Conversation(
      id: 'archive-$i',
      title: 'Archive note $i',
      source: 'manual',
      participantIds: [i % 100 == 0 ? 'alice' : 'bob'],
      startedAt: now.subtract(Duration(days: i % 1000)),
      endedAt: now.subtract(Duration(days: i % 1000)),
      segments: [
        for (var n = 0; n < words; n += 20)
          ConversationSegment(
            id: 'segment-$i-$n',
            text: text.skip(n).take(20).join(' '),
          ),
      ],
    );
    plaintextBytes += utf8.encode(jsonEncode(conversation)).length;
    return conversation;
  });
  final generateMs = build.elapsedMicroseconds / 1000;
  build.reset();
  var index = ConversationSearchIndex.build(
    conversations: corpus,
    participantById: {'alice': 'Alice Müller', 'bob': 'Bob'},
    relationTextByConversation: const {},
  );
  build.stop();
  final baseMetrics = <String, Object>{
    'conversations': count,
    'wordsPerConversation': words,
    'resultLimit': resultLimit,
    'segmentsPerConversation': (words + 19) ~/ 20,
    'fillerVocabulary': filler.length,
    'plaintextConversationBytes': plaintextBytes,
    'vocabulary': index.invertedIndex.length,
    'buildMs': build.elapsedMicroseconds / 1000,
    'generateMs': generateMs,
  };
  stderr.writeln('Built $count conversations; RSS ${ProcessInfo.currentRss}');
  // Check search before serialization too, so large snapshot failures do not
  // hide whether the in-memory index worked.
  final metrics = <String, Object>{};
  void measureQueries(String stage) {
    for (final query in [
      'insurance renewal',
      'insuranc alice',
      'ali muell',
      'insurance zxqvbnm',
      'archive',
      '',
      if (stage == 'updated') 'updateproof',
    ]) {
      final samples = <int>[];
      final tokens = ConversationSearchIndex.tokenize(query);
      final profile = SearchRankProfile();
      List<String>? previous;
      for (var i = 0; i < 21; i++) {
        final watch = Stopwatch()..start();
        final results = SearchService(index).rankConversations(
          SearchCriteria(query: query),
          SearchScorer(temporalIntent: null, normalizedQuery: query, now: now),
          tokens,
          tokens.join(' '),
          maxResults: resultLimit,
          profile: profile,
        );
        watch.stop();
        final expected = switch (query) {
          'insurance zxqvbnm' => 0,
          'updateproof' => count < 100 ? count : 100,
          'archive' || '' => count,
          _ => (count + 99) ~/ 100,
        };
        final ids = results.map((item) => item.id).toList();
        if (profile.matchedCount != expected ||
            results.length !=
                (expected < resultLimit ? expected : resultLimit) ||
            (previous != null && jsonEncode(previous) != jsonEncode(ids)) ||
            (expected < count &&
                query != 'updateproof' &&
                results.any(
                  (item) => int.parse(item.id.split('-').last) % 100 != 0,
                ))) {
          throw StateError(
            'Incorrect/unstable $stage search: $query '
            '${profile.matchedCount} != $expected',
          );
        }
        previous = ids;
        if (i > 0) samples.add(watch.elapsedMicroseconds);
      }
      samples.sort();
      metrics['$stage:${query.isEmpty ? '(recent)' : query}'] = {
        'medianMs': samples[samples.length ~/ 2] / 1000,
        'p95Ms': samples[(samples.length * 0.95).ceil() - 1] / 1000,
        'candidates': profile.candidateCount,
        'matched': profile.matchedCount,
        'returned': previous!.length,
      };
    }
    stderr.writeln('$stage search passed; RSS ${ProcessInfo.currentRss}');
  }

  measureQueries('built');
  if (arguments.contains('--search-only')) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        ...baseMetrics,
        'peakRssBytes': ProcessInfo.maxRss,
        'searchOnly': true,
        'queries': metrics,
      }),
    );
    return;
  }
  final encode = Stopwatch()..start();
  final snapshot = jsonEncode(index.toJson());
  encode.stop();
  final restore = Stopwatch()..start();
  index = ConversationSearchIndex.fromJson(
    jsonDecode(snapshot) as Map<String, dynamic>,
  );
  restore.stop();
  final crypto = VaultCrypto();
  Future<void> unlock() => crypto.unlock(
    email: 'benchmark@example.test',
    passphrase: 'synthetic benchmark only',
    vaultSalt: 'benchmark-salt',
    background: true,
  );
  await unlock();
  final deviceKey = await crypto.exportDeviceKey();
  final sealed = await crypto.encryptJson(
    await encodeSearchSnapshot(index),
    background: true,
  );
  // Include a real file read, fresh key derivation, authenticated decryption,
  // decompression and index restoration; never use private vault data here.
  final directory = await Directory.systemTemp.createTemp('lifenizer-startup-');
  final file = File('${directory.path}/index.json');
  await file.writeAsString(
    jsonEncode({'cipherText': sealed.cipherText, 'nonce': sealed.nonce}),
  );
  crypto.lock();
  final startup = Stopwatch()..start();
  await unlock();
  final keyMs = startup.elapsedMicroseconds / 1000;
  final record = jsonDecode(await file.readAsString()) as Map;
  final decrypted = await crypto.decryptJson(
    cipherText: record['cipherText'] as String,
    nonce: record['nonce'] as String,
    background: true,
  );
  final decryptMs = startup.elapsedMicroseconds / 1000 - keyMs;
  index = await decodeSearchSnapshot(decrypted);
  startup.stop();
  crypto.lock();
  final pairedStartup = Stopwatch()..start();
  crypto.unlockDeviceKey(deviceKey);
  deviceKey.fillRange(0, deviceKey.length, 0);
  final pairedRecord = jsonDecode(await file.readAsString()) as Map;
  index = await decodeSearchSnapshot(
    await crypto.decryptJson(
      cipherText: pairedRecord['cipherText'] as String,
      nonce: pairedRecord['nonce'] as String,
      background: true,
    ),
  );
  pairedStartup.stop();
  crypto.lock();
  await directory.delete(recursive: true);
  measureQueries('restored');
  final updates = Stopwatch()..start();
  for (final conversation in corpus.take(100)) {
    index.upsert(
      Conversation.fromJson({
        ...conversation.toJson(),
        'title': '${conversation.title} updateproof',
      }),
      participantById: {'alice': 'Alice Müller', 'bob': 'Bob'},
      relationTextByConversation: const {},
      refresh: false,
    );
  }
  index.refreshStatistics();
  updates.stop();
  measureQueries('updated');
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      ...baseMetrics,
      'peakRssBytes': ProcessInfo.maxRss,
      'snapshotBytes': utf8.encode(snapshot).length,
      'snapshotEncodeMs': encode.elapsedMicroseconds / 1000,
      'snapshotRestoreMs': restore.elapsedMicroseconds / 1000,
      'encryptedStartupMs': startup.elapsedMicroseconds / 1000,
      'pairedStartupMs': pairedStartup.elapsedMicroseconds / 1000,
      'keyDerivationMs': keyMs,
      'readDecryptMs': decryptMs,
      'encryptedSnapshotBytes': sealed.cipherText.length,
      'batch100IndexUpdateMs': updates.elapsedMicroseconds / 1000,
      'queries': metrics,
    }),
  );
}
