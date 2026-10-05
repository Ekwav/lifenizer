import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/services/transcript_enrichment.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String _video(String id, {String transcript = 'none', String? when}) =>
    jsonEncode({
      'source': 'youtube-watch-history',
      'plaintextCompute': false,
      'message': 'ok',
      'participants': <dynamic>[],
      'diagnostics': {'entries': '1', 'videos': '1'},
      'conversations': [
        {
          'title': 'Cat video $id',
          'source': 'youtube-watch-history',
          'sourceThreadId': 'youtube:$id',
          'participantNames': <String>[],
          'metadata': {
            'platform': 'youtube',
            'videoId': id,
            'channel': 'Cat Channel',
            'watchCount': '2',
            'lastWatchedAt': when ?? '2026-05-01T10:00:00Z',
            'transcript': transcript,
          },
          'segments': [
            {
              'text': 'Cat video $id',
              'sourceMessageId': 'youtube:$id@1',
              'createdAt': when ?? '2026-05-01T10:00:00Z',
            },
          ],
        },
      ],
    });

String _transcript() => jsonEncode({
  'source': 'youtube-transcript',
  'plaintextCompute': false,
  'message': 'ok',
  'participants': <dynamic>[],
  'conversations': [
    {
      'title': 'Cat video',
      'source': 'youtube-transcript',
      'participantNames': <String>[],
      'metadata': {
        'transcriptSource': 'youtube-captions',
        'language': 'en',
        'kind': 'asr',
      },
      'segments': [
        {'text': 'purring is wonderful', 'offsetMs': 0, 'endMs': 1500},
        {'text': 'zebrafinch cameo', 'offsetMs': 1500, 'endMs': 3000},
      ],
    },
  ],
});

typedef _Handler = http.Response Function(http.Request request);

class _Harness {
  _Harness(this.transcript);
  _Handler transcript;
  String videoBody = '';
  late final LifenizerAppState state;

  Future<void> init() async {
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/imports/youtube-transcript') {
        return transcript(request);
      }
      if (path == '/api/imports/youtube-watch-history') {
        return http.Response(videoBody, 200);
      }
      if (path == '/api/sync/push') {
        return http.Response(jsonEncode({'cursor': 1}), 200);
      }
      return http.Response('nope', 404);
    });
    state = LifenizerAppState();
    await state.debugAuthenticateForTesting(
      LifenizerApiClient(
        baseUrl: 'http://127.0.0.1:5075',
        authToken: 't',
        client: client,
      ),
    );
  }

  /// Feeds a watched-video conversation through the real import path.
  Future<void> importVideo(String id, {String? when}) async {
    videoBody = _video(id, when: when);
    await state.importSource(source: 'youtube-watch-history', text: 'x$id');
    expect(state.error, isNull);
  }
}

Future<_Harness> _harness(_Handler transcript) async {
  final harness = _Harness(transcript);
  await harness.init();
  return harness;
}

