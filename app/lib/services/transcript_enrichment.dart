import 'dart:async';

/// Result of trying to attach a YouTube transcript to a watched video.
enum TranscriptOutcome {
  /// Captions were fetched and merged into the conversation.
  merged,

  /// The conversation already carries captions; nothing was requested.
  alreadyEnriched,

  /// No public captions (404). Recorded so the video is not retried.
  unavailable,

  /// 429 `rate_limited`; retry after [TranscriptResult.retryAfter].
  rateLimited,

  /// 429 `provider_blocked`; YouTube is blocking the server for a while.
  blocked,

  /// Not a YouTube watch-history conversation, or no video id.
  unsupported,

  /// Any other failure (network, server error, locked vault).
  failed,
}

class TranscriptResult {
  const TranscriptResult(this.outcome, {this.retryAfter, this.message});
  final TranscriptOutcome outcome;
  final Duration? retryAfter;
  final String? message;
}

/// Lets the UI stop a running batch; waits end as soon as it is cancelled.
class TranscriptBatchCancel {
  bool _cancelled = false;
  final _signal = Completer<void>();
  bool get cancelled => _cancelled;
  Future<void> get whenCancelled => _signal.future;
  void cancel() {
    _cancelled = true;
    if (!_signal.isCompleted) _signal.complete();
  }
}

class TranscriptBatchProgress {
  const TranscriptBatchProgress({
    required this.total,
    required this.done,
    required this.enriched,
    required this.unavailable,
    required this.failed,
    this.waiting,
    this.current,
    this.stopReason,
    this.finished = false,
    this.cancelled = false,
  });

  final int total;
  final int done;
  final int enriched;
  final int unavailable;
  final int failed;

  /// Set while the batch sleeps for a server-provided `Retry-After`.
  final Duration? waiting;
  final String? current;
  final String? stopReason;
  final bool finished;
  final bool cancelled;

  String get summary {
    final parts = <String>[
      '$enriched transcript(s) added',
      if (unavailable > 0) '$unavailable without captions',
      if (failed > 0) '$failed failed',
    ];
    return parts.join(' · ');
  }
}

/// Maximum consecutive `provider_blocked` answers before a batch gives up.
const int maxConsecutiveBlocked = 3;

/// Retries of one video after plain `rate_limited` answers before giving up.
const int maxRateLimitRetries = 5;

/// Fallback pause when a 429 carries no usable `Retry-After`.
const Duration defaultRetryAfter = Duration(seconds: 10);

/// Fetches transcripts one video at a time, sequentially.
///
/// [enrich] performs one video; [wait] sleeps (injectable for tests). 429s
/// wait their `Retry-After` and then retry the same video; three consecutive
/// `provider_blocked` answers stop the batch.
Future<TranscriptBatchProgress> runTranscriptBatch({
  required List<String> conversationIds,
  required Future<TranscriptResult> Function(String id) enrich,
  required Future<void> Function(Duration) wait,
  required TranscriptBatchCancel cancel,
  void Function(TranscriptBatchProgress progress)? onProgress,
}) async {
  var done = 0;
  var enriched = 0;
  var unavailable = 0;
  var failed = 0;
  var blocked = 0;
  String? stopReason;

  TranscriptBatchProgress snapshot({
    Duration? waiting,
    String? current,
    bool finished = false,
  }) => TranscriptBatchProgress(
    total: conversationIds.length,
    done: done,
    enriched: enriched,
    unavailable: unavailable,
    failed: failed,
    waiting: waiting,
    current: current,
    stopReason: stopReason,
    finished: finished,
    cancelled: cancel.cancelled,
  );

  outer:
  for (final id in conversationIds) {
    var rateRetries = 0;
    while (true) {
      if (cancel.cancelled) break outer;
      onProgress?.call(snapshot(current: id));
      final result = await enrich(id);
      switch (result.outcome) {
        case TranscriptOutcome.merged:
          enriched++;
          blocked = 0;
        case TranscriptOutcome.unavailable:
          unavailable++;
          blocked = 0;
        case TranscriptOutcome.alreadyEnriched:
        case TranscriptOutcome.unsupported:
          blocked = 0;
        case TranscriptOutcome.failed:
          failed++;
        case TranscriptOutcome.rateLimited:
        case TranscriptOutcome.blocked:
          final isBlock = result.outcome == TranscriptOutcome.blocked;
          if (isBlock) {
            blocked++;
            if (blocked >= maxConsecutiveBlocked) {
              stopReason =
                  'YouTube is blocking caption requests from the server. '
                  'Try again later.';
              break outer;
            }
          } else if (++rateRetries > maxRateLimitRetries) {
            stopReason = 'Rate limit still active after $rateRetries tries.';
            break outer;
          }
          final pause = result.retryAfter ?? defaultRetryAfter;
          onProgress?.call(snapshot(waiting: pause, current: id));
          await wait(pause);
          continue; // Same video again after the pause.
      }
      break;
    }
    done++;
  }
  final last = snapshot(finished: true);
  onProgress?.call(last);
  return last;
}

/// Default [wait] that returns early when [cancel] fires.
Future<void> cancellableDelay(Duration pause, TranscriptBatchCancel cancel) =>
    Future.any([Future<void>.delayed(pause), cancel.whenCancelled]);
