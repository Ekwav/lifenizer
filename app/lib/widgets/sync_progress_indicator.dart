import 'package:flutter/material.dart';

import '../services/sync_progress.dart';

class SyncProgressIndicator extends StatelessWidget {
  const SyncProgressIndicator({required this.progress, super.key});

  final SyncProgress? progress;

  String _bytes(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(0)} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

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
          ],
          if (value.stage == SyncStage.downloading && value.receivedBytes > 0)
            Text(
              value.totalBytes == null
                  ? '${_bytes(value.receivedBytes)} received in this batch'
                  : '${_bytes(value.receivedBytes)} / ${_bytes(value.totalBytes!)} in this batch',
            ),
          Text(
            '${value.downloaded} records received · ${value.uploaded} changes uploaded',
          ),
          if (value.active)
            const Text('Keep this app open until the first sync finishes.'),
        ],
      ),
    );
  }
}
