import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/export_file_reader.dart';
import '../services/source_links.dart';

Future<void> showTranscriptionCorrection(
  BuildContext context,
  LifenizerAppState state,
  Conversation conversation,
  ConversationSegment segment,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => TranscriptionCorrectionDialog(
    state: state,
    conversation: conversation,
    segment: segment,
  ),
);

/// Explicit speech contributions; a failed request leaves the correction editable.
class TranscriptionCorrectionDialog extends StatefulWidget {
  const TranscriptionCorrectionDialog({
    required this.state,
    required this.conversation,
    required this.segment,
    super.key,
  });
  final LifenizerAppState state;
  final Conversation conversation;
  final ConversationSegment segment;

  @override
  State<TranscriptionCorrectionDialog> createState() =>
      _TranscriptionCorrectionDialogState();
}

class _TranscriptionCorrectionDialogState
    extends State<TranscriptionCorrectionDialog> {
  late final _text = TextEditingController(text: widget.segment.text);
  Map<String, dynamic>? _notice;
  Map<String, dynamic>? _consent;
  List<int>? _audio;
  String? _audioName;
  String? _error;
  bool _ownVoice = false;
  bool _acceptTerms = false;
  bool _working = false;
  bool _loading = true;

  Iterable<Map> get _receipts =>
      (_consent?['receipts'] as List? ?? const []).whereType<Map>();
  bool get _canWithdraw =>
      _receipts.any((receipt) => ((receipt['purposes'] as int? ?? 0) & 4) != 0);
  bool get _hasConsent {
    final receipt = _receipts.lastOrNull;
    return receipt != null &&
        receipt['version'] == _version &&
        ((receipt['purposes'] as int? ?? 0) & 4) != 0;
  }

  String get _version => _notice?['version'] as String? ?? '';
  Map? get _trainingPurpose => (_notice?['purposes'] as List? ?? const [])
      .whereType<Map>()
      .where((purpose) => purpose['value'] == 4)
      .firstOrNull;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final values = await Future.wait([
        widget.state.tabTrainingNotice(),
        widget.state.tabTrainingConsent(),
      ]);
      if (!mounted) return;
      setState(() {
        _notice = values[0];
        _consent = values[1];
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not load the current TAB training notice. Retry before contributing.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _attach() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['wav'],
        withReadStream: true,
      );
      if (picked == null || !mounted) return;
      final file = picked.files.single;
      if (!file.name.toLowerCase().endsWith('.wav')) {
        throw const FormatException('Choose the original WAV recording.');
      }
      final bytes = await readExportBytes(file);
      if (!mounted) return;
      setState(() {
        _audio = bytes;
        _audioName = file.name;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Choose the original WAV recording, up to 64 MiB. Only the selected sentence will be sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _submit() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final accepted = await widget.state.submitTranscriptionCorrection(
        conversation: widget.conversation,
        segment: widget.segment,
        correctedText: _text.text.trim(),
        acceptTerms: _acceptTerms,
        consentVersion: _version,
        audioOverride: _audio,
      );
      if (!mounted) return;
      if (accepted) {
        Navigator.of(context).pop();
      } else {
        final consent = await widget.state.tabTrainingConsent();
        if (!mounted) return;
        setState(() {
          _consent = consent;
          _error =
              widget.state.error ??
              'TAB could not accept this correction. Your text is kept here for retry.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'TAB could not accept this correction. Your text is kept here for retry.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _withdraw() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final withdrawn = await widget.state.withdrawTabTrainingConsent();
      if (!mounted) return;
      if (withdrawn) {
        setState(() {
          _consent = null;
          _acceptTerms = false;
        });
      } else {
        setState(
          () => _error =
              widget.state.error ??
              'Could not withdraw TAB training consent. Retry withdrawal.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not withdraw TAB training consent. Retry withdrawal.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _link(String link) async {
    if (!await openExternalLink(link) && mounted) {
      setState(() => _error = 'Could not open this link in another app.');
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _audio = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final changed =
        _text.text.trim().isNotEmpty &&
        _text.text.trim() != widget.segment.text.trim();
    final enabled =
        !_loading &&
        !_working &&
        _version.isNotEmpty &&
        _trainingPurpose != null &&
        _ownVoice &&
        (_hasConsent || _acceptTerms) &&
        changed;
    return PopScope(
      canPop: !_working,
      child: AlertDialog(
        title: const Text('Correct this sentence for TAB'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Only this sentence’s audio clip and corrected text are sent to TAB for validation and speech-recognition training. Contributions are anonymous; no email is required.',
                ),
                const SizedBox(height: 12),
                const Text('Original transcription'),
                SelectableText(widget.segment.text),
                const SizedBox(height: 12),
                TextField(
                  controller: _text,
                  enabled: !_working,
                  minLines: 2,
                  maxLines: 6,
                  maxLength: 10000,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Corrected sentence',
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: !_working ? _attach : null,
                  icon: const Icon(Icons.audio_file),
                  label: const Text('Attach original WAV'),
                ),
                Text(
                  _audioName == null
                      ? 'The app uses the original recording saved on this device. For older imports or another device, attach the original WAV; the app extracts only this sentence.'
                      : 'Original recording attached: $_audioName · only this sentence will be sent.',
                ),
                if (_loading) const LinearProgressIndicator(),
                if (_notice != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    'TAB training notice · $_version',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  if (_notice!['information'] is String)
                    SelectableText(_notice!['information'] as String),
                  const SizedBox(height: 8),
                  if (_notice!['terms'] is String)
                    SelectableText(_notice!['terms'] as String),
                  if (_trainingPurpose != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${_trainingPurpose!['title']}',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text('${_trainingPurpose!['description']}'),
                  ],
                  Wrap(
                    spacing: 8,
                    children: [
                      if (_notice!['privacyUrl'] is String &&
                          externalLinkUri(_notice!['privacyUrl'] as String) !=
                              null)
                        TextButton(
                          onPressed: () =>
                              _link(_notice!['privacyUrl'] as String),
                          child: const Text('Privacy notice'),
                        ),
                    ],
                  ),
                ],
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _ownVoice,
                  onChanged: !_working
                      ? (value) => setState(() => _ownVoice = value!)
                      : null,
                  title: const Text(
                    'This is my own voice and this sentence contains no confidential information.',
                  ),
                ),
                if (!_hasConsent)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _acceptTerms,
                    onChanged: !_working && _notice != null
                        ? (value) => setState(() => _acceptTerms = value!)
                        : null,
                    title: const Text(
                      'I accept the current TAB notice and consent to Coflnet speech-recognition training for my contributions.',
                    ),
                  ),
                if (_canWithdraw)
                  TextButton(
                    onPressed: !_working ? _withdraw : null,
                    child: const Text('Withdraw TAB training consent'),
                  ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_notice == null && !_loading)
                  TextButton(
                    onPressed: _load,
                    child: const Text('Retry notice'),
                  ),
                if (_working) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: !_working ? () => Navigator.of(context).pop() : null,
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: enabled ? _submit : null,
            child: const Text('Submit correction'),
          ),
        ],
      ),
    );
  }
}
