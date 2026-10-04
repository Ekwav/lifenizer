import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show kDebugMode, kIsWeb, defaultTargetPlatform, TargetPlatform;

import '../app_state.dart';
import '../models.dart';
import '../services/export_file_reader.dart';
import '../services/discord_archive.dart';
import '../services/export_watch_service.dart';
import 'page_frame.dart';

class ImportsPage extends StatefulWidget {
  const ImportsPage({required this.state, super.key});

  final LifenizerAppState state;

  @override
  State<ImportsPage> createState() => _ImportsPageState();
}

class _ImportsPageState extends State<ImportsPage> {
  final TextEditingController _sourceController = TextEditingController(
    text: 'whatsapp',
  );
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _participantsController = TextEditingController();
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _fileController = TextEditingController();
  final TextEditingController _mimeController = TextEditingController();
  final TextEditingController _metadataController = TextEditingController(
    text: '{}',
  );

  bool _watchExport = false;
  bool _dragging = false;
  bool get _desktop =>
      !kIsWeb &&
      const [
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      ].contains(defaultTargetPlatform);

  @override
  void dispose() {
    _sourceController.dispose();
    _titleController.dispose();
    _participantsController.dispose();
    _textController.dispose();
    _fileController.dispose();
    _mimeController.dispose();
    _metadataController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      enable:
          _desktop &&
          widget.state.isAuthenticated &&
          !widget.state.busy &&
          (ModalRoute.of(context)?.isCurrent ?? true),
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: _dropExports,
      child: PageFrame(
        title: 'Imports',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: _dragging
                  ? Theme.of(context).colorScheme.secondaryContainer
                  : null,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Import an export',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Discord data packages are read locally. Other configured importers process plaintext on your server. Results are encrypted before sync.',
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: widget.state.busy ? null : () => _pickExport(),
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Choose backup or export'),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Drop files here or choose a Discord data ZIP, Telegram JSON, WhatsApp text/ZIP, or Lifenizer JSON export. Discord updates merge by message ID; identical backups are skipped. For other formats, choose a source below.',
                    ),
                    if (_desktop) ...[
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _watchExport,
                        onChanged: widget.state.busy
                            ? null
                            : (value) =>
                                  setState(() => _watchExport = value ?? false),
                        title: const Text(
                          'Watch this Discord export for changes',
                        ),
                        subtitle: const Text(
                          'Import again when you replace the ZIP with a newer export, while the app is open and unlocked.',
                        ),
                      ),
                      ListenableBuilder(
                        listenable: ExportWatchService.instance,
                        builder: (context, _) {
                          final path = ExportWatchService.instance.path;
                          return path == null
                              ? const SizedBox.shrink()
                              : ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('Watching Discord export'),
                                  subtitle: Text(path),
                                  trailing: TextButton(
                                    onPressed: () => ExportWatchService.instance
                                        .stopWatching(),
                                    child: const Text('Stop'),
                                  ),
                                );
                        },
                      ),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        SizedBox(
                          width: 220,
                          child: TextField(
                            controller: _sourceController,
                            decoration: const InputDecoration(
                              labelText: 'Source',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 300,
                          child: TextField(
                            controller: _titleController,
                            decoration: const InputDecoration(
                              labelText: 'Title',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 300,
                          child: TextField(
                            controller: _participantsController,
                            decoration: const InputDecoration(
                              labelText: 'Participants',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 240,
                          child: TextField(
                            controller: _fileController,
                            decoration: const InputDecoration(
                              labelText: 'Original file',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 220,
                          child: TextField(
                            controller: _mimeController,
                            decoration: const InputDecoration(
                              labelText: 'MIME type',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _textController,
                      minLines: 5,
                      maxLines: 9,
                      decoration: const InputDecoration(
                        labelText: 'Text or export payload',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _metadataController,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Provider metadata JSON',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: widget.state.busy ? null : _runImport,
                          icon: const Icon(Icons.input),
                          label: const Text('Send import and encrypt result'),
                        ),
                        OutlinedButton.icon(
                          onPressed: widget.state.busy
                              ? null
                              : () => _pickExport(useSource: true),
                          icon: const Icon(Icons.file_open),
                          label: const Text('Choose file for this source'),
                        ),
                        if (kDebugMode)
                          for (final source in const [
                            'whatsapp',
                            'telegram',
                            'signal',
                            'slack',
                            'teams',
                            'facebook-messenger',
                            'instagram',
                            'imessage',
                            'mbox',
                            'git',
                            'browser-capture',
                            'google-search-history',
                            'bookmarks',
                            'lifenizer-backup',
                            'browser-history',
                            'youtube-transcript',
                            'audio',
                            'scanned-pdf',
                          ])
                            OutlinedButton(
                              onPressed: widget.state.busy
                                  ? null
                                  : () => widget.state.importSample(source),
                              child: Text(source),
                            ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            _AudioImportPanel(state: widget.state),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final capability in widget.state.importCapabilities)
                  SizedBox(
                    width: 340,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  capability.availableNow
                                      ? Icons.check_circle_outline
                                      : Icons.pending_outlined,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    capability.displayName,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(capability.source),
                            const SizedBox(height: 8),
                            Text(capability.status),
                            const SizedBox(height: 8),
                            Text(
                              capability.requiresCredentials
                                  ? 'Requires provider credentials'
                                  : 'No provider credentials required',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            if (capability.acceptedFormats.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (final format
                                      in capability.acceptedFormats)
                                    Chip(
                                      visualDensity: VisualDensity.compact,
                                      label: Text(format),
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _runImport() async {
    final decoded = _metadataController.text.trim().isEmpty
        ? <String, dynamic>{}
        : decodeJsonMap(_metadataController.text);
    final metadata = decoded.map((key, value) => MapEntry(key, '$value'));
    await widget.state.importSource(
      source: _sourceController.text.trim(),
      title: _titleController.text,
      participantNames: _participantsController.text,
      text: _textController.text,
      originalFileName: _fileController.text.trim().isEmpty
          ? null
          : _fileController.text.trim(),
      mimeType: _mimeController.text.trim().isEmpty
          ? null
          : _mimeController.text.trim(),
      metadata: metadata,
    );
  }

  Future<void> _pickExport({bool useSource = false}) async {
    try {
      final result = await FilePicker.pickFiles(
        withData: false,
        withReadStream: true,
      );
      final file = result?.files.single;
      if (file == null || !mounted) return;
      if (!widget.state.isAuthenticated || widget.state.busy) return;
      await _importExport(file, useSource: useSource);
    } catch (exception) {
      widget.state.reportError('Could not import this file: $exception');
    }
  }

  Future<void> _importExport(
    PlatformFile file, {
    bool useSource = false,
  }) async {
    if (!widget.state.isAuthenticated || widget.state.busy) return;
    if ((!useSource ||
            _sourceController.text.trim().toLowerCase() == 'discord') &&
        !kIsWeb &&
        file.path != null &&
        file.name.toLowerCase().endsWith('.zip') &&
        await isDiscordArchive(file.path!)) {
      if (!widget.state.isAuthenticated || widget.state.busy) return;
      if (_desktop && _watchExport) {
        await ExportWatchService.instance.watch(file.path!);
      } else {
        await widget.state.importDiscordArchive(file.path!);
      }
      return;
    }
    final bytes = await readExportBytes(file);
    if (!mounted) return;
    if (!widget.state.isAuthenticated || widget.state.busy) {
      widget.state.reportError('Unlock your vault before importing a file.');
      return;
    }
    if (useSource) {
      await widget.state.importSource(
        source: _sourceController.text.trim(),
        title: _titleController.text,
        participantNames: _participantsController.text,
        originalFileName: file.name,
        payloadBase64: base64Encode(bytes),
      );
    } else {
      await widget.state.importSharedPayload(fileName: file.name, bytes: bytes);
    }
  }

  Future<void> _dropExports(DropDoneDetails details) async {
    setState(() => _dragging = false);
    try {
      for (final item in details.files) {
        if (item is DropItemDirectory) {
          throw const FormatException(
            'Drop an export file, rather than a folder.',
          );
        }
        await _importExport(
          PlatformFile(
            name: item.name,
            size: await item.length(),
            path: item.path,
            readStream: item.openRead(),
          ),
        );
        if (widget.state.error != null) break;
      }
    } catch (exception) {
      widget.state.reportError('Could not import this file: $exception');
    }
  }
}

/// Panel for importing a real audio recording for server-side transcription.
///
/// Picks an audio file (mp3/m4a/wav/ogg/opus/flac/aac/webm) with bytes
/// resolved eagerly so it works on web, then hands the bytes to
/// [LifenizerAppState.importAudioBytes]. That call can take several minutes
/// (transcription runs server-side on CPU); progress is surfaced through the
/// app-wide busy indicator and status/error banner (see VaultShell), same as
/// every other import.
class _AudioImportPanel extends StatefulWidget {
  const _AudioImportPanel({required this.state});

  final LifenizerAppState state;

  @override
  State<_AudioImportPanel> createState() => _AudioImportPanelState();
}

class _AudioImportPanelState extends State<_AudioImportPanel> {
  static const _allowedExtensions = [
    'mp3',
    'm4a',
    'wav',
    'ogg',
    'opus',
    'flac',
    'aac',
    'webm',
  ];

  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _participantsController = TextEditingController();
  final TextEditingController _languageController = TextEditingController();
  String? _pickError;
  DateTime? _recordedAt;

  @override
  void dispose() {
    _titleController.dispose();
    _participantsController.dispose();
    _languageController.dispose();
    super.dispose();
  }

  Future<void> _pickAndImport() async {
    setState(() => _pickError = null);
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: _allowedExtensions,
      withData: true,
    );
    final file = result?.files.single;
    if (file == null) return;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      setState(
        () => _pickError = 'Could not read the selected file. Try again.',
      );
      return;
    }
    await widget.state.importAudioBytes(
      bytes: bytes,
      fileName: file.name,
      title: _titleController.text,
      participantNames: _participantsController.text,
      language: _languageController.text,
      recordedAt: _recordedAt,
    );
  }

  Future<void> _pickRecordedAt() async {
    final now = DateTime.now();
    final initialDate = _recordedAt ?? now;
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initialDate.isAfter(now) ? now : initialDate,
      firstDate: DateTime(2000),
      lastDate: now,
    );
    if (pickedDate == null || !mounted) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initialDate),
    );
    if (!mounted) return;

    setState(() {
      _recordedAt = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime?.hour ?? 0,
        pickedTime?.minute ?? 0,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Audio recording',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'Upload a real audio file to transcribe it on the server. '
              'This can take a few minutes for longer recordings.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: 260,
                  child: TextField(
                    controller: _titleController,
                    decoration: const InputDecoration(
                      labelText: 'Title (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                SizedBox(
                  width: 260,
                  child: TextField(
                    controller: _participantsController,
                    decoration: const InputDecoration(
                      labelText: 'Participants (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _languageController,
                    decoration: const InputDecoration(
                      labelText: 'Language code (optional, e.g. de)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              key: const Key('import-audio-recorded-at'),
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _pickRecordedAt,
                  icon: const Icon(Icons.event),
                  label: Text(
                    _recordedAt == null
                        ? 'Recorded on (optional)'
                        : 'Recorded on ${_recordedAt!.toCompactLocalString()}',
                  ),
                ),
                if (_recordedAt != null)
                  IconButton(
                    tooltip: 'Clear recorded-on date',
                    icon: const Icon(Icons.clear),
                    onPressed: () => setState(() => _recordedAt = null),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('import-audio-button'),
              onPressed: widget.state.busy ? null : _pickAndImport,
              icon: const Icon(Icons.graphic_eq),
              label: const Text('Import audio recording'),
            ),
            if (_pickError != null) ...[
              const SizedBox(height: 8),
              Text(
                _pickError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
