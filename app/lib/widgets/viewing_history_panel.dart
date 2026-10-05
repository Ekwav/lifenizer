import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/export_file_reader.dart';
import '../services/transcript_enrichment.dart';

/// Imports panel for YouTube / TikTok watch history and transcript enrichment.
class ViewingHistoryPanel extends StatefulWidget {
  const ViewingHistoryPanel({required this.state, super.key});
  final LifenizerAppState state;

  @override
  State<ViewingHistoryPanel> createState() => _ViewingHistoryPanelState();
}

class _ViewingHistoryPanelState extends State<ViewingHistoryPanel> {
  String? _error;
  ImportSummary? _summary;
  TranscriptBatchProgress? _progress;
  TranscriptBatchCancel? _cancel;

  bool get _running => _cancel != null;

  Future<void> _pick() async {
    setState(() {
      _error = null;
      _summary = null;
    });
    try {
      final result = await FilePicker.pickFiles(
        withData: false,
        withReadStream: true,
        type: FileType.custom,
        allowedExtensions: const ['json', 'html', 'htm', 'txt', 'zip'],
      );
      final file = result?.files.single;
      if (file == null || !mounted) return;
      final bytes = await readExportBytes(file);
      if (!mounted) return;
      widget.state.lastImportSummary = null;
      await widget.state.importSharedPayload(fileName: file.name, bytes: bytes);
      if (!mounted) return;
      final summary = widget.state.lastImportSummary;
      setState(() {
        if (summary != null &&
            (summary.source == 'youtube-watch-history' ||
                summary.source == 'tiktok-watch-history')) {
          _summary = summary;
        } else if (widget.state.error == null) {
          _error =
              'This file was not recognised as a YouTube or TikTok watch history.';
        }
      });
    } catch (exception) {
      if (mounted) {
        setState(() => _error = 'Could not import this file: $exception');
      }
    }
  }

  Future<void> _fetchTranscripts() async {
    final cancel = TranscriptBatchCancel();
    setState(() {
      _cancel = cancel;
      _progress = null;
    });
    final result = await widget.state.enrichRecentWatchedVideos(
      cancel: cancel,
      onProgress: (progress) {
        if (mounted) setState(() => _progress = progress);
      },
    );
    if (!mounted) return;
    setState(() {
      _cancel = null;
      _progress = result;
    });
  }

  String _summaryText(ImportSummary summary) {
    final platform = summary.source.startsWith('tiktok') ? 'TikTok' : 'YouTube';
    final withoutLink = int.tryParse(
      summary.diagnostics['skippedWithoutVideoUrl'] ?? '',
    );
    return '$platform: ${summary.added} video(s) imported or updated · '
        '${summary.skipped} already present'
        '${withoutLink != null && withoutLink > 0 ? ' · $withoutLink entries without a video link skipped' : ''}';
  }

  String _progressText(TranscriptBatchProgress progress) {
    if (progress.waiting != null) {
      return '${progress.done}/${progress.total} · waiting '
          '${progress.waiting!.inSeconds}s for YouTube rate limit';
    }
    final base = '${progress.done}/${progress.total} · ${progress.summary}';
    if (progress.finished) {
      return '${progress.cancelled ? 'Cancelled. ' : 'Done. '}$base'
          '${progress.stopReason == null ? '' : '\n${progress.stopReason}'}';
    }
    return base;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.state,
    builder: (context, _) {
      final theme = Theme.of(context);
      final idle = widget.state.isAuthenticated && !widget.state.busy;
      final pending = widget.state.recentVideosNeedingTranscript().length;
      return Card(
        key: const Key('viewing-history-panel'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Viewing history', style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Watched videos are kept as "Consumed" media and rank below '
                'your own conversations in search.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'YouTube: Google Takeout, choose "YouTube and YouTube Music", '
                'select History, and export as JSON (HTML also works).',
              ),
              const Text(
                'TikTok: Settings, Download your data, choose JSON. Exports '
                'contain video links and times only.',
              ),
              const SizedBox(height: 8),
              const Text(
                'Choose the file or the whole ZIP; Lifenizer finds '
                'watch-history.json or the TikTok data file inside.',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const Key('viewing-history-pick'),
                    onPressed: idle ? _pick : null,
                    icon: const Icon(Icons.history),
                    label: const Text('Choose watch history'),
                  ),
                  if (!_running)
                    OutlinedButton.icon(
                      key: const Key('viewing-history-transcripts'),
                      onPressed: idle && pending > 0 ? _fetchTranscripts : null,
                      icon: const Icon(Icons.subtitles_outlined),
                      label: const Text(
                        'Fetch transcripts for the 25 most recent videos',
                      ),
                    )
                  else
                    OutlinedButton.icon(
                      key: const Key('viewing-history-cancel'),
                      onPressed: () => _cancel?.cancel(),
                      icon: const Icon(Icons.stop),
                      label: const Text('Cancel'),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'YouTube transcripts are public captions fetched by your '
                'server (about one per few seconds; YouTube may rate limit). '
                'TikTok videos have no transcript: that would need a video '
                'download and speech/OCR pipeline.',
                style: theme.textTheme.bodySmall,
              ),
              if (_running) const LinearProgressIndicator(),
              if (_progress != null) Text(_progressText(_progress!)),
              if (_summary != null)
                Text(
                  _summaryText(_summary!),
                  key: const Key('viewing-history-summary'),
                ),
              if (_error != null)
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ),
        ),
      );
    },
  );
}
