// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:app/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Import performance (client normalization ingest)', () {
    test('benchmarks 20 import sources across small/medium/large payloads', () {
      const parserSources = <String>[
        'manual-text',
        'scanned-pdf',
        'live-recording',
        'whatsapp',
        'imessage',
        'signal',
        'telegram',
        'discord',
        'slack',
        'teams',
        'facebook-messenger',
        'instagram',
        'mbox',
        'git',
        'browser-history',
        'browser-capture',
        'bookmarks',
        'google-search-history',
        'lifenizer-backup',
        'youtube-transcript',
      ];
      const sizes = <int>[10, 100, 1000];

      final summary = <_PerfRow>[];

      for (final source in parserSources) {
        for (final messageCount in sizes) {
          final payload = _buildNormalizedImportPayload(
            source: source,
            messageCount: messageCount,
          );

          final repeats = messageCount >= 1000 ? 2 : 5;
          final rssBefore = ProcessInfo.currentRss;
          final elapsedMicros = _medianParsingMicros(
            () => NormalizedImportResult.fromJson(payload),
            repeats: repeats,
            expectedSegments: messageCount,
          );
          final rssAfter = ProcessInfo.currentRss;

          final totalMessages = messageCount * repeats;
          final millis = elapsedMicros / 1000.0;
          final msPerMessage = millis / totalMessages;
          final segmentsPerSecond = totalMessages / (elapsedMicros / 1000000.0);

          summary.add(
            _PerfRow(
              source: source,
              messageCount: messageCount,
              repeats: repeats,
              msPerMessage: msPerMessage,
              segmentsPerSecond: segmentsPerSecond,
              rssDeltaKiB: (rssAfter - rssBefore) / 1024.0,
            ),
          );
        }
      }

      // Old vs new architecture proxy comparison on medium-size payload.
      final legacyVsNew = <String, ({double newMs, double legacyMs})>{};
      for (final source in parserSources) {
        final payload = _buildNormalizedImportPayload(
          source: source,
          messageCount: 100,
        );

        const repeats = 5;
        legacyVsNew[source] = (
          newMs:
              _medianParsingMicros(
                () => NormalizedImportResult.fromJson(payload),
                repeats: repeats,
                expectedSegments: 100,
              ) /
              (1000 * repeats),
          legacyMs:
              _medianParsingMicros(
                () => _legacyParse(payload),
                repeats: repeats,
                expectedSegments: 100,
              ) /
              (1000 * repeats),
        );
      }

      final slowest = [...summary]
        ..sort((a, b) => b.msPerMessage.compareTo(a.msPerMessage));
      final topSlow = slowest.take(5).toList(growable: false);

      print('Import parser performance summary (median of 7 warmed batches)');
      for (final row in summary) {
        print(
          '${row.source.padRight(20)} '
          'n=${row.messageCount.toString().padLeft(4)} '
          'repeat=${row.repeats} '
          'ms/msg=${row.msPerMessage.toStringAsFixed(4).padLeft(8)} '
          'seg/s=${row.segmentsPerSecond.toStringAsFixed(1).padLeft(10)} '
          'rssDeltaKiB=${row.rssDeltaKiB.toStringAsFixed(1).padLeft(8)}',
        );
      }

      print('Slowest cases (ms/message):');
      for (final row in topSlow) {
        print(
          '  ${row.source} n=${row.messageCount}: '
          '${row.msPerMessage.toStringAsFixed(4)} ms/msg',
        );
      }

      print('Legacy vs new parser proxy (100 messages):');
      legacyVsNew.forEach((source, result) {
        final ratio = result.legacyMs <= 0
            ? 0.0
            : result.newMs / result.legacyMs;
        print(
          '  $source: new=${result.newMs.toStringAsFixed(3)} ms, '
          'legacy=${result.legacyMs.toStringAsFixed(3)} ms, '
          'ratio=${ratio.toStringAsFixed(2)}x',
        );
      });

      // Coarse guardrail for accidental quadratic behavior in client parsing.
      for (final source in parserSources) {
        final n100 = summary.firstWhere(
          (row) => row.source == source && row.messageCount == 100,
        );
        final n1000 = summary.firstWhere(
          (row) => row.source == source && row.messageCount == 1000,
        );
        final scaleRatio = n1000.msPerMessage / n100.msPerMessage;
        expect(
          scaleRatio,
          lessThan(8.0),
          reason:
              '$source appears to scale poorly (1000-msg ms/msg / 100-msg ms/msg = ${scaleRatio.toStringAsFixed(2)}).',
        );
      }

      expect(summary.length, equals(parserSources.length * sizes.length));
    });
  });
}

