import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_state.dart';
import '../models.dart';
import '../image_widgets.dart';
import 'page_frame.dart';

class SyncPage extends StatelessWidget {
  const SyncPage({required this.state, super.key});

  final LifenizerAppState state;

  @override
  Widget build(BuildContext context) {
    final quota = state.quotaStatus;
    final paired = state.pairing.matchesVault(
      state.apiBaseUrl,
      state.rememberedEmail,
    );
    return PageFrame(
      title: 'Sync',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${state.pendingSyncCount} change(s) waiting to sync'),
          Text(
            state.lastSyncedAt == null
                ? 'No sync this session'
                : 'Last synced ${state.lastSyncedAt!.toCompactLocalString()}',
          ),
          const SizedBox(height: 8),
          Text(
            paired
                ? 'Devices connected with your link share this encrypted vault. Changes sync automatically while the app is open.'
                : 'Use the same API URL, account and vault passphrase on your computer and phone. Changes sync automatically while the app is open.',
          ),
          if (paired) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: state.pairing.connectionLink == null
                  ? null
                  : () => _showPairingCode(context),
              icon: const Icon(Icons.qr_code),
              label: const Text('Add device'),
            ),
            const SizedBox(height: 8),
            Text(
              state.pairing.automaticApprovalActive
                  ? 'New devices with your connection link connect automatically until ${state.pairing.automaticApprovalUntil!.toLocal()}.'
                  : 'New devices need your approval. Compare the code on both devices.',
            ),
            for (final request in state.pairing.pending)
              ListTile(
                title: Text(request['deviceName'] as String),
                subtitle: Text(
                  'Verification code ${request['verificationCode']}',
                ),
                trailing: Wrap(
                  children: [
                    TextButton(
                      onPressed: state.busy
                          ? null
                          : () async {
                              try {
                                await state.pairing.deny(request);
                              } catch (_) {
                                state.reportError(
                                  'Could not deny this device. Try again.',
                                );
                              }
                            },
                      child: const Text('Deny'),
                    ),
                    FilledButton(
                      onPressed: state.busy
                          ? null
                          : () async {
                              try {
                                await state.pairing.approve(request);
                              } catch (_) {
                                state.reportError(
                                  'Could not approve this device. Try again.',
                                );
                              }
                            },
                      child: const Text('Approve'),
                    ),
                  ],
                ),
              ),
          ],
          if (state.pairing.error != null) Text(state.pairing.error!),
          if (state.syncError != null) Text(state.syncError!),
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
            label: const Text('Sync now'),
          ),
        ],
      ),
    );
  }

  Future<void> _showPairingCode(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final link = state.pairing.connectionLink;
        return AlertDialog(
          title: const Text('Add a device'),
          content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (link == null)
                    const Text('Unlock this vault to show its connection code.')
                  else ...[
                    const Text(
                      'Open Lifenizer on your phone and tap Scan connection QR.',
                    ),
                    const SizedBox(height: 12),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: QrImageView(
                        data: link,
                        size: 280,
                        backgroundColor: Colors.white,
                        semanticsLabel: 'Secure vault connection QR code',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      state.pairing.automaticApprovalActive
                          ? 'Automatic approval is available until ${state.pairing.automaticApprovalUntil!.toLocal()}. Keep this code private.'
                          : 'Keep this device unlocked. Compare the verification code on both devices, then approve the new device in Sync.',
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            if (link != null)
              OutlinedButton.icon(
                onPressed: () async {
                  final currentLink = state.pairing.connectionLink;
                  if (currentLink == null) return;
                  await Clipboard.setData(ClipboardData(text: currentLink));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Connection link copied')),
                  );
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy connection link'),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ],
        );
      },
    ),
  );
}
