import 'dart:convert';
import 'dart:io';

import 'package:app/models.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:app/services/search_criteria.dart';
import 'package:app/services/search_scorer.dart';
import 'package:app/services/search_service.dart';

/// Run: dart run tool/search_benchmark.dart [conversation-count]
void main(List<String> arguments) {
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
  final index = ConversationSearchIndex.build(
    conversations: corpus,
    participantById: {'alice': 'Alice Müller', 'bob': 'Bob'},
    relationTextByConversation: const {},
  );
  build.stop();
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
      'queries': metrics,
    }),
  );
}