double _medianParsingMicros(
  NormalizedImportResult Function() parse, {
  required int repeats,
  required int expectedSegments,
}) {
  // Warm the parser/JIT before measuring. Independent batches and their median
  // prevent a scheduler pause or a GC cycle from deciding the scaling guardrail.
  for (var i = 0; i < 3; i++) {
    parse();
  }
  final samples = <int>[];
  for (var sample = 0; sample < 7; sample++) {
    var parsedSegments = 0;
    final stopwatch = Stopwatch()..start();
    for (var i = 0; i < repeats; i++) {
      parsedSegments += parse().conversations.fold<int>(
        0,
        (count, conversation) => count + conversation.segments.length,
      );
    }
    stopwatch.stop();
    expect(parsedSegments, repeats * expectedSegments);
    samples.add(stopwatch.elapsedMicroseconds);
  }
  samples.sort();
  return samples[samples.length ~/ 2].toDouble();
}

Map<String, dynamic> _buildNormalizedImportPayload({
  required String source,
  required int messageCount,
}) {
  final now = DateTime.now().toUtc();
  final segments = List<Map<String, dynamic>>.generate(
    messageCount,
    (index) => {
      'text':
          '[$source] message $index discussing timeline, imports, and search relevance.',
      'participantName': index.isEven ? 'Alice' : 'Bob',
      'offsetMs': index * 1500,
      'createdAt': now.subtract(Duration(seconds: messageCount - index)).toIso8601String(),
    },
    growable: false,
  );

  return <String, dynamic>{
    'source': source,
    'plaintextCompute': true,
    'message': 'Normalized $messageCount messages from $source',
    'conversations': [
      {
        'title': '$source benchmark conversation',
        'source': source,
        'participantNames': ['Alice', 'Bob'],
        'segments': segments,
        'artifactNames': const <String>[],
      },
    ],
    'participants': [
      {
        'displayName': 'Alice',
        'identifiers': ['alice@example.test'],
      },
      {
        'displayName': 'Bob',
        'identifiers': ['bob@example.test'],
      },
    ],
  };
}

NormalizedImportResult _legacyParse(Map<String, dynamic> payload) {
  // Simulates pre-refactor overhead via JSON roundtrip and repeated casts.
  final decoded = jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;

  final source = decoded['source'] as String;
  final plaintextCompute = decoded['plaintextCompute'] as bool? ?? true;
  final message = decoded['message'] as String? ?? '';

  final conversationList = (decoded['conversations'] as List<dynamic>? ?? const [])
      .cast<Map<dynamic, dynamic>>();

  final conversations = <NormalizedConversation>[];
  for (final raw in conversationList) {
    final segmentsRaw =
        (raw['segments'] as List<dynamic>? ?? const []).cast<Map<dynamic, dynamic>>();
    final segments = <NormalizedSegment>[];
    for (final segment in segmentsRaw) {
      segments.add(
        NormalizedSegment(
          text: (segment['text'] as String?) ?? '',
          participantName: segment['participantName'] as String?,
          offsetMs: (segment['offsetMs'] as int?) ?? 0,
          createdAt: segment['createdAt'] == null
              ? null
              : DateTime.parse(segment['createdAt'] as String),
        ),
      );
    }

    conversations.add(
      NormalizedConversation(
        title: (raw['title'] as String?) ?? '',
        source: (raw['source'] as String?) ?? source,
        participantNames:
            ((raw['participantNames'] as List<dynamic>? ?? const [])
                    .map((entry) => entry.toString())
                    .toList(growable: false)),
        segments: segments,
        artifactNames: ((raw['artifactNames'] as List<dynamic>? ?? const [])
            .map((entry) => entry.toString())
            .toList(growable: false)),
      ),
    );
  }

  final participantsRaw =
      (decoded['participants'] as List<dynamic>? ?? const []).cast<Map<dynamic, dynamic>>();
  final participants = participantsRaw
      .map(
        (raw) => NormalizedParticipant(
          displayName: (raw['displayName'] as String?) ?? '',
          identifiers: ((raw['identifiers'] as List<dynamic>? ?? const [])
              .map((entry) => entry.toString())
              .toList(growable: false)),
        ),
      )
      .toList(growable: false);

  return NormalizedImportResult(
    source: source,
    plaintextCompute: plaintextCompute,
    message: message,
    conversations: conversations,
    participants: participants,
  );
}

class _PerfRow {
  _PerfRow({
    required this.source,
    required this.messageCount,
    required this.repeats,
    required this.msPerMessage,
    required this.segmentsPerSecond,
    required this.rssDeltaKiB,
  });

  final String source;
  final int messageCount;
  final int repeats;
  final double msPerMessage;
  final double segmentsPerSecond;
  final double rssDeltaKiB;
}
