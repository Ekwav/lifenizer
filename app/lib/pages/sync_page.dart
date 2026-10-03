import 'package:flutter/material.dart';

import '../app_state.dart';
import '../image_widgets.dart';
import 'page_frame.dart';

class SyncPage extends StatelessWidget {
  const SyncPage({required this.state, super.key});

  final LifenizerAppState state;

  @override
  Widget build(BuildContext context) {
    final quota = state.quotaStatus;
    return PageFrame(
      title: 'Sync',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('User ${state.session?.userId ?? ''}'),
          Text('Vault ${state.session?.vaultId ?? ''}'),
          Text('Cursor ${state.syncCursor}'),
          const SizedBox(height: 20),
          // Storage indicator
          if (quota != null) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Storage · ${quota.plan}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(
                  '${quota.usedFormatted} / ${quota.limitFormatted}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (quota.usedPercent / 100).clamp(0.0, 1.0),
                minHeight: 8,
                color: quota.isOverLimit
                    ? Theme.of(context).colorScheme.error
                    : quota.isNearLimit
                    ? Colors.orange
                    : null,
              ),
            ),
            if (quota.plan == 'Free') ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.star_outline),
                label: const Text('Upgrade for more storage'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => UpgradeDialog(state: state),
                ),
              ),
            ],
            const SizedBox(height: 20),
          ],
          FilledButton.icon(
            onPressed: state.busy ? null : state.pullSync,
            icon: const Icon(Icons.sync),
            label: const Text('Pull sync'),
          ),
        ],
      ),
    );
  }
}
