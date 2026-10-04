enum SyncStage {
  authenticating,
  readingLocal,
  derivingKey,
  decryptingLocal,
  restoring,
  uploading,
  downloading,
  decrypting,
  applying,
  saving,
  indexing,
  complete,
  failed,
}

class SyncProgress {
  const SyncProgress({
    required this.stage,
    this.completed = 0,
    this.total,
    this.receivedBytes = 0,
    this.totalBytes,
    this.downloaded = 0,
    this.uploaded = 0,
    this.batch = 0,
    this.detail,
    Duration elapsed = Duration.zero,
    this.stageClock,
  }) : _elapsed = elapsed;

  final SyncStage stage;
  final int completed;
  final int? total;
  final int receivedBytes;
  final int? totalBytes;
  final int downloaded;
  final int uploaded;
  final int batch;
  final String? detail;
  final Duration _elapsed;
  final Stopwatch? stageClock;
  Duration get elapsed => stageClock?.elapsed ?? _elapsed;

  Duration? get estimatedRemaining {
    final done = stage == SyncStage.downloading ? receivedBytes : completed;
    final count = stage == SyncStage.downloading ? totalBytes : total;
    if (!active ||
        count == null ||
        done <= 0 ||
        done >= count ||
        elapsed.inSeconds < 1) {
      return null;
    }
    return Duration(
      microseconds: (elapsed.inMicroseconds * (count - done) / done).round(),
    );
  }

  bool get active => stage != SyncStage.complete && stage != SyncStage.failed;

  double? get fraction {
    if (stage == SyncStage.downloading) {
      return totalBytes != null && totalBytes! > 0
          ? (receivedBytes / totalBytes!).clamp(0.0, 1.0)
          : null;
    }
    return total != null && total! > 0
        ? (completed / total!).clamp(0.0, 1.0)
        : null;
  }

  String get label => switch (stage) {
    SyncStage.authenticating => detail ?? 'Verifying this device',
    SyncStage.readingLocal => 'Reading encrypted local vault',
    SyncStage.derivingKey => 'Deriving the vault encryption key',
    SyncStage.decryptingLocal => 'Decrypting your cached vault',
    SyncStage.restoring =>
      '${detail ?? 'Restoring local vault'} · $completed / $total ${detail == null ? 'messages' : 'conversations'}',
    SyncStage.uploading => 'Uploading encrypted changes · $completed / $total',
    SyncStage.downloading => 'Downloading encrypted batch $batch',
    SyncStage.decrypting =>
      'Decrypting batch $batch · $completed / $total records',
    SyncStage.applying => 'Merging batch $batch · $completed / $total records',
    SyncStage.saving => 'Saving encrypted vault on this device',
    SyncStage.indexing =>
      total == null
          ? (detail ?? 'Preparing search')
          : '${detail ?? 'Preparing search'} · $completed / $total conversations',
    SyncStage.complete => 'Sync complete',
    SyncStage.failed => 'Sync interrupted · retry to continue',
  };
}
