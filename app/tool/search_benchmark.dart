import 'dart:convert';
import 'dart:io';

import 'package:app/models.dart';
import 'package:app/crypto_service.dart';
import 'package:app/services/search_index_worker_io.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:app/services/search_criteria.dart';
import 'package:app/services/search_scorer.dart';
import 'package:app/services/search_service.dart';

/// Run: dart run tool/search_benchmark.dart [conversation-count]
Future<void> main(List<String> arguments) async {
  final count = arguments.isEmpty ? 10000 : int.parse(arguments.first);
  final now = DateTime.utc(2026, 10, 3);
  final build = Stopwatch()..start();
  final corpus = List.generate(
    count,
    (i) => Conversation(
      id: 'archive-$i',
      title: 'Archive note $i',
      source: 'manual',
      participantIds: [i % 100 == 0 ? 'alice' : 'bob'],
      startedAt: now.subtract(Duration(days: i % 1000)),
      endedAt: now.subtract(Duration(days: i % 1000)),
      segments: [
        ConversationSegment(
          id: 'segment-$i',
          text: i % 100 == 0
              ? 'Insurance renewal policy and quarterly discussion'
              : 'Grocery shopping and weekend holiday plans',
        ),
      ],
    ),
  );
  var index = ConversationSearchIndex.build(
    conversations: corpus,
    participantById: {'alice': 'Alice Müller', 'bob': 'Bob'},
    relationTextByConversation: const {},
  );
  build.stop();
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
    email: 'benchmark@example.test', passphrase: 'synthetic benchmark only',
    vaultSalt: 'benchmark-salt', background: true,
  );
  await unlock();
  final deviceKey = await crypto.exportDeviceKey();
  final sealed = await crypto.encryptJson(await encodeSearchSnapshot(index), background: true);
  // Include a real file read, fresh key derivation, authenticated decryption,
  // decompression and index restoration; never use private vault data here.
  final directory = await Directory.systemTemp.createTemp('lifenizer-startup-');
  final file = File('${directory.path}/index.json');
  await file.writeAsString(jsonEncode({'cipherText': sealed.cipherText, 'nonce': sealed.nonce}));
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
  index = await decodeSearchSnapshot(await crypto.decryptJson(
    cipherText: pairedRecord['cipherText'] as String,
    nonce: pairedRecord['nonce'] as String,
    background: true,
  ));
  pairedStartup.stop();
  crypto.lock();
  await directory.delete(recursive: true);
  final metrics = <String, Object>{};
  for (final query in [
    'insurance renewal',
    'insuranc alice',
    'ali muell',
    'insurance banana',
    '',
  ]) {
    final samples = <int>[];
    final tokens = ConversationSearchIndex.tokenize(query);
    final profile = SearchRankProfile();
    var matches = 0;
    for (var i = 0; i < 21; i++) {
      final watch = Stopwatch()..start();
      final results = SearchService(index).rankConversations(
        SearchCriteria(query: query),
        SearchScorer(temporalIntent: null, normalizedQuery: query, now: now),
        tokens,
        tokens.join(' '),
        maxResults: 8,
        profile: profile,
      );
      watch.stop();
      matches = results.length;
      if (i > 0) samples.add(watch.elapsedMicroseconds);
    }
    samples.sort();
    metrics[query.isEmpty ? '(recent)' : query] = {
      'medianMs': samples[samples.length ~/ 2] / 1000,
      'p95Ms': samples[(samples.length * 0.95).ceil() - 1] / 1000,
      'candidates': profile.candidateCount,
      'matched': profile.matchedCount,
      'returned': matches,
    };
  }
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'conversations': count,
      'vocabulary': index.invertedIndex.length,
      'buildMs': build.elapsedMicroseconds / 1000,
      'snapshotBytes': utf8.encode(snapshot).length,
      'snapshotEncodeMs': encode.elapsedMicroseconds / 1000,
      'snapshotRestoreMs': restore.elapsedMicroseconds / 1000,
      'encryptedStartupMs': startup.elapsedMicroseconds / 1000,
      'pairedStartupMs': pairedStartup.elapsedMicroseconds / 1000,
      'keyDerivationMs': keyMs,
      'readDecryptMs': decryptMs,
      'encryptedSnapshotBytes': sealed.cipherText.length,
      'queries': metrics,
    }),
  );
}
