import 'package:flutter/material.dart';

import '../services/sync_progress.dart';

class SyncProgressIndicator extends StatelessWidget {
  const SyncProgressIndicator({required this.progress, super.key});

  final SyncProgress? progress;

  String _bytes(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(0)} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  String _duration(Duration duration) {
    final seconds = duration.inSeconds;
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}m ${seconds % 60}s';
    return '${seconds ~/ 3600}h ${(seconds % 3600) ~/ 60}m';
  }

  @override
  Widget build(BuildContext context) {
    final value = progress;
    if (value == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value.label),
          if (value.active) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: value.fraction),
            Text('Elapsed ${_duration(value.elapsed)}'),
            Text(
              value.estimatedRemaining != null
                  ? 'About ${_duration(value.estimatedRemaining!)} remaining'
                  : value.fraction != null
                  ? 'Calculating estimate…'
                  : 'No reliable time estimate for this step yet.',
            ),
          ],
          if (value.stage == SyncStage.downloading && value.receivedBytes > 0)
            Text(
              value.totalBytes == null
                  ? '${_bytes(value.receivedBytes)} received in this batch'
                  : '${_bytes(value.receivedBytes)} / ${_bytes(value.totalBytes!)} in this batch',
            ),
          if (value.downloaded > 0 ||
              value.uploaded > 0 ||
              value.stage == SyncStage.downloading ||
              value.stage == SyncStage.uploading)
            Text(
              '${value.downloaded} records received · ${value.uploaded} changes uploaded',
            ),
          if (value.active)
            const Text('Keep this app open until this finishes.'),
        ],
      ),
    );
  }
}
