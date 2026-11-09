import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/browser_history_watch_service.dart';

/// "Keep updated from browser history" section of the Viewing history panel.
class BrowserHistorySection extends StatefulWidget {
  const BrowserHistorySection({
    required this.service,
    required this.signedIn,
    super.key,
  });
  final BrowserHistoryWatchService service;
  final bool signedIn;

  @override
  State<BrowserHistorySection> createState() => _BrowserHistorySectionState();
}

class _BrowserHistorySectionState extends State<BrowserHistorySection> {
  String? _localError;
  bool _backfill = false;

  static const _intervals = <int, String>{
    15: '15 minutes',
    60: '1 hour',
    360: '6 hours',
    1440: '24 hours',
  };

  BrowserHistoryWatchService get _service => widget.service;

  Future<void> _guard(Future<void> Function() action) async {
    setState(() => _localError = null);
    try {
      await action();
    } catch (exception) {
      if (mounted) setState(() => _localError = '$exception');
    }
  }

  Future<void> _pickFile() => _guard(() async {
    final result = await FilePicker.pickFiles(withData: false);
    final path = result?.files.single.path;
    if (path == null) return;
    await _service.addProfileFile(path);
  });

  String _intervalLabel(Duration d) =>
      _intervals[d.inMinutes] ?? '${d.inMinutes} minutes';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      key: const Key('browser-history-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 28),
        Text(
          'Keep updated from browser history',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        if (!_service.supported)
          Text(
            'Available in the desktop app (Linux, macOS, Windows). Android, '
            'iOS and the web cannot read browser history, and YouTube or '
            'TikTok videos watched in their phone apps cannot be read at all. '
            'Re-import a Takeout or TikTok export to add them.',
            key: const Key('browser-history-unsupported'),
            style: muted,
          )
        else ...[
          Text(
            'YouTube and TikTok offer no watch-history API, so after the first '
            'export import, new views are read from the history database of '
            'the browsers you select. Videos watched in phone apps are not '
            'included.',
            style: muted,
          ),
          const SizedBox(height: 8),
          if (_service.profiles.isEmpty)
            const Text(
              'No browser profiles found. Choose a history file below.',
            ),
          for (final profile in _service.profiles)
            CheckboxListTile(
              key: Key('browser-profile-${profile.path}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _service.selected.contains(profile.path),
              title: Text(profile.label),
              subtitle: Text(profile.path, style: muted),
              onChanged: widget.signedIn
                  ? (value) => _guard(
                      () => _service.setProfileSelected(
                        profile.path,
                        value ?? false,
                        backfillDays: _backfill ? 30 : 0,
                      ),
                    )
                  : null,
            ),
          CheckboxListTile(
            key: const Key('browser-history-backfill'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _backfill,
            title: const Text(
              'Also import the last 30 days of newly selected profiles',
            ),
            onChanged: (value) => setState(() => _backfill = value ?? false),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                key: const Key('browser-history-pick-file'),
                onPressed: widget.signedIn ? _pickFile : null,
                icon: const Icon(Icons.folder_open),
                label: const Text('Choose history file'),
              ),
              OutlinedButton.icon(
                key: const Key('browser-history-refresh'),
                onPressed: _service.refreshProfiles,
                icon: const Icon(Icons.refresh),
                label: const Text('Find profiles'),
              ),
              const Text('Check every'),
              DropdownButton<int>(
                key: const Key('browser-history-interval'),
                value: _intervals.containsKey(_service.interval.inMinutes)
                    ? _service.interval.inMinutes
                    : null,
                hint: Text(_intervalLabel(_service.interval)),
                items: [
                  for (final e in _intervals.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (value) => value == null
                    ? null
                    : _guard(
                        () => _service.setInterval(Duration(minutes: value)),
                      ),
              ),
            ],
          ),
          SwitchListTile(
            key: const Key('browser-history-enabled'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Keep viewing history updated from this browser'),
            value: _service.enabled,
            onChanged: widget.signedIn && _service.selected.isNotEmpty
                ? (value) => _guard(() => _service.setEnabled(value))
                : null,
          ),
          SwitchListTile(
            key: const Key('browser-history-auto-transcripts'),
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Fetch transcripts for new videos automatically '
              '(max ${_service.transcriptsPerDay} per day)',
            ),
            subtitle: Text(
              'Today: ${_service.transcriptsToday} of ${_service.transcriptsPerDay}',
              style: muted,
            ),
            value: _service.autoTranscripts,
            onChanged: widget.signedIn
                ? (value) => _guard(() => _service.setAutoTranscripts(value))
                : null,
          ),
          if (_service.working) const LinearProgressIndicator(),
          if (_service.status != null)
            Text(_service.status!, key: const Key('browser-history-status')),
          if (_service.lastCheck != null)
            Text(
              'Last check ${_service.lastCheck!.toLocal().toString().split('.').first} · '
              '${_service.visitsFound} visit(s) found · '
              '${_service.videosImported} video(s) imported',
              key: const Key('browser-history-counters'),
              style: muted,
            ),
          for (final message in [?_service.error, ?_localError])
            Text(
              message,
              key: const Key('browser-history-error'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          const SizedBox(height: 4),
          Text(
            'Privacy: only YouTube and TikTok video links, titles and visit '
            'times are read from the browser database (a temporary copy that '
            'is deleted afterwards). Nothing else is read or uploaded.',
            style: muted,
          ),
        ],
      ],
    );
  }
}
