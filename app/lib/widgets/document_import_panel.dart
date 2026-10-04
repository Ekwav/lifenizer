import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';

class DocumentImportPanel extends StatefulWidget {
  const DocumentImportPanel({required this.state, super.key});
  final LifenizerAppState state;
  @override
  State<DocumentImportPanel> createState() => _DocumentImportPanelState();
}

class _DocumentImportPanelState extends State<DocumentImportPanel> {
  final _token = TextEditingController();
  bool _remember = !kIsWeb;
  String? _error;
  Map<String, dynamic>? _settings;
  @override
  void initState() {
    super.initState();
    unawaited(_loadSettings());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.state.documentImport.start();
    });
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await widget.state.paperlessSettings();
      if (mounted) setState(() => _settings = settings);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not load the configured Paperless server.',
        );
      }
    }
  }

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final token = _token.text;
    _token.clear();
    await widget.state.documentImport.connect(
      token: token,
      remember: _remember,
    );
  }

  Future<void> _folder([String? path]) async {
    try {
      path ??= await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose a scans or PDF folder',
      );
      if (path == null || !mounted) return;
      setState(() => _error = null);
      await widget.state.documentImport.folders.addFolder(path);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not watch this folder. Choose an existing folder and unlock the desktop vault.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.state, widget.state.documentImport]),
    builder: (context, _) {
      final service = widget.state.documentImport;
      final folders = service.folders;
      final enabled =
          widget.state.isAuthenticated &&
          !widget.state.busy &&
          !service.working &&
          !folders.working;
      final desktop =
          !kIsWeb &&
          [
            TargetPlatform.linux,
            TargetPlatform.macOS,
            TargetPlatform.windows,
          ].contains(defaultTargetPlatform);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Documents & scans',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'Import a PDF with the file picker, drag it here, or share it to Lifenizer. Searchable text and scanned pages are indexed and saved encrypted.',
          ),
          if (desktop) ...[
            const SizedBox(height: 8),
            const Text(
              'Watch selected folders for PDFs, PNGs and JPEG scans up to 25 MiB. Includes existing files and updates, checks every 5 minutes while unlocked, and stays within each selected folder.',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: enabled ? () => _folder() : null,
                  child: const Text('Watch scan/PDF folder'),
                ),
                if (folders.downloadsPath != null)
                  OutlinedButton(
                    onPressed: enabled
                        ? () => _folder(folders.downloadsPath)
                        : null,
                    child: const Text('Index Downloads PDFs'),
                  ),
                if (folders.folders.isNotEmpty)
                  TextButton(
                    onPressed: enabled ? folders.check : null,
                    child: const Text('Check folders now'),
                  ),
              ],
            ),
            for (final folder in folders.folders)
              Row(
                children: [
                  Expanded(child: Text(folder)),
                  IconButton(
                    onPressed: enabled
                        ? () => folders.removeFolder(folder)
                        : null,
                    tooltip: 'Stop watching folder',
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            if (folders.working) const LinearProgressIndicator(),
            if (folders.status != null) Text(folders.status!),
            if (folders.error != null)
              Text(
                folders.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
          const SizedBox(height: 16),
          Text(
            'Connect Paperless',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (_settings != null)
            Text(
              _settings!['configured'] == true
                  ? '${_settings!['baseUrl']}'
                  : 'The server administrator must configure a Paperless address.',
            ),
          const Text(
            'Your server administrator configures the Paperless address. Enter its API token to index document text, including scans already recognized by Paperless.',
          ),
          TextField(
            controller: _token,
            enabled: enabled,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Paperless API token'),
          ),
          if (!kIsWeb)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Remember on this device'),
              subtitle: const Text(
                'Saved in the OS credential store. Checks for updates every 5 minutes while unlocked.',
              ),
              value: _remember,
              onChanged: enabled
                  ? (value) => setState(() => _remember = value!)
                  : null,
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: enabled && _settings?['configured'] == true
                    ? _connect
                    : null,
                child: const Text('Connect & index'),
              ),
              if (service.connected)
                OutlinedButton(
                  onPressed: enabled ? service.fetch : null,
                  child: const Text('Check Paperless now'),
                ),
              if (service.connected || service.error != null)
                TextButton(
                  onPressed: enabled ? service.removeAccount : null,
                  child: const Text('Stop & remove connection'),
                ),
            ],
          ),
          if (service.working) const LinearProgressIndicator(),
          if (service.status != null) Text(service.status!),
          if (service.error != null || _error != null)
            Text(
              service.error ?? _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      );
    },
  );
}
