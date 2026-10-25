import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform, listEquals;

import '../app_state.dart';
import '../models.dart';
import '../services/export_file_reader.dart';
import '../services/discord_archive.dart';
import '../services/export_watch_service.dart';
import '../services/source_links.dart';
import '../widgets/browser_extension_section.dart';
import '../widgets/imap_import_panel.dart';
import '../widgets/document_import_panel.dart';
import '../widgets/paperless_import_panel.dart';
import '../widgets/participant_picker.dart';
import '../widgets/camera_photos_panel.dart';
import '../widgets/viewing_history_panel.dart';
import '../widgets/discord_bot_import_panel.dart';
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
  final _participantIds = ValueNotifier<List<String>>([]);
  final _manualError = ValueNotifier<String?>(null);
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _fileController = TextEditingController();
  final TextEditingController _mimeController = TextEditingController();
  final TextEditingController _metadataController = TextEditingController(
    text: '{}',
  );

  String _query = '';
  bool _watchExport = false;
  bool _dragging = false;
  bool Function() _setupHasDraft = () => false;
  String get _ownDiscordId {
    final email = widget.state.rememberedEmail.toLowerCase();
    for (final person in widget.state.participants) {
      if (!person.identifiers.contains('email:$email')) continue;
      for (final id in person.identifiers) {
        if (id.startsWith('discord:')) return id.substring(8);
      }
    }
    return '';
  }

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
    _participantIds.dispose();
    _manualError.dispose();
    _textController.dispose();
    _fileController.dispose();
    _mimeController.dispose();
    _metadataController.dispose();
    super.dispose();
  }

  static const _adapters = [
    (
      id: 'email',
      title: 'Email (IMAP)',
      description: 'Connect a mailbox with an email app password.',
      steps: [
        'Enable IMAP for your email account and create an app password.',
        'Check the configured server below, then enter your address and mailbox.',
        'Connect and import; choose whether to remember this account.',
      ],
    ),
    (
      id: 'discord-export',
      title: 'Discord data package',
      description:
          'Read a Discord account export locally, with optional file watching.',
      steps: [
        'Request your Discord data package in its privacy settings and download the ZIP.',
        'Choose the ZIP below. Messages merge by ID; identical backups are skipped.',
        'Optionally watch the file and replace it with a newer export later.',
      ],
    ),
    (
      id: 'discord-bot',
      title: 'Discord bot',
      description: 'Read selected server channels with your own bot.',
      steps: [
        'Create a Discord bot and give it access to the channels you want to import.',
        'Enable Message Content Intent and copy the bot token and channel IDs.',
        'Enter the details below and connect.',
      ],
    ),
    (
      id: 'documents',
      title: 'Documents & scans',
      description: 'Import PDFs and scans, or watch a folder.',
      steps: [
        'Choose a PDF or scan using the file picker below.',
        'For automatic imports, select a folder below.',
      ],
    ),
    (
      id: 'paperless',
      title: 'Paperless',
      description: 'Connect Paperless to import and search document text.',
      steps: <String>[],
    ),
    (
      id: 'photos',
      title: 'Camera photos',
      description: 'Import camera photos and the text visible in them.',
      steps: [
        'Grant access to your photos or choose a camera folder.',
        'Choose whether to keep original photos in the vault.',
        'Import recent photos or turn on automatic imports below.',
      ],
    ),
    (
      id: 'history',
      title: 'Browser & watch history files',
      description:
          'Import YouTube / TikTok exports or watch local browser history.',
      steps: [
        'For YouTube, export watch history with Google Takeout.',
        'For TikTok, request Download your data and choose JSON or browsing-history text.',
        'Choose your export below, or configure a local browser history file.',
      ],
    ),
    (
      id: 'audio',
      title: 'Audio recording',
      description: 'Transcribe an existing audio file.',
      steps: [
        'Choose an MP3, M4A, WAV, OGG, Opus, FLAC, AAC or WebM recording.',
        'Optionally add a title, participants, language and recording date.',
        'Import the recording; transcription can take a few minutes.',
      ],
    ),
    (
      id: 'manual',
      title: 'Other source / pasted export',
      description: 'Choose an adapter explicitly or paste an export payload.',
      steps: [
        'Enter the source adapter name for your export.',
        'Choose a file or paste its text below.',
        'Add a title or participants if needed, then import.',
      ],
    ),
  ];
  static const _extensions = [
    (
      id: 'youtube',
      title: 'YouTube',
      description: 'Watch history from your signed-in YouTube account.',
    ),
    (
      id: 'tiktok',
      title: 'TikTok',
      description: 'Watch history from your signed-in TikTok account.',
    ),
    (
      id: 'whatsapp',
      title: 'WhatsApp Web',
      description: 'New messages rendered in your open conversations.',
    ),
    (
      id: 'discord',
      title: 'Discord Web',
      description: 'New messages rendered in your open conversations.',
    ),
  ];

  bool _matches(String text) => text.toLowerCase().contains(_query);

  @override
  Widget build(BuildContext context) {
    final adapters = _adapters
        .where((a) => _matches('${a.title} ${a.description} ${a.id}'))
        .toList();
    final capabilities = widget.state.importCapabilities
        .where(
          (a) =>
              !const {
                'email',
                'paperless',
                'photo',
                'audio',
                'scanned-pdf',
                'discord',
              }.contains(a.source) &&
              _matches('${a.displayName} ${a.source} ${a.status}'),
        )
        .toList();
    final extensions = _extensions
        .where((a) => _matches('${a.title} ${a.description} browser extension'))
        .toList();
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
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Start with a file',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Choose or drop an export, backup, PDF or scan. Lifenizer detects the source automatically.',
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      key: const Key('imports-auto-file'),
                      onPressed: widget.state.busy ? null : () => _pickExport(),
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Choose backup or export'),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Discord data packages are read locally. Other configured importers process plaintext on your server. Results are encrypted before sync.',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              key: const Key('imports-search'),
              decoration: const InputDecoration(
                labelText: 'Find an importer',
                hintText: 'Search an app, file type or connection',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
            ),
            const SizedBox(height: 16),
            if (adapters.isNotEmpty || capabilities.isNotEmpty) ...[
              Text(
                'Files & connections',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              for (final adapter in adapters)
                _adapterCard(
                  adapter.id,
                  adapter.title,
                  adapter.description,
                  () => _openAdapter(
                    adapter.title,
                    adapter.steps,
                    () => _panel(adapter.id),
                  ),
                ),
              for (final capability in capabilities)
                _adapterCard(
                  'source-${capability.source}',
                  capability.displayName,
                  'Export file • ${capability.availableNow ? 'Ready to import' : 'Currently unavailable'}',
                  () {
                    _sourceController.text = capability.source;
                    _openAdapter(
                      capability.displayName,
                      [
                        _exportStep(capability.source, capability.displayName),
                        if (capability.acceptedFormats.isNotEmpty)
                          'Supported formats: ${capability.acceptedFormats.join(', ')}.',
                        'Choose the export below. The adapter is already selected.',
                      ],
                      () => Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            capability.availableNow
                                ? 'Import an existing export file, or paste its text below.'
                                : capability.status,
                          ),
                          _manualImport(),
                        ],
                      ),
                    );
                  },
                ),
            ],
            if (extensions.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'Browser extension',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Text(
                'Install the Lifenizer extension on this computer, then choose what it may import.',
              ),
              const SizedBox(height: 8),
              for (final extension in extensions)
                _adapterCard(
                  'extension-${extension.id}',
                  extension.title,
                  'Extension required • ${extension.description}',
                  () => _openExtension(extension.id, extension.title),
                ),
            ],
            if (adapters.isEmpty && capabilities.isEmpty && extensions.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  'No importers match. Try another app name or file type.',
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _exportStep(String source, String title) => switch (source) {
    'whatsapp' =>
      'In WhatsApp, export the conversation as text or a ZIP. Use an export without media for a smaller file.',
    'telegram' =>
      'Export your data with Telegram Desktop and choose the machine-readable JSON format.',
    'slack' =>
      'Get a JSON workspace export from your Slack workspace administrator.',
    'facebook-messenger' || 'instagram' =>
      'Download your messages from Meta Accounts Center and choose JSON.',
    'youtube-watch-history' =>
      'Use Google Takeout to export YouTube watch history as JSON or HTML.',
    'tiktok-watch-history' =>
      'In TikTok, request Download your data as JSON or browsing-history text.',
    'mbox' => 'Export a mailbox as an MBOX file from your email application.',
    'bookmarks' =>
      'Export bookmarks from your browser as an HTML or JSON file.',
    'lifenizer-backup' => 'Choose a previously exported Lifenizer backup.',
    'signal' =>
      'Prepare a Signal-compatible CSV, JSON or text transcript. Encrypted Signal backup files are not supported.',
    _ => 'Prepare a supported export file for $title.',
  };

  Widget _adapterCard(
    String id,
    String title,
    String description,
    VoidCallback open,
  ) => Card(
    child: ListTile(
      key: Key('import-adapter-$id'),
      title: Text(title),
      subtitle: Text(description, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
      onTap: open,
    ),
  );

  void _openAdapter(String title, List<String> steps, Widget Function() panel) {
    _setupHasDraft = () => false;
    var closing = false;
    Future<void> close(BuildContext context) async {
      if (closing) return;
      closing = true;
      final discard =
          !_setupHasDraft() ||
          await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Discard setup changes?'),
                  content: const Text(
                    'Your unsaved setup details will be lost.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Keep editing'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('Discard changes'),
                    ),
                  ],
                ),
              ) ==
              true;
      closing = false;
      if (discard && context.mounted) Navigator.of(context).pop();
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: false,
      enableDrag: false,
      builder: (context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) close(context);
        },
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .9,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close setup',
                      onPressed: () => close(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    8,
                    16,
                    24 + MediaQuery.viewInsetsOf(context).bottom,
                  ),
                  child: AnimatedBuilder(
                    animation: widget.state,
                    builder: (context, _) => Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < steps.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text('${i + 1}. ${steps[i]}'),
                          ),
                        const SizedBox(height: 12),
                        panel(),
                        if (widget.state.error != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            widget.state.error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ).whenComplete(() => _setupHasDraft = () => false);
  }

  void _registerDraftCheck(bool Function() check) => _setupHasDraft = check;

  Widget _panel(String id) => switch (id) {
    'email' => ImapImportPanel(
      state: widget.state,
      registerDraftCheck: _registerDraftCheck,
    ),
    'discord-export' => Column(
      children: [
        _discordExportOptions(),
        FilledButton.icon(
          onPressed: widget.state.busy ? null : () => _pickExport(),
          icon: const Icon(Icons.file_open),
          label: const Text('Choose Discord data package'),
        ),
      ],
    ),
    'discord-bot' => DiscordBotImportPanel(
      service: widget.state.discordImport,
      ownUserId: _ownDiscordId,
      registerDraftCheck: _registerDraftCheck,
    ),
    'documents' => DocumentImportPanel(
      state: widget.state,
      onPickFile: () => _pickExport(),
    ),
    'paperless' => PaperlessImportPanel(
      state: widget.state,
      registerDraftCheck: _registerDraftCheck,
    ),
    'photos' => CameraPhotosPanel(state: widget.state),
    'history' => ViewingHistoryPanel(state: widget.state),
    'audio' => _AudioImportPanel(
      state: widget.state,
      registerDraftCheck: _registerDraftCheck,
    ),
    _ => _manualImport(showSource: true),
  };

  void _openExtension(String platform, String title) => _openAdapter(
    '$title extension setup',
    [
      if (!_desktop)
        'Continue on a computer running the Lifenizer desktop app. Browser and mobile apps cannot accept the extension connection.',
      'Download the browser extension from lifenizer.coflnet.com. In desktop Chrome / Edge, extract its ZIP, open Extensions, enable Developer mode and choose Load unpacked. In Firefox 140+, open about:debugging → This Firefox → Load Temporary Add-on and select its ZIP. Temporary Firefox installs disappear after restart.',
      '${_desktop ? 'Choose Connect browser below' : 'On a computer, open the Lifenizer website and choose Connect browser'}. Confirm the connection in the desktop app. You can also choose Show QR code here and Scan QR code in the extension. No port or token copying is needed. Keep the desktop app open and its vault unlocked.',
      if (platform == 'youtube' || platform == 'tiktok')
        'In extension Settings, set the expected $title account ID or @handle, then Save. Sign in to that account in your desktop browser. In the extension popup, choose $title and Sync now. Use Retry delivery to resend queued imports after unlocking or reopening the desktop app.'
      else
        'In extension Settings, enable $title capture, then Save. Reload existing browser tabs after installing the extension. Open a signed-in conversation; only newly rendered messages are captured. Existing history is not imported. Use Retry delivery to resend queued messages after unlocking or reopening the desktop app.',
    ],
    () => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextButton.icon(
          onPressed: () async {
            final opened = await openExternalLink(
              'https://lifenizer.coflnet.com/extension',
            );
            if (!opened && mounted) {
              widget.state.reportError(
                'Could not open the download page. Check your browser and try again.',
              );
            }
          },
          icon: const Icon(Icons.open_in_new),
          label: const Text('Get browser extension'),
        ),
        if (!_desktop)
          const Text(
            'The browser extension connects to the desktop app on the same computer.',
          ),
        BrowserExtensionSection(
          service: widget.state.browserExtension,
          signedIn: widget.state.isAuthenticated,
        ),
      ],
    ),
  );

  Widget _discordExportOptions() => StatefulBuilder(
    builder: (context, update) => Column(
      children: [
        if (_desktop)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _watchExport,
            onChanged: widget.state.busy
                ? null
                : (value) => update(() => _watchExport = value ?? false),
            title: const Text('Watch this Discord export for changes'),
            subtitle: const Text(
              'Import again when you replace the ZIP, while the app is open and unlocked.',
            ),
          ),
        ListenableBuilder(
          listenable: ExportWatchService.instance,
          builder: (context, _) {
            final path = ExportWatchService.instance.path;
            return path == null
                ? const SizedBox.shrink()
                : ListTile(
                    title: const Text('Watching Discord export'),
                    subtitle: Text(path),
                    trailing: TextButton(
                      onPressed: ExportWatchService.instance.stopWatching,
                      child: const Text('Stop'),
                    ),
                  );
          },
        ),
      ],
    ),
  );

  Widget _manualImport({bool showSource = false}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (showSource)
        TextField(
          controller: _sourceController,
          decoration: const InputDecoration(labelText: 'Source adapter'),
        ),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: widget.state.busy
            ? null
            : () => _pickExport(useSource: true),
        icon: const Icon(Icons.file_open),
        label: const Text('Choose file for this source'),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _titleController,
        decoration: const InputDecoration(labelText: 'Title (optional)'),
      ),
      ValueListenableBuilder<List<String>>(
        valueListenable: _participantIds,
        builder: (context, ids, _) => ParticipantPicker(
          state: widget.state,
          controller: _participantsController,
          selectedIds: ids,
          onChanged: (ids) => _participantIds.value = ids,
          enabled: !widget.state.busy,
          decoration: const InputDecoration(
            labelText: 'Participants (optional)',
          ),
        ),
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
      ExpansionTile(
        title: const Text('Advanced import settings'),
        children: [
          TextField(
            controller: _fileController,
            decoration: const InputDecoration(labelText: 'Original file'),
          ),
          TextField(
            controller: _mimeController,
            decoration: const InputDecoration(labelText: 'MIME type'),
          ),
          TextField(
            controller: _metadataController,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Provider metadata JSON',
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: widget.state.busy ? null : _runImport,
        icon: const Icon(Icons.input),
        label: const Text('Send import and encrypt result'),
      ),
      ValueListenableBuilder<String?>(
        valueListenable: _manualError,
        builder: (context, error, _) => error == null
            ? const SizedBox.shrink()
            : Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
      ),
    ],
  );

  Future<void> _runImport() async {
    _manualError.value = null;
    late final Map<String, dynamic> decoded;
    try {
      final value = _metadataController.text.trim().isEmpty
          ? <String, dynamic>{}
          : jsonDecode(_metadataController.text);
      if (value is! Map<String, dynamic>) throw const FormatException();
      decoded = value;
    } on FormatException {
      _manualError.value =
          'Provider metadata must be a JSON object, for example {}. Correct it and retry.';
      return;
    }
    final metadata = decoded.map((key, value) => MapEntry(key, '$value'));
    await widget.state.importSource(
      source: _sourceController.text.trim(),
      title: _titleController.text,
      participantNames: _participantsController.text,
      participantIds: _participantIds.value,
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
    final identity = widget.state.recordingIdentity;
    if (identity == null) return;
    try {
      final result = await FilePicker.pickFiles(
        withData: false,
        withReadStream: true,
      );
      final file = result?.files.single;
      if (file == null) return;
      await _importExport(file, identity: identity, useSource: useSource);
    } catch (exception) {
      if (mounted && widget.state.recordingIdentity == identity) {
        widget.state.reportError('Could not import this file: $exception');
      }
    }
  }

  bool _canImport(String identity) {
    if (!mounted || widget.state.recordingIdentity != identity) return false;
    if (widget.state.busy) {
      widget.state.reportError(
        'Wait for the current operation, then select the file again.',
      );
      return false;
    }
    return true;
  }

  Future<void> _importExport(
    PlatformFile file, {
    required String identity,
    bool useSource = false,
  }) async {
    if (!_canImport(identity)) return;
    if (file.name.toLowerCase().endsWith('.lfb')) {
      throw const FormatException(
        'Open Sync → Restore backup and select all .lfb parts together.',
      );
    }
    if (!useSource &&
        _desktop &&
        file.path != null &&
        RegExp(
          r'\.(pdf|png|jpe?g|webp|heic|heif)$',
          caseSensitive: false,
        ).hasMatch(file.name)) {
      await widget.state.importDocumentFile(file.path!);
      return;
    }
    if ((!useSource ||
            _sourceController.text.trim().toLowerCase() == 'discord') &&
        !kIsWeb &&
        file.path != null &&
        file.name.toLowerCase().endsWith('.zip') &&
        await isDiscordArchive(file.path!)) {
      if (!_canImport(identity)) return;
      if (_desktop && _watchExport) {
        await ExportWatchService.instance.watch(file.path!);
      } else {
        await widget.state.importDiscordArchive(file.path!);
      }
      return;
    }
    final bytes = await readExportBytes(file);
    if (!_canImport(identity)) return;
    if (useSource) {
      await widget.state.importSource(
        source: _sourceController.text.trim(),
        title: _titleController.text,
        participantNames: _participantsController.text,
        participantIds: _participantIds.value,
        originalFileName: file.name,
        payloadBase64: base64Encode(bytes),
      );
    } else {
      await widget.state.importSharedPayload(fileName: file.name, bytes: bytes);
    }
  }

  Future<void> _dropExports(DropDoneDetails details) async {
    setState(() => _dragging = false);
    final identity = widget.state.recordingIdentity;
    if (identity == null) return;
    try {
      for (final item in details.files) {
        if (!_canImport(identity)) return;
        if (item is DropItemDirectory) {
          await widget.state.documentImport.folders.addFolder(item.path);
          continue;
        }
        await _importExport(
          PlatformFile(
            name: item.name,
            size: await item.length(),
            path: item.path,
            readStream: item.openRead(),
          ),
          identity: identity,
        );
        if (widget.state.error != null) break;
      }
    } catch (exception) {
      if (mounted && widget.state.recordingIdentity == identity) {
        widget.state.reportError('Could not import this file: $exception');
      }
    }
  }
}

/// Panel for importing a real audio recording for server-side transcription.
///
/// Reads an audio file (mp3/m4a/wav/ogg/opus/flac/aac/webm) as a bounded
/// stream on native and web, then hands the bytes to
/// [LifenizerAppState.importAudioBytes]. That call can take several minutes
/// (transcription runs server-side on CPU); progress is surfaced through the
/// app-wide busy indicator and status/error banner (see VaultShell), same as
/// every other import.
class _AudioImportPanel extends StatefulWidget {
  const _AudioImportPanel({required this.state, this.registerDraftCheck});

  final LifenizerAppState state;
  final ValueChanged<bool Function()>? registerDraftCheck;

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
  List<String> _participantIds = [];
  final TextEditingController _languageController = TextEditingController();
  String? _pickError;
  DateTime? _recordedAt;
  late List<Object?> _savedDraft;
  List<Object?> get _draft => [
    _titleController.text,
    _participantsController.text,
    _languageController.text,
    _recordedAt,
    ..._participantIds,
  ];

  @override
  void initState() {
    super.initState();
    _savedDraft = _draft;
    widget.registerDraftCheck?.call(() => !listEquals(_draft, _savedDraft));
  }

  @override
  void dispose() {
    _titleController.dispose();
    _participantsController.dispose();
    _languageController.dispose();
    super.dispose();
  }

  Future<void> _pickAndImport() async {
    final identity = widget.state.recordingIdentity;
    if (identity == null) return;
    setState(() => _pickError = null);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: _allowedExtensions,
        withData: false,
        withReadStream: true,
      );
      final file = result?.files.single;
      if (file == null || !_canImport(identity)) return;
      final bytes = await readExportBytes(file, maxBytes: 128 * 1024 * 1024);
      if (!_canImport(identity)) return;
      final submittedDraft = _draft;
      await widget.state.importAudioBytes(
        bytes: bytes,
        fileName: file.name,
        title: _titleController.text,
        participantNames: _participantsController.text,
        participantIds: _participantIds,
        language: _languageController.text,
        recordedAt: _recordedAt,
      );
      if (mounted &&
          widget.state.recordingIdentity == identity &&
          widget.state.error == null) {
        _savedDraft = submittedDraft;
      }
    } catch (exception) {
      if (mounted && widget.state.recordingIdentity == identity) {
        setState(
          () => _pickError =
              'Could not import this recording. Choose the file again to retry: $exception',
        );
      }
    }
  }

  bool _canImport(String identity) {
    if (!mounted || widget.state.recordingIdentity != identity) return false;
    if (widget.state.busy) {
      setState(
        () => _pickError =
            'Wait for the current operation, then choose the recording again.',
      );
      return false;
    }
    return true;
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
              'Files can be up to 128 MiB. '
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
                  child: ParticipantPicker(
                    state: widget.state,
                    controller: _participantsController,
                    selectedIds: _participantIds,
                    onChanged: (ids) => setState(() => _participantIds = ids),
                    enabled: !widget.state.busy,
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
