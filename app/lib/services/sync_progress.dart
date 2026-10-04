enum SyncStage {
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
  });

  final SyncStage stage;
  final int completed;
  final int? total;
  final int receivedBytes;
  final int? totalBytes;
  final int downloaded;
  final int uploaded;
  final int batch;

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
    SyncStage.uploading => 'Uploading encrypted changes · $completed / $total',
    SyncStage.downloading => 'Downloading encrypted batch $batch',
    SyncStage.decrypting =>
      'Decrypting batch $batch · $completed / $total records',
    SyncStage.applying => 'Merging batch $batch · $completed / $total records',
    SyncStage.saving => 'Saving encrypted vault on this device',
    SyncStage.indexing => 'Preparing search',
    SyncStage.complete => 'Sync complete',
    SyncStage.failed => 'Sync interrupted · retry to continue',
  };
}
