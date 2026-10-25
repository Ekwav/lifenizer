import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/camera_roll_watch_service.dart';

/// Imports panel for automatic camera photo import (OCR + optional image copy).
class CameraPhotosPanel extends StatefulWidget {
  const CameraPhotosPanel({required this.state, super.key});
  final LifenizerAppState state;

  @override
  State<CameraPhotosPanel> createState() => _CameraPhotosPanelState();
}

class _CameraPhotosPanelState extends State<CameraPhotosPanel> {
  bool _includeLastWeek = false;
  String? _error;

  CameraRollWatchService get _service => widget.state.cameraRoll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _service.start();
    });
  }

  Future<void> _toggle(bool value) async {
    setState(() => _error = null);
    try {
      await _service.setEnabled(value, includeLastWeek: _includeLastWeek);
    } catch (exception) {
      if (mounted) setState(() => _error = '$exception');
    }
  }

  Future<void> _chooseFolder() async {
    try {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose the folder your camera photos sync to',
      );
      if (path == null || !mounted) return;
      setState(() => _error = null);
      await _service.addFolder(path);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not watch this folder. Choose an existing folder and '
              'unlock the vault.',
        );
      }
    }
  }

  String _permissionLabel(CameraPermission permission) => switch (permission) {
    CameraPermission.granted => 'Photo access granted',
    CameraPermission.denied => 'Photo access denied',
    CameraPermission.notNeeded => 'No permission needed',
    CameraPermission.unknown => 'Photo access not requested yet',
  };

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.state, _service]),
    builder: (context, _) {
      final theme = Theme.of(context);
      final ready = widget.state.isAuthenticated && !_service.working;
      final lastCheck = _service.lastCheck;
      return Card(
        key: const Key('camera-photos-panel'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Camera photos', style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Photos are read for text (OCR) on your server and saved as '
                'searchable, encrypted conversations. Import happens only '
                'while Lifenizer is open and unlocked: when you open the app, '
                'and every 10 minutes while it stays in the foreground. '
                'There is no background service, so photos taken while the '
                'app is closed are imported the next time you open it.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (!_service.supported)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Automatic photo imports require the Android or desktop app.',
                  ),
                )
              else ...[
                SwitchListTile(
                  key: const Key('camera-auto-import'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Auto-import camera photos'),
                  value: _service.enabled,
                  onChanged: ready ? _toggle : null,
                ),
                if (!_service.enabled)
                  CheckboxListTile(
                    key: const Key('camera-last-week'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Also import photos from the last 7 days',
                    ),
                    subtitle: const Text(
                      'Otherwise only photos taken after you turn this on are imported.',
                    ),
                    value: _includeLastWeek,
                    onChanged: ready
                        ? (value) =>
                              setState(() => _includeLastWeek = value ?? false)
                        : null,
                  ),
                CheckboxListTile(
                  key: const Key('camera-keep-in-vault'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Keep photo in vault'),
                  subtitle: const Text(
                    'Also stores a compressed, encrypted copy in the conversation '
                    'gallery. Uses your storage quota; if it is full, only the '
                    'text is imported.',
                  ),
                  value: _service.keepInVault,
                  onChanged: ready
                      ? (value) => _service.setKeepInVault(value ?? true)
                      : null,
                ),
                if (_service.needsFolderChoice) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: ready ? _chooseFolder : null,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Choose camera folder'),
                      ),
                    ],
                  ),
                  for (final folder in _service.folders)
                    Row(
                      children: [
                        Expanded(child: Text(folder)),
                        IconButton(
                          tooltip: 'Stop watching folder',
                          onPressed: ready
                              ? () => _service.removeFolder(folder)
                              : null,
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                ] else
                  const Text('Folder: DCIM/Camera on this device'),
                const SizedBox(height: 4),
                Text(_permissionLabel(_service.permission)),
                Text(
                  lastCheck == null
                      ? 'Not checked yet'
                      : 'Last check: ${lastCheck.toLocal().toString().split('.').first}',
                ),
                Text(
                  'Imported ${_service.imported} · skipped ${_service.skipped} '
                  '(over 25 MiB) · failed ${_service.failed}',
                ),
                if (_service.working) const LinearProgressIndicator(),
                if (_service.status != null) Text(_service.status!),
                if (_service.vaultNote != null)
                  Text(
                    _service.vaultNote!,
                    key: const Key('camera-vault-note'),
                    style: TextStyle(color: theme.colorScheme.tertiary),
                  ),
                if (_service.enabled)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: ready
                          ? () => unawaited(_service.check())
                          : null,
                      child: const Text('Check now'),
                    ),
                  ),
                for (final message in [_service.error, _error])
                  if (message != null)
                    Text(
                      message,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
              ],
            ],
          ),
        ),
      );
    },
  );
}
