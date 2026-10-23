import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/backup_archive.dart';
import '../services/backup_files.dart';

Future<void> showBackupDialog(
  BuildContext context,
  LifenizerAppState state, {
  bool restore = false,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _BackupDialog(state: state, restore: restore),
);

class _BackupDialog extends StatefulWidget {
  const _BackupDialog({required this.state, required this.restore});
  final LifenizerAppState state;
  final bool restore;

  @override
  State<_BackupDialog> createState() => _BackupDialogState();
}

class _BackupDialogState extends State<_BackupDialog> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _includeMedia = true;
  bool _working = false;
  bool _cancelled = false;
  bool _done = false;
  String? _error;
  String? _progress;

  @override
  void dispose() {
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final password = _password.text;
    if (password.isEmpty || (!widget.restore && password.length < 12)) {
      setState(
        () => _error = widget.restore
            ? 'Enter the backup password.'
            : 'Use a backup password of at least 12 characters.',
      );
      return;
    }
    if (!widget.restore && password != _confirmation.text) {
      setState(() => _error = 'The backup passwords do not match.');
      return;
    }
    setState(() {
      _working = true;
      _cancelled = false;
      _error = null;
      _progress = widget.restore
          ? 'Choose all backup parts…'
          : 'Choose a folder…';
    });
    BackupTarget? target;
    try {
      if (widget.restore) {
        final parts = await pickBackupParts();
        if (parts.isEmpty) return;
        final added = await widget.state.restoreBackup(
          parts: parts,
          password: password,
          onProgress: (message) {
            if (mounted) setState(() => _progress = message);
          },
        );
        _progress =
            'Restore finished. Added $added library items and restored '
            'included media. Existing library items were kept.';
      } else {
        target = await pickBackupTarget();
        if (target == null) return;
        final result = await widget.state.makeBackup(
          target: target,
          password: password,
          includeMedia: _includeMedia,
          cancelled: () => _cancelled,
          onProgress: (bytes, parts) {
            if (mounted) {
              setState(
                () => _progress =
                    '${(bytes / 1000000).toStringAsFixed(1)} MB written · $parts file(s)',
              );
            }
          },
        );
        _progress =
            '${_includeMedia ? 'Backup' : 'Library-only backup'} saved '
            'to ${target.label}. ${result.parts} file(s), '
            '${(result.bytes / 1000000).toStringAsFixed(1)} MB. '
            'You need all parts and this password to restore it.';
      }
      _password.clear();
      _confirmation.clear();
      _done = true;
    } catch (e) {
      _error = e.toString();
      // Also cleans up a selected target if a vault check failed before the
      // archive writer started. Targets support repeated abort calls.
      try {
        await target?.abort();
      } catch (_) {
        _error =
            '$_error Remove any incomplete backup files from the selected folder.';
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_working,
    child: AlertDialog(
      title: Text(widget.restore ? 'Restore backup' : 'Make backup'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!_done) ...[
                Text(
                  widget.restore
                      ? 'Select every .lfb part from one backup. All files are '
                            'checked before restoring missing items into this vault. '
                            'Current items with the same ID are kept. Included photos '
                            'are uploaded to your encrypted storage; recordings stay '
                            'on this device until you enable their online sync.'
                      : 'Choose a password and a destination folder. Files are '
                            'split automatically at 5 GB (5,000,000,000 bytes). '
                            'The backup password is separate from your device unlock '
                            'and cannot be recovered.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _password,
                  enabled: !_working,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Backup password',
                  ),
                ),
                if (!widget.restore) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _confirmation,
                    enabled: !_working,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Confirm backup password',
                    ),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Include recordings and uploaded photos'),
                    subtitle: const Text(
                      'Keep source devices and online storage reachable. '
                      'Uncheck for a library-only backup that works offline. '
                      'Pending recordings restore as saved recordings.',
                    ),
                    value: _includeMedia,
                    onChanged: _working
                        ? null
                        : (value) => setState(() => _includeMedia = value!),
                  ),
                ],
              ],
              if (_working) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
                const Text('Keep Lifenizer open until this finishes.'),
              ],
              if (_progress != null) ...[
                const SizedBox(height: 12),
                Text(_progress!),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (!_working)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(_done ? 'Done' : 'Close'),
          ),
        if (_working && !widget.restore)
          TextButton(
            onPressed: _cancelled
                ? null
                : () => setState(() {
                    _cancelled = true;
                    _progress = 'Cancelling and removing incomplete files…';
                  }),
            child: const Text('Cancel backup'),
          ),
        if (!_working && !_done)
          FilledButton(
            onPressed: _start,
            child: Text(
              widget.restore ? 'Choose backup files' : 'Choose folder',
            ),
          ),
      ],
    ),
  );
}