void main() {
  const idA = 'aaaaaaaaaaa';

  group('enrichWatchedVideo', () {
    test('merges transcript segments into the watched video', () async {
      http.Request? sent;
      final h = await _harness((request) {
        sent = request;
        return http.Response(_transcript(), 200);
      });
      await h.importVideo(idA);
      final id = h.state.conversations.single.id;
      final result = await h.state.enrichWatchedVideo(id);
      expect(result.outcome, TranscriptOutcome.merged);
      expect(
        jsonDecode(sent!.body),
        containsPair('metadata', {'videoId': idA}),
      );
      // One conversation, no second youtube-transcript conversation.
      expect(h.state.conversations, hasLength(1));
      final merged = h.state.conversations.single;
      expect(merged.id, id);
      expect(merged.segments, hasLength(3));
      expect(merged.segments.last.endMs, 3000);
      expect(merged.metadata['transcript'], 'youtube-captions');
      expect(merged.metadata['language'], 'en');
      expect(merged.metadata['kind'], 'asr');
      expect(h.state.search('zebrafinch').map((c) => c.id), [id]);

      // Idempotent, and a later watch-history re-import keeps the marker.
      expect(
        (await h.state.enrichWatchedVideo(id)).outcome,
        TranscriptOutcome.alreadyEnriched,
      );
      await h.importVideo(idA);
      expect(
        h.state.conversations.single.metadata['transcript'],
        'youtube-captions',
      );
      expect(h.state.conversations.single.segments, hasLength(3));
    });

    test('404 marks the video unavailable so it is not retried', () async {
      var calls = 0;
      final h = await _harness((request) {
        calls++;
        return http.Response(
          jsonEncode({'error': 'transcript_unavailable'}),
          404,
        );
      });
      await h.importVideo(idA);
      final id = h.state.conversations.single.id;
      final result = await h.state.enrichWatchedVideo(id);
      expect(result.outcome, TranscriptOutcome.unavailable);
      expect(
        h.state.conversations.single.metadata['transcript'],
        'unavailable',
      );
      expect(h.state.recentVideosNeedingTranscript(), isEmpty);
      final batch = await h.state.enrichRecentWatchedVideos(
        cancel: TranscriptBatchCancel(),
      );
      expect(batch.total, 0);
      expect(calls, 1);
      // Re-importing the history does not reset the marker.
      await h.importVideo(idA);
      expect(
        h.state.conversations.single.metadata['transcript'],
        'unavailable',
      );
    });

    test('429 reports Retry-After and provider_blocked', () async {
      final h = await _harness(
        (request) => http.Response(
          jsonEncode({'error': 'rate_limited'}),
          429,
          headers: {'retry-after': '7'},
        ),
      );
      await h.importVideo(idA);
      final id = h.state.conversations.single.id;
      final result = await h.state.enrichWatchedVideo(id);
      expect(result.outcome, TranscriptOutcome.rateLimited);
      expect(result.retryAfter, const Duration(seconds: 7));
      expect(h.state.conversations.single.metadata['transcript'], 'none');
    });

    test('non-YouTube conversations are unsupported', () async {
      final h = await _harness((_) => http.Response('', 500));
      expect(
        (await h.state.enrichWatchedVideo('missing')).outcome,
        TranscriptOutcome.unsupported,
      );
    });
  });

  group('runTranscriptBatch', () {
    TranscriptResult merged() =>
        const TranscriptResult(TranscriptOutcome.merged);

    test(
      'waits Retry-After on 429 then continues with the same video',
      () async {
        final waits = <Duration>[];
        final calls = <String>[];
        var first = true;
        final progress = await runTranscriptBatch(
          conversationIds: ['a', 'b'],
          enrich: (id) async {
            calls.add(id);
            if (id == 'a' && first) {
              first = false;
              return const TranscriptResult(
                TranscriptOutcome.rateLimited,
                retryAfter: Duration(seconds: 12),
              );
            }
            return merged();
          },
          wait: (d) async => waits.add(d),
          cancel: TranscriptBatchCancel(),
        );
        expect(calls, ['a', 'a', 'b']);
        expect(waits, [const Duration(seconds: 12)]);
        expect(progress.enriched, 2);
        expect(progress.finished, isTrue);
        expect(progress.stopReason, isNull);
      },
    );

    test('stops after 3 consecutive provider_blocked answers', () async {
      final waits = <Duration>[];
      var calls = 0;
      final progress = await runTranscriptBatch(
        conversationIds: ['a', 'b', 'c'],
        enrich: (id) async {
          calls++;
          return const TranscriptResult(
            TranscriptOutcome.blocked,
            retryAfter: Duration(minutes: 5),
          );
        },
        wait: (d) async => waits.add(d),
        cancel: TranscriptBatchCancel(),
      );
      expect(calls, 3);
      expect(waits, hasLength(2));
      expect(progress.stopReason, isNotNull);
      expect(progress.enriched, 0);
    });

    test(
      'a success resets the blocked streak; unavailable is counted',
      () async {
        final outcomes = [
          TranscriptOutcome.blocked,
          TranscriptOutcome.blocked,
          TranscriptOutcome.merged,
          TranscriptOutcome.blocked,
          TranscriptOutcome.unavailable,
        ];
        var i = 0;
        final progress = await runTranscriptBatch(
          conversationIds: ['a', 'b'],
          enrich: (_) async => TranscriptResult(outcomes[i++]),
          wait: (_) async {},
          cancel: TranscriptBatchCancel(),
        );
        expect(progress.stopReason, isNull);
        expect(progress.enriched, 1);
        expect(progress.unavailable, 1);
        expect(progress.done, 2);
      },
    );

    test('cancel stops before the next video and ends waits', () async {
      final cancel = TranscriptBatchCancel();
      final calls = <String>[];
      final progress = await runTranscriptBatch(
        conversationIds: ['a', 'b', 'c'],
        enrich: (id) async {
          calls.add(id);
          if (id == 'a') cancel.cancel();
          return merged();
        },
        wait: (_) async {},
        cancel: cancel,
      );
      expect(calls, ['a']);
      expect(progress.cancelled, isTrue);
      expect(progress.done, 1);
      // A wait started before cancel completes immediately.
      final stopwatch = Stopwatch()..start();
      await cancellableDelay(const Duration(seconds: 30), cancel);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });

  test(
    'bulk enrichment picks the newest 25 videos lacking a transcript',
    () async {
      final h = await _harness((_) => http.Response(_transcript(), 200));
      for (var i = 0; i < 30; i++) {
        final id = 'v${i.toString().padLeft(10, '0')}';
        await h.importVideo(
          id,
          when: DateTime.utc(
            2026,
            5,
            1,
          ).add(Duration(days: i)).toIso8601String(),
        );
      }
      final ids = h.state.recentVideosNeedingTranscript();
      expect(ids, hasLength(25));
      final titles = ids
          .map(
            (id) => h.state.conversations.firstWhere((c) => c.id == id).title,
          )
          .toList();
      expect(titles.first, 'Cat video v0000000029');
      expect(titles.last, 'Cat video v0000000005');
    },
  );
}
